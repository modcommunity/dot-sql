@tool
class_name DotSqlDriverSqlite
extends DotSqlDriver

## SQLite, through the `godot-sqlite` GDExtension (github.com/2shady4u/godot-sqlite).
##
## [b]The extension is reached by name and never by identifier.[/b] `ClassDB.instantiate`
## plus `Object.call`, as `DotTransportENet` reaches ENet and for the same reason: a script
## that merely mentions a class the project does not have fails to compile, and takes
## every script that references it down too. So this file compiles with no extension
## installed and says so when asked.
##
## [codeblock]
## var driver := DotSqlDriverSqlite.new("user://records.db")
## var opened := await driver.open()
## [/codeblock]
##
## [b]One process, one file.[/b] SQLite is the right answer for one server keeping its own
## records and the wrong one for five servers sharing them; that is
## [DotSqlDriverGateway]'s job. WAL mode lets a web panel read while the server writes.
##
## [b]What the suite covers.[/b] `tools/fetch_sqlite.sh` installs a pinned godot-sqlite
## release, and with it present `tools/test_live.sh` runs the live suite through this driver
## as well as through the gateway. WAL plus the extension's default `synchronous=FULL`
## means a committed write survives the process being killed, which on a headless server
## is how it always stops: Godot runs no exit notification on SIGINT or SIGTERM.

const EXTENSION_CLASS := "SQLite"

var path: String = "user://dot.db"

## The extension's own statement logging. For a bad afternoon.
var verbose: bool = false

var _db: Object = null


func _init(p_path: String = "user://dot.db") -> void:
	path = p_path


func dialect() -> int:
	return DotSqlDialect.Kind.SQLITE


func driver_name() -> String:
	return "sqlite"


func is_available() -> DotResult:
	if not ClassDB.class_exists(EXTENSION_CLASS):
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED,
			"The SQLite GDExtension is not installed.",
			"run dot-sql's tools/fetch_sqlite.sh <project> and then --import it (Godot loads only the extensions .godot/extension_list.cfg names, and only an import writes that), or point the store at a SQL gateway"
		)
	if not ClassDB.can_instantiate(EXTENSION_CLASS):
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED,
			"The SQLite class exists but cannot be instantiated on this platform.",
			"a GDExtension ships a binary per platform, and the web is usually the one it does not"
		)
	return DotResult.success(true)


func open() -> DotResult:
	if _db != null:
		return DotResult.success(true)

	var available := is_available()
	if not available.ok:
		return available

	# SQLite creates the file but not the directory it goes in, and says only "unable to
	# open database file". A game's default is a path under a directory of its own
	# (user://g2gfast/records.db), which on a fresh server does not exist yet, so every
	# first boot fell back to whatever the store does without a database.
	if path != ":memory:":
		var dir := path.get_base_dir()
		if dir != "" and not DirAccess.dir_exists_absolute(dir):
			var made := DirAccess.make_dir_recursive_absolute(dir)
			if made != OK:
				return DotResult.fail(DotError.CODE_IO, "Could not create the database's directory.", "%s: %s" % [dir, error_string(made)])

	_db = ClassDB.instantiate(EXTENSION_CLASS)
	if _db == null:
		return DotResult.fail(DotError.CODE_INTERNAL, "The SQLite extension would not instantiate.")

	# The extension resolves `user://` itself and wants the Godot path, not an OS one.
	_db.set("path", path)
	_db.set("verbosity_level", 2 if verbose else 0)

	if not bool(_db.call("open_db")):
		var why := str(_db.get("error_message"))
		_db = null
		return DotResult.fail(DotError.CODE_IO, "Could not open the SQLite database.", "%s: %s" % [path, why])

	_db.call("query", "PRAGMA journal_mode=WAL")
	# Without this SQLite does not enforce foreign keys, which makes them decoration.
	_db.call("query", "PRAGMA foreign_keys=ON")
	# A second process holding the write lock is a wait, not an immediate SQLITE_BUSY.
	_db.call("query", "PRAGMA busy_timeout=2000")

	DotLog.info(CHANNEL, "sqlite open", {"path": path})
	return DotResult.success(true)


func close() -> void:
	if _db == null:
		return
	_db.call("close_db")
	_db = null


func is_open() -> bool:
	return _db != null


func supports_transactions() -> bool:
	return true


func _execute(sql: String, params: Array) -> DotResult:
	if _db == null:
		return DotResult.fail(DotError.CODE_STATE, "The database is not open.")
	if not bool(_db.call("query_with_bindings", sql, params)):
		return DotResult.fail(DotError.CODE_IO, "A statement failed.", str(_db.get("error_message")))
	# The rows the statement changed, as the gateway reports them: the contract callers
	# rely on (dot-stats' revision guard, a store's "was there anything to remove").
	# `true` here read as success to every one of them, so a lost race on a shared
	# SQLite file was never detected.
	_db.call("query", "SELECT changes() AS n")
	var counted: Variant = _db.get("query_result")
	if counted is Array and not (counted as Array).is_empty() and (counted as Array)[0] is Dictionary:
		return DotResult.success(int(((counted as Array)[0] as Dictionary).get("n", 0)))
	return DotResult.success(0)


func _query(sql: String, params: Array) -> DotResult:
	if _db == null:
		return DotResult.fail(DotError.CODE_STATE, "The database is not open.")
	if not bool(_db.call("query_with_bindings", sql, params)):
		return DotResult.fail(DotError.CODE_IO, "A query failed.", str(_db.get("error_message")))
	var rows: Variant = _db.get("query_result")
	# The extension reuses its result array between queries; a caller holding the last
	# answer would see it change under them.
	return DotResult.success((rows as Array).duplicate(true) if rows is Array else [])


func batch(statements: Array) -> DotResult:
	if _db == null:
		return DotResult.fail(DotError.CODE_STATE, "The database is not open.")

	_db.call("query", "BEGIN")
	var done := 0
	for entry in statements:
		var pair := _pair(entry)
		if pair.is_empty():
			continue
		var result: DotResult = await execute(pair[0], pair[1])
		if not result.ok:
			_db.call("query", "ROLLBACK")
			return result.wrap("Statement %d of %d failed; rolled back." % [done + 1, statements.size()])
		done += 1
	_db.call("query", "COMMIT")
	return DotResult.success(done)


func describe() -> Dictionary:
	var out := super.describe()
	out["path"] = path
	out["available"] = is_available().ok
	return out
