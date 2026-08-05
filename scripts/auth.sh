#!/usr/bin/env bash
# Forward the local Claude Code login credential to a remote host.
#
# The long-lived refresh token never leaves this machine: only the short-lived
# access token is sent, so a compromised remote yields a credential that
# expires on its own and cannot be renewed. This mirrors what the desktop app
# does (see docs/research/desktop-ssh-sessions-teardown.md).
#
# The payload always travels over stdin — never as a command-line argument,
# which would expose it in the remote process list.

CCSSH_KEYCHAIN_SERVICE="${CCSSH_KEYCHAIN_SERVICE:-Claude Code-credentials}"

# --- reading the local credential ------------------------------------------

# Print the raw credential JSON, or exit non-zero if there is none.
#
# On macOS the login credential lives in the Keychain, not in
# .credentials.json — that file typically holds only MCP OAuth entries.
ccssh_read_credential() {
  local dir file

  if [ "$(uname -s)" = "Darwin" ]; then
    if security find-generic-password -s "$CCSSH_KEYCHAIN_SERVICE" -w 2>/dev/null; then
      return 0
    fi
  fi

  dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  file="$dir/.credentials.json"
  [ -f "$file" ] || return 1
  cat "$file"
}

# --- shaping what gets sent -------------------------------------------------

# ccssh_strip_credential [keep-refresh-token]
# stdin: raw credential JSON. stdout: the reduced payload to send.
# Exit 3 when there is no login credential, 4 when the access token is missing.
#
# By default the refresh token is dropped, so the forwarded credential expires
# on its own. Passing 1 keeps it, which lets the remote renew itself — only
# appropriate for a host you control (see ccssh_renewal_enabled).
ccssh_strip_credential() {
  python3 -c '
import json, sys

keep_refresh = len(sys.argv) > 1 and sys.argv[1] == "1"

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(3)

oauth = data.get("claudeAiOauth")
if not isinstance(oauth, dict):
    sys.exit(3)

if not keep_refresh:
    oauth.pop("refreshToken", None)
    oauth.pop("refreshTokenExpiresAt", None)

if not oauth.get("accessToken"):
    sys.exit(4)

# mcpOAuth belongs to this machine MCP servers; the remote has its own.
json.dump({"claudeAiOauth": oauth}, sys.stdout)
' "${1:-0}"
}

# stdin: credential JSON. stdout: the raw expiry timestamp, for comparing one
# credential against another.
ccssh_credential_expires_at() {
  python3 -c '
import json, sys

try:
    expires = json.load(sys.stdin).get("claudeAiOauth", {}).get("expiresAt")
except Exception:
    sys.exit(0)

if isinstance(expires, (int, float)):
    print(int(expires))
'
}

# stdin: credential JSON. Succeeds when the access token has already expired.
ccssh_credential_expired() {
  python3 -c '
import json, sys, time

try:
    oauth = json.load(sys.stdin).get("claudeAiOauth", {})
except Exception:
    sys.exit(1)

expires = oauth.get("expiresAt")
sys.exit(0 if isinstance(expires, (int, float)) and expires / 1000.0 <= time.time() else 1)
'
}

# stdin: credential JSON. stdout: hours until the access token expires,
# one decimal place. Empty when the credential carries no expiry.
ccssh_credential_hours_left() {
  python3 -c '
import json, sys, time

try:
    oauth = json.load(sys.stdin).get("claudeAiOauth", {})
except Exception:
    sys.exit(0)

expires = oauth.get("expiresAt")
if isinstance(expires, (int, float)):
    print("%.1f" % ((expires / 1000.0 - time.time()) / 3600.0))
'
}

# --- per-host policy --------------------------------------------------------

# ccssh_host_option <host> <key> <default:true|false>
# Reads ~/.claude/ccssh/config.json:
#   { "hosts": { "mac-mini": { "allowRenewal": true },
#                "shared-cluster": { "forwardAuth": false } } }
ccssh_host_option() {
  local host="$1" key="$2" default="$3"
  local config="${CCSSH_STATE_DIR:-$HOME/.claude/ccssh}/config.json"

  if [ ! -f "$config" ]; then
    [ "$default" = "true" ] && return 0 || return 1
  fi

  python3 -c '
import json, sys

path, host, key, default = sys.argv[1:5]
try:
    with open(path) as f:
        hosts = json.load(f).get("hosts", {})
except Exception:
    hosts = {}

value = hosts.get(host, {}).get(key, default == "true")
sys.exit(0 if value else 1)
' "$config" "$host" "$key" "$default"
}

# Credential forwarding is opt-out per host, for machines you do not control.
ccssh_forward_enabled() {
  ccssh_host_option "$1" forwardAuth true
}

# Letting the remote renew itself means sending the long-lived refresh token.
#
# Off by default, and not merely for exposure: refresh tokens rotate, so two
# machines holding one are two clients racing over a single credential, and
# whichever renews first can leave the other logged out. Signing in on the host
# is the durable answer; see docs/risks.md R1c.
ccssh_renewal_enabled() {
  ccssh_host_option "$1" allowRenewal false
}

# --- installing on the remote ----------------------------------------------

# Merge the payload into the remote credential file, preserving whatever
# mcpOAuth entries the remote already has. The script below is quoted with
# double quotes only so it can be wrapped in single quotes for ssh, and it
# contains no secret — the payload arrives on stdin.
_CCSSH_MERGE_PY='
import json, os, sys

home = os.path.expanduser("~")
path = os.path.join(home, ".claude", ".credentials.json")

try:
    incoming = json.load(sys.stdin)
except Exception:
    sys.stderr.write("payload is not valid JSON\n")
    sys.exit(3)

oauth = incoming.get("claudeAiOauth")
if not isinstance(oauth, dict):
    sys.stderr.write("payload carries no claudeAiOauth\n")
    sys.exit(3)

try:
    with open(path) as f:
        current = json.load(f)
    if not isinstance(current, dict):
        current = {}
except Exception:
    current = {}

current["claudeAiOauth"] = oauth

tmp = path + ".ccssh-tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(current, f)
os.replace(tmp, path)
print("ok")
'

# ccssh_push_credential <host> ; payload on stdin
ccssh_push_credential() {
  local host="$1"
  ssh "$host" "umask 077; mkdir -p ~/.claude && chmod 700 ~/.claude && python3 -c '$_CCSSH_MERGE_PY'" \
    >/dev/null
}

# --- orchestration ----------------------------------------------------------

# Forward the credential to <host>. Never fatal: on any failure the caller is
# told the remote needs an interactive login, and the connection continues.
# Returns 0 when the remote is authenticated, 1 when the user must log in there.
# Set by ccssh_forward_credential so a relay knows what the remote already has.
CCSSH_FORWARDED=0
CCSSH_FORWARDED_EXPIRY=''

ccssh_forward_credential() {
  local host="$1" raw payload hours keep_refresh=0

  CCSSH_FORWARDED=0
  CCSSH_FORWARDED_EXPIRY=''

  if ! ccssh_forward_enabled "$host"; then
    info "credential forwarding disabled for $host"
    return 1
  fi

  if ! raw="$(ccssh_read_credential)"; then
    warn "no local credential found"
    return 1
  fi

  # Pushing an already-dead token would look like success and fail later on
  # the remote, so say what is actually wrong.
  if printf '%s' "$raw" | ccssh_credential_expired; then
    warn "the local access token has already expired"
    warn "run any Claude Code command here to renew it, then reconnect"
    return 1
  fi

  ccssh_renewal_enabled "$host" && keep_refresh=1

  if ! payload="$(printf '%s' "$raw" | ccssh_strip_credential "$keep_refresh")"; then
    warn "local credential is not in a recognised format"
    return 1
  fi

  if ! printf '%s' "$payload" | ccssh_push_credential "$host"; then
    warn "could not write the credential on $host"
    return 1
  fi

  CCSSH_FORWARDED=1
  CCSSH_FORWARDED_EXPIRY="$(printf '%s' "$raw" | ccssh_credential_expires_at)"

  if [ "$keep_refresh" = "1" ]; then
    ok "credentials forwarded — $host can renew them itself"
    warn "both machines now share one rotating token; either may be logged out"
    return 0
  fi

  hours="$(printf '%s' "$raw" | ccssh_credential_hours_left)"
  if [ -n "$hours" ]; then
    ok "credentials forwarded (valid for ${hours}h)"
    # Without the refresh token the remote cannot renew on its own.
    if [ "${hours%.*}" -lt 2 ] 2>/dev/null; then
      warn "reconnect with ccssh when that runs out, or enable allowRenewal for $host"
    fi
  else
    ok "credentials forwarded"
  fi
  return 0
}
