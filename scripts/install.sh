#!/usr/bin/env bash
# Install Claude Code on a remote host using the official installer.
#
# We never download or redistribute Anthropic binaries ourselves — the remote
# fetches them from the official endpoint.

CCSSH_INSTALL_URL="${CCSSH_INSTALL_URL:-https://claude.ai/install.sh}"

# ccssh_install_claude <host> — runs on a TTY so the installer can report
# progress. Returns non-zero if claude is still missing afterwards.
ccssh_install_claude() {
  local host="$1"

  ssh -t "$host" "curl -fsSL $(ccssh_shq "$CCSSH_INSTALL_URL") | bash" || return 1

  # Re-probe rather than guessing: the installer extends PATH through the shell
  # profile, which only a login shell reads.
  ccssh_probe "$host" || return 1
  [ -n "$CCSSH_CLAUDE" ]
}
