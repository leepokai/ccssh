#!/usr/bin/env bash
# Hand the terminal over to Claude Code on the remote host.
#
# tmux keeps the session alive across a dropped connection: reconnecting
# attaches to the same session rather than starting over.
#
# Only tmux — screen was tried and dropped. The copy Apple ships is from 2006
# and renders a modern TUI badly, and supporting two multiplexers means two sets
# of key bindings and two behaviours to reason about. Where tmux is missing,
# ccssh installs it (see install.sh).

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

# Prints "tmux" or "none".
ccssh_multiplexer() {
  if [ -n "${CCSSH_TMUX:-}" ]; then
    printf 'tmux\n'
  else
    printf 'none\n'
  fi
}

# ccssh_remote_command <workdir> <session-name>
#
# Uses the absolute paths the probe resolved, and carries the login PATH into
# the session: an ssh command runs with a bare PATH, so a bare `claude` or
# `tmux` would not be found even though both are installed.
ccssh_remote_command() {
  local dir="$1" name="$2" prefix=''
  local claude_bin="${CCSSH_CLAUDE:-claude}"

  [ -n "${CCSSH_REMOTE_PATH:-}" ] &&
    prefix="export PATH=$(ccssh_shq "$CCSSH_REMOTE_PATH"); "

  printf '%scd %s && exec ' "$prefix" "$(ccssh_shq "$dir")"

  case "$(ccssh_multiplexer)" in
    tmux)
      # new -As attaches to the session if it exists, creates it otherwise.
      printf '%s new -As %s %s\n' \
        "$(ccssh_shq "$CCSSH_TMUX")" "$(ccssh_shq "$name")" "$(ccssh_shq "$claude_bin")"
      ;;
    *)
      printf '%s\n' "$(ccssh_shq "$claude_bin")"
      ;;
  esac
}

# Prints "mosh" or "ssh".
#
# mosh survives a changed IP, a closed lid and a dead network, reattaching by
# itself — tmux keeps the remote session alive, mosh keeps the client attached
# to it. It is used only when both ends already have it: a VPS with mosh-server
# installed is a deliberate choice, and one whose UDP ports are presumably open.
ccssh_transport() {
  local host="${1:-}"

  [ "${CCSSH_NO_MOSH:-0}" = "1" ] && { printf 'ssh\n'; return; }
  [ -n "$host" ] && ! ccssh_host_option "$host" useMosh true && { printf 'ssh\n'; return; }

  if [ -n "${CCSSH_MOSH_SERVER:-}" ] && command -v mosh >/dev/null 2>&1; then
    printf 'mosh\n'
  else
    printf 'ssh\n'
  fi
}

# ccssh_run_session <host> <workdir> <session-name>
# Runs in the foreground and returns the transport's exit status. Staying alive
# as the parent is what lets a credential relay run alongside the session; see
# relay.sh. The transport still owns the terminal, so Ctrl-C and resizing behave
# normally.
ccssh_run_session() {
  local host="$1" dir="$2" name="$3" command
  command="$(ccssh_remote_command "$dir" "$name")"

  [ "$(ccssh_multiplexer)" = "none" ] &&
    warn "no tmux on $host — the session ends if the connection drops"

  if [ "$(ccssh_transport "$host")" = "mosh" ]; then
    info "using mosh — the session reattaches by itself after a network drop"
    # --server takes the absolute path because mosh looks it up over a
    # non-interactive ssh, whose PATH would not find it.
    # -- takes a command rather than a shell, so run one explicitly.
    mosh --server="$CCSSH_MOSH_SERVER" "$host" -- sh -c "$command" && return 0

    warn "mosh could not connect — falling back to ssh"
    warn "if that persists, open UDP 60000-61000 on $host or set useMosh: false"
  fi

  ssh -t "$host" "$command"
}
