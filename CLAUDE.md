# dot-sql

SQLite, PostgreSQL and MySQL for the Dot family: drivers, one dialect layer, tables as plain data, and versioned migrations. Stores in other addons reach a driver by duck typing, so nothing depends on dot-sql.

Read the family [CLAUDE.md](../../CLAUDE.md) first.

**The distributable is `addons/dot_sql/`.** It requires [dot-core](../dot-core) and nothing else (`ln -s ../../dot-core/addons/dot_core addons/dot_core`, gitignored). The SQLite driver also wants godot-sqlite in `addons/godot-sqlite` (gitignored; `tools/fetch_sqlite.sh .`).

## Read before

| Read | Before |
| --- | --- |
| [docs/design.md](docs/design.md) | changing a driver, the dialect, the schema, migrations or the gateway: the duck-typed contract, where the three databases differ, migrations, the gateway's no-retry rule, SQLite durability, what is deliberately not here |
| [docs/history.md](docs/history.md) | the column named `key`, the missing database directory |

## Layout

| Path | What |
| --- | --- |
| `addons/dot_sql/core/dot_sql.gd` | `DotSql`: `from_config` builds a driver (gateway or SQLite) |
| `addons/dot_sql/core/dot_sql_dialect.gd` | `DotSqlDialect`: frozen `Kind`, column types, `RESERVED`, `is_safe_identifier`, `numbered`, `upsert` |
| `addons/dot_sql/core/dot_sql_schema.gd` | `DotSqlSchema`: a table spec (plain data) to DDL per dialect |
| `addons/dot_sql/core/dot_sql_migrator.gd` | `DotSqlMigrator`: per-component versions in `dot_sql_migrations` |
| `addons/dot_sql/driver/dot_sql_driver.gd` | `DotSqlDriver`: the base and the duck-typed surface (`query`, `execute`, `batch`, `upsert_sql`, `migrate`, `ensure_table`) |
| `addons/dot_sql/driver/dot_sql_driver_gateway.gd` | `DotSqlDriverGateway`: HTTP to a gateway, `/query` and `/batch` |
| `addons/dot_sql/driver/dot_sql_driver_sqlite.gd` | `DotSqlDriverSqlite`: the godot-sqlite extension |
| `addons/dot_sql/driver/dot_sql_driver_recording.gd` | `DotSqlDriverRecording`: records statements, for suites |
| `tools/sql_gateway.py` | the reference gateway (SQLite, Postgres, MySQL) |
| `tools/test_live.sh` | runs a live suite against SQLite, the extension, and any database given a DSN |
| `tools/fetch_sqlite.sh` | installs pinned godot-sqlite into a project |
| `examples/sql_selftest.tscn`, `sql_live.tscn` | the offline suite; the live suite |

## Running and testing

The family's two steps ([game-dev/CLAUDE.md](../../CLAUDE.md#validating-anything)), then:

```bash
timeout 120 godot --headless --path . res://examples/sql_selftest.tscn   # offline
tools/fetch_sqlite.sh .                                                  # once, for the extension run
tools/test_live.sh                                                       # sql_live via the gateway on SQLite, then the extension
```

Live against Postgres and MariaDB, through `tools/sql_gateway.py`: a Python with `psycopg` and `pymysql` importable, a Postgres role and database `dot_sql_test`, and a MariaDB 11 container on 127.0.0.1:13306 (for example `docker run -d --name dot-sql-mariadb -p 127.0.0.1:13306:3306 -e MARIADB_DATABASE=dot_sql_test -e MARIADB_USER=dot_sql_test -e MARIADB_PASSWORD=... -e MARIADB_RANDOM_ROOT_PASSWORD=1 mariadb:11`):

```bash
DOT_SQL_PYTHON=<venv>/bin/python \
DOT_SQL_PG_DSN=postgresql://dot_sql_test:...@127.0.0.1/dot_sql_test \
DOT_SQL_MYSQL_DSN=mysql://dot_sql_test:...@127.0.0.1:13306/dot_sql_test tools/test_live.sh
```

The runner takes a project and a scene, so every store's live suite runs the same way: `tools/test_live.sh ../dot-timer res://examples/timer_sql_live.tscn`, and likewise dot-moderation, dot-leaderboard, dot-achievements and dot-stats (`examples/<addon>_sql_live.tscn`). The extension prints `ERROR:  --> SQL error` for every failing statement, including ones a suite fails on purpose; `test_live.sh` filters those and still fails on `SCRIPT ERROR` or `Parse Error`.

## Rules that bite

- Never name a `DotSql*` class from a store or a delivered game; hold the driver untyped, or load `dot_sql.gd` by path. [design](docs/design.md#stores-reach-a-driver-duck-typed)
- `?` placeholders everywhere; wrap integers from rows in `int()`; always `await`. [design](docs/design.md#stores-reach-a-driver-duck-typed)
- `DotSqlDialect.Kind` values are frozen; other repos compare against 0, 1, 2. [design](docs/design.md#stores-reach-a-driver-duck-typed)
- A dialect difference is handled in `DotSqlDialect` or `DotSqlSchema` once, never in a store; never use a `RESERVED` word as a column. [design](docs/design.md#where-the-three-differ-handled-once)
- Bind computed values rather than `SET a = …, b = a + …`: MySQL reads the new `a`. [design](docs/design.md#where-the-three-differ-handled-once)
- Append a migration step, never edit one; name components `<addon>:<prefix or table>`. [design](docs/design.md#migrations)
- The gateway's `DotHttp` never retries; a refused statement is a 200 carrying `error`. [design](docs/design.md#the-gateway)
- The gateway's token comes from a file, never argv; its fence is the database user. [design](docs/design.md#the-gateway)
- Headless Godot gets no notification on SIGINT or SIGTERM: a store writes as it goes, never at exit. [design](docs/design.md#sqlite-through-the-extension)
- Run the live suites against all three databases after a dialect or schema change; SQLite alone accepts what MySQL refuses. [history](docs/history.md#a-column-named-key)
