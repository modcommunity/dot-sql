@tool
class_name DotSqlDriver
extends RefCounted

## Runs statements against a database. One subclass per way of reaching one.
##
## [b]Godot ships no database client, and this interface exists to be honest about it.[/b]
## There is no `SQLite`, `PostgreSQLClient` or `MySQL` class in the engine; each is a
## GDExtension somebody installs, or a server somebody runs. So a store does everything
## GDScript can do — choose the tables, build parameterised statements, bind values, map
## rows — and the one step that needs a native library is behind this class.
##
## [b]Stores reach a driver duck-typed.[/b] dot-timer, dot-stats and the rest hold it in an
## untyped variable and call [method query], [method execute], [method dialect] and
## [method ensure_table] on it, so none of them fails to parse in a project that has not
## installed dot-sql. That is the whole public contract and it is plain data in and out:
##
## - statements use [code]?[/code] placeholders, in every dialect;
## - [method query] answers an [Array] of [Dictionary] rows keyed by column name;
## - numbers may come back as [float] (JSON has one number type), so a row mapper wraps
##   integers in [code]int()[/code];
## - every method returns a [DotResult] and every one is a coroutine.
##
## [b]Never build a statement by concatenation.[/b] A player name is the string most likely
## to contain a quote and the one an attacker chooses.

const CHANNEL := "sql"

## Statements slower than this are logged at WARN. A database that has started to drag is
## the cause of a timer that has started to stutter, and nothing else will say so.
var slow_ms: int = 250


## Which SQL this driver speaks: a [enum DotSqlDialect.Kind] as a plain integer.
func dialect() -> int:
	return DotSqlDialect.Kind.SQLITE


func driver_name() -> String:
	return "none"


## Whether what this driver needs is there, answered before anything is opened — so a
## deployment hears "the SQLite extension is not installed" rather than a first write failing.
func is_available() -> DotResult:
	return DotResult.fail(DotError.CODE_UNSUPPORTED, "This driver has no backend.")


func open() -> DotResult:
	return DotResult.fail(DotError.CODE_UNSUPPORTED, "This driver cannot open.")


func close() -> void:
	pass


func is_open() -> bool:
	return false


## Runs a statement that returns no rows.
func execute(sql: String, params: Array = []) -> DotResult:
	var started := Time.get_ticks_msec()
	var result: DotResult = await _execute(sql, params)
	_timed(sql, started, result)
	return result


## Runs a statement and returns its rows.
func query(sql: String, params: Array = []) -> DotResult:
	var started := Time.get_ticks_msec()
	var result: DotResult = await _query(sql, params)
	_timed(sql, started, result)
	if result.ok and not (result.value is Array):
		return DotResult.success([])
	return result


## The first row of a query, or a success carrying null when there is none.
func query_one(sql: String, params: Array = []) -> DotResult:
	var result: DotResult = await query(sql, params)
	if not result.ok:
		return result
	var rows: Array = result.value
	return DotResult.success(rows[0] if not rows.is_empty() else null)


## The first column of the first row, or [param default] when there is no row.
func query_value(sql: String, params: Array = [], default: Variant = null) -> DotResult:
	var result: DotResult = await query_one(sql, params)
	if not result.ok:
		return result
	var row: Variant = result.value
	if row is Dictionary and not (row as Dictionary).is_empty():
		var value: Variant = (row as Dictionary).values()[0]
		return DotResult.success(default if value == null else value)
	return DotResult.success(default)


## Runs [code][[sql, params], …][/code] as one unit.
##
## The default runs them in order with no transaction, which is honest rather than
## pretending: a driver that has transactions overrides this, and a store that needs
## atomicity asks [method supports_transactions].
func batch(statements: Array) -> DotResult:
	var done := 0
	for entry in statements:
		var pair := _pair(entry)
		if pair.is_empty():
			continue
		var result: DotResult = await execute(pair[0], pair[1])
		if not result.ok:
			return result.wrap("Statement %d of %d failed." % [done + 1, statements.size()])
		done += 1
	return DotResult.success(done)


func supports_transactions() -> bool:
	return false


## Creates a table described as plain data, if it is not there. See [DotSqlSchema].
func ensure_table(spec: Dictionary) -> DotResult:
	var valid := DotSqlSchema.validate(spec)
	if not valid.ok:
		return valid
	for statement in DotSqlSchema.ddl(spec, dialect()):
		var result: DotResult = await execute(statement)
		if not result.ok:
			return result.wrap("Could not create %s." % str(spec["name"]))
	return DotResult.success(true)


## An upsert in this driver's dialect. See [method DotSqlDialect.upsert].
func upsert_sql(
	table: String,
	columns: PackedStringArray,
	key_columns: PackedStringArray,
	update_columns: Variant = null
) -> String:
	return DotSqlDialect.upsert(dialect(), table, columns, key_columns, update_columns)


## Brings [param component]'s tables up to [code]steps.size()[/code]. See [DotSqlMigrator].
func migrate(component: String, steps: Array) -> DotResult:
	return await DotSqlMigrator.new(self).migrate(component, steps)


func _execute(_sql: String, _params: Array) -> DotResult:
	return DotResult.fail(DotError.CODE_UNSUPPORTED, "This driver cannot execute.")


func _query(_sql: String, _params: Array) -> DotResult:
	return DotResult.fail(DotError.CODE_UNSUPPORTED, "This driver cannot query.")


## Normalises one batch entry to [code][sql, params][/code], or [] to skip it.
static func _pair(entry: Variant) -> Array:
	if entry is String:
		return [entry, []]
	if not (entry is Array) or (entry as Array).is_empty():
		return []
	var list := entry as Array
	var params: Array = list[1] if list.size() > 1 and list[1] is Array else []
	return [str(list[0]), params]


func _timed(sql: String, started: int, result: DotResult) -> void:
	var took := Time.get_ticks_msec() - started
	if not result.ok:
		# DEBUG, not WARN: the caller gets the failure and decides how loud it is. A
		# uniqueness race a store expects and retries is not an operator's problem.
		DotLog.debug(CHANNEL, "statement failed", {
			"driver": driver_name(), "sql": sql.left(160), "why": result.error.message,
		})
	elif took >= slow_ms:
		DotLog.warn(CHANNEL, "slow statement", {
			"driver": driver_name(), "ms": took, "sql": sql.left(160),
		})


func describe() -> Dictionary:
	return {
		"driver": driver_name(),
		"dialect": DotSqlDialect.name_of(dialect()),
		"open": is_open(),
	}
