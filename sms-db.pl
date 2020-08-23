#! /usr/bin/perl -w

# Copyright (C) 2019-2020 Thomas More (tmore1@gmx.com)
# sms-db is free software, released under the terms of the Perl Artistic
# License, contained in the included file 'License'
# sms-db comes with ABSOLUTELY NO WARRANTY
# sms-db is available at ***
# sms-db is documented in its *** and its sample config file, 'sms-db.config'

use ConfigReader::Simple;
use Getopt::Std;

use XML::LibXML '1.70';

use DBI;
use DBD::SQLite::Constants qw/:extended_result_codes/;

#use Text::CSV;

use Try::Tiny;
use Time::HiRes qw(gettimeofday tv_interval);

#use Data::Dump;

use strict;

# configuration

my %opts;
getopts('c:d:f:t:', \%opts);
$opts{'c'} //= "sms-db.config";
#$opts{'c'} //= "$ENV{'HOME'}/sms-db.config";

my $config = ConfigReader::Simple->new($opts{'c'}, ['tag']);

my $database = $opts{'d'} // $config->get('database') // "sms.db";
my $file = $opts{'f'} // $config->get('file');
unless (defined $file) {die "No input file specified - aborting.\n"}
my $type = $opts{'t'} // $config->get('type') // 'xml';
my @fields = ('sender_address', 'sender_name', 'recipient_address', 'recipient_name', 'direction', 'timestamp', 'body');
my @unique = ('sender_address', 'recipient_address', 'timestamp', 'body');
my ($XML, $BUGLE, $INCOMING, $OUTGOING) = (0, 1, 1, 2);

# open / create database

my $dbh = DBI->connect("dbi:SQLite:$database", undef, undef, {RaiseError => 1, PrintError => 0, AutoCommit => 0, sqlite_extended_result_codes => 1});
unless ($dbh->tables(undef, undef, 'sms', 'TABLE')) {
	my $table_creation = "CREATE TABLE sms(_id INTEGER PRIMARY KEY AUTOINCREMENT, ";
	foreach (@fields) {$table_creation .= "$_ TEXT, "} # we currently treat all fields as TEXT, although this may change
	$table_creation .= "source INTEGER, UNIQUE(" . (join ', ', @unique) . "))";
	#print $table_creation, "\n";
	$dbh->do($table_creation);
}

my $sth = $dbh->prepare("INSERT INTO sms(" . (join ',', @fields) . ", source) VALUES (?" . (",?" x ($#fields + 1)) . ")");
my ($total_records, $inserted_records, $duplicate_records, $ignored_records, $start_time) = (0, 0, 0, 0, [gettimeofday]);

if ($type eq 'xml') {
	open (my $fh, "< $file") or die "Can't open $file: $!";
	my $dom = XML::LibXML->load_xml(IO => $fh);
	foreach my $element ($dom->documentElement->getElementsByTagName('sms')) {
		my %sms = (timestamp => $element->getAttribute('date'), body => $element->getAttribute('body'));
		#my %sms = (sender_address => $element->getAttribute('address'), sender_name => $element->getAttribute('contact_name'), timestamp => $element->getAttribute('date'), body => $element->getAttribute('body'));
		($sms{'sender_address'}, $sms{'sender_name'}, $sms{'recipient_address'}, $sms{'recipient_name'}, $sms{'direction'}) = ($element->getAttribute('type') eq '1') ? ($element->getAttribute('address'), $element->getAttribute('contact_name'), '<SELF>', '<SELF>', $INCOMING) : ('<SELF>', '<SELF>', $element->getAttribute('address'), $element->getAttribute('contact_name'), $OUTGOING);
		insert(\%sms, $XML);
	}
}

elsif ($type eq 'bugle') {
	my $bugle = DBI->connect("dbi:SQLite:$file", undef, undef, {RaiseError => 1, PrintError => 0, AutoCommit => 0, sqlite_extended_result_codes => 1});
	my @messages = $bugle->selectall_array("SELECT text,timestamp,sender_info.normalized_destination,sender_info.full_name,participant_normalized_destination,participant_count,name,sub_id FROM parts INNER JOIN messages ON parts.message_id = messages._id INNER JOIN participants sender_info ON messages.sender_id = sender_info._id INNER JOIN conversations ON messages.conversation_id = conversations._id", {Slice => {}});
	$bugle->disconnect;
	#foreach (@messages) {print $_->{text}, "\n"}
	#dd @messages;
	foreach (@messages) {
		#dd $_;
		if (not defined $_->{'text'}) {$ignored_records++; next}; # it's an MMS non text part, and we don't handle those yet
		my %sms = (sender_address => $_->{'normalized_destination'}, sender_name => $_->{'full_name'}, timestamp => $_->{'timestamp'}, body => $_->{'text'});
		($sms{'recipient_address'}, $sms{'recipient_name'}, $sms{'direction'}) = ($_->{sub_id} eq '-2') ? ('<SELF>', '<SELF>', $INCOMING) : ($_->{'participant_normalized_destination'}, $_->{'name'}, $OUTGOING);
		if ($_->{participant_count} > 1 && not defined $_->{'participant_normalized_destination'}) {$sms{'recipient_address'} = "<$_->{participant_count}>"}
		insert(\%sms, $BUGLE);
		#dd %sms;
	}
	#my @messages = $bugle->selectall_array("SELECT text,timestamp,sender_info.normalized_destination,sender_info.full_name,recipient_info.normalized_destination,recipient_info.full_name,name,participant_normalized_destination FROM parts INNER JOIN messages ON parts.message_id = messages._id INNER JOIN participants sender_info ON messages.sender_id = sender_info._id INNER JOIN participants recipient_info ON messages.self_id = recipient_info._id INNER JOIN conversations ON messages.conversation_id = conversations._id");
	#my @messages = $bugle->selectall_array("SELECT text,timestamp,sent_timestamp,received_timestamp,normalized_destination,full_name,name,participant_normalized_destination FROM parts INNER JOIN messages ON parts.message_id = messages._id INNER JOIN participants ON messages.sender_id = participants._id INNER JOIN conversations ON messages.conversation_id = conversations._id");
	#foreach (@messages) {insert( $XML)}
	#foreach (@parts) {
	#	my @messages = $bugle->selectall_array("SELECT message_id,text,timestamp FROM messages WHERE");
	#}
}

$dbh->commit;
print "Ignored records:\t$ignored_records\nTotal records:\t\t$total_records\nInserted records:\t$inserted_records\nDuplicate records:\t$duplicate_records\nElapsed time:\t\t", tv_interval($start_time), " seconds\n";

sub insert {
	my ($sms, $type) = @_;
	try {$sth->execute((map (${$sms}{$_}, @fields)), $type); $inserted_records++;} catch {
		if ($dbh->err eq SQLITE_CONSTRAINT_UNIQUE) {$duplicate_records++; return;}
		warn "caught error: $_";
	};
	$total_records++;
}
