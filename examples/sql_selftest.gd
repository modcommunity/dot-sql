extends Node

## Exercises dot-sql without a database: the dialect layer, the DDL, the migrator's
## bookkeeping and the config factory, all against [DotSqlDriverRecording].
##
## Whether the SQL is VALID is the other suite's job — `examples/sql_live.tscn`, run by
## `tools/test_live.sh` against real SQLite and Postgres through the reference gateway.
##
## [codeblock]
## godot --headless --path . res://examples/sql_selftest.tscn
## [/codeblock]

const CHECKS := 44

## Sections entered against sections that ran to their last line. See docs/testing.md.
const SECTIONS := 6

var _passed := 0
var _failed := 0
var _entered := 0
var _completed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	await _run()


func _run() -> void:
	print("dot-sql self-test")
	print("")

	_test_dialects()
	_test_placeholders()
	_test_schema()
	_test_upsert()
	await _test_migrator()
	_test_config()

	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	_finish()


func _test_dialects() -> void:
	_section("dialects")

	# Frozen: dot-moderation and mg-dangerous-delivery compare against these integers.
	_check("sqlite is 0, postgres 1, mysql 2", DotSqlDialect.Kind.SQLITE == 0 and DotSqlDialect.Kind.POSTGRES == 1 and DotSqlDialect.Kind.MYSQL == 2)
	_check("names round-trip", DotSqlDialect.from_name(DotSqlDialect.name_of(DotSqlDialect.Kind.MYSQL)) == DotSqlDialect.Kind.MYSQL)
	_check("operator spellings are accepted", DotSqlDialect.from_name(" PostgreSQL ") == 1 and DotSqlDialect.from_name("mariadb") == 2)
	_check("an unknown dialect is -1", DotSqlDialect.from_name("oracle") == -1)
	_check("an indexed string is VARCHAR on mysql only", DotSqlDialect.column_type(DotSqlDialect.KEY, 2) == "VARCHAR(191)" and DotSqlDialect.column_type(DotSqlDialect.KEY, 1) == "TEXT")
	# Single precision in Postgres loses a run's thousandths past a few hours.
	_check("a real is double precision in postgres", DotSqlDialect.column_type(DotSqlDialect.REAL, 1) == "DOUBLE PRECISION")
	_check("safe identifiers pass", DotSqlDialect.is_safe_identifier("dot_timer_records") and DotSqlDialect.is_safe_identifier("_x1"))
	_check("unsafe identifiers fail", not DotSqlDialect.is_safe_identifier("x; DROP TABLE y") and not DotSqlDialect.is_safe_identifier("1abc") and not DotSqlDialect.is_safe_identifier("a".repeat(64)))
	# `key` is what dot-moderation shipped, and MySQL refuses it; `rank` is the one a
	# timer table wants, and MySQL 8 refuses that too.
	_check("reserved words fail, in any case", not DotSqlDialect.is_safe_identifier("key") and not DotSqlDialect.is_safe_identifier("RANK") and not DotSqlDialect.is_safe_identifier("user"))

	_done()


func _test_placeholders() -> void:
	_section("placeholders")

	_check("? becomes $n", DotSqlDialect.numbered("a = ? AND b = ?") == "a = $1 AND b = $2")
	_check("a ? in a string is not a placeholder", DotSqlDialect.numbered("x = 'who?' AND y = ?") == "x = 'who?' AND y = $1")
	_check("a doubled quote does not end the string", DotSqlDialect.numbered("x = 'it''s ?' AND y = ?") == "x = 'it''s ?' AND y = $1")
	_check("a ? in a quoted identifier is skipped", DotSqlDialect.numbered("\"odd?\" = ?") == "\"odd?\" = $1")
	_check("a ? in a comment is skipped", DotSqlDialect.numbered("-- why?\nSELECT ?") == "-- why?\nSELECT $1")
	_check("counting agrees with rewriting", DotSqlDialect.count_placeholders("x = 'who?' AND y = ? AND z = ?") == 2)

	_done()


func _table() -> Dictionary:
	return {
		"name": "dot_test_rows",
		"columns": [
			{"name": "id", "type": DotSqlDialect.KEY, "null": false},
			{"name": "label", "type": DotSqlDialect.TEXT},
			{"name": "score", "type": DotSqlDialect.REAL, "null": false, "default": 0},
			{"name": "flag", "type": DotSqlDialect.BOOL, "default": false},
		],
		"primary_key": ["id"],
		"indexes": [{"name": "score", "columns": ["score"]}],
	}


func _test_schema() -> void:
	_section("schema")

	var table := _table()
	_check("a good spec validates", DotSqlSchema.validate(table).ok)

	var sqlite := DotSqlSchema.ddl(table, DotSqlDialect.Kind.SQLITE)
	var mysql := DotSqlSchema.ddl(table, DotSqlDialect.Kind.MYSQL)
	_check("sqlite: a table and a separate index", sqlite.size() == 2 and sqlite[1].begins_with("CREATE INDEX IF NOT EXISTS dot_test_rows_score"))
	# MySQL has no CREATE INDEX IF NOT EXISTS, so the index has to live inside the table.
	_check("mysql: the index is inside the table", mysql.size() == 1 and mysql[0].contains("KEY dot_test_rows_score (score)"))
	_check("mysql: utf8mb4", mysql[0].ends_with("DEFAULT CHARSET=utf8mb4"))
	_check("a boolean default is 0", sqlite[0].contains("flag INTEGER DEFAULT 0"))

	var bad := _table()
	bad["name"] = "rows; DROP TABLE x"
	_check("an unsafe table name is refused", not DotSqlSchema.validate(bad).ok)

	bad = _table()
	(bad["columns"] as Array).append({"name": "id", "type": "key"})
	_check("a duplicate column is refused", not DotSqlSchema.validate(bad).ok)

	bad = _table()
	bad["indexes"] = [{"name": "label", "columns": ["label"]}]
	# MySQL cannot index TEXT without a prefix; refused for every dialect so a schema
	# tested on SQLite does not fail the day it meets MySQL.
	_check("an index on a text column is refused", not DotSqlSchema.validate(bad).ok)

	bad = _table()
	(bad["columns"] as Array)[1]["type"] = "timestamp"
	_check("an unknown type is refused", not DotSqlSchema.validate(bad).ok)

	_done()


func _test_upsert() -> void:
	_section("upsert")

	var columns := PackedStringArray(["id", "label", "score"])
	var keys := PackedStringArray(["id"])

	var pg := DotSqlDialect.upsert(1, "t", columns, keys)
	_check("postgres: ON CONFLICT … excluded", pg == "INSERT INTO t (id, label, score) VALUES (?, ?, ?) ON CONFLICT (id) DO UPDATE SET label = excluded.label, score = excluded.score")
	var my := DotSqlDialect.upsert(2, "t", columns, keys)
	_check("mysql: ON DUPLICATE KEY … VALUES()", my.ends_with("ON DUPLICATE KEY UPDATE label = VALUES(label), score = VALUES(score)"))
	_check("insert-or-ignore on sqlite", DotSqlDialect.upsert(0, "t", columns, keys, []).ends_with("ON CONFLICT (id) DO NOTHING"))
	# Not INSERT IGNORE, which turns every other error on the row into a warning.
	_check("insert-or-ignore on mysql is a no-op update", DotSqlDialect.upsert(2, "t", columns, keys, []).ends_with("ON DUPLICATE KEY UPDATE id = id"))
	_check("only the named columns update", DotSqlDialect.upsert(1, "t", columns, keys, ["score"]).ends_with("DO UPDATE SET score = excluded.score"))

	_done()


func _test_migrator() -> void:
	_section("migrator")

	var driver := DotSqlDriverRecording.new()
	await driver.open()
	driver.answers = {"SELECT version FROM": []}

	var steps := [
		[_table()],
		["ALTER TABLE dot_test_rows ADD COLUMN extra TEXT"],
	]

	var result: DotResult = await driver.migrate("dot_test", steps)
	_check("a fresh database migrates to the last step", result.ok and int(result.value) == 2, result)
	_check("both steps ran", driver.matching("CREATE TABLE IF NOT EXISTS dot_test_rows").size() == 1 and driver.matching("ADD COLUMN extra").size() == 1)
	var recorded := driver.matching("INSERT INTO dot_sql_migrations")
	_check("each step is recorded as it lands", recorded.size() == 2 and int(recorded[1]["params"][1]) == 2)

	driver.clear()
	driver.answers = {"SELECT version FROM": [{"version": 2}]}
	result = await driver.migrate("dot_test", steps)
	_check("an up-to-date database runs nothing", result.ok and driver.matching("ALTER").is_empty())

	driver.answers = {"SELECT version FROM": [{"version": 3.0}]}
	result = await driver.migrate("dot_test", steps)
	_check("a database from a newer build is refused", not result.ok and result.code() == DotError.CODE_VERSION)

	driver.clear()
	driver.answers = {"SELECT version FROM": [{"version": 1}]}
	driver.fail_next = ""
	var failing := [
		[_table()],
		[func(_d) -> DotResult: return DotResult.fail(DotError.CODE_IO, "boom")],
	]
	result = await driver.migrate("dot_test", failing)
	_check("a failed step stops the migration", not result.ok and driver.matching("INSERT INTO dot_sql_migrations").is_empty())

	result = await driver.migrate("", steps)
	_check("a nameless component is refused", not result.ok)

	_done()


func _test_config() -> void:
	_section("config")

	var none := DotSql.from_config({})
	_check("no driver configured is a null success", none.ok and none.value == null)

	var sqlite := DotSql.from_config({"driver": "sqlite", "path": "user://x.db"})
	_check("sqlite builds a sqlite driver", sqlite.ok and sqlite.value is DotSqlDriverSqlite)

	var gw := DotSql.from_config({"driver": "mysql", "url": "http://127.0.0.1:1", "token": "t"}, self)
	_check("a mysql url builds a gateway in the mysql dialect", gw.ok and gw.value is DotSqlDriverGateway and (gw.value as DotSqlDriverGateway).dialect() == 2)
	# Statements are not idempotent; a retried timeout can apply a write twice.
	_check("the gateway's http does not retry", gw.ok and (gw.value as DotSqlDriverGateway).http.max_retries == 0)
	_check("the token never reaches describe()", gw.ok and not str((gw.value as DotSqlDriverGateway).describe()).contains("\"t\""))

	_check("a gateway with no url is refused", not DotSql.from_config({"driver": "gateway"}, self).ok)
	_check("a non-http url is refused", not DotSql.from_config({"driver": "gateway", "url": "file:///etc"}, self).ok)
	_check("an unknown driver is refused", not DotSql.from_config({"driver": "oracle"}).ok)

	_done()


func _section(title: String) -> void:
	_entered += 1
	print(title)


func _done() -> void:
	_completed += 1


func _check(what: String, passed: bool, res: DotResult = null) -> void:
	if passed:
		_passed += 1
		print("  %-56s ok" % what)
		return
	_failed += 1
	var why := ""
	if res != null and not res.ok and res.error != null:
		why = " — %s (%s)" % [res.error.message, res.error.detail]
	print("  %-56s FAILED%s" % [what, why])


func _finish() -> void:
	if not DotPlatform.is_headless():
		return
	await get_tree().process_frame
	print("%d of %d sections ran to their last line" % [_completed, _entered])
	if _entered != SECTIONS or _completed != _entered:
		print("ERROR: %d sections entered and %d completed, %d expected." % [_entered, _completed, SECTIONS])
		get_tree().quit(1)
		return
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [_passed + _failed, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)
