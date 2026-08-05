#!/usr/bin/env bash
# Tests for credential shaping. These guard a security property: the refresh
# token must never appear in what we send to a remote host.
set -uo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=../scripts/auth.sh
. scripts/auth.sh

pass=0
fail=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf '  ok   %s\n' "$name"
    pass=$((pass + 1))
  else
    printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$name" "$expected" "$actual"
    fail=$((fail + 1))
  fi
}

FULL='{
  "claudeAiOauth": {
    "accessToken": "sk-ant-oat-EXAMPLE",
    "expiresAt": 4102444800000,
    "refreshToken": "sk-ant-ort-SECRET",
    "refreshTokenExpiresAt": 4102444800000,
    "scopes": ["user:inference", "user:sessions:claude_code"],
    "subscriptionType": "max",
    "rateLimitTier": "default"
  },
  "mcpOAuth": {
    "some-server|abc123": { "accessToken": "mcp-SECRET" }
  }
}'

out="$(printf '%s' "$FULL" | ccssh_strip_credential)"

case "$out" in
  *sk-ant-ort-SECRET*) check "refresh token is removed" "absent" "PRESENT" ;;
  *)                   check "refresh token is removed" "absent" "absent" ;;
esac

case "$out" in
  *refreshTokenExpiresAt*) check "refreshTokenExpiresAt is removed" "absent" "PRESENT" ;;
  *)                       check "refreshTokenExpiresAt is removed" "absent" "absent" ;;
esac

case "$out" in
  *mcp-SECRET*) check "mcpOAuth is not forwarded" "absent" "PRESENT" ;;
  *)            check "mcpOAuth is not forwarded" "absent" "absent" ;;
esac

case "$out" in
  *sk-ant-oat-EXAMPLE*) check "access token is kept" "present" "present" ;;
  *)                    check "access token is kept" "present" "ABSENT" ;;
esac

kept="$(printf '%s' "$out" | python3 -c '
import json, sys
o = json.load(sys.stdin)["claudeAiOauth"]
print(",".join(sorted(o.keys())))
')"
check "surviving fields" \
  "accessToken,expiresAt,rateLimitTier,scopes,subscriptionType" "$kept"

printf '%s' '{"mcpOAuth":{}}' | ccssh_strip_credential >/dev/null 2>&1
check "exits 3 when there is no login credential" "3" "$?"

printf '%s' '{"claudeAiOauth":{"expiresAt":1}}' | ccssh_strip_credential >/dev/null 2>&1
check "exits 4 when the access token is missing" "4" "$?"

printf '%s' 'not json' | ccssh_strip_credential >/dev/null 2>&1
check "exits 3 on malformed input" "3" "$?"

# Opting a trusted host into self-renewal keeps the refresh token.
opted="$(printf '%s' "$FULL" | ccssh_strip_credential 1)"
case "$opted" in
  *sk-ant-ort-SECRET*) check "allowRenewal keeps the refresh token" "present" "present" ;;
  *)                   check "allowRenewal keeps the refresh token" "present" "ABSENT" ;;
esac
case "$opted" in
  *mcp-SECRET*) check "allowRenewal still drops mcpOAuth" "absent" "PRESENT" ;;
  *)            check "allowRenewal still drops mcpOAuth" "absent" "absent" ;;
esac

# Anything other than an explicit 1 must not leak the refresh token.
for flag in '' 0 true yes; do
  guarded="$(printf '%s' "$FULL" | ccssh_strip_credential "$flag")"
  case "$guarded" in
    *sk-ant-ort-SECRET*) check "flag '$flag' withholds the refresh token" "absent" "PRESENT" ;;
    *)                   check "flag '$flag' withholds the refresh token" "absent" "absent" ;;
  esac
done

past=$(( ($(date +%s) - 60) * 1000 ))
future=$(( ($(date +%s) + 3600) * 1000 ))
printf '%s' '{"claudeAiOauth":{"expiresAt":'"$past"'}}' | ccssh_credential_expired
check "detects an expired token" "0" "$?"
printf '%s' '{"claudeAiOauth":{"expiresAt":'"$future"'}}' | ccssh_credential_expired
check "detects a live token" "1" "$?"

hours="$(printf '%s' '{"claudeAiOauth":{"expiresAt":'"$(( ($(date +%s) + 7200) * 1000 ))"'}}' \
  | ccssh_credential_hours_left)"
check "reports hours until expiry" "2.0" "$hours"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
