# sms-db

sms-db is a tool to build an [SQLite](https://www.sqlite.org/index.html) database out of collections of SMS and MMS messages in various formats. The database can then be queried using standard SQLite queries, and the messages in the database can be exported in various formats.

This README is for sms-db version 0.3, which uses sms-db format 2.

## Design Goals

sms-db has several design goals:

- Providing message storage in a simple, standard, easily understandable format.

- Enabling the combination of messages from multiple sources into a single message store.

- Enabling the querying of message collections (via the SQLite framework).

- Enabling the output of messages in various formats, potentially allowing their import into other systems, including Android's internal message storage.

## Installation:

All versions of sms-db are available [here](https://github.com/tmo1/sms-db). sms-db depends on the following Perl modules (Debian packages are in parentheses):

- [XML::LibXML](https://metacpan.org/pod/XML::LibXML) (libxml-libxml-perl)
- [DBD::SQLite](https://metacpan.org/pod/DBD::SQLite) (libdbd-sqlite3-perl)
- [Try::Tiny](https://metacpan.org/pod/Try::Tiny) (libtry-tiny-perl)
- [Encode](https://metacpan.org/pod/Encode) (libencode-perl)
- [Data::Dump](https://metacpan.org/pod/Data::Dump) (libdata-dump-perl)

No special installation of sms-db itself is required.

## Usage:

	sms-db.pl [-d database-file.db] [-t message_type] -f format (-i input_file | -o output_file)

If `-d` is not given, the default is `sms-db.db` in the current directory. If the database or its tables do not exist, they will be created.

`-t` controls which message types will be imported or exported. It should be either `sms`, `mms`, or `all` (the default).

To import from multiple files with a single command, you can do something like:

	find path/to/files -name "sms*xml" -exec sms-db.pl -f xml -i '{}' -d ./sms.db \;

(This does not add any processing efficiency over invoking sms-db multiple times - it just saves typing. A future version of the program may allow the import of multiple files with a single invocation of sms-db and a single database connection.)

For examples of querying the database, see [querying](./querying.md).

**IMPORTANT**: to avoid data loss, all message sources should be retained after import by sms-db, both because of the possibility of corruption of the database due to bugs, and due to the fact that the database format is not yet entirely stable and may change with future versions of sms-db. In both of these cases it may be necessary to rebuild the database from the original message sources.

## Input Formats

The following input formats are currently (at least partially) supported:

### Bugle (`-f bugle`)

Bugle SQLite database files (`bugle_db`) used internally by recent versions of Android. These can be obtained in various ways, such as via the Android backup apps [oandbackup](https://github.com/jensstein/oandbackup) / [OAndBackupX](https://github.com/machiav3lli/oandbackupx).

#### Limitations

Both SMS and MMS metadata and text parts are imported, but MMS non-text parts (and their filenames) are not currently imported. I can't find them in the Bugle database itself, and I don't know how to use the `content://mms/part/nnnn` URIs in the `uri` field of the Bugle `parts` table to get the data. The information I found online explains how to use the URI to get the data programatically from a running Android system, but I could not find an explanation of how to use it with a standalone Bugle database.

### XML (`-f xml`)

XML files produced by the Android app [SMS Backup & Restore](https://synctech.com.au/sms-backup-restore/). These XML files contain both SMSs and MMSs, and both are imported.

The XML format is documented [here](https://synctech.com.au/sms-backup-restore/fields-in-xml-backup-files/). Note that many of the individual fields, particularly for MMS messages, are undocumented. Additionally, Synctech links to what it describes as ["The XSD schema"](https://synctech.com.au/wp-content/uploads/2018/01/sms.xsd_.txt), but the schema is apparently either wrong or outdated, since it does not allow for the presence of the `addrs` element present in both its webpage describing the XML fields as well as in actual XML backups produced by the app!

#### Limitations

sms-db does not currently distinguish between the various recipient address types (`To`, `CC`, and `BCC`). More generally, sbs-db ignores many of the fields in the XML, particularly with respect to MMS messages.

### Signal (`-f signal`)

Decoded [Signal backups](https://support.signal.org/hc/en-us/articles/360007059752-Backup-and-Restore-Messages#android_restore). This option is designed to work with the encrypted backups produced by Signal for Android, decrypted and unpacked by [signal backup decode](https://github.com/pajowu/signal-backup-decode). (It may or may not work with the output of other tools that decode Signal backups, such as [signal back](https://github.com/xeals/signal-back) or [signalbackup-tools](https://github.com/bepaald/signalbackup-tools); I haven't tried it.) When using this format, set `-i` to the root directory of the decrypted backup (e.g., `-i signal-yyyy-mm-dd-nn-nn-nn`); this directory should contain the file `signal-backup-db`, which contains the SMS and MMS metadata and text parts, as well as the directory `attachment`, which contains the MMS attachments stored as individual files. All this is imported.

#### Limitations

Signal has [updated its database format many times](https://github.com/signalapp/Signal-Android/blob/master/app/src/main/java/org/thoughtcrime/securesms/database/helpers/SignalDatabaseMigrations.kt), and will likely continue to do so in the future. This [can break](https://github.com/tmo1/sms-db/pull/2) sms-db's Signal import capability. sms-db will attempt to maintain compatibility with the latest version of the Signal database, which may result in incompatibility between more recent versions of sms-db and backups produced by earlier versions of Signal. In such cases, the recommended solution is to leverage [Signal's own database migration code](https://github.com/signalapp/Signal-Android/blob/master/app/src/main/java/org/thoughtcrime/securesms/database/helpers/SignalDatabaseMigrations.kt) to upgrade the database to the current format, via the following procedure (which ought to work, although it has not been tested):

 - Install the latest version of Signal, either on actual hardware, or on [an Android virtual device](https://developer.android.com/studio/run/managing-avds) run on the [Android Emulator](https://developer.android.com/studio/run/emulator).
 - In Signal, [restore from the old backup file](https://support.signal.org/hc/en-us/articles/360007059752-Backup-and-Restore-Messages).
 - In Signal, [create a new backup](https://support.signal.org/hc/en-us/articles/360007059752-Backup-and-Restore-Messages).
 
The new backup will hopefully be compatible with the latest version of sms-db. (If it isn't, [open an issue](https://github.com/tmo1/sms-db/issues) to report the problem.)

My Signal databases contain only ordinary SMS and MMS messages, and not Signal's end-to-end encrypted messages, so I do not know whether sms-db will properly import such messages. (See [here](https://github.com/tmo1/sms-db/pull/2#issue-1038058117).)

### General Limitations

I have not fully understood the meaning of all the fields in the various formats, and even with regard to those that I do understand, I have not currently chosen to import all of them (e.g., charsets and part sequence numbers). Future versions of sms-db may expand the scope of data and metadata imported (e.g., attachment filenames).

## Output Formats

### XML (`-o xml`)

Currently, the only supported output format is Synctech's XML format. This should work well for SMS messages, but MMS support should be considered experimental at best. Note that I have not yet done any testing on whether and to what extent sms-db's XML output is correctly handled by SMS Backup and Restore.

Synctech does not document many of the MMS fields at all, and sms-db currently does not preserve most of them (and certainly does not generate the information from MMS messages imported from other formats). In order to generate "valid" XML somewhat resembling the XML produced by Synctech's app, sms-db sets many of the fields to `null` and other arbitrary, and sometimes even known incorrect, values. The resulting XML mostly validates with Synctech's XSD schema (except for the fact that we include the `addrs` element - see above), but how well Synctech's import functionality will work, given all the missing and bogus information, is untested.

### CSV

sms-db does not produce CSV output, but such output can be easily generated by the SQLite executable, e.g.:

	sqlite3 -csv sms-db.db "select sender_name,recipient_name,timestamp,data from messages INNER JOIN parts ON messages._id = parts.message_id where content_type LIKE 'text%' ORDER BY timestamp;"

(See [querying](./querying.md) for further examples of queries against the database.)

## Internals

sms-db stores messages in a simple SQLite database, in two tables: `messages` and `parts`. Message metadata is stored in the former, and message data in the latter. (The database structure is a much simplified version of the Bugle one used by Android, with many tables and columns omitted. No notion of 'conversation' is preserved, and sender and recipient metadata is stored in the `messages` table.)

### Duplication avoidance

sms-db tries to avoid storing duplicate messages in its database. This is currently implemented by storing SHA-256 hashes of the stored message metadata alongside that metadata, and checking the hashes of potential additions to the message store for uniqueness. (It might be feasible to use a less computationally expensive hash algorithm, or even a non-cryptographic hash, but the performance of the current implementation seems quite adequate, and we don't seem to be paying too high a price for the collision resistance of SHA-256.) This is less likely to work with copies of messages stored in different formats, in which case sms-db may wind up storing duplicate copies of what is actually the same message. (This has been observed to occur with outgoing SMS messages that appear in both Bugle and Signal databases, since with outgoing Bugle messages, sms-db records the actual sender (i.e., owner) name and number, while with outgoing Signal messages, the sender name and number are recorded as '<SELF>', and the messages are therefore not considered identical. It is a design goal to never err in the opposite direction of failing to store messages which are actually not duplicates.)

Currently, all timestamps are in [Epoch time format](https://en.wikipedia.org/wiki/Unix_time), in milliseconds. To convert to or from a human readable date, use `date -d'@nnnnnnnnnn.nnn'` / `date -d'human_readable_date' +%s` (the decimal point must be inserted in the input, and '000' must be added to the output, since the `date` command date string format is in seconds rather than milliseconds), or use [this online converter](https://www.epochconverter.com/).

Many of the columns in the sms-db database schema should be self-explanatory; following is some explanation of some of the less obvious ones:

### Columns in the `messages` table: 

 - `msg_box` values have the meaning they have in the [Synctech XML format](https://synctech.com.au/sms-backup-restore/fields-in-xml-backup-files/): 1 = Received, 2 = Sent, 3 = Draft, 4 = Outbox. (Synctech uses `type` for SMSs and `msg_box` for MMS; we use `msg_box` for both.)

 - `message_type` records the type of message: 0 = SMS, 1 = MMS.

 - `source_format` records the format of the message collection of a message's origin: 0 = XML, 1 = Bugle, 2 = Signal.

## Alternatives

SMS-Tools, a "Multipurpose import / export / merge tool for your text message history", apparently does what sms-db does and more. It supports many more file formats, and can output to most of the formats it supports. On the other hand, it does not advertise Signal support. I have not used SMS-Tools or looked at its code. The original, last updated in 2014, is [here](https://github.com/t413/SMS-Tools); a fork, with a single commit in 2017, adding support for Bugle, is [here](https://github.com/p1ne/SMS-Tools).

## Bugs

Probably, particularly inaccurate interpretation of message metadata in the various supported input formats. For bug reports, feature requests, or general feedback, use [the sms-db issue tracker](https://github.com/tmo1/sms-db/issues).
