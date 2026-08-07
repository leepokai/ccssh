#!/usr/bin/env bash
# Get what a session needs onto the remote host.
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

# --- tmux -------------------------------------------------------------------

# Prints the command that would install tmux on this host, or nothing when
# there is no package manager we recognise.
#
# Only Homebrew installs into the user's own tree; the rest need root, so they
# are offered rather than run unannounced.
# ccssh_package_install_command <host> <package>
ccssh_package_install_command() {
  local host="$1" package="$2"

  ssh "$host" "$CCSSH_PATH_SETUP"'
    pkg="'"$package"'"
    if command -v brew >/dev/null 2>&1; then
      echo "brew|brew install $pkg"
    elif command -v apt-get >/dev/null 2>&1; then
      echo "root|apt-get update && apt-get install -y $pkg"
    elif command -v dnf >/dev/null 2>&1; then
      echo "root|dnf install -y $pkg"
    elif command -v yum >/dev/null 2>&1; then
      echo "root|yum install -y $pkg"
    elif command -v pacman >/dev/null 2>&1; then
      echo "root|pacman -S --noconfirm $pkg"
    elif command -v apk >/dev/null 2>&1; then
      echo "root|apk add $pkg"
    elif command -v zypper >/dev/null 2>&1; then
      echo "root|zypper install -y $pkg"
    fi
  ' 2>/dev/null
}

# ccssh_install_package <host> <package> <purpose>
# Best effort. Returns non-zero if the install did not happen.
ccssh_install_package() {
  local host="$1" package="$2" purpose="$3" spec kind command answer option

  # "never" from a previous run is remembered here, so the same question is
  # not put twice.
  option="install$(printf '%s' "$package" |
    awk '{ print toupper(substr($0, 1, 1)) substr($0, 2) }')"
  ccssh_host_option "$host" "$option" true || return 1

  spec="$(ccssh_package_install_command "$host" "$package")"
  if [ -z "$spec" ]; then
    warn "no package manager on $host to install $package with"
    return 1
  fi

  kind="${spec%%|*}"
  command="${spec#*|}"

  if [ "$kind" = "root" ]; then
    # Asking beforehand: this touches system packages and may want a password.
    # Most Linux VPS images land here.
    log ""
    info "$package is missing on $host — $purpose"
    info "  sudo $command"
    # Enter installs. Anything worth asking about here is worth having, and
    # the answer that costs you something should be the one you have to type.
    answer="$(ccssh_prompt "Install it? [Y/n/never]")" || return 1
    case "$answer" in
      [Nn][Ee][Vv][Ee][Rr])
        ccssh_host_option_set "$host" "$option" false
        say_info "noted — $package will not be offered for $host again"
        say_info "  undo with \"$option\": true in ~/.claude/ccssh/config.json"
        return 1
        ;;
      [Nn]|[Nn][Oo])
        return 1
        ;;
      *)
        command="sudo $command"
        ;;
    esac
  else
    info "installing $package on $host with brew"
  fi

  ssh -t "$host" "$CCSSH_PATH_SETUP$command"
}

# ccssh_install_tmux <host>
# A session still runs without tmux, it just does not survive a dropped
# connection. Returns non-zero when tmux is still missing.
ccssh_install_tmux() {
  local host="$1"
  ccssh_install_package "$host" tmux \
    "without it the session ends when the connection drops" || return 1
  ccssh_probe "$host" || return 1
  [ -n "$CCSSH_TMUX" ]
}

# ccssh_install_mosh <host>
# Purely a comfort: mosh reattaches by itself after a network drop. Never
# offered unasked — it needs UDP 60000-61000 open, which on a VPS usually means
# a firewall or security-group change the user has to make themselves.
ccssh_install_mosh() {
  local host="$1"
  ccssh_install_package "$host" mosh \
    "with it the session reattaches by itself after a network drop" || return 1
  ccssh_probe "$host" || return 1
  [ -n "$CCSSH_MOSH_SERVER" ]
}
