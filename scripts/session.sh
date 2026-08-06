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

# --- existing sessions ------------------------------------------------------

# ccssh_session_clients <host> <name>
# How many terminals are attached to that session: 0 when it exists but nobody
# is watching, empty when there is no such session.
ccssh_session_clients() {
  local host="$1" name="$2"

  [ -n "${CCSSH_TMUX:-}" ] || return 0
  ssh "$host" "
    $(ccssh_shq "$CCSSH_TMUX") has-session -t $(ccssh_shq "=$name") 2>/dev/null || exit 1
    $(ccssh_shq "$CCSSH_TMUX") list-clients -t $(ccssh_shq "=$name") 2>/dev/null | wc -l
  " 2>/dev/null | tr -d ' '
}

# ccssh_session_list <host> [prefix]
# "name<TAB>attached" for each matching session, most recently active first.
ccssh_session_list() {
  local host="$1" prefix="${2:-ccssh-}"

  [ -n "${CCSSH_TMUX:-}" ] || return 0
  ssh "$host" "$(ccssh_shq "$CCSSH_TMUX") list-sessions -F \
    '#{session_activity}|#{session_name}|#{session_attached}'" 2>/dev/null |
    awk -F'|' -v p="$prefix" '$2 ~ "^" p { print $1 "\t" $2 "\t" $3 }' |
    sort -rn | cut -f2,3
}

# ccssh_session_latest <host> <base>
# The most recently active session for this place, or nothing.
ccssh_session_latest() {
  ccssh_session_list "$1" "$2" | head -1 | cut -f1
}

# ccssh_session_free_name <host> <base>
# base, base-2, base-3 … — the first with no session of that name.
ccssh_session_free_name() {
  local host="$1" base="$2" candidate n=1

  [ -n "${CCSSH_TMUX:-}" ] || { printf '%s\n' "$base"; return 0; }

  while [ "$n" -lt 100 ]; do
    if [ "$n" -eq 1 ]; then candidate="$base"; else candidate="$base-$n"; fi
    if ! ssh "$host" "$(ccssh_shq "$CCSSH_TMUX") has-session -t $(ccssh_shq "=$candidate")" \
         >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
    n=$((n + 1))
  done

  printf '%s\n' "$base"
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
      # -A attaches to the session if it exists and creates it otherwise;
      # -D additionally detaches anyone else, so the window is not squeezed to
      # the smallest attached terminal.
      printf '%s new -A%s -s %s %s\n' \
        "$(ccssh_shq "$CCSSH_TMUX")" \
        "$([ "${CCSSH_TAKEOVER:-0}" = "1" ] && printf D)" \
        "$(ccssh_shq "$name")" "$(ccssh_shq "$claude_bin")"
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
  local host="$1" dir="$2" name="$3" command clients

  [ "$(ccssh_multiplexer)" = "none" ] &&
    say_warn "no tmux on $host — the session ends if the connection drops"

  # Joining a session someone is already watching is sometimes the point — from
  # a phone, or alongside someone else — but it should never be a surprise.
  # The probe already asked, when it knew which session we were heading for.
  if [ -n "${CCSSH_SESSION_CLIENTS:-}" ]; then
    clients="$CCSSH_SESSION_CLIENTS"
  else
    clients="$(ccssh_session_clients "$host" "$name")"
  fi
  if [ -n "$clients" ] && [ "$clients" -gt 0 ] 2>/dev/null; then
    if [ "${CCSSH_TAKEOVER:-0}" = "1" ]; then
      say_info "taking over $name — detaching the other terminal"
    else
      say_info "joining a session already open in another terminal"
      say_info "  --new for a separate one, --takeover to detach the other"
    fi
  fi

  command="$(ccssh_remote_command "$dir" "$name")"

  if [ "$(ccssh_transport "$host")" = "mosh" ]; then
    status_clear
    # --server takes the absolute path because mosh looks it up over a
    # non-interactive ssh, whose PATH would not find it.
    # -- takes a command rather than a shell, so run one explicitly.
    mosh --server="$CCSSH_MOSH_SERVER" "$host" -- sh -c "$command" && return 0

    say_warn "mosh could not connect — falling back to ssh"
    say_warn "if that persists, open UDP 60000-61000 on $host or set useMosh: false"
  fi

  status_clear
  ssh -t "$host" "$command"
}
