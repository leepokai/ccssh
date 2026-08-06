#!/usr/bin/env bash
# Remember where you last worked on each host.
#
# Keyed by host, not by local directory: ccssh is a fast way onto a machine,
# not a link between a local checkout and a remote one. Run it from anywhere,
# pick a host, and you are back where you left off there.

ccssh_memory_file() {
  printf '%s/hosts.json' "${CCSSH_STATE_DIR:-$HOME/.claude/ccssh}"
}

# ccssh_memory_get <host> — "dir<TAB>branch<TAB>worktree", empty for a new host.
ccssh_memory_get() {
  local file
  file="$(ccssh_memory_file)"
  [ -f "$file" ] || return 0
  python3 -c '
import json, sys

try:
    with open(sys.argv[1]) as f:
        hosts = json.load(f).get("hosts", {})
except Exception:
    sys.exit(0)

entry = hosts.get(sys.argv[2])
if not isinstance(entry, dict):
    sys.exit(0)

worktree = entry.get("worktree") or {}
print("\t".join([
    entry.get("dir", ""),
    worktree.get("branch", ""),
    worktree.get("path", ""),
]))
' "$file" "$1" 2>/dev/null
}

# Reads host names on stdin, prints "host<TAB>last-dir" for each. One process
# for the whole list — a python start per host would be felt in the picker.
ccssh_memory_annotate() {
  local file
  file="$(ccssh_memory_file)"
  python3 -c '
import json, sys

try:
    with open(sys.argv[1]) as f:
        hosts = json.load(f).get("hosts", {})
except Exception:
    hosts = {}

for line in sys.stdin:
    host = line.strip()
    if host:
        entry = hosts.get(host) or {}
        print("%s\t%s" % (host, entry.get("dir", "")))
' "$file" 2>/dev/null
}

# The host used most recently, so it can lead the picker.
ccssh_memory_last_host() {
  local file
  file="$(ccssh_memory_file)"
  [ -f "$file" ] || return 0
  python3 -c '
import json, sys

try:
    with open(sys.argv[1]) as f:
        host = json.load(f).get("lastHost")
except Exception:
    sys.exit(0)

if isinstance(host, str):
    print(host)
' "$file" 2>/dev/null
}

# ccssh_memory_put <host> <dir> [branch] [worktree-path]
ccssh_memory_put() {
  local file
  ensure_state_dir
  file="$(ccssh_memory_file)"
  python3 -c '
import datetime, json, os, sys

path, host, directory = sys.argv[1:4]
branch = sys.argv[4] if len(sys.argv) > 4 else ""
worktree = sys.argv[5] if len(sys.argv) > 5 else ""

try:
    with open(path) as f:
        data = json.load(f)
    if not isinstance(data, dict):
        data = {}
except Exception:
    data = {}

entry = {"dir": directory}
if branch:
    entry["worktree"] = {"branch": branch, "path": worktree}
entry["lastUsed"] = datetime.datetime.now(datetime.timezone.utc).strftime(
    "%Y-%m-%dT%H:%M:%SZ")

data.setdefault("hosts", {})[host] = entry
data["lastHost"] = host

tmp = path + ".tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(data, f, indent=2)
os.replace(tmp, path)
' "$file" "$1" "$2" "${3:-}" "${4:-}"
}

# ccssh_memory_forget [host] — one host, or every host when given none.
# Prints the host it dropped, or the count when clearing everything.
ccssh_memory_forget() {
  local file
  file="$(ccssh_memory_file)"
  [ -f "$file" ] || { [ -n "${1:-}" ] && printf '%s\n' "$1" || printf '0\n'; return 0; }
  python3 -c '
import json, os, sys

path = sys.argv[1]
host = sys.argv[2] if len(sys.argv) > 2 else ""

try:
    with open(path) as f:
        data = json.load(f)
    if not isinstance(data, dict):
        data = {}
except Exception:
    data = {}

if host:
    data.get("hosts", {}).pop(host, None)
    if data.get("lastHost") == host:
        data.pop("lastHost", None)
    print(host)
else:
    print(len(data.get("hosts", {})))
    data = {}

tmp = path + ".tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(data, f, indent=2)
os.replace(tmp, path)
' "$file" "${1:-}"
}
