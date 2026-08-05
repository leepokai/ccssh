#!/usr/bin/env bash
# Tests for worktree path composition. These guard a security property: no
# branch name may produce a path outside the worktree root.
set -uo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=../scripts/lib.sh
. scripts/lib.sh
# shellcheck source=../scripts/worktree.sh
. scripts/worktree.sh

CCSSH_HOME="/home/tester"
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

rejects() {
  if ccssh_branch_valid "$1" 2>/dev/null; then
    printf '  FAIL rejects %-28s (was accepted)\n' "$1"; fail=$((fail + 1))
  else
    printf '  ok   rejects %s\n' "$1"; pass=$((pass + 1))
  fi
}

accepts() {
  if ccssh_branch_valid "$1" 2>/dev/null; then
    printf '  ok   accepts %s\n' "$1"; pass=$((pass + 1))
  else
    printf '  FAIL accepts %-28s (was rejected)\n' "$1"; fail=$((fail + 1))
  fi
}

accepts "dev/kevin"
accepts "feature.x"
accepts "release-1.2"

rejects "../../etc/passwd"
rejects "/absolute"
rejects "has space"
rejects ""
rejects "a..b"

check "slug flattens slashes" "dev-kevin" "$(ccssh_branch_slug 'dev/kevin')"
check "slug sanitises exotic characters" "a_b_c" "$(ccssh_branch_slug 'a:b;c')"

path="$(ccssh_worktree_path /home/tester/projects/drive-bridge dev/kevin)"
digest="$(printf '%s' /home/tester/projects/drive-bridge | ccssh_sha256 | cut -c1-8)"
check "path is composed under the root" \
  "/home/tester/.ccssh-worktrees/drive-bridge-$digest/dev-kevin" "$path"

case "$path" in
  /home/tester/.ccssh-worktrees/*) check "path stays under the root" "yes" "yes" ;;
  *)                              check "path stays under the root" "yes" "no"  ;;
esac

a="$(ccssh_worktree_path /home/tester/a/api main)"
b="$(ccssh_worktree_path /home/tester/b/api main)"
if [ "$a" = "$b" ]; then
  check "same-named repos do not collide" "differ" "collide"
else
  check "same-named repos do not collide" "differ" "differ"
fi

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
