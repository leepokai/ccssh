#!/usr/bin/env bash
# Run every test suite. Exits non-zero if any of them fails.
set -uo pipefail

cd "$(dirname "$0")"

failed=0
for suite in *_test.sh; do
  printf '\n%s\n' "$suite"
  bash "$suite" || failed=1
done

# The end-to-end suite drives the real launcher on a real pty against a real
# host, so it only runs when given one:
#   CCSSH_E2E_HOST=my-vps tests/run.sh

# Parse against the oldest bash we support. macOS still ships 3.2, so a bash 4+
# construct that works on the author's machine would break for most users.
checker=bash
[ -x /bin/bash ] && checker=/bin/bash

printf '\nsyntax (%s %s)\n' "$checker" \
  "$("$checker" -c 'echo ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}')"
for script in ../bin/ccssh ../scripts/*.sh; do
  if "$checker" -n "$script" 2>/dev/null; then
    printf '  ok   %s\n' "$(basename "$script")"
  else
    printf '  FAIL %s\n' "$(basename "$script")"
    failed=1
  fi
done

printf '\nbash 3.2 compatibility\n'
if grep -nE 'declare -A|mapfile|readarray|\$\{[a-zA-Z_]+\^\^|\$\{[a-zA-Z_]+,,' \
     ../bin/ccssh ../scripts/*.sh 2>/dev/null; then
  printf '  FAIL uses a bash 4+ construct\n'
  failed=1
else
  printf '  ok   no bash 4+ constructs\n'
fi
if grep -nE 'read[^|]*-t +[0-9]*\.[0-9]' ../bin/ccssh ../scripts/*.sh 2>/dev/null |
     grep -v CCSSH_ESCAPE_TIMEOUT; then
  printf '  FAIL fractional read timeout (bash 3.2 rejects it)\n'
  failed=1
else
  printf '  ok   no literal fractional read timeouts\n'
fi

if [ "$failed" -eq 0 ]; then
  printf '\nall suites passed\n'
else
  printf '\nsome suites failed\n'
fi
exit "$failed"
