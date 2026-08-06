#!/usr/bin/env bash
# Tests for the command handed to the remote host.
#
# These exist because an ssh command runs with a bare PATH — on macOS just
# /usr/bin:/bin:/usr/sbin:/sbin — so a bare `claude` is not found even when it
# is installed. Adding -t does not change that.
set -uo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=../scripts/lib.sh
. scripts/lib.sh
# shellcheck source=../scripts/worktree.sh
. scripts/worktree.sh
# shellcheck source=../scripts/session.sh
. scripts/session.sh

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
contains() {
  case "$2" in
    *"$3"*) check "$1" "present" "present" ;;
    *)      check "$1" "present" "ABSENT: $3" ;;
  esac
}

CCSSH_REMOTE_PATH="/opt/homebrew/bin:/usr/bin:/bin"
CCSSH_CLAUDE="/Users/someone/.local/bin/claude"
CCSSH_TMUX="/opt/homebrew/bin/tmux"
CCSSH_SCREEN=""

cmd="$(ccssh_remote_command "/home/me/proj" "ccssh-proj")"

contains "carries the login PATH into the session" "$cmd" "export PATH='/opt/homebrew/bin:/usr/bin:/bin'"
contains "runs claude by absolute path" "$cmd" "'/Users/someone/.local/bin/claude'"
contains "runs tmux by absolute path" "$cmd" "'/opt/homebrew/bin/tmux'"
check "prefers tmux when both are present" "tmux" \
  "$(CCSSH_SCREEN=/usr/bin/screen ccssh_multiplexer)"
contains "attaches or creates one named session" "$cmd" "new -As 'ccssh-proj'"
contains "changes to the working directory" "$cmd" "cd '/home/me/proj'"
contains "replaces the shell rather than nesting one" "$cmd" "exec "

CCSSH_TMUX=""
without_tmux="$(ccssh_remote_command "/home/me/proj" "ccssh-proj")"
contains "falls back to claude alone without tmux" "$without_tmux" "exec '/Users/someone/.local/bin/claude'"
case "$without_tmux" in
  *tmux*) check "no tmux in the fallback" "absent" "PRESENT" ;;
  *)      check "no tmux in the fallback" "absent" "absent" ;;
esac

# screen ships with macOS and most distributions, so persistence still works
# on hosts where tmux was never installed.
CCSSH_SCREEN="/usr/bin/screen"
check "falls back to screen" "screen" "$(ccssh_multiplexer)"
scr="$(ccssh_remote_command "/home/me/proj" "ccssh-proj")"
contains "screen reattaches or creates one named session" "$scr" \
  "'/usr/bin/screen' -DRS 'ccssh-proj'"
contains "screen runs claude by absolute path" "$scr" "'/Users/someone/.local/bin/claude'"
CCSSH_SCREEN=""
check "reports none when neither is present" "none" "$(ccssh_multiplexer)"

# Paths with spaces or quotes must not break out of the command.
tricky="$(ccssh_remote_command "/home/me/my proj" "s")"
contains "quotes a path containing spaces" "$tricky" "cd '/home/me/my proj'"

# Falling back to a bare name is only acceptable when the probe found nothing.
CCSSH_CLAUDE=''
CCSSH_REMOTE_PATH=''
bare="$(ccssh_remote_command "/tmp" "s")"
contains "degrades to a bare command when unprobed" "$bare" "exec 'claude'"

digest="$(printf '%s' /home/me/proj | ccssh_sha256 | cut -c1-6)"
check "session name derives from repo, path and branch" \
  "ccssh-proj-$digest-dev-kevin" "$(ccssh_session_name /home/me/proj dev/kevin)"
check "session name without a branch" \
  "ccssh-proj-$digest" "$(ccssh_session_name /home/me/proj '')"

# Same-named repositories in different places must not share a tmux session.
one="$(ccssh_session_name /home/me/work/api '')"
two="$(ccssh_session_name /home/me/side/api '')"
if [ "$one" = "$two" ]; then
  check "same-named repos get different sessions" "differ" "collide"
else
  check "same-named repos get different sessions" "differ" "differ"
fi

# A quoted ~ refers to no directory at all, so it must be resolved first.
check "expands a leading tilde" "/home/me/proj" \
  "$(ccssh_expand_home '~/proj' /home/me)"
check "expands a bare tilde" "/home/me" "$(ccssh_expand_home '~' /home/me)"
check "leaves absolute paths alone" "/opt/thing" \
  "$(ccssh_expand_home /opt/thing /home/me)"
check "leaves a mid-path tilde alone" "/a/~/b" "$(ccssh_expand_home '/a/~/b' /home/me)"
check "leaves ~user alone" "~other/proj" "$(ccssh_expand_home '~other/proj' /home/me)"
check "passes through when the home is unknown" "~/proj" \
  "$(ccssh_expand_home '~/proj' '')"
check "expands nested paths" "/home/me/a/b/c" \
  "$(ccssh_expand_home '~/a/b/c' /home/me)"

CCSSH_REMOTE_PATH=''
CCSSH_CLAUDE=''
expanded="$(ccssh_remote_command "$(ccssh_expand_home '~/proj' /home/me)" s)"
contains "the composed command has no unexpanded tilde" "$expanded" "cd '/home/me/proj'"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
