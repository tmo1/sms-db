# Querying the sms-db database

Here are some examples of querying the sms-db database. Much of the information here will be elementary to someone proficient in [SQLite](https://www.sqlite.org/index.html); I am an SQLite novice, however, and these examples may be useful to others like me.

## Using the SQLite command line interface

Install the SQLite command line interface (in Debian, it's in the `sqlite3` package), and run it in interactive mode, e.g.:

	sqlite3 -column -header sms.db
	
List all messages sent by Alice:

	SELECT sender_name,sender_address,recipient_name,recipient_address,timestamp FROM messages WHERE sender_name = 'Alice' ORDER BY timestamp;
	
To match all sender names that begin with 'Alice', use the `LIKE` operator:

	SELECT sender_name,sender_address,recipient_name,recipient_address,timestamp FROM messages WHERE sender_name LIKE 'Alice%' ORDER BY timestamp;
	
Or for all sender names that include 'Alice' within them:

	SELECT sender_name,sender_address,recipient_name,recipient_address,timestamp FROM messages WHERE sender_name = '%Alice%' ORDER BY timestamp;
	
All messages sent or received on July 4, 2020 (GMT-04:00)

	SELECT sender_name,sender_address,recipient_name,recipient_address,timestamp FROM messages WHERE timestamp BETWEEN 1593835200000 AND 1593921600000 ORDER BY timestamp;

(Currently, all timestamps are in [Epoch time format](https://en.wikipedia.org/wiki/Unix_time), in milliseconds. To convert to or from a human readable date, use `date -d'@nnnnnnnnnn.nnn'` / `date -d'human_readable_date' +%s` (the decimal point must be inserted in the input, and '000' must be added to the output, since the `date` command date string format is in seconds rather than milliseconds), or use [this online converter](https://www.epochconverter.com/).

All messages sent by Alice prior to July 4, 2020:

	select sender_name,recipient_name,timestamp FROM messages where timestamp < 1593835200000 AND sender_name = 'Alice' ORDER BY timestamp;
	
All the previous commands display only message metadata, not data. To display the data as well, add an `INNER JOIN` clause:

	select sender_name,recipient_name,timestamp,data FROM messages INNER JOIN parts ON messages._id = parts.message_id where sender_name = 'Alice' ORDER BY timestamp;

To include only text parts, check the `content_type` column:

	select sender_name,recipient_name,timestamp,data FROM messages INNER JOIN parts ON messages._id = parts.message_id where sender_name = 'Alice' and content_type LIKE 'text%' ORDER BY timestamp;

## Using the SQLite Database Browser

The sms-db database can also be examined and searched via the SQLite Database Browser (`sqlitebrowser` in Debian). The program has many powerful features, but one of the simplest ways to use it is by opening the database, selecting the 'Browse Data' tab, selecting a table, and then using the filter boxes to search. For example, to search for any message containing the word 'Perl', select the 'parts' table, and type 'Perl' into the filter box for the 'data' column. To see the metadata of a particular part, press <CTRL> + <SHIFT> and left-click its 'message_id' field.

The browser also provides a convenient way to view (many) non-text parts; simply clicking on the 'data' field of a part will (often?) result in its display in the 'Edit Database Cell' pane.
