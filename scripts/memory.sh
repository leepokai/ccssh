#!/usr/bin/env bash
# Remember where each local project was last worked on.
#
# Keyed by the local directory you ran ccssh from, so returning to a project
# offers the same host, folder and branch you left it in.

ccssh_memory_file() {
  printf '%s/sessions.json' "${CCSSH_STATE_DIR:-$HOME/.claude/ccssh}"
}

# ccssh_memory_get <local-dir> — prints "host<TAB>dir<TAB>branch<TAB>worktree",
# empty when nothing is remembered.
ccssh_memory_get() {
  local file
  file="$(ccssh_memory_file)"
  [ -f "$file" ] || return 0
  python3 -c '
import json, sys

try:
    with open(sys.argv[1]) as f:
        store = json.load(f)
except Exception:
    sys.exit(0)

entry = store.get(sys.argv[2])
if not isinstance(entry, dict):
    sys.exit(0)

worktree = entry.get("worktree") or {}
print("\t".join([
    entry.get("host", ""),
    entry.get("dir", ""),
    worktree.get("branch", ""),
    worktree.get("path", ""),
]))
' "$file" "$1" 2>/dev/null
}

# ccssh_memory_put <local-dir> <host> <dir> [branch] [worktree-path]
ccssh_memory_put() {
  local file
  ensure_state_dir
  file="$(ccssh_memory_file)"
  python3 -c '
import json, os, sys

path, key, host, directory = sys.argv[1:5]
branch, worktree = (sys.argv[5], sys.argv[6]) if len(sys.argv) > 6 else ("", "")

try:
    with open(path) as f:
        store = json.load(f)
    if not isinstance(store, dict):
        store = {}
except Exception:
    store = {}

entry = {"host": host, "dir": directory}
if branch:
    entry["worktree"] = {"branch": branch, "path": worktree}

import datetime
entry["lastUsed"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
store[key] = entry

tmp = path + ".tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(store, f, indent=2)
os.replace(tmp, path)
' "$file" "$1" "$2" "$3" "${4:-}" "${5:-}"
}

# ccssh_memory_forget <local-dir>
ccssh_memory_forget() {
  local file
  file="$(ccssh_memory_file)"
  [ -f "$file" ] || return 0
  python3 -c '
import json, os, sys

path, key = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        store = json.load(f)
except Exception:
    sys.exit(0)

store.pop(key, None)
tmp = path + ".tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(store, f, indent=2)
os.replace(tmp, path)
' "$file" "$1"
}
