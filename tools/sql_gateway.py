#!/usr/bin/env python3
"""A reference SQL gateway for dot-sql's DotSqlDriverGateway.

Godot cannot speak the Postgres or MySQL wire protocols, so a game server reaches those
databases through a small HTTP service that holds the credentials instead. This is one,
in about two hundred lines of standard library plus the database's own client:

    python3 tools/sql_gateway.py --dialect sqlite   --dsn ./records.db           --token-file tok
    python3 tools/sql_gateway.py --dialect postgres --dsn postgresql://u:p@h/db  --token-file tok
    python3 tools/sql_gateway.py --dialect mysql    --dsn mysql://u:p@h:3306/db  --token-file tok

Postgres needs `pip install "psycopg[binary]"`, MySQL `pip install pymysql`.

It is a REFERENCE: one connection, one request at a time. That is plenty for a handful of
game servers writing records and it is the shape to copy, not a pool to deploy at scale.

What it does and does not protect:

- A bearer token is required on every request, compared in constant time, and read from a
  file rather than argv, because argv is visible in `ps` to every user on the machine.
- It binds 127.0.0.1 unless told otherwise. Put TLS in front of it (nginx) before exposing
  it; over plain HTTP the token is readable by anybody on the path.
- It runs whatever SQL the holder of the token sends. The fence is the DATABASE USER it
  connects as: grant that user rights on the game's tables (`dot_*`) and nothing else.
  A gateway that tried to parse SQL to decide what is allowed would be a worse fence than
  the database's own privilege system, and a false sense of one.

The contract (see addons/dot_sql/driver/dot_sql_driver_gateway.gd):

    POST /query  {"sql", "params", "dialect"}            -> {"rows": [...], "affected": n}
    POST /batch  {"statements": [{"sql","params"}], ...} -> {"done": n}   one transaction
    a refused statement                                  -> 200 {"error": "..."}
    a bad token                                          -> 401
"""

import argparse
import datetime
import decimal
import hmac
import json
import sqlite3
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, unquote

MAX_BODY = 4 * 1024 * 1024


def to_format_style(sql: str) -> str:
    """Rewrites `?` placeholders as `%s` for psycopg and pymysql.

    Both use Python %-formatting when parameters are given, so every literal `%` has to be
    doubled first — a `LIKE 'surf_%'` would otherwise be read as a placeholder. A `?`
    inside a quoted string or a `--` comment is not a placeholder and is left alone.
    """
    out = []
    i = 0
    n = len(sql)
    while i < n:
        c = sql[i]
        if c in ("'", '"'):
            j = i + 1
            while j < n:
                if sql[j] == c:
                    if j + 1 < n and sql[j + 1] == c:
                        j += 2
                        continue
                    break
                j += 1
            out.append(sql[i:j + 1].replace("%", "%%"))
            i = j + 1
            continue
        if c == "-" and i + 1 < n and sql[i + 1] == "-":
            end = sql.find("\n", i)
            end = n if end < 0 else end
            out.append(sql[i:end].replace("%", "%%"))
            i = end
            continue
        if c == "?":
            out.append("%s")
        elif c == "%":
            out.append("%%")
        else:
            out.append(c)
        i += 1
    return "".join(out)


def jsonable(value):
    if isinstance(value, decimal.Decimal):
        # A NUMERIC sum. Float is what the driver's callers expect from any number.
        return float(value)
    if isinstance(value, (datetime.datetime, datetime.date)):
        return value.isoformat()
    if isinstance(value, (bytes, bytearray, memoryview)):
        return bytes(value).hex()
    return str(value)


class Backend:
    def __init__(self, dialect: str, dsn: str):
        self.dialect = dialect
        self.dsn = dsn
        self.conn = None
        self.connect()

    def connect(self):
        if self.dialect == "sqlite":
            self.conn = sqlite3.connect(self.dsn, isolation_level=None)
            self.conn.row_factory = sqlite3.Row
            self.conn.execute("PRAGMA journal_mode=WAL")
            self.conn.execute("PRAGMA busy_timeout=2000")
        elif self.dialect == "postgres":
            import psycopg
            from psycopg.rows import dict_row
            self.conn = psycopg.connect(self.dsn, autocommit=True, row_factory=dict_row)
            # Unix seconds everywhere, but a session in UTC is the one setting that cannot
            # hurt and that every other comparison silently depends on.
            self.conn.execute("SET TIME ZONE 'UTC'")
        elif self.dialect == "mysql":
            import pymysql
            url = urlparse(self.dsn)
            self.conn = pymysql.connect(
                host=url.hostname or "127.0.0.1",
                port=url.port or 3306,
                user=unquote(url.username or ""),
                password=unquote(url.password or ""),
                database=(url.path or "/").lstrip("/"),
                charset="utf8mb4",
                autocommit=True,
                cursorclass=pymysql.cursors.DictCursor,
            )
        else:
            raise ValueError("unknown dialect %r" % self.dialect)

    def _run(self, cursor, sql, params):
        if self.dialect == "sqlite":
            cursor.execute(sql, params)
        else:
            cursor.execute(to_format_style(sql), params)

    def _rows(self, cursor):
        if cursor.description is None:
            return []
        fetched = cursor.fetchall()
        if self.dialect == "sqlite":
            return [dict(row) for row in fetched]
        return [dict(row) for row in fetched]

    def query(self, sql, params):
        cursor = self.conn.cursor()
        try:
            self._run(cursor, sql, params)
            rows = self._rows(cursor)
            affected = cursor.rowcount if cursor.rowcount is not None else 0
            return {"rows": rows, "affected": max(affected, 0)}
        finally:
            cursor.close()

    def batch(self, statements):
        cursor = self.conn.cursor()
        try:
            if self.dialect == "postgres":
                with self.conn.transaction():
                    for st in statements:
                        self._run(cursor, st["sql"], st.get("params") or [])
            else:
                self.conn.execute("BEGIN") if self.dialect == "sqlite" else self.conn.begin()
                try:
                    for st in statements:
                        self._run(cursor, st["sql"], st.get("params") or [])
                except Exception:
                    self.conn.rollback() if self.dialect == "mysql" else self.conn.execute("ROLLBACK")
                    raise
                self.conn.commit() if self.dialect == "mysql" else self.conn.execute("COMMIT")
            return {"done": len(statements)}
        finally:
            cursor.close()

    def healthy(self) -> bool:
        try:
            self.query("SELECT 1", [])
            return True
        except Exception:
            return False


def make_handler(backend: Backend, token: str):
    class Handler(BaseHTTPRequestHandler):
        server_version = "dot-sql-gateway/1"

        def log_message(self, fmt, *args):
            # Statements are not logged: they carry player names and whatever else a game
            # binds. Errors are, below, without their parameters.
            pass

        def _send(self, status, body):
            data = json.dumps(body, default=jsonable).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_POST(self):
            supplied = self.headers.get("Authorization", "")
            if not hmac.compare_digest(supplied.encode(), ("Bearer " + token).encode()):
                self._send(401, {"error": "unauthorised"})
                return

            length = int(self.headers.get("Content-Length") or 0)
            if length <= 0 or length > MAX_BODY:
                self._send(413 if length > MAX_BODY else 400, {"error": "bad body length"})
                return
            try:
                body = json.loads(self.rfile.read(length))
            except ValueError:
                self._send(400, {"error": "body is not JSON"})
                return

            wanted = str(body.get("dialect", backend.dialect))
            if wanted != backend.dialect:
                # A driver configured for MySQL talking to a Postgres gateway would send
                # MySQL's upsert spelling and fail on every write; say so on the first.
                self._send(200, {"error": "this gateway speaks %s, not %s" % (backend.dialect, wanted)})
                return

            try:
                if self.path == "/query":
                    result = backend.query(str(body.get("sql", "")), list(body.get("params") or []))
                elif self.path == "/batch":
                    result = backend.batch(list(body.get("statements") or []))
                else:
                    self._send(404, {"error": "no such route"})
                    return
            except Exception as exc:  # noqa: BLE001 — the database's own message is the answer
                if not backend.healthy():
                    try:
                        backend.connect()
                    except Exception as again:  # noqa: BLE001
                        print("gateway: reconnect failed: %s" % again, file=sys.stderr)
                self._send(200, {"error": str(exc).strip()[:500]})
                return

            self._send(200, result)

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--dialect", required=True, choices=["sqlite", "postgres", "mysql"])
    parser.add_argument("--dsn", required=True, help="a file path for sqlite, a URL otherwise")
    parser.add_argument("--token-file", required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8780)
    args = parser.parse_args()

    with open(args.token_file, encoding="utf-8") as handle:
        token = handle.read().strip()
    if len(token) < 16:
        sys.exit("gateway: the token must be at least 16 characters")

    backend = Backend(args.dialect, args.dsn)
    server = HTTPServer((args.host, args.port), make_handler(backend, token))
    print("gateway: %s on http://%s:%d" % (args.dialect, args.host, server.server_port), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
