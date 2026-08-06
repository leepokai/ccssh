#!/usr/bin/env bash
# Tests for what each host remembers.
#
# Keyed by host, not by local directory: running ccssh from anywhere should get
# you back to where you left off on whichever host you pick.
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

check "an unknown host remembers nothing" "" "$(ccssh_memory_get vps)"
check "no last host before anything is used" "" "$(ccssh_memory_last_host)"

ccssh_memory_put vps /srv/app dev/kevin '/home/me/.ccssh-worktrees/app-a1b2/dev-kevin'
check "round-trips a worktree entry" \
  '/srv/app|dev/kevin|/home/me/.ccssh-worktrees/app-a1b2/dev-kevin' \
  "$(ccssh_memory_get vps | tr '\t' '|')"

ccssh_memory_put build-01 '/home/me/code/thing'
check "round-trips an entry without a worktree" \
  '/home/me/code/thing||' "$(ccssh_memory_get build-01 | tr '\t' '|')"

check "the most recent host leads" "build-01" "$(ccssh_memory_last_host)"

ccssh_memory_put vps /srv/other
check "a host keeps only its latest folder" '/srv/other||' \
  "$(ccssh_memory_get vps | tr '\t' '|')"
check "hosts stay independent" '/home/me/code/thing||' \
  "$(ccssh_memory_get build-01 | tr '\t' '|')"
check "the last host follows the latest use" "vps" "$(ccssh_memory_last_host)"

check "annotates a host list in one pass" \
  'vps	/srv/other
build-01	/home/me/code/thing
never-used	' \
  "$(printf 'vps\nbuild-01\nnever-used\n' | ccssh_memory_annotate)"

check "the store is private" "600" \
  "$(stat -f '%Lp' "$CCSSH_STATE_DIR/hosts.json" 2>/dev/null ||
     stat -c '%a' "$CCSSH_STATE_DIR/hosts.json" 2>/dev/null)"

ccssh_memory_forget vps >/dev/null
check "forgetting one host clears it" "" "$(ccssh_memory_get vps)"
check "forgetting one host leaves the others" '/home/me/code/thing||' \
  "$(ccssh_memory_get build-01 | tr '\t' '|')"
check "forgetting the last host clears the pointer" "" "$(ccssh_memory_last_host)"

check "forgetting everything reports the count" "1" "$(ccssh_memory_forget)"
check "forgetting everything clears it" "" "$(ccssh_memory_get build-01)"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
