@tool
class_name DotSqlDriverRecording
extends DotSqlDriver

## Writes nothing and remembers everything it was asked to do.
##
## For a store's own suite: what a store gets wrong is which statements it sends, in what
## order, with which values bound where — and none of that needs a database to check.
## Queries are answered from [member rows], or from [member answers] by a substring of the
## statement, so the read path and the row mapping run for real rather than being assumed.
##
## What this cannot tell you is whether the SQL is valid. `examples/sql_live.tscn` against
## `tools/sql_gateway.py` is how that is checked.

## Every statement, in order, as [code]{sql, params}[/code].
var statements: Array[Dictionary] = []

## Rows every query answers, unless [member answers] has a better match.
var rows: Array = []

## Substring of a statement -> rows for it. The first match wins.
var answers: Dictionary = {}

## Makes the next call fail with this message, for testing what a store does about it.
var fail_next: String = ""

var sql_dialect: int = DotSqlDialect.Kind.SQLITE
var _open: bool = false


func _init(p_dialect: int = DotSqlDialect.Kind.SQLITE) -> void:
	sql_dialect = p_dialect


func dialect() -> int:
	return sql_dialect


func driver_name() -> String:
	return "recording"


func is_available() -> DotResult:
	return DotResult.success(true)


func open() -> DotResult:
	_open = true
	return DotResult.success(true)


func close() -> void:
	_open = false


func is_open() -> bool:
	return _open


func supports_transactions() -> bool:
	return true


func _execute(sql: String, params: Array) -> DotResult:
	statements.append({"sql": sql, "params": params.duplicate()})
	if fail_next != "":
		var why := fail_next
		fail_next = ""
		return DotResult.fail(DotError.CODE_IO, why)
	return DotResult.success(1)


func _query(sql: String, params: Array) -> DotResult:
	statements.append({"sql": sql, "params": params.duplicate()})
	if fail_next != "":
		var why := fail_next
		fail_next = ""
		return DotResult.fail(DotError.CODE_IO, why)
	for needle in answers:
		if sql.contains(str(needle)):
			return DotResult.success((answers[needle] as Array).duplicate(true))
	return DotResult.success(rows.duplicate(true))


## Statements whose SQL contains [param needle], for an assertion.
func matching(needle: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry in statements:
		if str(entry["sql"]).contains(needle):
			out.append(entry)
	return out


func clear() -> void:
	statements.clear()
