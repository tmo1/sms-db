# sms-db

sms-db is a tool to build an [SQLite](https://www.sqlite.org/index.html) database out of collections of SMS and MMS messages in various formats. The database can then be queried using standard SQLite queries. sms-db may eventually be able to export the messages in the database in various formats.

This README is for sms-db version 0.1, which uses the sms-db format 1.0.

## Design Goals

sms-db has several design goals:

- Providing message storage in a simple, standard, easily understandable format.

- Enabling the combination of messages from multiple sources into a single message store.

- Enabling the querying of message collections (via the SQLite framework).

- Enabling the output of messages in various formats, potentially allowing their import into other systems, including Android's internal message storage. [Not yet implemented.]

## Installation:

sms-db depends on the following Perl modules (Debian packages are in parentheses):

- [XML::LibXML](https://metacpan.org/pod/XML::LibXML) (libxml-libxml-perl)
- [DBD::SQLite](https://metacpan.org/pod/DBD::SQLite) (libdbd-sqlite3-perl)
- [Try::Tiny](https://metacpan.org/pod/Try::Tiny) (libtry-tiny-perl)
- [Encode](https://metacpan.org/pod/Encode) (libencode-perl)
- [Data::Dump](https://metacpan.org/pod/Data::Dump) (libdata-dump-perl)

No special installation of sms-db itself is required.

## Usage:

	sms-db.pl [-d database-file.db] -f format (-i input_file | -o output_file)

(The `-o` option is not yet implemented.)

If `-d` is not given, the default is `sms.db` in the current directory. If the database or its tables do not exist, they will be created.

To import from multiple files with a single command, you can do something like:

	find path/to/files -name "sms*xml" -exec sms-db.pl -f xml -i '{}' -d ./sms.db \;

(This does not add any processing efficiency over invoking sms-db multiple times - it just saves typing. A future version of the program may allow the import of multiple files with a single invocation of sms-db and a single database connection.)

For examples of querying the database, see the included "querying" document.

## Input Formats

The following input formats are currently (at least partially) supported:

### Bugle (`-f bugle`)

Bugle SQLite database files (`bugle_db`) used internally by recent versions of Android. These can be obtained in various ways, such as via the Android backup apps [oandbackup](https://github.com/jensstein/oandbackup) / [OAndBackupX](https://github.com/machiav3lli/oandbackupx).

#### Limitations

MMS data is not currently imported. I can't find it in the Bugle database itself, and I don't know how to use the `content://mms/part/nnnn` URIs in the `uri` field of the Bugle `parts` table to get the data. The information I found online explains how to use the URI to get the data programatically from a running Android system, but I could not find an explanation of how to use it with a standalone Bugle database.

### XML (`-f xml`)

XML files produced by the Android app [SMS Backup & Restore](https://synctech.com.au/sms-backup-restore/). The XML format is documented [here](https://synctech.com.au/sms-backup-restore/fields-in-xml-backup-files/).

#### Limitations

No distinction is currently made between the various recipient address types (`To`, `CC`, and `BCC`).

### General Limitations

I have not fully understood the meaning of all the fields in both the Bugle and XML formats, and even with regard to those that I do understand, I have not currently chosen to import all of them (e.g., charsets and part sequence numbers). Future versions of sms-db may expand the scope of data and metadata imported.

## Output Formats

Not yet implemented.

## Internals

sms-db stores messages in a simple SQLite database, in two tables: `messages` and `parts`. Message metadata is stored in the former, and message data in the latter. (The database structure is a much simplified version of the Bugle one used by Android, with many tables and columns omitted. No notion of 'conversation' is preserved, and sender and recipient metadata is stored in the `messages` table.)

sms-db tries to avoid storing duplicate messages in its database. This is currently implemented by storing SHA-256 hashes of the stored message metadata alongside that metadata, and checking the hashes of potential additions to the message store for uniqueness. (It might be feasible to use a less computationally expensive hash algorithm, or even a non-cryptographic hash, but the performance of the current implementation seems quite adequate, and we don't seem to be paying too high a price for the collision resistance of SHA-256.) This is less likely to work with copies of messages stored in different formats (such as Bugle and XML), in which case sms-db may wind up storing duplicate copies of the same message. It is a design goal to never err in the opposite direction of failing to store messages which are actually not duplicates.

Currently, all timestamps are in [Epoch time format](https://en.wikipedia.org/wiki/Unix_time), in milliseconds. To convert to or from a human readable date, use `date -d'@nnnnnnnnnn.nnn'` / `date -d'human_readable_date' +%s` (the decimal point must be inserted in the input, and '000' must be added to the output, since the `date` command date string format is in seconds rather than milliseconds), or use [this online converter](https://www.epochconverter.com/).

## Alternatives

SMS-Tools, a "Multipurpose import / export / merge tool for your text message history", apparently does what sms-db does and more. It supports many more file formats, and can output to most of the formats it supports. I have not used SMS-Tools or looked at its code. The original, last updated in 2014, is ([here](https://github.com/t413/SMS-Tools); a fork, with a single commit, adding support for Bugle, in 2017, is (here)[https://github.com/p1ne/SMS-Tools].
