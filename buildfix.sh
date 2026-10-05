#!/bin/bash
# buildfix.sh ROOT TARGET [ROUNDS] — module-level repair loop:
# build the SwiftPM target, group errors by file, give each file's onefile-bot its own errors plus
# the files that declare the types named in those errors (read-only), then rebuild. Files are edited
# in parallel (3 at a time); each bot may write only its one file.
set -u
ROOT="$1"; TARGET="$2"; ROUNDS="${3:-4}"
BOT="$(cd "$(dirname "$0")" && pwd)/onefile-bot"
SCRATCH="$HOME/.cache/$(basename "$ROOT")-build"
cd "$ROOT" || exit 1
mkdir -p .onefile-logs

build() { xcrun swift build --scratch-path "$SCRATCH" --target "$TARGET" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; }

fix_file() {  # $1 = file (absolute), $2 = errors file
  local f="$1" errs="$2" ctx=() t d
  for t in $(grep -oE "'[A-Z][A-Za-z0-9_]+'" "$errs" | tr -d "'" | sort -u | head -12); do
    for d in $(grep -rlE "^(public |internal |package )?(final )?(struct|class|enum|actor|protocol|typealias) $t\b" \
               --include='*.swift' "Sources/$TARGET" 2>/dev/null | head -1); do
      [ "$ROOT/$d" != "$f" ] && ctx+=(--context "$ROOT/$d")
    done
  done
  "$BOT" --file "$f" ${ctx[@]+"${ctx[@]}"} --check "xcrun swiftc -parse '$f'" --max-steps 30 \
    "$(basename "$f") is part of the $TARGET Swift module. Building the module reports these errors in this file:
$(cat "$errs")

The read-only reference files declare the other types these errors mention; use their exact names, members and initializers.
Fix every error in this file with edit_file. Typical fixes: add the missing protocol conformance or required members, mark types Sendable (value types with Sendable members, or final classes/actors), replace references to types that do not exist with the reference types, and remove a declaration that duplicates one in a reference file. Do not declare a type that a reference file already declares, and do not change unrelated code." \
    >> "$ROOT/.onefile-logs/buildfix__$(basename "$f").log" 2>&1
}
export -f fix_file
export BOT ROOT TARGET

for round in $(seq 1 "$ROUNDS"); do
  out=$(build)
  n=$(grep -c ": error:" <<<"$out")
  echo "round $round: $n errors"
  [ "$n" -eq 0 ] && { echo "BUILD OK: $TARGET"; exit 0; }
  work=$(mktemp -d)
  grep -E "^/.*\.swift:[0-9]+:[0-9]+: error:" <<<"$out" | sort -u | while IFS= read -r line; do
    f="${line%%:*}"; echo "$line" >> "$work/$(echo "$f" | tr / _)"; echo "$f" >> "$work/files"
  done
  sort -u "$work/files" | while read -r f; do printf '%s\0%s\0' "$f" "$work/$(echo "$f" | tr / _)"; done \
    | xargs -0 -n 2 -P 3 bash -c 'fix_file "$0" "$1"'
  rm -rf "$work"
done
n=$(build | grep -c ": error:"); echo "after $ROUNDS rounds: $n errors"
