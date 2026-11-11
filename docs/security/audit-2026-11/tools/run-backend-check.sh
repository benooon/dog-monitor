#!/bin/bash
# Bounded local check for the backend, inside sandbox.sh with a private Postgres on loopback.
# Usage (as root): run-backend-check.sh <agent-dir> <test path relative to backend/, e.g. test/audit-x.test.ts>
# The agent writes its test file into <agent-dir>/scratch/backend/<test path> (a disposable source copy made
# on first use). Output goes to <agent-dir>/scratch/check-output.txt and is printed.
set -euo pipefail
AG=$(realpath "$1"); TEST=$2
S=$AG/scratch; mkdir -p "$S/home"
if [ ! -d "$S/backend" ]; then
  cp -a /home/claude/dog-monitor/backend "$S/backend"
  rm -rf "$S/backend/dist"
fi
case "$TEST" in /*|*..*) echo "test path must be relative to backend/"; exit 2;; esac
/srv/security-audit/tools/sandbox.sh "$S" 300 bash --noprofile --norc -c '
  initdb -D "$SCRATCH/pg" -U postgres --auth=trust >/dev/null
  pg_ctl -D "$SCRATCH/pg" -o "-k /tmp -c listen_addresses=127.0.0.1 -p 55432 -c fsync=off" -l "$SCRATCH/pg.log" -w start >/dev/null
  psql -h 127.0.0.1 -p 55432 -U postgres -qc "create database audit" 
  cd "$SCRATCH/backend"
  set +e
  DATABASE_URL=postgres://postgres@127.0.0.1:55432/audit ./node_modules/.bin/vitest run "'"$TEST"'" --reporter=verbose > "$SCRATCH/check-output.txt" 2>&1
  code=$?
  pg_ctl -D "$SCRATCH/pg" -m fast stop >/dev/null
  rm -rf "$SCRATCH/pg"
  echo "exit=$code" >> "$SCRATCH/check-output.txt"
'
cat "$S/check-output.txt"
