#!/usr/bin/env bash
# Named environments.
#
# An environment is a name you give to a place you work: an SSH host, a
# directory on it, optionally a branch. `ccssh drive-bridge` then goes straight
# there, and you have a word for it when talking about it.
#
# The vocabulary follows the desktop app, whose session objects carry
# `name`, `sshHost` and `remoteCwd`. Defining them is optional — a bare host
# still works, and what a host remembers is still remembered.
#
# ~/.claude/ccssh/config.json:
#   {
#     "environments": {
#       "drive-bridge": { "sshHost": "vps", "directory": "/srv/drive-bridge" },
#       "api-staging":  { "sshHost": "vps", "directory": "/srv/api",
#                         "branch": "staging" }
#     }
#   }

ccssh_config_file() {
  printf '%s/config.json' "${CCSSH_STATE_DIR:-$HOME/.claude/ccssh}"
}

# Every environment as "name<TAB>sshHost<TAB>directory<TAB>branch", in the
# order they appear in the file.
ccssh_environments() {
  local config
  config="$(ccssh_config_file)"
  [ -f "$config" ] || return 0
  python3 -c '
import json, sys

try:
    with open(sys.argv[1]) as f:
        environments = json.load(f).get("environments", {})
except Exception:
    sys.exit(0)

if not isinstance(environments, dict):
    sys.exit(0)

for name, spec in environments.items():
    if not isinstance(spec, dict):
        continue
    host = spec.get("sshHost", "")
    if not host:
        continue
    print("\t".join([name, host, spec.get("directory", ""), spec.get("branch", "")]))
' "$config" 2>/dev/null
}

# ccssh_environment <name> — "sshHost<TAB>directory<TAB>branch", empty if the
# name is not defined. An environment name wins over a bare host of the same
# name: it was written down deliberately.
ccssh_environment() {
  local config
  config="$(ccssh_config_file)"
  [ -f "$config" ] || return 0
  python3 -c '
import json, sys

try:
    with open(sys.argv[1]) as f:
        environments = json.load(f).get("environments", {})
except Exception:
    sys.exit(0)

spec = environments.get(sys.argv[2]) if isinstance(environments, dict) else None
if not isinstance(spec, dict) or not spec.get("sshHost"):
    sys.exit(0)

print("\t".join([spec["sshHost"], spec.get("directory", ""), spec.get("branch", "")]))
' "$config" "$1" 2>/dev/null
}

# ccssh_environment_save <name> <sshHost> <directory> [branch]
# Writes one down so it can be named from then on.
ccssh_environment_save() {
  local config
  ensure_state_dir
  config="$(ccssh_config_file)"
  python3 -c '
import json, os, sys

path, name, host, directory = sys.argv[1:5]
branch = sys.argv[5] if len(sys.argv) > 5 else ""

try:
    with open(path) as f:
        data = json.load(f)
    if not isinstance(data, dict):
        data = {}
except Exception:
    data = {}

spec = {"sshHost": host, "directory": directory}
if branch:
    spec["branch"] = branch
data.setdefault("environments", {})[name] = spec

tmp = path + ".tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(data, f, indent=2)
os.replace(tmp, path)
' "$config" "$1" "$2" "$3" "${4:-}"
}
