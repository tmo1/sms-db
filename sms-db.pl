#! /usr/bin/perl -w

# This is free software, you may use it and distribute it under the same
# terms as Perl itself.
#
# Copyright (C) 2019-2021 Thomas More (tmore1@gmx.com)
#
# sms-db comes with ABSOLUTELY NO WARRANTY
# sms-db is available at https://github.com/tmo1/sms-db
# sms-db is documented in its README.md

use Getopt::Std;
use XML::LibXML '1.70';
use DBI;
use DBD::SQLite::Constants qw(:extended_result_codes);
use Try::Tiny;
use Time::HiRes qw(gettimeofday tv_interval);
use Encode;
use MIME::Base64;
use Digest::SHA qw(sha256_hex);
use Data::Dump;

use strict;

# configuration

my %opts;
getopts('d:i:o:f:t:', \%opts);

$opts{'d'} //= "sms-db.db";
$opts{'t'} //= 'all';
unless (defined $opts{'f'}) {die "A format must be specified via '-f format'\n"}

# constant definitions

my ($XML, $BUGLE, $SIGNAL) = (0, 1, 2);
my ($SMS, $MMS) = (0,1); # these are the values that the Bugle database seems to use in the 'message_protocal' column of the 'messages' table
my ($PROGRAM_VERSION, $DATABASE_VERSION) = ("0.3", 2);
my @message_fields = ('timestamp', 'sender_address', 'sender_name', 'recipient_address', 'recipient_name', 'msg_box', 'message_type', 'source_format');

# start

print "sms-db version $PROGRAM_VERSION\n";

# open / create database

my $dbh = DBI->connect("dbi:SQLite:$opts{'d'}", undef, undef, {RaiseError => 1, PrintError => 0, AutoCommit => 0, sqlite_extended_result_codes => 1});
unless ($dbh->tables(undef, undef, 'messages', 'TABLE')) {
	$dbh->do("CREATE TABLE messages(_id INTEGER PRIMARY KEY AUTOINCREMENT,timestamp INT,sender_address TEXT,sender_name TEXT,recipient_address TEXT,recipient_name TEXT,msg_box INT,message_type INT,source_format INT,hash INT UNIQUE)");
	$dbh->do("PRAGMA user_version = $DATABASE_VERSION");
}
unless ($dbh->tables(undef, undef, 'parts', 'TABLE')) {
	$dbh->do("CREATE TABLE parts(_id INTEGER PRIMARY KEY AUTOINCREMENT,message_id INT,data BLOB,content_type TEXT,filename TEXT,FOREIGN KEY (message_id) REFERENCES messages(_id) ON DELETE CASCADE)");
	# this is a simplified version of the bugle 'parts' table, whose CREATE statement is:
	# CREATE TABLE parts(_id INTEGER PRIMARY KEY AUTOINCREMENT,message_id INT,text TEXT,uri TEXT,content_type TEXT,width INT DEFAULT(-1),height INT DEFAULT(-1),timestamp INT, conversation_id INT NOT NULL,FOREIGN KEY (message_id) REFERENCES messages(_id) ON DELETE CASCADE FOREIGN KEY (conversation_id) REFERENCES conversations(_id) ON DELETE CASCADE )
}
my $message_sth = $dbh->prepare("INSERT INTO messages(" . join(',', (@message_fields, 'hash')) . ") VALUES(" . join(',', (('?') x ($#message_fields + 2))) . ")");
my $part_sth = $dbh->prepare("INSERT INTO parts(message_id,data,content_type,filename) VALUES(?,?,?,?)");
my ($total_messages, $inserted_messages, $duplicate_messages, $ignored_messages, $total_parts, $start_time) = (0, 0, 0, 0, 0, [gettimeofday]);

if (defined $opts{'i'}) {
	print "Importing messages from '$opts{'i'}' ...\n";
	if ($opts{'f'} eq 'xml') {
		my $dom = XML::LibXML->load_xml(location => $opts{'i'});
		if ($opts{'t'} eq 'sms' or $opts{'t'} eq 'all') {
			foreach my $element ($dom->documentElement->getElementsByTagName('sms')) {
				my %message = (source_format => $XML, timestamp => $element->getAttribute('date'), message_type => $SMS);
				$message{'msg_box'} = $element->getAttribute('type');
				# we use 'msg_box' for consistency between SMS and MMS, even though SMS Backup and Restore (and perhaps Android itself?) uses 'type' here
				($message{'sender_address'}, $message{'sender_name'}, $message{'recipient_address'}, $message{'recipient_name'}) = ($message{'msg_box'} eq 1) ? ($element->getAttribute('address'), $element->getAttribute('contact_name'), '<SELF>', '<SELF>') : ('<SELF>', '<SELF>', $element->getAttribute('address'), $element->getAttribute('contact_name'));
				my @parts;
				push @parts, {data => $element->getAttribute('body'), content_type => 'text/plain'};
				insert(\%message, \@parts);
			}
		}
		if ($opts{'t'} eq 'mms' or $opts{'t'} eq 'all') {
			foreach my $element ($dom->documentElement->getElementsByTagName('mms')) {
				my %message = (source_format => $XML, timestamp => $element->getAttribute('date'), message_type => $MMS);
				$message{'msg_box'} = $element->getAttribute('msg_box');
				($message{'sender_address'}, $message{'sender_name'}, $message{'recipient_address'}, $message{'recipient_name'}) = ($message{'msg_box'} eq '1') ? ($element->getAttribute('address'), $element->getAttribute('contact_name'), undef, '<SELF>') : ('<SELF>', '<SELF>', $element->getAttribute('address'), $element->getAttribute('contact_name'));
				foreach ($element->getElementsByTagName('addr')) {
					my $type = $_->getAttribute('type');
					if ($type eq '151' or $type eq '129' or $type eq '130') {$message{'recipient_address'} = defined $message{'recipient_address'} ? $message{'recipient_address'} . ',' . $_->getAttribute('address') : $_->getAttribute('address')}
				}
				my @parts;
				foreach my $part ($element->getElementsByTagName('part')) {
					my ($text, $data, $body) = ($part->getAttribute('text'), $part->getAttribute('data'));
					push @parts, {data => ((defined $data and $text eq "null") ? decode_base64($data) : $text), content_type => $part->getAttribute('ct'), filename => $part->getAttribute('name')};
				}
				insert(\%message, \@parts);
			}
		}
	}
	elsif ($opts{'f'} eq 'bugle') {
		my $bugle = DBI->connect("dbi:SQLite:$opts{'i'}", undef, undef, {RaiseError => 1, PrintError => 0, AutoCommit => 0, sqlite_extended_result_codes => 1});
		my $conversation_participants_sth = $bugle->prepare("SELECT participant_id FROM conversation_participants WHERE conversation_id = ?");
		my $participant_sth = $bugle->prepare("SELECT normalized_destination,full_name FROM participants WHERE _id = ?");
		my @messages = $bugle->selectall_array("SELECT messages._id,received_timestamp,message_protocol,sender_info.normalized_destination,sender_info.full_name,participant_normalized_destination,participant_count,name,sub_id,conversation_id FROM messages INNER JOIN participants sender_info ON messages.sender_id = sender_info._id INNER JOIN conversations ON messages.conversation_id = conversations._id", {Slice => {}});
		# we use received_timestamp instead of sent_timestamp, since for some reason the latter is often '0', while the former seems to always have a real value
		my $message_parts_sth = $bugle->prepare("SELECT text,uri,content_type FROM parts WHERE message_id = ?");
		foreach (@messages) {
			next if (($_->{'message_protocol'} eq 0 and $opts{'t'} ne 'sms' and $opts{'t'} ne 'all') or ($_->{'message_protocol'} eq 1 and $opts{'t'} ne 'mms' and $opts{'t'} ne 'all'));
			my %message = (source_format => $BUGLE, sender_address => $_->{'normalized_destination'}, sender_name => $_->{'full_name'} // "<UNAVAILABLE>", timestamp => $_->{'received_timestamp'}, message_type => $_->{'message_protocol'});
			($message{'recipient_address'}, $message{'recipient_name'}, $message{'msg_box'}) = ($_->{sub_id} eq '-2') ? ('<SELF>', '<SELF>', 1) : ($_->{'participant_normalized_destination'}, $_->{'name'}, 2);
			if ($_->{participant_count} > 1 && not defined $_->{'participant_normalized_destination'}) {
				foreach ($bugle->selectall_array($conversation_participants_sth, {}, $_->{'conversation_id'})) {
					#dd $_;
					my $participant = $bugle->selectrow_array($participant_sth, {}, ${$_}[0]);
					#dd $participant;
					$message{'recipient_address'} = defined $message{'recipient_address'} ? $message{'recipient_address'} . ',' . $participant : $participant;
				}
			}
			my @parts = $bugle->selectall_array($message_parts_sth, {Slice => {}}, $_->{_id});
			foreach (@parts) {$_->{data} = (defined $_->{text}) ? $_->{text} : "<$_->{uri}>"}
			insert(\%message, \@parts);
		}
		$bugle->disconnect;
	}
	elsif ($opts{'f'} eq 'signal') {
		my $signal = DBI->connect("dbi:SQLite:$opts{'i'}/signal_backup.db", undef, undef, {RaiseError => 1, PrintError => 0, AutoCommit => 0, sqlite_extended_result_codes => 1});
		my %message_types = (23 => 2, 87 => 2, 88 => 2, 10485783 => 2, 20 => 1, 10485780 => 1);
		# I'm not really sure what the message types all mean. I'm assuming, based on the contents of my Signal backup database, that the ones I've assigned to '2' are roughly equivalent to 'sent' and the ones I've assigned to '1' are roughly equivalent to 'received'. We use the Synctech XML 'type' / 'msg_box' field values (https://synctech.com.au/sms-backup-restore/fields-in-xml-backup-files/) internally to represent 'sent' and 'received'
		if ($opts{'t'} eq 'sms' or $opts{'t'} eq 'all') {
			my @smss = $signal->selectall_array("SELECT address,date,type,body,phone,system_display_name FROM sms INNER JOIN recipient ON sms.address = recipient._id", {Slice => {}});
			foreach (@smss) {
				my %message = (source_format => $SIGNAL, timestamp => $_->{date}, message_type => $SMS);
				unless (defined $message_types{$_->{type}}) {
					if ($_->{type} == 2097156) {
						# This is apparently a Signal-generated "Alice is on Signal!" message, so we're going to ignore it
						warn "Ignoring '$_->{system_display_name} is on Signal!' message\n";
					}
					else {
						warn "Unknown message type '$_->{type}' - ignoring message.\n";
						dd $_;
					}
					$total_messages++;
					$ignored_messages++;
					next;
				}
				($message{'msg_box'}, $message{'sender_address'}, $message{'sender_name'}, $message{'recipient_address'}, $message{'recipient_name'}) =
					($message_types{$_->{type}} eq 2) ? (2, "<SELF>", "<SELF>", $_->{phone}, $_->{system_display_name} // "<UNAVAILABLE>") : (1, $_->{phone}, $_->{system_display_name} // "<UNAVAILABLE>", "<SELF>", "<SELF>");
				my @parts;
				push @parts, {data => $_->{body}, content_type => 'text/plain'};
				insert(\%message, \@parts);
			}
		}
		if ($opts{'t'} eq 'mms' or $opts{'t'} eq 'all') {
			my $group_sth = $signal->prepare("SELECT members FROM groups WHERE group_id = ?");
			my $member_sth = $signal->prepare("SELECT phone,system_display_name FROM recipient WHERE _id = ?");
			my $thread_sth = $signal->prepare("SELECT recipient_ids FROM thread WHERE _id = ?");
			my $recipient_sth = $signal->prepare("SELECT group_id FROM recipient WHERE _id = ?");
			unless (opendir(DIR, "$opts{'i'}/attachment")) {warn "Can't open '$opts{'i'}/attachment': $!"; next}
			my @attachment_filenames;
			unless (@attachment_filenames = readdir(DIR)) {warn "Can't read directory '$opts{'i'}/attachment': $!"; next}
			closedir (DIR);
			my @attachment_parts = $signal->selectall_array("SELECT mid,ct,file_name,unique_id FROM part", {Slice => {}});
			my @mmss = $signal->selectall_array("SELECT mms._id,thread_id,address,date,msg_box,body,phone,system_display_name,group_id FROM mms INNER JOIN recipient ON mms.address = recipient._id", {Slice => {}});
			foreach (@mmss) {
				my %message = (source_format => $SIGNAL, timestamp => $_->{date}, message_type => $MMS);
				unless (defined $message_types{$_->{msg_box}}) {
					warn "Unknown message type '$_->{msg_box}' - ignoring message.\n";
					dd $_;
					$total_messages++;
					$ignored_messages++;
					next;
				}
				if (defined $_->{group_id}) {
					my (@phones, @system_display_names);
					my $members = $signal->selectrow_array($group_sth, {}, $_->{group_id});
					foreach (split(/,/, $members)) {
						($phones[$#phones +1], $system_display_names[$#system_display_names + 1]) = $signal->selectrow_array($member_sth, {}, $_);
					}
					$_->{phone} = join(',', @phones);
					$_->{system_display_name} = join(',', @system_display_names);
				}
				($message{'msg_box'}, $message{'sender_address'}, $message{'sender_name'}, $message{'recipient_address'}, $message{'recipient_name'}) =
					($message_types{$_->{msg_box}} eq 2) ? (2, "<SELF>", "<SELF>", $_->{phone}, $_->{system_display_name} // "<UNAVAILABLE>") : (1, $_->{phone}, $_->{system_display_name} // "<UNAVAILABLE>", "<SELF>", "<SELF>");
				my $recipient_ids = $signal->selectrow_array($thread_sth, {}, $_->{thread_id});
				my $group_id = $signal->selectrow_array($recipient_sth, {}, $recipient_ids);
				my ($recipient_phones, $recipient_system_display_names);
				if (defined $group_id) {
					my (@phones, @system_display_names);
					my $members = $signal->selectrow_array($group_sth, {}, $group_id);
					foreach (split(/,/, $members)) {
						($phones[$#phones +1], $system_display_names[$#system_display_names + 1]) = $signal->selectrow_array($member_sth, {}, $_);
					}
					$recipient_phones = join(',', @phones);
					foreach (@system_display_names) {$_ //= "<UNAVAILABLE>"}
					$recipient_system_display_names = join(',', @system_display_names);
				}
				if (defined $recipient_phones) {$message{'recipient_address'} = $recipient_phones};
				if (defined $recipient_system_display_names) {$message{'recipient_name'} = $recipient_system_display_names};
				my $mid = $_->{_id};
				my @parts;
				if (defined $_->{body}) {push @parts, {data => $_->{body}, content_type => 'text/plain'}}
				foreach (@attachment_parts) {
					next unless ($_->{mid} eq $mid);
					my $unique_id = $_->{unique_id};	
					my $filename; # this will be the filename used in the backup to store the attachment data on disk, as opposed to the original filename of the attachment as stored in the 'file_name' column of the 'parts' table
					foreach (@attachment_filenames) {if (/^${unique_id}_.*$/) {$filename = $_; last}}
					unless (defined $filename) {warn "File not found for attachment with unique_id '$unique_id'\n"; next}
					unless (open (ATTACHMENT, '<', "$opts{'i'}/attachment/$filename")) {warn "Can't open '$filename': $!"; next}
					my $attachment = do {local $/; <ATTACHMENT>};
					close ATTACHMENT;
					push @parts, {data => $attachment, content_type => $_->{ct}, filename => $_->{file_name}};
				}
				#unless (@parts) {warn "Message has no parts - skipping.\n"; dd $_; $total_messages++; $ignored_messages++; next}
				insert(\%message, \@parts);
			}
		}
		$signal->disconnect;
	}
	else {die "Unknown format '$opts{'f'}'\n"}
	$dbh->commit;
	my $rows = $dbh->selectrow_array("SELECT COUNT(1) FROM messages");
	print "Total messages seen:\t\t$total_messages\nTotal messages imported:\t$inserted_messages\nDuplicate messages:\t\t$duplicate_messages\nIgnored messages:\t\t$ignored_messages\nTotal message parts imported:\t$total_parts\nMessages in database:\t\t$rows\nElapsed time:\t\t\t", tv_interval($start_time), " seconds\n\n";
}
elsif (defined $opts{'o'}) {
	print "Exporting messages to '$opts{'o'}' ...\n";
	my $doc = XML::LibXML->createDocument("1.0", "UTF-8");
	$doc->setStandalone(1);
	my $smses = $doc->createElement("smses");
	$doc->appendChild($doc->createComment("File Created By sms-db v$PROGRAM_VERSION on " . scalar localtime));
	if ($opts{'t'} eq 'sms' or $opts{'t'} eq 'all') {
		foreach ($dbh->selectall_array("SELECT _id,timestamp,sender_address,sender_name,recipient_address,recipient_name,msg_box FROM messages WHERE message_type = 0 ORDER BY timestamp", {Slice => {}})) {
			my $sms = $doc->createElement("sms");
			$sms->setAttribute("address", ($_->{'msg_box'} == 1) ? $_->{'sender_address'} : $_->{'recipient_address'});
			$sms->setAttribute("date", $_->{'timestamp'});
			$sms->setAttribute("type", $_->{'msg_box'});
			$sms->setAttribute("body", $dbh->selectrow_array("SELECT data FROM parts WHERE message_id = $_->{'_id'}"));
			$sms->setAttribute("read", "1"); # we don't currently store 'read' status, so we just set it to 1 = 'read'
			$sms->setAttribute("status", "-1"); # we don't currently store 'status', so we just set it to -1 = 'none'
			$smses->appendChild($sms);
			$total_messages++;
		}
	}
	if ($opts{'t'} eq 'mms' or $opts{'t'} eq 'all') {
		foreach ($dbh->selectall_array("SELECT _id,timestamp,sender_address,sender_name,recipient_address,recipient_name,msg_box FROM messages WHERE message_type = 1 ORDER BY timestamp", {Slice => {}})) {
			my $mms = $doc->createElement("mms");
			# I have no idea what many of the following attributes are, and they aren't all explained in Synctech's explanation of the fields (https://synctech.com.au/sms-backup-restore/fields-in-xml-backup-files/), but they're required by its XSD schema (https://synctech.com.au/wp-content/uploads/2018/01/sms.xsd_.txt), so we just set them all to 'null' or '0' :| Some actually are null in my Synctech backups. Obviously, MMS export to XML should be considered experimental
			$mms->setAttribute("date", $_->{'timestamp'});
			$mms->setAttribute("msg_box", $_->{'msg_box'});
			if ($_->{'msg_box'} == 1) {
				$mms->setAttribute("address", $_->{'sender_address'});
				$mms->setAttribute("contact_name", $_->{'sender_name'});
			}
			else {
				my @recipients = split (/,/, $_->{'recipient_address'});
				$mms->setAttribute("address", $recipients[0] =~ s/\D//g);
				$mms->setAttribute("contact_name", $_->{'recipient_name'});
			}
			foreach ("retr_st", "ct_cls", "sub_cs", "ct_l", "tr_id", "st", "m_cls", "d_tm", "read_status", "retr_txt_cs", "m_id", "ct_t", "exp", "resp_txt", "rpt_a", "retr_txt", "resp_st", "m_size") {$mms->setAttribute($_, "null")}
			my %attributes = (d_rpt => 0, read => 1, seen => 1, "date_sent" => 1, m_type => 0, v => 0, pri => 0, rr => 0, locked => 0);
			foreach (keys %attributes) {$mms->setAttribute($_, $attributes{$_})}
			my $parts = $doc->createElement('parts');
			foreach ($dbh->selectall_array("SELECT data,content_type,filename FROM parts WHERE message_id = $_->{'_id'}", {Slice => {}})) {
				my $part = $doc->createElement('part');
				$part->setAttribute("ct", $_->{'content_type'});
				$part->setAttribute("name", $_->{'filename'} // "null");
				if ($_->{'content_type'} =~ /^text\//) {$part->setAttribute("text", $_->{'data'})}
				else {
					$part->setAttribute("text", "null");
					$part->setAttribute("data", encode_base64($_->{'data'}));
				}
				my %attributes = (seq => 0, chset => "null", cd => "null", fn => "null", cid => "null", cl => "null", ctt_s => "null", ctt_t => "null");
				foreach (keys %attributes) {$part->setAttribute($_, $attributes{$_})}
				$parts->appendChild($part);
			}
			$mms->appendChild($parts);
			my $addrs = $doc->createElement('addrs');
			my $addr = $doc->createElement('addr');
			$addr->setAttribute('address', $_->{'sender_address'});
			$addr->setAttribute('type', 137);
			$addr->setAttribute('charset', 0);
			$addrs->appendChild($addr);
			my @addresses = split(/,/, $_->{'recipient_address'});
			foreach (@addresses) {
				$addr = $doc->createElement('addr');
				$addr->setAttribute('address', $_);
				$addr->setAttribute('type', 151);
				$addr->setAttribute('charset', 0);
				$addrs->appendChild($addr);
			}
			$mms->appendChild($addrs);
			$smses->appendChild($mms);
			$total_messages++;
		}
	}
	$smses->setAttribute('count', $total_messages);
	$doc->setDocumentElement($smses);
	#my $xmlschema = XML::LibXML::Schema->new(location => "sms.xsd_.txt");
	#$xmlschema->validate($doc);
	# Synctech's XSD (at https://synctech.com.au/wp-content/uploads/2018/01/sms.xsd_.txt) is apparently wrong or outdated - it doesn't accept the 'addrs' element that appears in actual Synctech backups!
	$doc->toFile($opts{'o'}, 1);
	print "Total messages exported:\t$total_messages\nElapsed time:\t\t\t", tv_interval($start_time), " seconds\n\n";
}
else {die "Either input ('-i filename') or output ('-o filename') must be specified.\n"}

# the end

sub insert {
	my ($message, $parts) = @_;
	my @record = map($message->{$_}, @message_fields);
	foreach (@record) {unless (defined $_) {warn "We have an undefined field!\n"; dd @record;}}
	unless (@record) {warn "We have a record with no elements!\n"; dd @record;}
	my $err;
	# we need to encode due to the fact that the digest algorithm works on bytes, not strings, and will croak if the string contains wide characters, as discussed in the Digest::SHA documentation
	try {$message_sth->execute(@record, sha256_hex(Encode::encode_utf8(join('', @record, map {($_->{'data'}, $_->{'content_type'})} @{$parts})))); $inserted_messages++;} catch {
	if ($dbh->err eq SQLITE_CONSTRAINT_UNIQUE) {
			$duplicate_messages++;
		}
		else {warn "caught error: $_"; dd $message, $parts;}
		$err = 1;
	};
	$total_messages++;
	return if $err;
	my $message_id = $dbh->last_insert_id;
	foreach (@{$parts}) {
		$part_sth->execute($message_id, $_->{'data'}, $_->{'content_type'}, $_->{'filename'}); 
		$total_parts++;
	}
}
