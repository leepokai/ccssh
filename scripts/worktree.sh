#!/usr/bin/env bash
# Branch and worktree selection on the remote host.
#
# Worktrees are placed under a single root derived from the repository path, so
# a branch name can never steer writes outside that root — the containment
# check below is what makes an attacker-supplied branch name harmless.

ccssh_worktree_root() {
  printf '%s/.ccssh-worktrees' "${CCSSH_HOME:-\$HOME}"
}

# Reject names git itself would reject, plus anything that could climb out of
# the worktree root.
ccssh_branch_valid() {
  local branch="$1"
  case "$branch" in
    ''|/*|*..*|*' '*) return 1 ;;
  esac
  git check-ref-format --branch "$branch" >/dev/null 2>&1
}

ccssh_branch_slug() {
  printf '%s' "$1" | tr '/' '-' | LC_ALL=C sed 's/[^A-Za-z0-9._-]/_/g'
}

# ccssh_worktree_path <repo-abs-path> <branch>
# Fails if the composed path would escape the worktree root.
ccssh_worktree_path() {
  local repo="$1" branch="$2" name digest slug root path
  name="$(basename "$repo")"
  digest="$(printf '%s' "$repo" | ccssh_sha256 | cut -c1-8)"
  slug="$(ccssh_branch_slug "$branch")"
  [ -n "$slug" ] || return 1

  root="$(ccssh_worktree_root)"
  path="$root/$name-$digest/$slug"

  case "$path" in
    "$root"/*/*) printf '%s\n' "$path" ;;
    *) return 1 ;;
  esac
}

# ccssh_current_branch <host> <repo>
ccssh_current_branch() {
  ssh "$1" "git -C $(ccssh_shq "$2") rev-parse --abbrev-ref HEAD 2>/dev/null" 2>/dev/null
}

# ccssh_worktree_list <host> <repo> — "branch<TAB>path" for each linked worktree,
# excluding the main checkout. Queried live so it can never go stale.
ccssh_worktree_list() {
  ssh "$1" "git -C $(ccssh_shq "$2") worktree list --porcelain 2>/dev/null" 2>/dev/null | awk '
    function flush() {
      if (path == "") return
      # The first record is the main checkout, which is not a worktree choice.
      if (++count > 1 && branch != "") print branch "\t" path
      path = ""; branch = ""
    }
    /^worktree / { flush(); path = substr($0, 10); next }
    /^branch /   { branch = substr($0, 8); sub(/^refs\/heads\//, "", branch) }
    END          { flush() }
  '
}

# ccssh_worktree_create <host> <repo> <branch> <path>
# Reuses an existing branch when there is one, otherwise creates it.
ccssh_worktree_create() {
  local host="$1" repo="$2" branch="$3" path="$4"
  ssh "$host" "
    set -e
    mkdir -p $(ccssh_shq "$(dirname "$path")")
    if git -C $(ccssh_shq "$repo") show-ref --verify --quiet refs/heads/$(ccssh_shq "$branch"); then
      git -C $(ccssh_shq "$repo") worktree add $(ccssh_shq "$path") $(ccssh_shq "$branch")
    else
      git -C $(ccssh_shq "$repo") worktree add $(ccssh_shq "$path") -b $(ccssh_shq "$branch")
    fi
  " >/dev/null
}

# ccssh_worktree_remove <host> <repo> <path>
ccssh_worktree_remove() {
  ssh "$1" "git -C $(ccssh_shq "$2") worktree remove $(ccssh_shq "$3")" >/dev/null
}
