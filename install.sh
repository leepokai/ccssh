#!/usr/bin/env bash
# Put ccssh on your PATH.
#
# This symlinks rather than copies, so `git pull` in this clone is all an
# update takes. Keep the clone somewhere permanent — the link points at it.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
launcher="$root/bin/ccssh"

if [ ! -x "$launcher" ]; then
  printf 'No launcher at %s — run this from inside the ccssh clone.\n' "$launcher" >&2
  exit 1
fi

# Prefer a directory already on PATH that we can write to. ~/.local/bin comes
# first because that is where Claude Code installs itself.
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

# Nothing suitable: create ~/.local/bin and say what to add to the profile.
if [ -z "$target" ]; then
  target="$HOME/.local/bin"
  mkdir -p "$target"
  case ":$PATH:" in
    *":$target:"*) ;;
    *)
      printf '%s is not on your PATH yet. Add this to your shell profile:\n\n' "$target"
      printf '  export PATH="$HOME/.local/bin:$PATH"\n\n'
      ;;
  esac
fi

link="$target/ccssh"

if [ -e "$link" ] && [ ! -L "$link" ]; then
  printf 'There is already a real file at %s — not touching it.\n' "$link" >&2
  exit 1
fi

ln -sf "$launcher" "$link"

printf 'Installed: %s -> %s\n' "$link" "$launcher"

if command -v ccssh >/dev/null 2>&1; then
  printf 'Ready: %s\n' "$(ccssh --version)"
else
  printf 'Installed, but ccssh is not resolving yet — open a new shell.\n'
fi

command -v tmux >/dev/null 2>&1 ||
  printf '\nNote: hosts need tmux for a session to survive a dropped connection.\n'
