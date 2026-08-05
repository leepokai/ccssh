#!/usr/bin/env bash
# Tests for the built-in menu, driven through a real pty.
#
# These exist because the menu can only fail where it actually runs: reading
# keystrokes needs a terminal, and macOS ships bash 3.2, whose `read -t`
# rejects the fractional timeouts newer bash accepts.
set -uo pipefail

cd "$(dirname "$0")/.."

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

driver="$(mktemp)"
trap 'rm -f "$driver"' EXIT
cat > "$driver" <<'DRIVER'
. scripts/lib.sh
. scripts/picker.sh
result="$(ccssh_pick "Pick one" alpha beta gamma)"
status=$?
printf 'SELECTED=[%s] STATUS=%d\n' "$result" "$status"
DRIVER

# fzf would bypass the menu entirely, so make sure we exercise the fallback.
run_menu() {
  local keys="$1" out
  if script -q /dev/null /bin/echo probe >/dev/null 2>&1; then
    out="$(printf '%b' "$keys" | PATH=/usr/bin:/bin script -q /dev/null /bin/bash "$driver" 2>&1)"
  else
    out="$(printf '%b' "$keys" | PATH=/usr/bin:/bin script -q -c "/bin/bash $driver" /dev/null 2>&1)"
  fi
  printf '%s' "$out" | tr -d '\r' | grep -o 'SELECTED=\[[^]]*\] STATUS=[0-9]*' | tail -1
}

if ! command -v script >/dev/null 2>&1; then
  printf '  skip menu tests (no script command to allocate a pty)\n'
  exit 0
fi

check "Enter takes the first option" \
  "SELECTED=[alpha] STATUS=0" "$(run_menu '\n')"

check "down arrow moves the selection" \
  "SELECTED=[beta] STATUS=0" "$(run_menu '\033[B\n')"

check "arrows work under bash 3.2 fractional-timeout limits" \
  "SELECTED=[gamma] STATUS=0" "$(run_menu '\033[B\033[B\n')"

check "up arrow wraps to the last option" \
  "SELECTED=[gamma] STATUS=0" "$(run_menu '\033[A\n')"

check "j moves down" \
  "SELECTED=[beta] STATUS=0" "$(run_menu 'j\n')"

check "k wraps upward" \
  "SELECTED=[gamma] STATUS=0" "$(run_menu 'k\n')"

check "q cancels" \
  "SELECTED=[] STATUS=1" "$(run_menu 'q')"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
