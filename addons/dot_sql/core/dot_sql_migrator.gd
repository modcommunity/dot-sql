@tool
class_name DotSqlMigrator
extends RefCounted

## Versioned schema changes, one counter per component, in one shared table.
##
## [b]Why a counter and not "create if missing".[/b] `CREATE TABLE IF NOT EXISTS` is enough
## for version one and wrong for version two: a table that exists from last month does not
## grow the column this month's build reads, and nothing errors until the first query that
## names it. A step that adds a column has to run exactly once, which needs a record of
## what has run.
##
## [codeblock]
## var steps := [
##     [records_table, stages_table],                         # -> 1: plain table specs
##     ["ALTER TABLE dot_timer_records ADD COLUMN flags INTEGER NOT NULL DEFAULT 0"],  # -> 2
## ]
## await driver.migrate("dot_timer", steps)
## [/codeblock]
##
## A step is an [Array] whose entries are a SQL [String], [code][sql, params][/code], a
## table spec [Dictionary] (see [DotSqlSchema]), or a [Callable] taking the driver and
## returning a [DotResult] — for the step that has to say something different per dialect.
##
## [b]A database newer than the code is refused[/b], not read. A build that does not know
## what version three added would read rows it half understands and write rows missing
## what version three needs. Rolling a server back is then a decision somebody makes
## knowingly, rather than a quiet corruption.
##
## [b]Two servers migrating one database at once[/b] is the normal case on a community
## running several servers against one MySQL. Creation is idempotent; an ADD COLUMN is
## not, and the second server's fails. So a failed step re-reads the counter, and if the
## other server got there first, carries on.

const TABLE := "dot_sql_migrations"

const CHANNEL := "sql.migrate"

var driver = null


func _init(p_driver = null) -> void:
	driver = p_driver


static func table_spec() -> Dictionary:
	return {
		"name": TABLE,
		"columns": [
			{"name": "component", "type": DotSqlDialect.KEY, "null": false},
			{"name": "version", "type": DotSqlDialect.INT, "null": false, "default": 0},
			{"name": "applied_at", "type": DotSqlDialect.BIGINT, "null": false, "default": 0},
		],
		"primary_key": ["component"],
	}


## The version recorded for [param component]; 0 when it has never migrated.
func version_of(component: String) -> DotResult:
	var made: DotResult = await driver.ensure_table(table_spec())
	if not made.ok:
		return made
	var got: DotResult = await driver.query_value(
		"SELECT version FROM %s WHERE component = ?" % TABLE, [component], 0
	)
	if not got.ok:
		return got
	return DotResult.success(int(got.value))


func migrate(component: String, steps: Array) -> DotResult:
	if driver == null:
		return DotResult.fail(DotError.CODE_STATE, "A migrator needs a driver.")
	if component.strip_edges() == "":
		return DotResult.fail(DotError.CODE_INVALID, "A migration needs a component name.")

	var current_result := await version_of(component)
	if not current_result.ok:
		return current_result.wrap("Could not read the schema version of %s." % component)

	var current: int = current_result.value
	var target := steps.size()

	if current > target:
		return DotResult.fail(
			DotError.CODE_VERSION,
			"The database was written by a newer build.",
			"%s is at schema %d and this build knows %d; upgrade the server, or restore a backup" % [
				component, current, target
			]
		)

	while current < target:
		var step: Variant = steps[current]
		var applied := await _apply(step)

		if not applied.ok:
			# Somebody else may have run this step between our read and our write.
			var again := await version_of(component)
			if again.ok and int(again.value) > current:
				current = int(again.value)
				continue
			return applied.wrap("Migrating %s to %d failed." % [component, current + 1])

		current += 1

		var recorded: DotResult = await driver.execute(
			driver.upsert_sql(TABLE, PackedStringArray(["component", "version", "applied_at"]),
				PackedStringArray(["component"])),
			[component, current, int(Time.get_unix_time_from_system())]
		)
		if not recorded.ok:
			return recorded.wrap("Could not record %s at %d." % [component, current])

		DotLog.info(CHANNEL, "schema migrated", {"component": component, "version": current})

	return DotResult.success(current)


func _apply(step: Variant) -> DotResult:
	var entries: Array = step if step is Array else [step]

	for entry in entries:
		var result: DotResult
		if entry is Dictionary:
			result = await driver.ensure_table(entry)
		elif entry is Callable:
			result = await (entry as Callable).call(driver)
		elif entry is String:
			result = await driver.execute(entry)
		elif entry is Array and not (entry as Array).is_empty():
			var params: Array = entry[1] if (entry as Array).size() > 1 and entry[1] is Array else []
			result = await driver.execute(str(entry[0]), params)
		else:
			return DotResult.fail(DotError.CODE_INVALID, "A migration step has an entry it cannot run.")

		if result == null or not result.ok:
			return result if result != null else DotResult.fail(
				DotError.CODE_INTERNAL, "A migration callable returned nothing."
			)

	return DotResult.success(true)
