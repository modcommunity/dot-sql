# dot-sql

SQLite, PostgreSQL and MySQL for the Dot family: drivers, one dialect layer, tables as plain data, and versioned migrations.

Read the family-wide conventions in [`../../CLAUDE.md`](../../CLAUDE.md) first. This file is only what is specific to SQL.

**Only dot-core is a dependency.** And no other addon depends on this one, which is the design rather than an accident.

## The one idea: stores reach a driver duck-typed

Every addon with a SQL store (dot-timer, dot-moderation, dot-leaderboard, dot-achievements, dot-stats) holds its driver in an **untyped** variable and calls `query`, `execute`, `batch`, `upsert_sql`, `migrate` and `ensure_table` on it. None of them names a `DotSql*` class. In GDScript naming a `class_name` the project lacks is a parse error that takes every referencing script down with it, so a store that typed its driver as `DotSqlDriver` would make its whole addon fail to load in a project without dot-sql. Duck-typed, SQL is a thing a host adds. Only examples (suites) name dot-sql classes, and a repository whose suites do lists `/addons/dot_sql` in its `.gitignore` as a test dependency.

The same rule reaches games: a game delivered as a pack must not name `DotSql` either, because a pack parses against whatever addons the host build carries. game-g2gfast loads `res://addons/dot_sql/core/dot_sql.gd` by path and calls `from_config` on the script.

**The contract, as plain data:** statements use `?` in every dialect; `query` answers an Array of Dictionary rows; numbers may come back as float (a gateway's JSON has one number type), so a row mapper wraps integers in `int()`; JSON columns may come back as text; booleans may come back as bool, int, float or string; every method returns a `DotResult` and is a coroutine, so callers always `await`.

**The dialect integers are frozen** (`SQLITE = 0`, `POSTGRES = 1`, `MYSQL = 2`). mg-dangerous-delivery's bank and dot-moderation compare against them without naming this class.

## Where the three differ, handled once

| Difference | Handled in |
| --- | --- |
| MySQL cannot index TEXT without a prefix | `key` columns are VARCHAR(191) there (191 x 4 bytes fits the 767-byte key limit) |
| MySQL has no `CREATE INDEX IF NOT EXISTS` | indexes go inside the CREATE TABLE on MySQL |
| Postgres REAL is single precision | `real` is DOUBLE PRECISION there, or a four-hour run loses its thousandths |
| Postgres numbers placeholders | `DotSqlDialect.numbered()` for a native driver; the gateway contract is `?` |
| Upsert spelling | `DotSqlDialect.upsert()`: ON CONFLICT … excluded, or ON DUPLICATE KEY … VALUES() |
| Reserved words | `RESERVED`, refused by `is_safe_identifier`, so `key` and `rank` never become columns |
| Charset | utf8mb4 on MySQL, or a name with an emoji fails the insert |
| MySQL evaluates `SET a = …, b = a + 1` left to right with the NEW `a` | not here: stores bind computed values instead. dot-timer's `note_progress` is the example |

**`key` is not hypothetical.** dot-moderation shipped a metadata table with a column named `key`, which every MySQL refuses (ERROR 1064, measured on MariaDB 11) while SQLite and Postgres accept it. Its DDL also used `CREATE INDEX IF NOT EXISTS`. Both bugs are why dot-moderation's DDL now comes from here.

## Migrations

`DotSqlMigrator` keeps one row per component in `dot_sql_migrations`. A component's steps are an Array; step N brings version N to N+1. A step is a list of SQL strings, `[sql, params]` pairs, table specs, or Callables taking the driver (for a step that differs per dialect). **Append a step, never edit one.** A database at a version higher than the code knows is refused with `CODE_VERSION`. Two servers migrating one database at once is normal: a failed step re-reads the counter and carries on if the other server got there first. Stores name their component `<addon>:<prefix or table>` so two copies with different table names keep separate versions.

## The gateway

`DotSqlDriverGateway` posts `{sql, params, dialect}` to `/query` and `{statements}` to `/batch` (one transaction). **A refused statement is a 200 carrying `error`**, because `DotHttp` retries every non-2xx and a failed statement fails the same way twice more. **The gateway's `DotHttp` must not retry** (`DotSql.from_config` builds one with `max_retries = 0` and the driver warns if it does): a timed-out write may have committed, and retried, `points = points + 3` adds six.

`tools/sql_gateway.py` is the reference: stdlib plus psycopg or pymysql, one connection, token from a file (argv is in `ps`), binds 127.0.0.1 by default, and rewrites `?` to `%s` while doubling literal `%` (both client libraries use %-formatting when given parameters, so `LIKE 'p%'` would otherwise be read as a placeholder). Its fence is the database user it connects as, not SQL parsing.

## Validating

```bash
godot --headless --path . --import
godot --headless --path . res://examples/sql_selftest.tscn     # 44 checks, 6 sections
tools/test_live.sh                                               # sql_live against SQLite: 16
```

Live against all three, as run on 2026-10-08 (a scratch Postgres database and a throwaway MariaDB 11 container):

```bash
DOT_SQL_PYTHON=<venv with psycopg, pymysql>/bin/python \
DOT_SQL_PG_DSN=postgresql://dot_sql_test:...@127.0.0.1/dot_sql_test \
DOT_SQL_MYSQL_DSN=mysql://dot_sql_test:...@127.0.0.1:13306/dot_sql_test tools/test_live.sh
```

The runner takes a project and a scene, so every store's live suite runs the same way: `tools/test_live.sh ../dot-timer res://examples/timer_sql_live.tscn` (58 checks per database), `../dot-moderation … moderation_sql_live.tscn` (10), and the leaderboard, achievements and stats live suites.

**`DotSqlDriverSqlite` against the real extension, since 2026-10-09.** `tools/fetch_sqlite.sh <project>` installs godot-sqlite **v4.9** (MIT, `compatibility_minimum = "4.7"`), pinned by the archive's sha256 and without its 250 MB of iOS frameworks, into `addons/godot-sqlite` (gitignored). With it there, `tools/test_live.sh` runs `sql_live` a second time with `DOT_SQL_SQLITE_PATH` and no gateway: 16 checks through the extension's own calls. Running it the first time found that **SQLite creates the file but not its directory** — `user://g2gfast/records.db` on a fresh server was "unable to open database file", and the game fell back to files on every first boot; `open()` makes the directory now. Measured the same day: `journal_mode` is `wal`, `synchronous` is 2 (FULL), and 200 inserts followed by a `kill -9` reopen as 200 rows with `integrity_check` ok. That last one is the point of SQLite here: **Godot 4.7 headless dies on SIGINT and SIGTERM without a single notification**, so a store that writes at exit writes nothing on a panel's stop (`^C`) or a `docker stop`. The extension prints its own `ERROR:  --> SQL error` for every statement that fails, including the ones a suite fails on purpose; `test_live.sh` filters those.

## Things deliberately not here

- **A native Postgres or MySQL client.** See the gateway section; a half-finished protocol implementation is a security problem.
- **An ORM or a query builder.** Stores write their own parameterised SQL against a few helpers. A builder general enough for five stores is a second language to learn and to get wrong.
- **Connection pooling.** The gateway's job, if a deployment needs one.
