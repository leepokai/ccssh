#!/usr/bin/env bash
# Hand the terminal over to Claude Code on the remote host.
#
# A multiplexer keeps the session alive across a dropped connection:
# reconnecting attaches to the same session rather than starting over. tmux is
# preferred, but screen ships with macOS and most Linux distributions, so
# falling back to it means persistence usually works with nothing to install.

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

# Prints "tmux", "screen" or "none" for what the remote can offer.
ccssh_multiplexer() {
  if [ -n "${CCSSH_TMUX:-}" ]; then
    printf 'tmux\n'
  elif [ -n "${CCSSH_SCREEN:-}" ]; then
    printf 'screen\n'
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
    screen)
      # -D -R detaches the session from anywhere else and reattaches here,
      # creating it if there is none; -S names it.
      printf '%s -DRS %s %s\n' \
        "$(ccssh_shq "$CCSSH_SCREEN")" "$(ccssh_shq "$name")" "$(ccssh_shq "$claude_bin")"
      ;;
    *)
      printf '%s\n' "$(ccssh_shq "$claude_bin")"
      ;;
  esac
}

# ccssh_run_session <host> <workdir> <session-name>
# Runs in the foreground and returns ssh's exit status. Staying alive as the
# parent is what lets a credential relay run alongside the session; see
# relay.sh. ssh still owns the terminal, so Ctrl-C and resizing behave normally.
ccssh_run_session() {
  local host="$1" dir="$2" name="$3"

  case "$(ccssh_multiplexer)" in
    screen) info "using screen on $host — tmux is not installed there" ;;
    none)   warn "no tmux or screen on $host — the session ends if the connection drops" ;;
  esac

  ssh -t "$host" "$(ccssh_remote_command "$dir" "$name")"
}
