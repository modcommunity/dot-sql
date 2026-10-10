#!/usr/bin/env bash
# Runs a live SQL suite against real databases through tools/sql_gateway.py.
#
#   tools/test_live.sh                                   # dot-sql's own suite, SQLite only
#   tools/test_live.sh ../dot-timer res://examples/timer_sql_live.tscn
#   DOT_SQL_PG_DSN=postgresql://u:p@127.0.0.1/dot_sql_test tools/test_live.sh
#   DOT_SQL_MYSQL_DSN=mysql://u:p@127.0.0.1:3306/dot_sql_test tools/test_live.sh
#
# SQLite always runs (Python ships it). Postgres and MySQL run when their DSN is set, and
# need psycopg / pymysql importable by $DOT_SQL_PYTHON (default python3).
#
# Any other addon's live suite is run the same way: it reads DOT_SQL_URL, DOT_SQL_DIALECT
# and DOT_SQL_TOKEN_FILE, exactly as examples/sql_live.gd does.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
project="$(cd "${1:-$here}" && pwd)"
scene="${2:-res://examples/sql_live.tscn}"
python="${DOT_SQL_PYTHON:-python3}"
godot="${GODOT:-godot}"
work="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$work"' EXIT

head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$work/token"
chmod 600 "$work/token"

failed=0
port=$((18780 + RANDOM % 1000))

run() {
    local dialect="$1" dsn="$2"
    port=$((port + 1))
    "$python" "$here/tools/sql_gateway.py" --dialect "$dialect" --dsn "$dsn" \
        --token-file "$work/token" --port "$port" > "$work/gw-$dialect.log" 2>&1 &
    local pid=$!
    for _ in $(seq 50); do
        grep -q "gateway:" "$work/gw-$dialect.log" 2>/dev/null && break
        sleep 0.1
    done
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "== $dialect: the gateway did not start"; cat "$work/gw-$dialect.log"; failed=1; return
    fi
    echo "== $dialect"
    DOT_SQL_URL="http://127.0.0.1:$port" DOT_SQL_DIALECT="$dialect" DOT_SQL_TOKEN_FILE="$work/token" \
        timeout 120 "$godot" --headless --path "$project" "$scene" > "$work/out-$dialect.log" 2>&1
    local code=$?
    grep -v "^Godot Engine\|^$" "$work/out-$dialect.log" | grep -v "^  .* ok$" || true
    # A script error inside a section aborts it without failing the run; say so.
    if grep -q "SCRIPT ERROR\|Parse Error" "$work/out-$dialect.log"; then
        echo "   (script errors above)"; code=1
    fi
    [ "$code" -eq 0 ] || failed=1
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
}

run sqlite "$work/live.db"

# And SQLite through the extension itself, with no gateway in between, when the project
# has it (tools/fetch_sqlite.sh). The only run that reaches DotSqlDriverSqlite's calls.
if [ -f "$project/addons/godot-sqlite/gdsqlite.gdextension" ]; then
    echo "== sqlite (extension)"
    DOT_SQL_SQLITE_PATH="$work/direct.db" timeout 120 "$godot" --headless --path "$project" "$scene" \
        > "$work/out-direct.log" 2>&1
    code=$?
    # The extension prints its own ERROR for each statement a suite fails on purpose.
    grep -v "^Godot Engine\|^$\|^ERROR:  --> SQL error\|^   at: \|^   GDScript backtrace\|^       \[" "$work/out-direct.log" | grep -v "^  .* ok$" || true
    if grep -q "SCRIPT ERROR\|Parse Error" "$work/out-direct.log"; then
        echo "   (script errors above)"; code=1
    fi
    [ "$code" -eq 0 ] || failed=1
else
    echo "== sqlite (extension): not installed here; tools/fetch_sqlite.sh . to run it"
fi
[ -n "${DOT_SQL_PG_DSN:-}" ] && run postgres "$DOT_SQL_PG_DSN"
[ -n "${DOT_SQL_MYSQL_DSN:-}" ] && run mysql "$DOT_SQL_MYSQL_DSN"

exit $failed
