#!/usr/bin/env bash
# Hand the terminal over to Claude Code on the remote host.
#
# tmux keeps the session alive across a dropped connection: reconnecting
# attaches to the same session rather than starting over.

# ccssh_session_name <remote-dir> [branch]
#
# The directory's full path is hashed in, so two repositories that happen to
# share a name — ~/work/api and ~/side/api — never attach to each other's
# session.
ccssh_session_name() {
  local dir="$1" branch="${2:-}" digest name
  digest="$(printf '%s' "$dir" | ccssh_sha256 | cut -c1-6)"
  name="$(ccssh_branch_slug "$(basename "$dir")")"
  printf 'ccssh-%s-%s' "$name" "$digest"
  [ -n "$branch" ] && printf -- '-%s' "$(ccssh_branch_slug "$branch")"
  printf '\n'
}

# ccssh_remote_command <workdir> <tmux-path> <session-name>
#
# Uses the absolute paths the probe resolved, and carries the login PATH into
# the session: an ssh command runs with a bare PATH, so a bare `claude` or
# `tmux` would not be found even though both are installed.
ccssh_remote_command() {
  local dir="$1" tmux_bin="$2" name="$3" prefix=''
  local claude_bin="${CCSSH_CLAUDE:-claude}"

  [ -n "${CCSSH_REMOTE_PATH:-}" ] &&
    prefix="export PATH=$(ccssh_shq "$CCSSH_REMOTE_PATH"); "

  if [ -n "$tmux_bin" ]; then
    printf '%scd %s && exec %s new -As %s %s' "$prefix" \
      "$(ccssh_shq "$dir")" "$(ccssh_shq "$tmux_bin")" \
      "$(ccssh_shq "$name")" "$(ccssh_shq "$claude_bin")"
  else
    printf '%scd %s && exec %s' "$prefix" \
      "$(ccssh_shq "$dir")" "$(ccssh_shq "$claude_bin")"
  fi
}

# ccssh_run_session <host> <workdir> <tmux-path> <session-name>
# Runs in the foreground and returns ssh's exit status. Staying alive as the
# parent is what lets a credential relay run alongside the session; see
# relay.sh. ssh still owns the terminal, so Ctrl-C and resizing behave normally.
ccssh_run_session() {
  local host="$1" dir="$2" tmux_bin="$3" name="$4"

  [ -n "$tmux_bin" ] ||
    warn "tmux not found on $host — the session ends if the connection drops"

  ssh -t "$host" "$(ccssh_remote_command "$dir" "$tmux_bin" "$name")"
}
