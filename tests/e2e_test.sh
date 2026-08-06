#!/usr/bin/env bash
# End-to-end tests: the real launcher, driven through a real terminal, against
# a real host.
#
# Everything here runs under --dry-run, so nothing on the host changes and no
# Claude Code session is started. That last exec is the only step these do not
# cover — by then the command has been composed and printed, and the session
# tests check its shape.
#
# Needs a host to talk to:
#
#   CCSSH_E2E_HOST=my-vps tests/e2e_test.sh
#
# Skipped without one, so the rest of the suite still runs anywhere.
set -uo pipefail

cd "$(dirname "$0")/.."
LAUNCHER="$PWD/bin/ccssh"

HOST="${CCSSH_E2E_HOST:-}"
if [ -z "$HOST" ]; then
  printf '  skip end-to-end tests (set CCSSH_E2E_HOST to a reachable host)\n'
  exit 0
fi

if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$HOST" true 2>/dev/null; then
  printf '  skip end-to-end tests (%s is not reachable)\n' "$HOST"
  exit 0
fi

command -v script >/dev/null 2>&1 || {
  printf '  skip end-to-end tests (no script command to allocate a pty)\n'
  exit 0
}

CCSSH_STATE_DIR="$(mktemp -d)"
export CCSSH_STATE_DIR
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
saw() {
  case "$2" in
    *"$3"*) check "$1" "present" "present" ;;
    *)      check "$1" "present" "MISSING: $3" ;;
  esac
}
absent() {
  case "$2" in
    *"$3"*) check "$1" "absent" "PRESENT: $3" ;;
    *)      check "$1" "absent" "absent" ;;
  esac
}

# Run the launcher on a pty, feeding it keystrokes. fzf would bypass the
# built-in menu, so keep it off the PATH for these.
#
# Bounded: a menu waiting for a keystroke that never comes would otherwise hang
# the suite forever rather than failing it.
CCSSH_E2E_TIMEOUT="${CCSSH_E2E_TIMEOUT:-45}"

run() {
  local keys="$1"; shift
  local out="$CCSSH_STATE_DIR/out.$$" pid waited=0

  (
    printf '%b' "$keys" |
      PATH="/usr/bin:/bin" CCSSH_STATE_DIR="$CCSSH_STATE_DIR" \
      script -q /dev/null "$LAUNCHER" --dry-run "$@" > "$out" 2>&1
  ) &
  pid=$!

  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$CCSSH_E2E_TIMEOUT" ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null
    printf 'TIMED OUT after %ss\n' "$CCSSH_E2E_TIMEOUT"
  fi
  wait "$pid" 2>/dev/null

  tr -d '\r' < "$out"
  rm -f "$out"
}

DOWN=$'\033[B'

# --- flags that never touch a host ------------------------------------------

out="$(printf '' | script -q /dev/null "$LAUNCHER" --version 2>&1 | tr -d '\r')"
saw "--version prints a version" "$out" "ccssh 0.1.0"

out="$(printf '' | script -q /dev/null "$LAUNCHER" --help 2>&1 | tr -d '\r')"
saw "--help lists the environment form" "$out" "ccssh <environment>"
saw "--help lists continue" "$out" "ccssh -c"

# --- explicit path, which also gives the host something to remember ---------

out="$(run '' "$HOST:/tmp")"
saw "host:path goes straight to that directory" "$out" "/tmp"
absent "and skips the folder menu" "$out" "Folder on"
saw "and reports the dry run finished" "$out" "dry run"

# --dry-run does not write memory, so seed it the way a real run would.
# shellcheck source=../scripts/lib.sh
. scripts/lib.sh
# shellcheck source=../scripts/memory.sh
. scripts/memory.sh
ccssh_memory_put "$HOST" /tmp

# --- the fast path ----------------------------------------------------------

out="$(run '' "$HOST")"
saw "a named host connects" "$out" "connecting to $HOST"
absent "with no menu in the way" "$out" "Where do you want to work?"
absent "and without asking for a directory" "$out" "Folder on"
saw "it goes where it left off" "$out" "would remember for $HOST"

out="$(run '' "$HOST:/definitely/not/here")"
saw "a bad path fails by name" "$out" "/definitely/not/here does not exist"

# --- the menu ---------------------------------------------------------------

out="$(run "\n")"
saw "the menu offers the remembered entry first" "$out" "★ $HOST"
saw "the same host appears bare below it" "$out" "◆ $HOST"
saw "Local comes after that" "$out" "▪ Local"
saw "choosing the first entry connects" "$out" "connecting to $HOST"

# Second entry is the bare host, which should ask which directory.
out="$(run "${DOWN}\n\n")"
saw "the bare host entry asks for a directory" "$out" "Folder on $HOST"

# -p forces the question even on the fast path.
out="$(run '\n' "$HOST" -p)"
saw "-p asks again" "$out" "Folder on $HOST"

# --- environments -----------------------------------------------------------

run '' "$HOST:/tmp" --save e2e-tmp >/dev/null
saw "--save writes the environment" "$(cat "$CCSSH_STATE_DIR/config.json")" '"e2e-tmp"'

out="$(run '' e2e-tmp)"
saw "the name resolves to its host" "$out" "connecting to $HOST"
saw "and to its directory" "$out" "/tmp"
absent "without asking anything" "$out" "Folder on"

out="$(run "\n")"
saw "named environments lead the menu" "$out" "◇ e2e-tmp"

# --- sessions ---------------------------------------------------------------

out="$(run '' "$HOST" -c)"
saw "-c runs" "$out" "connecting to $HOST"

out="$(run '\n' "$HOST" -r)"
saw "-r handles having nothing to resume" "$out" "connecting to $HOST"

# --- forgetting -------------------------------------------------------------

out="$(printf '' | CCSSH_STATE_DIR="$CCSSH_STATE_DIR" \
  script -q /dev/null "$LAUNCHER" --forget "$HOST" 2>&1 | tr -d '\r')"
saw "--forget names what it dropped" "$out" "forgot $HOST"

out="$(run '\n')"
saw "and the host is no longer remembered" "$out" "▪ Local"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
