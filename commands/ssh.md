---
description: Manage ccssh remote hosts — list, test, forward credentials, handle worktrees
argument-hint: "[list | test <host> | auth <host> | worktree list | worktree rm <branch> | forget]"
allowed-tools: Bash
---

Manage ccssh connections. The user asked: `$ARGUMENTS`

Scripts live in `${CLAUDE_PLUGIN_ROOT}/scripts/`. Source `lib.sh` first, then the
module you need, and run the matching function. Everything below runs on the
machine this session is on.

| Request | What to run |
|---|---|
| `list` (or no argument) | `ccssh_list_hosts` from `hosts.sh` |
| `test <host>` | `ccssh_probe <host>` from `probe.sh`, then report OS, arch, claude version, and whether git/tmux/python3 are present |
| `auth <host>` | `ccssh_forward_credential <host>` from `auth.sh` |
| `worktree list` | `ccssh_worktree_list <host> <repo>` from `worktree.sh` |
| `worktree rm <branch>` | resolve the path with `ccssh_worktree_list`, then `ccssh_worktree_remove` |
| `forget` | `ccssh_memory_forget "$PWD"` from `memory.sh` |

Example:

```bash
. "${CLAUDE_PLUGIN_ROOT}/scripts/lib.sh"
. "${CLAUDE_PLUGIN_ROOT}/scripts/probe.sh"
ccssh_probe mac-mini && echo "$CCSSH_OS $CCSSH_ARCH claude=$CCSSH_VERSION"
```

Report results in prose — say what the state is, not just what the command
printed. If a host is unreachable, say so plainly and suggest `ssh <host>` to
check it directly.

Switching the session to a different host is not something this command can do:
a slash command cannot take over the terminal. To move, leave the session and
run `ccssh <host>`.
