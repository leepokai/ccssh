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
