#!/usr/bin/env bash
# Tests for named environments.
#
# The vocabulary follows the desktop app, whose session objects carry `name`,
# `sshHost` and `remoteCwd` — so an environment here is a name, a host and a
# directory, optionally a branch.
set -uo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=../scripts/lib.sh
. scripts/lib.sh
# shellcheck source=../scripts/environments.sh
. scripts/environments.sh

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

check "nothing is defined to begin with" "" "$(ccssh_environments)"
check "an unknown name resolves to nothing" "" "$(ccssh_environment drive-bridge)"

ccssh_environment_save drive-bridge vps /srv/drive-bridge dev/kevin
check "round-trips host, directory and branch" 'vps|/srv/drive-bridge|dev/kevin' \
  "$(ccssh_environment drive-bridge | tr '\t' '|')"

ccssh_environment_save api-staging vps /srv/api
check "round-trips without a branch" 'vps|/srv/api|' \
  "$(ccssh_environment api-staging | tr '\t' '|')"

check "lists every environment" 'drive-bridge|vps|/srv/drive-bridge|dev/kevin
api-staging|vps|/srv/api|' "$(ccssh_environments | tr '\t' '|')"

ccssh_environment_save drive-bridge other /srv/moved
check "saving again replaces the entry" 'other|/srv/moved|' \
  "$(ccssh_environment drive-bridge | tr '\t' '|')"
check "and drops a branch that is no longer set" "2" \
  "$(ccssh_environments | wc -l | tr -d ' ')"

check "the config is private" "600" \
  "$(stat -f '%Lp' "$CCSSH_STATE_DIR/config.json" 2>/dev/null ||
     stat -c '%a' "$CCSSH_STATE_DIR/config.json" 2>/dev/null)"

# Per-host options live in the same file and must survive writing environments.
python3 - "$CCSSH_STATE_DIR/config.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
data["hosts"] = {"vps": {"forwardAuth": False}}
with open(sys.argv[1], "w") as f:
    json.dump(data, f)
PY
ccssh_environment_save third vps /srv/third
# shellcheck source=../scripts/auth.sh
. scripts/auth.sh
if ccssh_host_option vps forwardAuth true; then
  check "host options survive an environment write" "false" "true"
else
  check "host options survive an environment write" "false" "false"
fi

# A malformed file must not take the whole tool down.
printf 'not json\n' > "$CCSSH_STATE_DIR/config.json"
check "a broken config yields no environments" "" "$(ccssh_environments)"
check "a broken config resolves no name" "" "$(ccssh_environment drive-bridge)"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
