#!/usr/bin/env bash
# Offer the git repositories that live on a remote host.

CCSSH_FOLDER_LIMIT="${CCSSH_FOLDER_LIMIT:-50}"

# ccssh_list_repos <host> — repository paths, most recently touched first.
#
# Both a .git directory and a .git file (linked worktrees) count, so worktrees
# created by ccssh itself show up alongside their parent repositories.
ccssh_list_repos() {
  ssh "$1" '
    for base in "$HOME" "$HOME/projects" "$HOME/work" "$HOME/src" "$HOME/code" "$HOME/dev" "$HOME/repos"; do
      [ -d "$base" ] || continue
      find "$base" -maxdepth 2 -name .git 2>/dev/null
    done | sed "s#/\.git\$##" | sort -u
  ' 2>/dev/null | head -n "$CCSSH_FOLDER_LIMIT"
}

# ccssh_dir_exists <host> <path>
ccssh_dir_exists() {
  ssh "$1" "test -d $(ccssh_shq "$2")" 2>/dev/null
}

# ccssh_is_repo <host> <path>
ccssh_is_repo() {
  ssh "$1" "git -C $(ccssh_shq "$2") rev-parse --git-dir >/dev/null 2>&1" 2>/dev/null
}
