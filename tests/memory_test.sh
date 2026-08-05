#!/usr/bin/env bash
# Tests for per-project connection memory.
set -uo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=../scripts/lib.sh
. scripts/lib.sh
# shellcheck source=../scripts/memory.sh
. scripts/memory.sh

CCSSH_STATE_DIR="$(mktemp -d)"
trap 'rm -rf "$CCSSH_STATE_DIR"' EXIT

pass=0
fail=0
check() {
  if [ "$2" = "$3" ]; then
    printf '  ok   %s\n' "$1"; pass=$((pass + 1))
  else
    printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"
    fail=$((fail + 1))
  fi
}

check "unknown project remembers nothing" "" "$(ccssh_memory_get /nope)"

ccssh_memory_put /home/x/proj mac-mini '~/projects/drive-bridge' \
  dev/kevin '~/.ccssh-worktrees/drive-bridge-a1b2c3d4/dev-kevin'

check "round-trips a worktree entry" \
  'mac-mini|~/projects/drive-bridge|dev/kevin|~/.ccssh-worktrees/drive-bridge-a1b2c3d4/dev-kevin' \
  "$(ccssh_memory_get /home/x/proj | tr '\t' '|')"

ccssh_memory_put /home/x/plain yuan-vm '~/src/api'
check "round-trips an entry without a worktree" \
  'yuan-vm|~/src/api||' \
  "$(ccssh_memory_get /home/x/plain | tr '\t' '|')"

ccssh_memory_put /home/x/proj hardcore2 '~/other'
check "overwrites the earlier entry" \
  'hardcore2|~/other||' \
  "$(ccssh_memory_get /home/x/proj | tr '\t' '|')"

check "projects stay independent" \
  'yuan-vm|~/src/api||' \
  "$(ccssh_memory_get /home/x/plain | tr '\t' '|')"

check "store is private" "600" \
  "$(stat -f '%Lp' "$CCSSH_STATE_DIR/sessions.json" 2>/dev/null ||
     stat -c '%a' "$CCSSH_STATE_DIR/sessions.json" 2>/dev/null)"

ccssh_memory_forget /home/x/proj
check "forget clears one project" "" "$(ccssh_memory_get /home/x/proj)"
check "forget leaves the others" \
  'yuan-vm|~/src/api||' \
  "$(ccssh_memory_get /home/x/plain | tr '\t' '|')"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
