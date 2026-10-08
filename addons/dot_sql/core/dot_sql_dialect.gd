@tool
class_name DotSqlDialect
extends RefCounted

## The three SQLs this family speaks, and every place they differ.
##
## [b]The values are integers on purpose, and they are frozen.[/b] Stores in other addons
## reach a driver duck-typed — `driver.dialect()` — so that an addon which keeps records in
## SQL does not fail to parse in a project without dot-sql. An integer is the one thing such
## a store can compare against without naming this class, and dot-moderation and
## mg-dangerous-delivery already compare against 0, 1 and 2. Reordering this enum would
## silently hand every one of them the wrong SQL.
##
## [b]Statements are written with [code]?[/code] placeholders, everywhere.[/b] Postgres
## numbers its parameters ([code]$1[/code]); a native Postgres driver calls
## [method numbered] at the last moment. The HTTP gateway contract is [code]?[/code] too,
## because that is what PDO, JDBC and most gateway languages take for every backend, so a
## store never has to know which of the three it is talking to in order to bind a value.

enum Kind {
	SQLITE = 0,
	POSTGRES = 1,
	MYSQL = 2,
}

## Abstract column types. [method column_type] spells them per dialect.
##
## [b]There is no timestamp type, and that is deliberate.[/b] Time is Unix seconds in a
## BIGINT. A timestamp column carries a zone, or does not and pretends to, and two game
## servers writing one table are in two places; seconds since the epoch are one number
## everywhere. The site's own database lost a day to exactly this.
const KEY := "key"        ## A short indexed string: an id, a map name. VARCHAR(191) on MySQL.
const TEXT := "text"      ## An unindexed string of any length.
const INT := "int"        ## 32-bit integer.
const BIGINT := "bigint"  ## 64-bit integer. Times, counts that can grow.
const REAL := "real"      ## A double. Run times, points.
const BOOL := "bool"      ## Stored as 0/1 in every dialect; see [method column_type].
const JSON_TEXT := "json" ## A JSON document, stored as text. Never queried into.

const TYPES := [KEY, TEXT, INT, BIGINT, REAL, BOOL, JSON_TEXT]

## Words reserved in at least one of the three, which a table spec may not use as a name.
##
## [b]Refused rather than quoted.[/b] Quoting works until somebody writes a query by hand,
## or a second addon reads the table, and forgets — and the failure is a syntax error on
## one database only, months later. dot-moderation shipped a column named `key` that
## every MySQL refuses (`ERROR 1064`, measured on MariaDB 11) while SQLite and Postgres
## took it happily; `rank`, `row` and `groups` are the same trap on MySQL 8, and `user`,
## `offset` and `order` on Postgres. Not exhaustive — the names a game table is likely to
## want, from all three reserved-word lists.
const RESERVED := [
	"add", "all", "alter", "and", "any", "as", "asc", "between", "both", "by", "case",
	"check", "column", "condition", "constraint", "create", "cross", "current_date",
	"current_time", "current_user", "default", "delete", "desc", "distinct", "div", "drop",
	"else", "end", "exists", "false", "fetch", "for", "foreign", "from", "grant", "group",
	"groups", "having", "in", "index", "inner", "insert", "interval", "into", "is", "join",
	"key", "keys", "lateral", "leading", "left", "like", "limit", "lines", "load", "match",
	"natural", "not", "null", "offset", "on", "only", "or", "order", "outer", "over",
	"partition", "primary", "range", "rank", "read", "references", "release", "rename",
	"repeat", "replace", "require", "returning", "right", "row", "rows", "schema", "select",
	"session_user", "set", "show", "some", "table", "then", "to", "trailing", "true",
	"union", "unique", "update", "usage", "user", "using", "values", "when", "where",
	"window", "with", "write",
]


static func name_of(dialect: int) -> String:
	match dialect:
		Kind.SQLITE:
			return "sqlite"
		Kind.POSTGRES:
			return "postgres"
		Kind.MYSQL:
			return "mysql"
	return "unknown"


## The dialect for a configuration string. Accepts the spellings operators type.
static func from_name(text: String) -> int:
	match text.strip_edges().to_lower():
		"sqlite", "sqlite3":
			return Kind.SQLITE
		"postgres", "postgresql", "pg", "pgsql":
			return Kind.POSTGRES
		"mysql", "mariadb":
			return Kind.MYSQL
	return -1


## A column type in a dialect.
##
## The differences, each of which has cost somebody a day:
##
## - [b]MySQL cannot index TEXT[/b] without a prefix length, so an indexed string is
##   VARCHAR(191) — 191 because four bytes a character times 191 is the 767-byte key
##   limit older InnoDB row formats still enforce.
## - [b]Booleans.[/b] SQLite and MySQL have none worth the name. A 0/1 SMALLINT everywhere
##   means one row mapper rather than three.
## - [b]Doubles.[/b] Postgres spells it DOUBLE PRECISION; REAL there is single precision,
##   and a run time stored in single precision loses its thousandths past four hours.
static func column_type(type: String, dialect: int) -> String:
	match type:
		KEY:
			return "VARCHAR(191)" if dialect == Kind.MYSQL else "TEXT"
		TEXT, JSON_TEXT:
			return "TEXT"
		INT:
			return "INTEGER" if dialect != Kind.MYSQL else "INT"
		BIGINT:
			return "BIGINT" if dialect != Kind.SQLITE else "INTEGER"
		REAL:
			match dialect:
				Kind.POSTGRES:
					return "DOUBLE PRECISION"
				Kind.MYSQL:
					return "DOUBLE"
			return "REAL"
		BOOL:
			return "SMALLINT" if dialect != Kind.SQLITE else "INTEGER"
	return "TEXT"


## Quotes an identifier. Only for names this code chose — never for a value.
##
## Identifiers cannot be bound as parameters, so a table name an operator configured has
## to be spliced in. [method is_safe_identifier] is the gate; this only decorates.
static func quote_ident(name: String, dialect: int) -> String:
	if dialect == Kind.MYSQL:
		return "`%s`" % name
	return "\"%s\"" % name


## Whether a name may be spliced into SQL as an identifier.
##
## Letters, digits and underscores, starting with a letter or underscore, at most 63
## characters (Postgres truncates past that, silently, so two long names collide), and
## not a word any of the three reserves (see [constant RESERVED]). A table prefix comes
## from a config file; this is what stops it carrying a statement.
static func is_safe_identifier(name: String) -> bool:
	if name.is_empty() or name.length() > 63:
		return false
	if RESERVED.has(name.to_lower()):
		return false
	var first := name.unicode_at(0)
	if not (_is_letter(first) or first == 95):
		return false
	for i in range(name.length()):
		var c := name.unicode_at(i)
		if not (_is_letter(c) or (c >= 48 and c <= 57) or c == 95):
			return false
	return true


static func _is_letter(c: int) -> bool:
	return (c >= 65 and c <= 90) or (c >= 97 and c <= 122)


## Rewrites [code]?[/code] placeholders as [code]$1, $2…[/code] for Postgres.
##
## [b]A question mark inside a quoted string is not a placeholder[/b], and a rewrite that
## does not know that turns `WHERE name = 'who?'` into a statement with a parameter nobody
## bound. Single-quoted strings (with `''` escapes), double-quoted identifiers and `--`
## line comments are skipped.
static func numbered(sql: String) -> String:
	var out := ""
	var n := 0
	var i := 0
	var size := sql.length()

	while i < size:
		var c := sql[i]

		if c == "'" or c == "\"":
			var end := _skip_quoted(sql, i)
			out += sql.substr(i, end - i)
			i = end
			continue

		if c == "-" and i + 1 < size and sql[i + 1] == "-":
			var newline := sql.find("\n", i)
			var stop := size if newline < 0 else newline
			out += sql.substr(i, stop - i)
			i = stop
			continue

		if c == "?":
			n += 1
			out += "$%d" % n
		else:
			out += c
		i += 1

	return out


## How many [code]?[/code] placeholders a statement has, by the same rules as [method numbered].
static func count_placeholders(sql: String) -> int:
	var count := 0
	var i := 0
	var size := sql.length()

	while i < size:
		var c := sql[i]
		if c == "'" or c == "\"":
			i = _skip_quoted(sql, i)
			continue
		if c == "-" and i + 1 < size and sql[i + 1] == "-":
			var newline := sql.find("\n", i)
			i = size if newline < 0 else newline
			continue
		if c == "?":
			count += 1
		i += 1

	return count


## The index just past a quoted run starting at [param start]. A doubled quote is an escape.
static func _skip_quoted(sql: String, start: int) -> int:
	var quote := sql[start]
	var i := start + 1
	var size := sql.length()

	while i < size:
		if sql[i] == quote:
			if i + 1 < size and sql[i + 1] == quote:
				i += 2
				continue
			return i + 1
		i += 1

	return size


## An insert that replaces the row when its key already exists.
##
## [b]Three spellings of one idea.[/b] SQLite (3.24+) and Postgres share
## `ON CONFLICT (…) DO UPDATE SET c = excluded.c`; MySQL has
## `ON DUPLICATE KEY UPDATE c = VALUES(c)`, which keys on whichever unique index the row
## hit rather than on a named one — so a table used with this must have exactly one
## unique key besides, or MySQL will pick for you.
##
## [param update_columns] defaults to every non-key column. Pass an empty array to make it
## an insert-or-ignore.
static func upsert(
	dialect: int,
	table: String,
	columns: PackedStringArray,
	key_columns: PackedStringArray,
	update_columns: Variant = null
) -> String:
	var updates: PackedStringArray = PackedStringArray()
	if update_columns is PackedStringArray:
		updates = update_columns
	elif update_columns is Array:
		updates = PackedStringArray(update_columns)
	else:
		for column in columns:
			if not key_columns.has(column):
				updates.append(column)

	var marks := PackedStringArray()
	for _column in columns:
		marks.append("?")

	var head := "INSERT INTO %s (%s) VALUES (%s)" % [
		table, ", ".join(columns), ", ".join(marks)
	]

	if dialect == Kind.MYSQL:
		if updates.is_empty():
			# A no-op assignment rather than INSERT IGNORE, which also swallows every
			# other error on the row — a truncated value, a bad foreign key — as a warning.
			return "%s ON DUPLICATE KEY UPDATE %s = %s" % [head, key_columns[0], key_columns[0]]
		var sets := PackedStringArray()
		for column in updates:
			sets.append("%s = VALUES(%s)" % [column, column])
		return "%s ON DUPLICATE KEY UPDATE %s" % [head, ", ".join(sets)]

	if updates.is_empty():
		return "%s ON CONFLICT (%s) DO NOTHING" % [head, ", ".join(key_columns)]

	var assignments := PackedStringArray()
	for column in updates:
		assignments.append("%s = excluded.%s" % [column, column])

	return "%s ON CONFLICT (%s) DO UPDATE SET %s" % [
		head, ", ".join(key_columns), ", ".join(assignments)
	]


## `LIMIT ? OFFSET ?` — the same in all three, kept here so nobody spells it `LIMIT a, b`,
## which only MySQL and SQLite accept and which reverses the arguments.
static func limit_offset() -> String:
	return "LIMIT ? OFFSET ?"
