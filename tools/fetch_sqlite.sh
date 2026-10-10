#!/usr/bin/env bash
# Installs the godot-sqlite GDExtension into a project's addons/godot-sqlite.
#
#   tools/fetch_sqlite.sh <project directory>
#
# DotSqlDriverSqlite reaches the extension by name and never ships it: a project that
# keeps its records in SQLite runs this once (dot-server-deploy's setup.sh does). The
# release is PINNED, by version and by the archive's sha256, because this is a native
# library loaded into a server that accepts connections from strangers, and "whatever
# the latest release is today" is not something to load into one.
#
# godot-sqlite is MIT (github.com/2shady4u/godot-sqlite); its LICENSE.md is installed
# beside it. v4.9 says compatibility_minimum = "4.7", which is the family's engine.
#
# The iOS frameworks are left out: they are 250 MB of the archive's 330 and nothing in
# this family runs a server on a phone. Everything else stays, so the .gdextension's
# list of libraries is still true on every platform it names.
#
# Idempotent: an install that is already this version is left alone.
set -euo pipefail

VERSION="v4.9"
SHA256="95e91b72fe32984a84edaf6357a78753661f37a170cb362f5b948e0ede7c2cb0"
URL="https://github.com/2shady4u/godot-sqlite/releases/download/${VERSION}/addons.zip"

project="${1:?usage: fetch_sqlite.sh <project directory>}"
[ -f "$project/project.godot" ] || { echo "fetch_sqlite: $project has no project.godot" >&2; exit 2; }
dest="$project/addons/godot-sqlite"

if [ -f "$dest/.dot-sql-version" ] && [ "$(cat "$dest/.dot-sql-version")" = "$VERSION" ]; then
    echo "fetch_sqlite: godot-sqlite $VERSION already in $dest"
    exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "fetch_sqlite: downloading godot-sqlite $VERSION"
curl -fsSL --retry 3 -o "$work/addons.zip" "$URL"
got="$(sha256sum "$work/addons.zip" | cut -d' ' -f1)"
if [ "$got" != "$SHA256" ]; then
    echo "fetch_sqlite: checksum mismatch for $URL" >&2
    echo "  expected $SHA256" >&2
    echo "  got      $got" >&2
    exit 1
fi

# unzip is not on every box; Python is (setup.sh already needs it).
python3 - "$work/addons.zip" "$work/x" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    for name in z.namelist():
        if ".ios." in name:
            continue
        z.extract(name, sys.argv[2])
PY

src="$work/x/addons/godot-sqlite"
[ -f "$src/gdsqlite.gdextension" ] || { echo "fetch_sqlite: the archive has no addons/godot-sqlite" >&2; exit 1; }

# Replaced whole rather than merged, so a file the new release dropped is not left behind.
rm -rf "$dest"
mkdir -p "$(dirname "$dest")"
mv "$src" "$dest"
echo "$VERSION" > "$dest/.dot-sql-version"
echo "fetch_sqlite: installed godot-sqlite $VERSION in $dest"
echo "fetch_sqlite: run 'godot --headless --path $project --import' so the editor registers it"
