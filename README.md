This is the **SQL** asset for TMC's **Dot** collection. It lets any Dot asset keep its data in SQLite, PostgreSQL or MySQL, so records, statistics, achievements and bans can live in a real database that several servers share.

This collection of assets provides modular building blocks for creating games and applications within the TMC ecosystem, ensuring consistency and interoperability across all `dot-*` assets. This includes core functionality, networking, authentication, cloud integration, and more.

**These assets are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This asset, along with all the others, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** Every asset has its own headless test suite and those suites pass, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## What it does

Godot has no database client. There is no SQLite, PostgreSQL or MySQL class in the engine. This asset is the layer every other Dot asset uses to get one:

| Piece | What it is |
| --- | --- |
| `DotSqlDriverSqlite` | SQLite through the [godot-sqlite](https://github.com/2shady4u/godot-sqlite) GDExtension. One server, one file. |
| `DotSqlDriverGateway` | PostgreSQL, MySQL/MariaDB or SQLite through a small HTTP gateway that runs beside the database. Several servers, one database. |
| `tools/sql_gateway.py` | A reference gateway, about two hundred lines of Python. |
| `DotSqlDialect` | Every place the three databases differ: column types, upserts, placeholders, reserved words. |
| `DotSqlSchema` | Tables described as plain data and turned into the right SQL for each database. |
| `DotSqlMigrator` | Versioned schema changes, one counter per asset, so an older table grows the columns a newer build needs. |
| `DotSql.from_config` | Builds a driver from a config dictionary, so a server picks its database in a file. |

Needs **dot-core** and nothing else.

### Other assets do not depend on this one

dot-timer, dot-moderation, dot-leaderboard, dot-achievements and dot-stats each have a SQL store, and none of them names a class from this asset. They hold the driver in an untyped variable and call five methods on it (`query`, `execute`, `batch`, `upsert_sql`, `migrate`). So they still load in a project that does not have dot-sql, and SQL is something you add when you want it.

### Why PostgreSQL and MySQL go through HTTP

Speaking either wire protocol from GDScript means implementing an authentication handshake, a binary format and a connection pool. A half finished version of that is a security problem. A gateway is also the safer setup anyway: the database password stays on the gateway's machine instead of on every game server, and the gateway connects as a database user that can only touch the game's tables.

The gateway takes a bearer token on every request. Keep it on a private address or put TLS in front of it.

## Getting started

```bash
ln -s ../../dot-core/addons/dot_core addons/dot_core
```

In a game:

```gdscript
# One SQLite file on this server:
var made := DotSql.from_config({"driver": "sqlite", "path": "user://game.db"}, self)

# A shared MySQL or PostgreSQL database through the gateway:
var made := DotSql.from_config({
    "driver": "gateway", "dialect": "mysql",
    "url": "http://10.0.0.5:8780", "token": "from your config file",
}, self)

var store := DotTimerStoreSql.new(made.value)
await store.open()          # creates or migrates its tables
timers.store = store
```

Keep the token in the config file. Environment variables and command line arguments are readable by every process on the machine.

Running the reference gateway:

```bash
pip install "psycopg[binary]" pymysql      # only the one you need
echo "a long random token" > gateway.token
python3 tools/sql_gateway.py --dialect mysql --dsn mysql://user:pass@127.0.0.1:3306/game --token-file gateway.token
```

## Testing

| Suite | What it checks | Checks |
| --- | --- | --- |
| `examples/sql_selftest.tscn` | Dialects, placeholders, table specs, upserts, migrations, config, with no database | 44 |
| `examples/sql_live.tscn` | Real tables, upserts, emoji and quotes, run time precision, transactions and migrations against a real database | 16 per database |

```bash
godot --headless --path . res://examples/sql_selftest.tscn
tools/test_live.sh                                                     # SQLite
DOT_SQL_PG_DSN=postgresql://u:p@127.0.0.1/test DOT_SQL_MYSQL_DSN=mysql://u:p@127.0.0.1:3306/test tools/test_live.sh
```

`tools/test_live.sh` also runs other assets' live suites: `tools/test_live.sh ../dot-timer res://examples/timer_sql_live.tscn`.

## Not done yet

- The SQLite driver has not been run against the real GDExtension. Its SQL is tested against real SQLite through the gateway, but the extension calls themselves are written from its documentation.
- The reference gateway handles one request at a time. It is fine for a few servers and is meant to be copied, not scaled.

## License

MIT. See [LICENSE](LICENSE).
