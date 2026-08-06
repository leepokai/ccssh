#!/usr/bin/env bash
# Learn everything about a remote host in a single round trip.
#
# Output is fenced with sentinels so parsing survives login banners, MOTDs and
# anything else a shell profile decides to print.

# A non-interactive ssh command runs with a bare PATH — on macOS just
# /usr/bin:/bin:/usr/sbin:/sbin — which hides anything installed by Homebrew or
# the Claude installer. Adding -t does not help. So ask the login shell what
# PATH it would use, and search that instead.
CCSSH_PATH_SETUP='
LOGIN_PATH="$(${SHELL:-/bin/sh} -lc '"'"'printf %s "$PATH"'"'"' 2>/dev/null)"
[ -n "$LOGIN_PATH" ] && PATH="$LOGIN_PATH"
PATH="$HOME/.local/bin:$HOME/.claude/local:$PATH"
export PATH
'

# ccssh_probe_raw <host> [candidate-dir] [session-name]
#
# Everything the connect path needs, in one round trip. Asking separately cost
# four sequential ssh calls; folding the directory and session checks in here
# roughly halves the wait before Claude Code appears.
ccssh_probe_raw() {
  ssh "$1" "CCSSH_DIR=$(ccssh_shq "${2:-}") CCSSH_SESSION=$(ccssh_shq "${3:-}")
    $CCSSH_PATH_SETUP"'
    echo __OS__;     uname -s
    echo __ARCH__;   uname -m
    echo __HOME__;   printf "%s\n" "$HOME"
    echo __PATH__;   printf "%s\n" "$PATH"
    echo __CLAUDE__; command -v claude 2>/dev/null || true
    echo __VER__;    claude --version 2>/dev/null || true
    echo __TMUX__;   command -v tmux 2>/dev/null || true
    echo __MOSH__;   command -v mosh-server 2>/dev/null || true
    echo __GIT__;    command -v git 2>/dev/null || true
    echo __PY__;     command -v python3 2>/dev/null || true
    echo __DIR__;    { [ -n "$CCSSH_DIR" ] && [ -d "$CCSSH_DIR" ] && echo yes; } || echo no
    echo __CLIENTS__
    if [ -n "$CCSSH_SESSION" ] && command -v tmux >/dev/null 2>&1; then
      tmux has-session -t "=$CCSSH_SESSION" 2>/dev/null &&
        tmux list-clients -t "=$CCSSH_SESSION" 2>/dev/null | wc -l | tr -d " "
    fi
    echo __END__
  ' 2>/dev/null
}

# ccssh_probe_field <raw> <name> — first non-empty line of that section.
ccssh_probe_field() {
  printf '%s\n' "$1" | awk -v want="__${2}__" '
    $0 == want          { collecting = 1; next }
    /^__[A-Z]+__$/      { collecting = 0 }
    collecting && NF    { print; exit }
  '
}

# Probe <host> and export the results. Returns 1 when the host is unreachable.
ccssh_probe() {
  local host="$1" raw
  raw="$(ccssh_probe_raw "$host" "${2:-}" "${3:-}")" || return 1
  case "$raw" in
    *__END__*) ;;
    *) return 1 ;;
  esac

  CCSSH_OS="$(ccssh_probe_field "$raw" OS)"
  CCSSH_ARCH="$(ccssh_probe_field "$raw" ARCH)"
  CCSSH_HOME="$(ccssh_probe_field "$raw" HOME)"
  CCSSH_REMOTE_PATH="$(ccssh_probe_field "$raw" PATH)"
  CCSSH_CLAUDE="$(ccssh_probe_field "$raw" CLAUDE)"
  CCSSH_VERSION="$(ccssh_probe_field "$raw" VER)"
  CCSSH_TMUX="$(ccssh_probe_field "$raw" TMUX)"
  CCSSH_MOSH_SERVER="$(ccssh_probe_field "$raw" MOSH)"
  CCSSH_GIT="$(ccssh_probe_field "$raw" GIT)"
  CCSSH_PYTHON="$(ccssh_probe_field "$raw" PY)"
  CCSSH_DIR_EXISTS="$(ccssh_probe_field "$raw" DIR)"
  CCSSH_SESSION_CLIENTS="$(ccssh_probe_field "$raw" CLIENTS)"
  export CCSSH_OS CCSSH_ARCH CCSSH_HOME CCSSH_REMOTE_PATH \
    CCSSH_CLAUDE CCSSH_VERSION CCSSH_TMUX CCSSH_MOSH_SERVER CCSSH_GIT CCSSH_PYTHON \
    CCSSH_DIR_EXISTS CCSSH_SESSION_CLIENTS
}

# ccssh_version_older <a> <b> — true when version a is older than version b.
ccssh_version_older() {
  python3 -c '
import sys

def parts(v):
    return [int(x) for x in v.split(".") if x.isdigit()]

a, b = parts(sys.argv[1]), parts(sys.argv[2])
sys.exit(0 if a and b and a < b else 1)
' "$1" "$2" 2>/dev/null
}

# Report when the remote CLI lags behind this machine's. The desktop app pins
# the remote version outright; the least we can do is not let a stale one drift
# silently, since behaviour can differ between releases.
ccssh_report_version_drift() {
  local host="$1" here there

  [ -n "${CCSSH_VERSION:-}" ] || return 0
  command -v claude >/dev/null 2>&1 || return 0

  here="$(claude --version 2>/dev/null | awk "{print \$1}")"
  there="$(printf "%s" "$CCSSH_VERSION" | awk "{print \$1}")"
  [ -n "$here" ] && [ -n "$there" ] || return 0

  if ccssh_version_older "$there" "$here"; then
    info "$host has claude $there, you have $here — run 'claude update' there to match"
  fi
}

# v1 runs Claude Code itself on the remote, which needs a POSIX host.
ccssh_platform_supported() {
  case "$CCSSH_OS" in
    Linux|Darwin) return 0 ;;
    *) return 1 ;;
  esac
}
