@tool
class_name DotSqlDriverGateway
extends DotSqlDriver

## PostgreSQL, MySQL or SQLite, through a small HTTP service beside the database.
##
## [b]Why HTTP, and why this is usually the right answer rather than a workaround.[/b]
## Godot has no Postgres or MySQL client, and neither protocol can be spoken from GDScript
## without implementing an authentication handshake (SCRAM-SHA-256, caching_sha2_password),
## a binary wire format and a connection pool — a project, not a file, and a half-finished
## one is a security problem. And a game server holding a database password is a game
## server whose compromise is the database's; a gateway holds the password instead and can
## be limited to the tables the game uses. `tools/sql_gateway.py` is a reference one.
##
## [codeblock]
## POST {base_url}/query   {"sql": "...", "params": [...], "dialect": "postgres"}
##   -> 200 {"rows": [{...}], "affected": n}
## POST {base_url}/batch   {"statements": [{"sql": "...", "params": [...]}], "dialect": "..."}
##   -> 200 {"done": n}           all applied in one transaction, or none
##   -> 200 {"error": "..."}      the statement was refused; nothing in a batch applied
##   -> 401                       wrong or missing token
##
## [b]A refused statement is a 200 carrying [code]error[/code][/b], not a 4xx, because
## [DotHttp] retries every non-2xx answer and a statement that failed once fails the same
## way twice more, a second and a half later, holding up whatever was waiting on it.
## [/codeblock]
##
## Placeholders are [code]?[/code] on the wire whatever the dialect; the gateway binds them
## the way its own client library wants. A gateway in PHP passes them to PDO untouched.
##
## [b]The token is a bearer secret[/b] and is only ever sent to the configured URL. Put the
## gateway on a private address or behind TLS: over plain HTTP on a public network the
## token is readable by anybody on the path, and with it every table the gateway allows.

var base_url: String = ""

## Sent as `Authorization: Bearer <token>`. Never logged; see [method describe].
var token: String = ""

var sql_dialect: int = DotSqlDialect.Kind.POSTGRES

## A [DotHttp] in the scene tree. [HTTPRequest] is a Node, so this driver cannot make its own.
var http: DotHttp = null

var _open: bool = false


func _init(p_base_url: String = "", p_dialect: int = DotSqlDialect.Kind.POSTGRES) -> void:
	base_url = p_base_url
	sql_dialect = p_dialect


func dialect() -> int:
	return sql_dialect


func driver_name() -> String:
	return "gateway/%s" % DotSqlDialect.name_of(sql_dialect)


func is_available() -> DotResult:
	if base_url.strip_edges() == "":
		return DotResult.fail(DotError.CODE_INVALID, "A SQL gateway driver needs a base_url.")
	if DotSqlDialect.name_of(sql_dialect) == "unknown":
		return DotResult.fail(DotError.CODE_INVALID, "Unknown SQL dialect.", str(sql_dialect))
	return DotResult.success(true)


## Checks the gateway answers, so a wrong URL or token is found at boot and not on the
## first record somebody sets.
func open() -> DotResult:
	var available := is_available()
	if not available.ok:
		return available
	if http == null:
		return DotResult.fail(
			DotError.CODE_STATE, "A SQL gateway driver needs a DotHttp.",
			"add a DotHttp to the scene tree and assign it to .http"
		)
	if http.max_retries > 0:
		# DotHttp retries a timeout, and a write that timed out may already have committed:
		# retried, `points = points + 3` adds six. Statements are not idempotent in general,
		# so the gateway's DotHttp should be its own, with retries off.
		DotLog.warn(CHANNEL, "the SQL gateway's DotHttp retries; a retried write can apply twice", {
			"max_retries": http.max_retries, "fix": "give the driver its own DotHttp with max_retries = 0",
		})
	_open = true
	var probe := await _post("/query", {"sql": "SELECT 1 AS ok", "params": []})
	if not probe.ok:
		_open = false
		return probe.wrap("The SQL gateway at %s did not answer." % base_url)
	DotLog.info(CHANNEL, "sql gateway open", {"url": base_url, "dialect": DotSqlDialect.name_of(sql_dialect)})
	return DotResult.success(true)


func close() -> void:
	_open = false


func is_open() -> bool:
	return _open


func supports_transactions() -> bool:
	return true


func _execute(sql: String, params: Array) -> DotResult:
	var result := await _post("/query", {"sql": sql, "params": params})
	if not result.ok:
		return result
	return DotResult.success(int((result.value as Dictionary).get("affected", 0)))


func _query(sql: String, params: Array) -> DotResult:
	var result := await _post("/query", {"sql": sql, "params": params})
	if not result.ok:
		return result
	var rows: Variant = (result.value as Dictionary).get("rows", [])
	return DotResult.success(rows if rows is Array else [])


func batch(statements: Array) -> DotResult:
	var list: Array = []
	for entry in statements:
		var pair := _pair(entry)
		if not pair.is_empty():
			list.append({"sql": pair[0], "params": pair[1]})
	if list.is_empty():
		return DotResult.success(0)
	var started := Time.get_ticks_msec()
	var result := await _post("/batch", {"statements": list})
	_timed("batch of %d" % list.size(), started, result)
	if not result.ok:
		return result
	return DotResult.success(int((result.value as Dictionary).get("done", list.size())))


func _post(route: String, body: Dictionary) -> DotResult:
	if not _open or http == null:
		return DotResult.fail(DotError.CODE_STATE, "The gateway is not open.")

	body["dialect"] = DotSqlDialect.name_of(sql_dialect)
	var headers := {}
	if token != "":
		headers["Authorization"] = "Bearer %s" % token

	# Serialised here with full precision rather than through `post_json`, whose plain
	# `JSON.stringify` keeps about fifteen significant digits: a run time of
	# 25.123456789012345 reached the database as 25.1234567890123, so the time a server
	# had just filed was not the time the database held, and a cached best ranked the
	# player behind their own row. Every float that crosses here is a value somebody
	# compares exactly.
	headers["Content-Type"] = "application/json"
	var raw := await http.request(
		HTTPClient.METHOD_POST, base_url.trim_suffix("/") + route,
		JSON.stringify(body, "", true, true).to_utf8_buffer(), headers
	)
	var response := raw
	if raw.ok:
		var parsed_body: Variant = JSON.parse_string(str((raw.value as Dictionary).get("body_text", "")))
		response = DotResult.success(parsed_body) if parsed_body != null else DotResult.fail(
			DotError.CODE_PARSE, "The SQL gateway's answer is not JSON."
		)

	if not response.ok:
		# A refused statement comes back as a 4xx carrying {"error": "..."}; say what the
		# database said rather than "HTTP 400".
		var detail := response.error.detail if response.error != null else ""
		var parsed: Variant = JSON.parse_string(detail) if detail.begins_with("{") else null
		if parsed is Dictionary and (parsed as Dictionary).has("error"):
			return DotResult.fail(DotError.CODE_IO, "The SQL gateway refused a statement.", str(parsed["error"]))
		return response.wrap("The SQL gateway did not answer.")

	if not (response.value is Dictionary):
		return DotResult.fail(DotError.CODE_PARSE, "The SQL gateway did not return an object.")

	var document: Dictionary = response.value
	if document.has("error"):
		return DotResult.fail(DotError.CODE_IO, "The SQL gateway refused a statement.", str(document["error"]))

	return DotResult.success(document)


func describe() -> Dictionary:
	var out := super.describe()
	out["base_url"] = base_url
	# Never the token itself: this is what reaches a console dump and a pasted bug report.
	out["authenticated"] = token != ""
	return out
