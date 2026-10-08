@tool
class_name DotSqlSchema
extends RefCounted

## Tables as plain data, rendered to DDL per dialect.
##
## [b]A table is a [Dictionary], not an object of this class[/b], because the stores that
## declare tables live in addons that must not name dot-sql (see [DotSqlDialect]). A store
## builds the dictionary and hands it to [method DotSqlDriver.ensure_table]; the driver,
## which IS dot-sql, renders it. So the DDL for three dialects is written once, here,
## rather than once per addon — and the next store does not get to forget that MySQL
## cannot index TEXT.
##
## [codeblock]
## {
##     "name": "dot_timer_records",
##     "columns": [
##         {"name": "map", "type": "key", "null": false},
##         {"name": "time", "type": "real", "null": false},
##         {"name": "set_at", "type": "bigint", "default": 0},
##     ],
##     "primary_key": ["map", "player"],
##     "indexes": [
##         {"name": "board", "columns": ["map", "track", "style", "time"]},
##         {"name": "player_unique", "columns": ["player"], "unique": true},
##     ],
## }
## [/codeblock]
##
## [b]Every statement is idempotent[/b] ([code]IF NOT EXISTS[/code]) so a server can run
## them on every boot and an operator who created a table by hand is not fought with —
## except on MySQL, which has no [code]CREATE INDEX IF NOT EXISTS[/code]; there the
## indexes go inside the CREATE TABLE, which is only run when the table is new.


## Checks a table spec. Every identifier in it will be spliced into SQL, so every one is
## checked here rather than trusted.
static func validate(spec: Dictionary) -> DotResult:
	var name := str(spec.get("name", ""))
	if not DotSqlDialect.is_safe_identifier(name):
		return DotResult.fail(DotError.CODE_INVALID, "Unsafe table name.", name)

	var columns: Variant = spec.get("columns", [])
	if not (columns is Array) or (columns as Array).is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "A table needs columns.", name)

	var seen := {}
	for column in columns:
		if not (column is Dictionary):
			return DotResult.fail(DotError.CODE_INVALID, "A column must be a dictionary.", name)
		var cname := str((column as Dictionary).get("name", ""))
		if not DotSqlDialect.is_safe_identifier(cname):
			return DotResult.fail(DotError.CODE_INVALID, "Unsafe column name.", "%s.%s" % [name, cname])
		if seen.has(cname):
			return DotResult.fail(DotError.CODE_INVALID, "A column is declared twice.", "%s.%s" % [name, cname])
		var ctype := str((column as Dictionary).get("type", DotSqlDialect.TEXT))
		if not DotSqlDialect.TYPES.has(ctype):
			return DotResult.fail(DotError.CODE_INVALID, "Unknown column type.", "%s.%s: %s" % [name, cname, ctype])
		seen[cname] = ctype

	for key in _names(spec.get("primary_key", [])):
		if not seen.has(key):
			return DotResult.fail(DotError.CODE_INVALID, "The primary key names a missing column.", "%s.%s" % [name, key])
		# MySQL cannot key on TEXT, and a primary key on an unbounded string is a mistake
		# in the other two as well.
		if seen[key] == DotSqlDialect.TEXT or seen[key] == DotSqlDialect.JSON_TEXT:
			return DotResult.fail(DotError.CODE_INVALID, "A key column must be `key`, not `text`.", "%s.%s" % [name, key])

	for index in spec.get("indexes", []):
		if not (index is Dictionary):
			return DotResult.fail(DotError.CODE_INVALID, "An index must be a dictionary.", name)
		var iname := str((index as Dictionary).get("name", ""))
		if not DotSqlDialect.is_safe_identifier("%s_%s" % [name, iname]):
			return DotResult.fail(DotError.CODE_INVALID, "Unsafe index name.", iname)
		var icolumns := _names((index as Dictionary).get("columns", []))
		if icolumns.is_empty():
			return DotResult.fail(DotError.CODE_INVALID, "An index needs columns.", iname)
		for icolumn in icolumns:
			if not seen.has(icolumn):
				return DotResult.fail(DotError.CODE_INVALID, "An index names a missing column.", "%s: %s" % [iname, icolumn])
			if seen[icolumn] == DotSqlDialect.TEXT or seen[icolumn] == DotSqlDialect.JSON_TEXT:
				return DotResult.fail(DotError.CODE_INVALID, "An indexed column must be `key`, not `text`.", "%s: %s" % [iname, icolumn])

	return DotResult.success(true)


## Every statement that creates [param spec] in [param dialect], in order.
static func ddl(spec: Dictionary, dialect: int) -> PackedStringArray:
	var out := PackedStringArray()
	var table := str(spec["name"])
	var lines := PackedStringArray()

	for column in spec["columns"]:
		lines.append("  " + column_sql(column, dialect))

	var primary := _names(spec.get("primary_key", []))
	if not primary.is_empty():
		lines.append("  PRIMARY KEY (%s)" % ", ".join(primary))

	var indexes: Array = spec.get("indexes", [])

	if dialect == DotSqlDialect.Kind.MYSQL:
		for index in indexes:
			lines.append("  %sKEY %s_%s (%s)" % [
				"UNIQUE " if bool(index.get("unique", false)) else "",
				table, str(index["name"]), ", ".join(_names(index["columns"])),
			])

	var tail := ""
	if dialect == DotSqlDialect.Kind.MYSQL:
		# utf8mb4, or a player name with an emoji in it fails the insert. The server
		# default is still latin1 on more installations than anybody would guess.
		tail = " DEFAULT CHARSET=utf8mb4"

	out.append("CREATE TABLE IF NOT EXISTS %s (\n%s\n)%s" % [table, ",\n".join(lines), tail])

	if dialect != DotSqlDialect.Kind.MYSQL:
		for index in indexes:
			out.append("CREATE %sINDEX IF NOT EXISTS %s_%s ON %s (%s)" % [
				"UNIQUE " if bool(index.get("unique", false)) else "",
				table, str(index["name"]), table, ", ".join(_names(index["columns"])),
			])

	return out


## One column's definition, as it appears in CREATE TABLE and in ALTER TABLE ADD COLUMN.
static func column_sql(column: Dictionary, dialect: int) -> String:
	var line := "%s %s" % [
		str(column["name"]),
		DotSqlDialect.column_type(str(column.get("type", DotSqlDialect.TEXT)), dialect),
	]
	if not bool(column.get("null", true)):
		line += " NOT NULL"
	if column.has("default"):
		line += " DEFAULT %s" % _literal(column["default"])
	return line


## An ALTER that adds [param column] to [param table]. For a migration step.
##
## No IF NOT EXISTS — MySQL and older SQLite have none — so a migration that adds a column
## must run exactly once, which is what [DotSqlMigrator] is for.
static func add_column(table: String, column: Dictionary, dialect: int) -> String:
	return "ALTER TABLE %s ADD COLUMN %s" % [table, column_sql(column, dialect)]


## A default, as SQL. Numbers and booleans only, plus strings with quotes doubled; a
## default is a constant somebody wrote in code, never a value from a player.
static func _literal(value: Variant) -> String:
	match typeof(value):
		TYPE_BOOL:
			return "1" if value else "0"
		TYPE_INT:
			return str(value)
		TYPE_FLOAT:
			return String.num(value)
		TYPE_NIL:
			return "NULL"
	return "'%s'" % str(value).replace("'", "''")


static func _names(value: Variant) -> PackedStringArray:
	var out := PackedStringArray()
	if value is Array or value is PackedStringArray:
		for item in value:
			out.append(str(item))
	return out
