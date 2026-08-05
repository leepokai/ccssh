#!/usr/bin/env bash
# Shared helpers. Source this; do not execute it.

CCSSH_STATE_DIR="${CCSSH_STATE_DIR:-$HOME/.claude/ccssh}"

if [ -t 2 ]; then
  _c_dim=$'\033[2m'; _c_red=$'\033[31m'; _c_yellow=$'\033[33m'
  _c_green=$'\033[32m'; _c_reset=$'\033[0m'
else
  _c_dim=''; _c_red=''; _c_yellow=''; _c_green=''; _c_reset=''
fi

log()  { printf '%s\n' "$*" >&2; }
info() { printf '  %s%s%s\n' "$_c_dim" "$*" "$_c_reset" >&2; }
ok()   { printf '  %s✓%s %s\n' "$_c_green" "$_c_reset" "$*" >&2; }
warn() { printf '  %s!%s %s\n' "$_c_yellow" "$_c_reset" "$*" >&2; }

# die <stage> <message> [hint]
# Every failure names the stage it happened in so the user knows what to retry.
die() {
  local stage="$1" msg="$2" hint="${3:-}"
  printf '\n%serror%s [%s] %s\n' "$_c_red" "$_c_reset" "$stage" "$msg" >&2
  [ -n "$hint" ] && printf '  %s%s%s\n' "$_c_dim" "$hint" "$_c_reset" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 ||
    die "setup" "'$1' is required but not installed" "${2:-}"
}

# Write stdin to a file atomically with 0600 permissions.
write_private() {
  local dest="$1" tmp
  tmp="$(mktemp "${dest}.XXXXXX")"
  chmod 600 "$tmp"
  cat > "$tmp"
  mv -f "$tmp" "$dest"
}

ensure_state_dir() {
  mkdir -p "$CCSSH_STATE_DIR"
  chmod 700 "$CCSSH_STATE_DIR"
}

# Single-quote a value for safe interpolation into a remote shell command.
ccssh_shq() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# ccssh_expand_home <path> <remote-home>
#
# Quoting a path keeps the remote shell from doing anything clever with it —
# including expanding a leading ~, which then refers to no directory at all.
# So resolve the tilde here, where we know the remote's home, and keep quoting.
ccssh_expand_home() {
  local path="$1" home="${2:-}"

  [ -n "$home" ] || { printf '%s\n' "$path"; return 0; }

  case "$path" in
    '~')    printf '%s\n' "$home" ;;
    '~/'*)  printf '%s/%s\n' "$home" "${path#\~/}" ;;
    *)      printf '%s\n' "$path" ;;
  esac
}

ccssh_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256
  else
    sha256sum
  fi
}
