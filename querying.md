Here are some examples of querying the sms-db database. Much of the information here will be elementary to someone proficient in SQLite; I am an SQLite newbie, however, and these examples may be useful to others like me.

Install the SQLite command line interface (in Debian, it's in the sqlite3 package), and run it in interactive mode, e.g.:

	sqlite3 -column -header sms.db
	
List all messages sent by Alice:

	SELECT sender_name,sender_address,recipient_name,recipient_address,timestamp WHERE sender_name = 'Alice' ORDER BY timestamp;
	
To match all sender names that begin with 'Alice', use the `LIKE` operator:

	SELECT sender_name,sender_address,recipient_name,recipient_address,timestamp WHERE sender_name LIKE 'Alice%' ORDER BY timestamp;
	
Or for all sender names that include 'Alice' within them:

	SELECT sender_name,sender_address,recipient_name,recipient_address,timestamp WHERE sender_name = '%Alice%' ORDER BY timestamp;
	
All messages sent or received on July 4, 2020 (GMT-04:00)

	SELECT sender_name,sender_address,recipient_name,recipient_address,timestamp WHERE timestamp BETWEEN 1593835200000 AND 1593921600000 ORDER BY timestamp;

(Currently, all timestamps are in [Epoch time format](https://en.wikipedia.org/wiki/Unix_time), in milliseconds. To convert to or from a human readable date, use `date -d'@nnnnnnnnnn.nnn'` / `date -d'human_readable_date' +%s` (the decimal point must be inserted in the input, and '000' must be added to the output, since the `date` command date string format is in seconds rather than milliseconds), or use [this online converter](https://www.epochconverter.com/).

All messages sent by Alice prior to July 4, 2020:

	select sender_name,recipient_name,timestamp from messages where timestamp < 1593835200000 AND sender_name = 'Alice' ORDER BY timestamp;
	
All the previous commands display only message metadata, not data. To display the data as well, add an `INNER JOIN` clause:

	select sender_name,recipient_name,timestamp,data from messages INNER JOIN parts ON messages._id = parts.message_id where sender_name = 'Alice' ORDER BY timestamp;

To include only text parts, check the `content_type` column:

	select sender_name,recipient_name,timestamp,data from messages INNER JOIN parts ON messages._id = parts.message_id where sender_name = 'Alice' and content_type LIKE 'text%' ORDER BY timestamp;
