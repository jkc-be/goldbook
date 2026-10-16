#!/usr/bin/env bash
set -euo pipefail

# Copies the server's database to /opt/goldbook/backups on <ssh-host>, through
# SQLite's backup API so that a write in progress cannot tear the copy, and
# checks the copy. Does nothing before the first deploy, when there is no
# database yet.
if [[ $# -ne 1 ]]; then
  echo "usage: $0 <ssh-host>" >&2
  exit 2
fi

ssh "$1" bash -s <<'EOF'
set -euo pipefail
database=/opt/goldbook/data/goldbook.sqlite
if [[ ! -e $database ]]; then
  echo "No database to back up yet."
  exit 0
fi
mkdir -p /opt/goldbook/backups
backup=/opt/goldbook/backups/goldbook-$(date -u +%Y%m%dT%H%M%SZ).sqlite
python3 - "$database" "$backup" <<'PY'
import sqlite3, sys
source = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
copy = sqlite3.connect(sys.argv[2])
source.backup(copy)
result = copy.execute("PRAGMA integrity_check").fetchone()[0]
if result != "ok":
    sys.exit(f"The backup failed its integrity check: {result}")
PY
chmod 600 "$backup"
echo "Backed up the database to $backup"
EOF
