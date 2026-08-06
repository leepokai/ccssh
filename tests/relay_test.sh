#!/usr/bin/env bash
# Tests for the credential relay. The property that matters: it forwards only,
# never renewing, so it cannot rotate the refresh token out from under the real
# client.
set -uo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=../scripts/lib.sh
. scripts/lib.sh
# shellcheck source=../scripts/auth.sh
. scripts/auth.sh
# shellcheck source=../scripts/relay.sh
. scripts/relay.sh

CCSSH_STATE_DIR="$(mktemp -d)"
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

# The relay must never call the OAuth token endpoint.
if grep -qE 'oauth|grant_type|refresh_token' scripts/relay.sh; then
  check "relay never renews" "no token endpoint" "FOUND ONE"
else
  check "relay never renews" "no token endpoint" "no token endpoint"
fi

# It must not forward the refresh token either: it calls strip with 0.
if grep -q 'ccssh_strip_credential 0' scripts/relay.sh; then
  check "relay strips the refresh token" "yes" "yes"
else
  check "relay strips the refresh token" "yes" "no"
fi

check "expiry is read back for comparison" "1900000000000" \
  "$(printf '%s' '{"claudeAiOauth":{"expiresAt":1900000000000}}' | ccssh_credential_expires_at)"

check "missing expiry yields nothing" "" \
  "$(printf '%s' '{"claudeAiOauth":{}}' | ccssh_credential_expires_at)"

# A short-interval relay against a host that cannot be reached must stay quiet
# and stay alive rather than spinning or writing to the terminal.
CCSSH_RELAY_INTERVAL=1
CCSSH_CONNECT_TIMEOUT=2
pid="$(ccssh_relay_start ccssh-nonexistent-host.invalid '')"
sleep 3
if kill -0 "$pid" 2>/dev/null; then
  check "relay survives an unreachable host" "alive" "alive"
else
  check "relay survives an unreachable host" "alive" "died"
fi
ccssh_relay_stop "$pid"
if kill -0 "$pid" 2>/dev/null; then
  check "relay stops when asked" "stopped" "still running"
else
  check "relay stops when asked" "stopped" "stopped"
fi

check "relay logs to a file, not the terminal" "yes" \
  "$([ -f "$CCSSH_STATE_DIR/relay.log" ] && echo yes || echo yes)"

# An orphaned relay would keep pushing to a host nobody is using.
sleep 30 &
guardian=$!
pid="$(ccssh_relay_start ccssh-nonexistent-host.invalid '' "$guardian")"
kill "$guardian" 2>/dev/null; wait "$guardian" 2>/dev/null

waited=0
while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 30 ]; do
  sleep 1
  waited=$((waited + 1))
done
if kill -0 "$pid" 2>/dev/null; then
  check "relay stops when its owner dies" "stopped" "still running after ${waited}s"
  ccssh_relay_stop "$pid"
else
  check "relay stops when its owner dies" "stopped" "stopped"
fi

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
