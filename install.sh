#!/usr/bin/env bash
# Install ccssh.
#
#   curl -fsSL https://raw.githubusercontent.com/leepokai/ccssh/main/install.sh | bash
#
# or, from a clone you already have:
#
#   ./install.sh
#
# Piped through a shell there is no repository next door, so this fetches one
# into ~/.local/share/ccssh first. Re-running it updates that copy. Run from a
# clone and it links to the clone instead, leaving your working copy in charge.
set -euo pipefail

REPO_URL="${CCSSH_REPO_URL:-https://github.com/leepokai/ccssh}"
INSTALL_DIR="${CCSSH_INSTALL_DIR:-$HOME/.local/share/ccssh}"

note() { printf '%s\n' "$*" >&2; }
fail() { printf 'ccssh install: %s\n' "$*" >&2; exit 1; }

# --- where the source lives -------------------------------------------------

# Running from a clone? BASH_SOURCE is only a real path when this file exists
# on disk, which it does not when the script arrives on stdin.
source_dir=''
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  candidate="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [ -x "$candidate/bin/ccssh" ] && source_dir="$candidate"
fi

fetch() {
  if command -v git >/dev/null 2>&1; then
    if [ -d "$INSTALL_DIR/.git" ]; then
      note "Updating $INSTALL_DIR"
      git -C "$INSTALL_DIR" pull --quiet --ff-only ||
        fail "could not update $INSTALL_DIR — remove it and try again"
    else
      note "Fetching ccssh into $INSTALL_DIR"
      mkdir -p "$(dirname "$INSTALL_DIR")"
      git clone --quiet --depth 1 "$REPO_URL" "$INSTALL_DIR" ||
        fail "could not clone $REPO_URL"
    fi
  else
    # No git: a tarball is enough to run from, it just cannot be pulled.
    command -v curl >/dev/null 2>&1 || fail "needs git or curl"
    note "Fetching ccssh into $INSTALL_DIR"
    rm -rf "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    curl -fsSL "$REPO_URL/archive/refs/heads/main.tar.gz" |
      tar -xz -C "$INSTALL_DIR" --strip-components=1 ||
      fail "could not download $REPO_URL"
  fi
  source_dir="$INSTALL_DIR"
}

[ -n "$source_dir" ] || fetch

launcher="$source_dir/bin/ccssh"
[ -x "$launcher" ] || chmod +x "$launcher" 2>/dev/null || true
[ -x "$launcher" ] || fail "no launcher at $launcher"

# --- where it goes on PATH --------------------------------------------------

target=''
for candidate in "$HOME/.local/bin" "/usr/local/bin"; do
  case ":$PATH:" in
    *":$candidate:"*)
      if [ -d "$candidate" ] && [ -w "$candidate" ]; then
        target="$candidate"
        break
      fi
      ;;
  esac
done

if [ -z "$target" ]; then
  target="$HOME/.local/bin"
  mkdir -p "$target"
  case ":$PATH:" in
    *":$target:"*) ;;
    *)
      note ""
      note "$target is not on your PATH yet. Add this to your shell profile:"
      note ""
      note '  export PATH="$HOME/.local/bin:$PATH"'
      note ""
      ;;
  esac
fi

link="$target/ccssh"

if [ -e "$link" ] && [ ! -L "$link" ]; then
  fail "there is already a real file at $link — not touching it"
fi

ln -sf "$launcher" "$link"
note "Installed: $link -> $launcher"

# --- mosh ------------------------------------------------------------------

# mosh shows your keystrokes before the host answers and reattaches itself
# after a dropped network, so ccssh uses it whenever both ends have it. Getting
# it here is half of that, and the half that costs nothing to arrange.
# CCSSH_SKIP_MOSH=1 opts out.
install_mosh_locally() {
  [ "${CCSSH_SKIP_MOSH:-0}" = "1" ] && return 0
  command -v mosh >/dev/null 2>&1 && return 0

  local manager=''
  for candidate in brew apt-get dnf pacman apk zypper; do
    command -v "$candidate" >/dev/null 2>&1 && { manager="$candidate"; break; }
  done
  [ -n "$manager" ] || { note "No package manager here to install mosh with"; return 0; }

  note "Installing mosh"
  case "$manager" in
    brew)    brew install mosh >/dev/null 2>&1 ;;
    apt-get) sudo apt-get update >/dev/null 2>&1 && sudo apt-get install -y mosh >/dev/null 2>&1 ;;
    dnf)     sudo dnf install -y mosh >/dev/null 2>&1 ;;
    pacman)  sudo pacman -S --noconfirm mosh >/dev/null 2>&1 ;;
    apk)     sudo apk add mosh >/dev/null 2>&1 ;;
    zypper)  sudo zypper install -y mosh >/dev/null 2>&1 ;;
  esac

  if command -v mosh >/dev/null 2>&1; then
    note "  mosh installed — typing on a distant host will feel local"
  else
    note "  could not install mosh; ccssh will use ssh (install it later to switch)"
  fi
}

install_mosh_locally

# --- what to do next --------------------------------------------------------

missing=''
for dependency in ssh python3; do
  command -v "$dependency" >/dev/null 2>&1 || missing="$missing $dependency"
done
[ -n "$missing" ] && note "Missing locally:$missing — ccssh needs them"

if command -v ccssh >/dev/null 2>&1; then
  note "Ready: $(ccssh --version)"
  note ""
  note "  ccssh                 pick a host and go"
  note "  ccssh --setup <host>  get a host ready in one go"
  note "  ccssh --dry-run       walk through it without changing anything"
else
  note "Installed, but ccssh is not resolving yet — open a new shell."
fi
