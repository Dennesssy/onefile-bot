#!/bin/bash
# repair.sh ROOT TREE.csv FILE...  — re-check each file and, while it fails, give onefile-bot that one file
# plus the exact checker output and its CSV purpose/requirement (max 3 rounds per file).
# Checks: Swift syntax (swiftc -parse), Terraform syntax (terraform fmt), SQL (applied in order to a
# scratch SQLite database after all earlier migrations; must be portable to SQLite and Postgres).
set -u
ROOT="$1"; TREE="$2"; shift 2
BOT="$(cd "$(dirname "$0")" && pwd)/onefile-bot"
cd "$ROOT" || exit 1

check() {  # prints errors for $1, nothing when it passes
  local f="$1"
  case "$f" in
    *.swift) xcrun swiftc -parse "$f" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep ": error:" | head -15 ;;
    *.tf)    terraform fmt -write=false -list=false "$f" 2>&1 >/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -v "^[[:space:]]*$" | head -15 ;;
    *.sql)   local db; db=$(mktemp); local prev
             for prev in $(/bin/ls db/migrations/*.sql | sort); do
               [ "$prev" = "$f" ] && break
               sqlite3 "$db" < "$prev" >/dev/null 2>&1
             done
             sqlite3 "$db" < "$f" 2>&1 | head -15; rm -f "$db" ;;
  esac
}

row() {  # "purpose Requirement: requirement" for a path from the CSV
  /usr/bin/python3 - "$TREE" "$1" <<'EOF'
import csv, sys
for r in csv.DictReader(open(sys.argv[1])):
    if r["path"] == sys.argv[2]:
        print(f"{r['purpose']} Requirement: {r['requirement']}")
EOF
}

for f in "$@"; do
  for round in 1 2 3; do
    errors=$(check "$f")
    if [ -z "$errors" ]; then echo "PASS $f (after $((round - 1)) repair rounds)"; continue 2; fi
    extra=""; context=(); checkcmd=()
    case "$f" in *.swift) checkcmd=(--check "xcrun swiftc -parse '$ROOT/$f'") ;; esac
    case "$f" in
      *.sql)
        extra="The migrations must run unchanged on both SQLite and Postgres: use only portable SQL (CREATE TABLE IF NOT EXISTS, CREATE INDEX IF NOT EXISTS, TEXT/INTEGER/REAL/BLOB columns, CHECK and FOREIGN KEY constraints). No extensions, no Postgres-only types (UUID, JSONB, TIMESTAMPTZ, SERIAL), no ALTER ... ADD CONSTRAINT, no materialized views, no stored functions. Store JSON as TEXT, timestamps as TEXT ISO-8601 or INTEGER epoch, ids as TEXT. Earlier migrations (read-only context) define the tables you may reference."
        for prev in $(/bin/ls db/migrations/*.sql | sort); do [ "$prev" = "$f" ] && break; context+=(--context "$ROOT/$prev"); done ;;
    esac
    "$BOT" --file "$ROOT/$f" ${context[@]+"${context[@]}"} ${checkcmd[@]+"${checkcmd[@]}"} --max-steps 30 "$(basename "$f") fails its check with:
$errors

What this file is: $(row "$f")
$extra
Read the file and fix every error. Prefer edit_file for local fixes; if the file is fundamentally broken you may rewrite it with write_file. Keep its purpose and requirement. This is repair round $round." >> "$ROOT/.onefile-logs/repair__$(echo "$f" | tr / _).log" 2>&1
  done
  errors=$(check "$f")
  if [ -z "$errors" ]; then echo "PASS $f (after 3 repair rounds)"; else echo "FAIL $f :: $(echo "$errors" | head -1 | cut -c1-150)"; fi
done
