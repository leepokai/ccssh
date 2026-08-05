#!/usr/bin/env bash
# Keep the remote's credential in step with this machine's, for as long as the
# session runs.
#
# This only ever *relays*: it reads whatever token this machine currently holds
# and pushes it. It never calls the token endpoint, so it never rotates the
# refresh token and cannot race the real client — the hazard that rules out
# sharing refresh tokens (docs/risks.md R1c) does not apply here.
#
# The consequence is that it extends the remote only as far as this machine
# renews. Use Claude Code here and the remote follows along; leave this machine
# idle and both run out together.

CCSSH_RELAY_INTERVAL="${CCSSH_RELAY_INTERVAL:-900}"

ccssh_relay_log() {
  printf '%s/relay.log' "${CCSSH_STATE_DIR:-$HOME/.claude/ccssh}"
}

# ccssh_relay_loop <host> <interval>
# Never writes to the terminal: the remote session owns it, and stray output
# would corrupt the display.
ccssh_relay_loop() {
  local host="$1" interval="$2" pushed="$3" guardian="${4:-}" raw expires payload

  while sleep "$interval"; do
    # If ccssh was killed outright its EXIT trap never ran, and without this
    # the relay would keep pushing to a host nobody is using any more.
    if [ -n "$guardian" ] && ! kill -0 "$guardian" 2>/dev/null; then
      printf '%s session owner %s is gone, stopping\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$guardian"
      break
    fi

    raw="$(ccssh_read_credential 2>/dev/null)" || continue

    # A dead token is worse than none: it would look installed and fail later.
    printf '%s' "$raw" | ccssh_credential_expired && continue

    expires="$(printf '%s' "$raw" | ccssh_credential_expires_at)"
    [ -n "$expires" ] || continue
    [ "$expires" = "$pushed" ] && continue

    # Shape it fully before sending: piping straight into ssh leaves a broken
    # pipe behind whenever the host is unreachable.
    payload="$(printf '%s' "$raw" | ccssh_strip_credential 0)" || continue

    if printf '%s' "$payload" | ccssh_push_credential "$host" 2>/dev/null; then
      pushed="$expires"
      printf '%s relayed to %s, expires %s\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$host" "$expires"
    fi
  done
}

# ccssh_relay_start <host> <already-pushed-expiry> [guardian-pid]
# Prints the pid of the background relay, or nothing if it did not start.
ccssh_relay_start() {
  local host="$1" pushed="${2:-}" guardian="${3:-}" log

  ensure_state_dir
  log="$(ccssh_relay_log)"

  ccssh_relay_loop "$host" "$CCSSH_RELAY_INTERVAL" "$pushed" "$guardian" \
    >>"$log" 2>&1 </dev/null &
  printf '%s\n' "$!"
}

# The relay is started inside a command substitution, so it is not a child of
# the caller and `wait` cannot be used — poll for it to actually go away.
ccssh_relay_stop() {
  local pid="${1:-}" attempt=0
  [ -n "$pid" ] || return 0

  kill "$pid" 2>/dev/null || return 0

  while kill -0 "$pid" 2>/dev/null; do
    attempt=$((attempt + 1))
    if [ "$attempt" -gt 20 ]; then
      kill -9 "$pid" 2>/dev/null || true
      break
    fi
    sleep 0.1
  done
}
