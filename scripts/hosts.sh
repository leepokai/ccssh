#!/usr/bin/env bash
# List SSH hosts worth offering as work environments.
#
# Alias resolution is delegated entirely to `ssh -G` so that Include, Match
# and every other ssh_config construct keeps working — we never reimplement
# ssh config semantics.

CCSSH_SSH_CONFIG="${CCSSH_SSH_CONFIG:-$HOME/.ssh/config}"

# Hosts that are git services, not machines we can open a session on.
_ccssh_is_git_host() {
  case "$1" in
    github.com|gitlab.com|bitbucket.org|ssh.dev.azure.com|git.sr.ht|codeberg.org)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

# Every non-wildcard alias declared in the config, in file order, deduplicated.
ccssh_list_aliases() {
  [ -f "$CCSSH_SSH_CONFIG" ] || return 0
  awk '
    tolower($1) == "host" {
      for (i = 2; i <= NF; i++)
        if ($i !~ /[*?!]/ && !seen[$i]++) print $i
    }
  ' "$CCSSH_SSH_CONFIG"
}

# Aliases that actually point at a login host.
ccssh_list_hosts() {
  local alias hostname
  while IFS= read -r alias; do
    [ -n "$alias" ] || continue
    hostname="$(ssh -G "$alias" 2>/dev/null | awk '$1 == "hostname" { print $2; exit }')"
    _ccssh_is_git_host "$hostname" && continue
    printf '%s\n' "$alias"
  done < <(ccssh_list_aliases)
}

# True when ~/.ssh/config multiplexes connections. Without it every probe,
# credential push and worktree call pays a full handshake.
ccssh_has_multiplexing() {
  local alias="${1:-}"
  [ -n "$alias" ] || return 1
  ssh -G "$alias" 2>/dev/null | grep -qi '^controlpath [^n]'
}
