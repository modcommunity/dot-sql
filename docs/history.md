# dot-sql history

Kept because each could come back. The live rules are in [design.md](design.md).

## A column named `key`

dot-moderation shipped a metadata table with a column named `key`, which every MySQL refuses (ERROR 1064, measured on MariaDB 11) while SQLite and Postgres accept it. Its DDL also used `CREATE INDEX IF NOT EXISTS`, which MySQL does not have. Both bugs are why dot-moderation's DDL now comes from `DotSqlSchema`, and why `is_safe_identifier` refuses `RESERVED` words. A suite run only against SQLite would never have found either: run the live suites against all three.

## The database directory did not exist

The first run against the real extension found that SQLite creates the file but not its directory: `user://g2gfast/records.db` on a fresh server was "unable to open database file", and game-g2gfast fell back to files on every first boot. `DotSqlDriverSqlite.open()` makes the directory now.
