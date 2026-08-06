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
HOME_ON_HOST="$(ssh -n "$HOST" 'printf %s "$HOME"' 2>/dev/null)"
# shellcheck source=../scripts/folders.sh
. scripts/lib.sh; . scripts/folders.sh

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

# --- choosing a directory ---------------------------------------------------

# Driving the input directly: reaching it through the menu would make the test
# about the menu instead.
driver="$CCSSH_STATE_DIR/folder-driver.sh"
cat > "$driver" <<DRIVER
cd "$PWD"
. scripts/lib.sh
. scripts/worktree.sh
. scripts/folders.sh
. scripts/picker.sh
printf 'RESULT=[%s]\\n' "\$(ccssh_pick_folder "$HOST" "$HOME_ON_HOST")"
DRIVER

type_folder() {
  local keys="$1" out="$CCSSH_STATE_DIR/folder.$$" pid waited=0
  ( printf '%b' "$keys" | script -q /dev/null /bin/bash "$driver" > "$out" 2>&1 ) &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$CCSSH_E2E_TIMEOUT" ]; do
    sleep 1; waited=$((waited + 1))
  done
  kill -9 "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  tr -d '\r' < "$out" | grep -o 'RESULT=\[.*\]' | head -1
  rm -f "$out"
}

# One bulk listing rather than a round trip per directory.
listing="$(ccssh_list_dirs "$HOST")"
count="$(printf '%s\n' "$listing" | wc -l | tr -d ' ')"
check "the whole tree arrives in one listing" "yes" \
  "$([ "$count" -gt 1 ] && echo yes || echo no)"

first="$(printf '%s\n' "$listing" | head -1)"
check "Enter takes the first entry" "RESULT=[$first]" "$(type_folder "\n")"

# Typing narrows straight away — no keystroke needed to start.
target="$(printf '%s\n' "$listing" | grep -v "^$HOME_ON_HOST\$" | head -1)"
if [ -n "$target" ]; then
  needle="$(basename "$target")"
  got="$(type_folder "$needle\n")"
  check "typing narrows the list straight away" "yes" \
    "$([ -n "$got" ] && [ "$got" != "RESULT=[]" ] && echo yes || echo no)"
fi

# Dotted directories are reachable, and rank above a nested namesake — typing
# "ssh" should reach ~/.ssh, not something buried that merely contains it.
if printf '%s\n' "$listing" | grep -qx "$HOME_ON_HOST/.ssh"; then
  check "a dotted directory outranks a nested namesake" \
    "RESULT=[$HOME_ON_HOST/.ssh]" "$(type_folder "ssh\n")"
fi

# Tab writes the directory onto the line in the ~ form it is displayed in,
# while the listing holds absolute paths — so the line has to be expanded
# before matching, or taking a directory leaves you with nothing selected.
if printf '%s\n' "$listing" | grep -qx "$HOME_ON_HOST/.ssh"; then
  tabbed="$(type_folder "ssh\t\n")"
  check "Tab leaves the directory still matching" \
    "RESULT=[$HOME_ON_HOST/.ssh]" "$tabbed"
fi

# The cursor has to come to rest where the next character will land, not out
# past the counter on the right-hand edge.
# Enter, not Ctrl-C: the terminal driver turns Ctrl-C into a signal before it
# ever reaches the program, so the picker would die before drawing anything.
# Enter breaks the loop without redrawing, leaving the last frame typed.
rawfile="$CCSSH_STATE_DIR/cursor.$$"
( printf 'ssh\n' | script -q /dev/null /bin/bash "$driver" > "$rawfile" 2>&1 ) &
rawpid=$!
rawwait=0
while kill -0 "$rawpid" 2>/dev/null && [ "$rawwait" -lt "$CCSSH_E2E_TIMEOUT" ]; do
  sleep 1; rawwait=$((rawwait + 1))
done
kill -9 "$rawpid" 2>/dev/null
wait "$rawpid" 2>/dev/null

# Read the file directly: routing terminal bytes through a shell variable
# mangles them.
check "the cursor rests at the end of the line" "yes" \
  "$(python3 -c '
import sys

with open(sys.argv[1], "rb") as handle:
    data = handle.read()

index = data.rfind(b"\x1b[s")
before = data[max(0, index - 8):index] if index >= 0 else b""
print("yes" if before.endswith(b"ssh") else "no")
' "$rawfile")"
rm -f "$rawfile"

check "something matching nothing is taken as typed" \
  "RESULT=[ccssh-no-such-thing]" "$(type_folder "ccssh-no-such-thing\n")"

# script sends a Ctrl-D before anything else; if that reached the buffer it
# would match nothing, invisibly.
check "control bytes never reach the buffer" "RESULT=[$first]" "$(type_folder "\n")"

noise="$( ( printf 'a\n' | script -q /dev/null /bin/bash "$driver" 2>&1 ) |
  tr -d '\r' | grep -iE 'command not found|no such file|unbound variable|syntax error' |
  head -1 )"
check "the picker prints no errors of its own" "" "$noise"

# ls without -A hides dotfiles and without -L leaves a symlinked directory
# with no trailing slash, so both were being dropped in silence.
scratch="/tmp/ccssh-e2e-$$"
ssh -n "$HOST" "mkdir -p $scratch/realdir $scratch/.hidden && ln -s realdir $scratch/linkdir" 2>/dev/null
found="$(ssh -n "$HOST" "ls -1pAL $scratch/ 2>/dev/null" | grep -c '/$')"
ssh -n "$HOST" "rm -rf $scratch" 2>/dev/null
check "hidden and symlinked directories both list" "3" "$found"

# --- forgetting -------------------------------------------------------------

out="$(printf '' | CCSSH_STATE_DIR="$CCSSH_STATE_DIR" \
  script -q /dev/null "$LAUNCHER" --forget "$HOST" 2>&1 | tr -d '\r')"
saw "--forget names what it dropped" "$out" "forgot $HOST"

out="$(run '\n')"
saw "and the host is no longer remembered" "$out" "▪ Local"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
