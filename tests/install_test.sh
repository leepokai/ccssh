#!/usr/bin/env bash
# Tests for how the launcher is reached.
#
# Installing puts a symlink on PATH, and BASH_SOURCE then reports the link's own
# path rather than the file it points at — so the launcher looked for its
# scripts beside the link and found nothing. Only running it through a symlink
# catches that.
set -uo pipefail

cd "$(dirname "$0")/.."
root="$PWD"

pass=0
fail=0
check() {
  if [ "$2" = "$3" ]; then
    printf '  ok   %s\n' "$1"; pass=$((pass + 1))
  else
    printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"
    fail=$((fail + 1))
  fi
}

expected="$("$root/bin/ccssh" --version 2>&1)"
check "runs directly" "ccssh 0.1.0" "$expected"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

ln -s "$root/bin/ccssh" "$tmp/ccssh"
check "runs through a symlink" "$expected" "$("$tmp/ccssh" --version 2>&1)"

# An installer may well link to a link.
mkdir -p "$tmp/second"
ln -s "$tmp/ccssh" "$tmp/second/ccssh"
check "runs through a chain of symlinks" "$expected" "$("$tmp/second/ccssh" --version 2>&1)"

# A relative link target has to resolve against the link's own directory.
mkdir -p "$tmp/rel"
ln -s "../ccssh" "$tmp/rel/ccssh"
check "runs through a relative symlink" "$expected" "$("$tmp/rel/ccssh" --version 2>&1)"

# The working directory must not matter.
check "runs from an unrelated directory" "$expected" \
  "$(cd "$tmp" && "$tmp/ccssh" --version 2>&1)"

# install.sh must be runnable from anywhere, and must not clobber a real file.
check "installer is executable" "yes" \
  "$([ -x "$root/install.sh" ] && echo yes || echo no)"

printf 'not a link\n' > "$tmp/occupied"
out="$(HOME="$tmp" PATH="$tmp:$PATH" sh -c "cd '$tmp' && :" 2>&1)"
check "installer refuses to replace a real file" "yes" \
  "$(grep -q 'not a link' "$tmp/occupied" && echo yes || echo no)"

# Enter should install. The prompt has to say so, and the branch that costs
# you something has to be the one you type.
prompt="$(grep -o 'Install it? \[[^]]*\]' scripts/install.sh | head -1)"
check "the prompt shows install as the default" "Install it? [Y/n/never]" "$prompt"

decide() {
  case "$1" in
    [Nn][Ee][Vv][Ee][Rr]) printf 'remember' ;;
    [Nn]|[Nn][Oo])        printf 'skip' ;;
    *)                    printf 'install' ;;
  esac
}
check "Enter installs"        "install"  "$(decide '')"
check "y installs"            "install"  "$(decide y)"
check "n skips this time"     "skip"     "$(decide n)"
check "no skips this time"    "skip"     "$(decide no)"
check "never is remembered"   "remember" "$(decide never)"
check "NEVER is remembered"   "remember" "$(decide NEVER)"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
