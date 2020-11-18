#! /usr/bin/perl -w

# This is free software, you may use it and distribute it under the same terms as
# Perl itself.
#
# Copyright (C) 2019-2020 Thomas More (tmore1@gmx.com)
#
# sms-db comes with ABSOLUTELY NO WARRANTY
# sms-db is available at https://github.com/tmo1/sms-db
# sms-db is documented in its README.md

use Getopt::Std;

use XML::LibXML '1.70';
#use Text::CSV;
use DBI;
use DBD::SQLite::Constants qw/:extended_result_codes/;

use Try::Tiny;
use Time::HiRes qw(gettimeofday tv_interval);
use Encode;
use Digest::SHA qw(sha256_hex);

use Data::Dump;

use strict;

my ($program_version, $database_version) = (0.1, 1.0);

# configuration

my %opts;
getopts('d:i:o:f:', \%opts);

my $database = $opts{'d'} // "sms.db";
unless (defined $opts{'f'}) {die "A format must be specified via '-f format'\n"}

# constant definitions

my ($XML, $BUGLE) = (0, 1);
my @message_fields = ('timestamp', 'sender_address', 'sender_name', 'recipient_address', 'recipient_name', 'msg_box', 'source_format');

# open / create database

my $dbh = DBI->connect("dbi:SQLite:$database", undef, undef, {RaiseError => 1, PrintError => 0, AutoCommit => 0, sqlite_extended_result_codes => 1});
unless ($dbh->tables(undef, undef, 'messages', 'TABLE')) {
	$dbh->do("CREATE TABLE messages(_id INTEGER PRIMARY KEY AUTOINCREMENT,timestamp INT,sender_address TEXT,sender_name TEXT,recipient_address TEXT,recipient_name TEXT,msg_box INT,source_format INT,hash INT UNIQUE)");
}
unless ($dbh->tables(undef, undef, 'parts', 'TABLE')) {
	$dbh->do("CREATE TABLE parts(_id INTEGER PRIMARY KEY AUTOINCREMENT,message_id INT,data TEXT,content_type TEXT,FOREIGN KEY (message_id) REFERENCES messages(_id) ON DELETE CASCADE)");
	# this is a simplified version of the bugle 'parts' table, whose CREATE statement is:
	# CREATE TABLE parts(_id INTEGER PRIMARY KEY AUTOINCREMENT,message_id INT,text TEXT,uri TEXT,content_type TEXT,width INT DEFAULT(-1),height INT DEFAULT(-1),timestamp INT, conversation_id INT NOT NULL,FOREIGN KEY (message_id) REFERENCES messages(_id) ON DELETE CASCADE FOREIGN KEY (conversation_id) REFERENCES conversations(_id) ON DELETE CASCADE )
}
$dbh->do("PRAGMA user_version = $database_version");
my $message_sth = $dbh->prepare("INSERT INTO messages(" . join(',', (@message_fields, 'hash')) . ") VALUES(" . join(',', (('?') x ($#message_fields + 2))) . ")");
my $part_sth = $dbh->prepare("INSERT INTO parts(message_id,data,content_type) VALUES(?,?,?)");
my ($total_messages, $inserted_messages, $duplicate_messages, $ignored_messages, $total_parts, $start_time) = (0, 0, 0, 0, 0, [gettimeofday]);

if (defined $opts{'i'}) {
	print "Importing messages from '$opts{'i'}' ...\n";
	if ($opts{'f'} eq 'xml') {
		my $dom = XML::LibXML->load_xml(location => $opts{'i'});
		foreach my $element ($dom->documentElement->getElementsByTagName('sms')) {
			my %message = (source_format => $XML, timestamp => $element->getAttribute('date'));
			$message{'msg_box'} = $element->getAttribute('type');
			# we use 'msg_box' for consistency between SMS and MMS, even though SMS Backup and Restore (and perhaps Android itself?) uses 'type' here
			($message{'sender_address'}, $message{'sender_name'}, $message{'recipient_address'}, $message{'recipient_name'}) = ($message{'msg_box'} eq 1) ? ($element->getAttribute('address'), $element->getAttribute('contact_name'), '<SELF>', '<SELF>') : ('<SELF>', '<SELF>', $element->getAttribute('address'), $element->getAttribute('contact_name'));
			my @parts;
			push @parts, {data => $element->getAttribute('body'), content_type => 'text/plain'};
			insert(\%message, \@parts);
		}
		foreach my $element ($dom->documentElement->getElementsByTagName('mms')) {
			my %message = (source_format => $XML, timestamp => $element->getAttribute('date'));
			$message{'msg_box'} = $element->getAttribute('msg_box');
			($message{'sender_address'}, $message{'sender_name'}, $message{'recipient_address'}, $message{'recipient_name'}) = ($message{'msg_box'} eq '1') ? ($element->getAttribute('address'), $element->getAttribute('contact_name'), '<SELF>', '<SELF>') : ('<SELF>', '<SELF>', $element->getAttribute('address'), $element->getAttribute('contact_name'));
			foreach ($element->getElementsByTagName('addr')) {
				my $type = $_->getAttribute('type');
				if ($type eq '151' or $type eq '129' or $type eq '130') {$message{'recipient_address'} = defined $message{'recipient_address'} ? $message{'recipient_address'} . ',' . $_->getAttribute('address') : $_->getAttribute('address')}
			}
			my @parts;
			foreach my $part ($element->getElementsByTagName('part')) {
				my ($text, $data, $body) = ($part->getAttribute('text'), $part->getAttribute('data'));
				push @parts, {data => ((defined $data and $text eq "null") ? $data : $text), content_type => $part->getAttribute('ct')};
			}
			insert(\%message, \@parts);
		}
	}
	
	elsif ($opts{'f'} eq 'bugle') {
		my $bugle = DBI->connect("dbi:SQLite:$opts{'i'}", undef, undef, {RaiseError => 1, PrintError => 0, AutoCommit => 0, sqlite_extended_result_codes => 1});
		my @messages = $bugle->selectall_array("SELECT messages._id,received_timestamp,sender_info.normalized_destination,sender_info.full_name,participant_normalized_destination,participant_count,name,sub_id FROM messages INNER JOIN participants sender_info ON messages.sender_id = sender_info._id INNER JOIN conversations ON messages.conversation_id = conversations._id", {Slice => {}});
		# we use received_timestamp instead of sent_timestamp, since for some reason the latter is often '0', while the former seems to always have a real value
		my $message_parts_sth = $bugle->prepare("SELECT text,uri,content_type FROM parts WHERE message_id = ?");
		foreach (@messages) {
			my %message = (source_format => $BUGLE, sender_address => $_->{'normalized_destination'}, sender_name => $_->{'full_name'} // "<UNAVAILABLE>", timestamp => $_->{'received_timestamp'});
			($message{'recipient_address'}, $message{'recipient_name'}, $message{'msg_box'}) = ($_->{sub_id} eq '-2') ? ('<SELF>', '<SELF>', 1) : ($_->{'participant_normalized_destination'}, $_->{'name'}, 2);
			if ($_->{participant_count} > 1 && not defined $_->{'participant_normalized_destination'}) {$message{'recipient_address'} = "<$_->{participant_count}>"};
			my @parts = $bugle->selectall_array($message_parts_sth, {Slice => {}}, $_->{_id});
			foreach (@parts) {$_->{data} = (defined $_->{text}) ? $_->{text} : "<$_->{uri}>"}
			insert(\%message, \@parts);
		}
		$bugle->disconnect;
	}
	else {die "Unknown format '$opts{'f'}'\n"}
	$dbh->commit;
	print "Ignored messages:\t$ignored_messages\nTotal messages:\t\t$total_messages\nInserted messages:\t$inserted_messages\nDuplicate messages:\t$duplicate_messages\nTotal parts:\t\t$total_parts\nElapsed time:\t\t", tv_interval($start_time), " seconds\n\n";
}
elsif (defined $opts{'o'}) {
	die "Output ('-o') is not yet implemented.\n";
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
		$part_sth->execute($message_id, $_->{'data'}, $_->{'content_type'}); 
		$total_parts++;
	}
}