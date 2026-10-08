extends Node

## Runs real SQL against a real database through [DotSqlDriverGateway].
##
## The offline suite proves which statements are built; only this proves a database
## accepts them. `tools/test_live.sh` starts `tools/sql_gateway.py` for SQLite, and for
## Postgres and MySQL when a DSN is given, and runs this once per dialect:
##
## [codeblock]
## DOT_SQL_URL=http://127.0.0.1:8780 DOT_SQL_DIALECT=sqlite DOT_SQL_TOKEN_FILE=/tmp/tok \
##     godot --headless --path . res://examples/sql_live.tscn
## [/codeblock]
##
## The token comes from a FILE named in the environment, never from the environment itself
## — the same rule DotConfig enforces for a game.

const CHECKS := 16
const SECTIONS := 4

var _passed := 0
var _failed := 0
var _entered := 0
var _completed := 0

var driver: DotSqlDriverGateway = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)

	var url := OS.get_environment("DOT_SQL_URL")
	var dialect := DotSqlDialect.from_name(OS.get_environment("DOT_SQL_DIALECT"))
	var token_file := OS.get_environment("DOT_SQL_TOKEN_FILE")
	if url == "" or dialect < 0 or token_file == "":
		print("set DOT_SQL_URL, DOT_SQL_DIALECT and DOT_SQL_TOKEN_FILE; see tools/test_live.sh")
		get_tree().quit(2)
		return

	var made := DotSql.from_config({
		"driver": "gateway", "url": url, "dialect": DotSqlDialect.name_of(dialect),
		"token": FileAccess.get_file_as_string(token_file).strip_edges(),
	}, self)
	driver = made.value

	print("dot-sql live: %s" % DotSqlDialect.name_of(dialect))
	await _run()


func _run() -> void:
	await _test_open()
	await _test_rows()
	await _test_batch()
	await _test_migrate()
	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	_finish()


func _test_open() -> void:
	_section("open")

	var opened := await driver.open()
	_check("the gateway answers", opened.ok, opened)

	# Fresh tables every run; a previous failed run may have left them.
	await driver.execute("DROP TABLE IF EXISTS dot_sql_live")
	await driver.execute("DELETE FROM dot_sql_migrations WHERE component = ?", ["dot_sql_live"])
	await driver.execute("DROP TABLE IF EXISTS dot_sql_live_m")

	var made := await driver.ensure_table({
		"name": "dot_sql_live",
		"columns": [
			{"name": "id", "type": DotSqlDialect.KEY, "null": false},
			{"name": "name", "type": DotSqlDialect.TEXT},
			{"name": "time", "type": DotSqlDialect.REAL, "null": false, "default": 0},
			{"name": "at", "type": DotSqlDialect.BIGINT, "null": false, "default": 0},
			{"name": "ok", "type": DotSqlDialect.BOOL, "null": false, "default": false},
		],
		"primary_key": ["id"],
		"indexes": [{"name": "time", "columns": ["time"]}],
	})
	_check("a table spec creates a table", made.ok, made)
	var again := await driver.ensure_table({
		"name": "dot_sql_live",
		"columns": [{"name": "id", "type": DotSqlDialect.KEY, "null": false}],
		"primary_key": ["id"],
	})
	_check("creating it twice is harmless", again.ok, again)

	_done()


func _test_rows() -> void:
	_section("rows")

	var upsert := driver.upsert_sql("dot_sql_live", PackedStringArray(["id", "name", "time", "at", "ok"]), PackedStringArray(["id"]))
	var first := await driver.execute(upsert, ["p1", "Zoë 🏁 'quotes'", 12345.678, 1790000000, 1])
	_check("an upsert inserts", first.ok, first)
	var second := await driver.execute(upsert, ["p1", "Zoë", 61.25, 1790000001, 0])
	_check("an upsert replaces", second.ok, second)

	var row := await driver.query_one("SELECT * FROM dot_sql_live WHERE id = ?", ["p1"])
	_check("the replaced row reads back", row.ok and row.value is Dictionary and is_equal_approx(float(row.value["time"]), 61.25), row)

	await driver.execute(upsert, ["p2", "Zoë 🏁 'quotes'", 12345.678, 1790000002, 1])
	var p2 := await driver.query_one("SELECT name, time, at FROM dot_sql_live WHERE id = ?", ["p2"])
	_check("a name with an emoji and quotes survives", p2.ok and str(p2.value["name"]) == "Zoë 🏁 'quotes'", p2)
	# Thousandths decide this genre; a REAL column in Postgres would round them away.
	_check("a run time keeps its thousandths", p2.ok and absf(float(p2.value["time"]) - 12345.678) < 0.0005, p2)

	var like := await driver.query_value("SELECT COUNT(*) AS n FROM dot_sql_live WHERE id LIKE 'p%' AND name <> 'who?'", [], 0)
	_check("a literal % and ? are not placeholders", like.ok and int(like.value) == 2, like)

	var refused := await driver.query("SELECT nonsense FROM nowhere")
	_check("a bad statement is a failure, not a crash", not refused.ok)

	_done()


func _test_batch() -> void:
	_section("batch")

	var ok := await driver.batch([
		["UPDATE dot_sql_live SET at = ? WHERE id = ?", [1, "p1"]],
		["UPDATE dot_sql_live SET at = ? WHERE id = ?", [2, "p2"]],
	])
	_check("a batch applies", ok.ok, ok)

	var bad := await driver.batch([
		["UPDATE dot_sql_live SET at = ? WHERE id = ?", [99, "p1"]],
		["INSERT INTO dot_sql_live (id) VALUES (?)", ["p2"]],
	])
	_check("a batch with a failing statement fails", not bad.ok)
	var at := await driver.query_value("SELECT at FROM dot_sql_live WHERE id = ?", ["p1"], -1)
	_check("and none of it applied", at.ok and int(at.value) == 1, at)

	_done()


func _test_migrate() -> void:
	_section("migrate")

	var steps := [
		[{
			"name": "dot_sql_live_m",
			"columns": [{"name": "id", "type": DotSqlDialect.KEY, "null": false}],
			"primary_key": ["id"],
		}],
		[func(d) -> DotResult:
			return await d.execute(DotSqlSchema.add_column("dot_sql_live_m", {"name": "extra", "type": DotSqlDialect.INT, "null": false, "default": 7}, d.dialect()))],
	]
	var first := await driver.migrate("dot_sql_live", steps)
	_check("migrates to 2", first.ok and int(first.value) == 2, first)
	var second := await driver.migrate("dot_sql_live", steps)
	_check("a second run is a no-op", second.ok and int(second.value) == 2, second)
	await driver.execute("INSERT INTO dot_sql_live_m (id) VALUES (?)", ["a"])
	var extra := await driver.query_value("SELECT extra FROM dot_sql_live_m WHERE id = ?", ["a"], 0)
	_check("the added column has its default", extra.ok and int(extra.value) == 7, extra)

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
	await get_tree().process_frame
	print("%d of %d sections ran to their last line" % [_completed, _entered])
	if _entered != SECTIONS or _completed != _entered or _passed + _failed != CHECKS:
		print("ERROR: %d/%d sections, %d/%d checks." % [_completed, SECTIONS, _passed + _failed, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)
