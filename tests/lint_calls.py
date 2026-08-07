"""Report ccssh_* helpers that are called but never defined.

A helper deleted during a rewrite while its callers stay behind fails only at
the moment that branch runs, which a test can easily never reach — one shipped
that way and printed "command not found" into the middle of the picker.
"""

import re
import sys

DEFINITION = re.compile(r"^\s*(_?[a-z][a-z0-9_]*)\s*\(\)")

# Helpers whose names do not carry the prefix. Distinctive enough not to
# collide with ordinary words in strings — which is why `log`, `info`, `ok`
# and `warn` are deliberately left out.
BARE = (
    "ensure_state_dir",
    "write_private",
    "require_cmd",
    "say_ok",
    "say_warn",
    "say_info",
    "status_clear",
)

# A call, as opposed to a variable: not preceded by $ or {, and not followed by
# = (an assignment) or ( (a definition).
CALL = re.compile(
    r"(?<![\w${-])(_?ccssh_[a-z_]+|%s)(?![\w(=])" % "|".join(BARE)
)
DECLARATION = re.compile(r"^\s*(unset|local|export|readonly|declare|typeset)\s")


def main(paths):
    defined = set()
    called = {}

    for path in paths:
        with open(path) as handle:
            for number, line in enumerate(handle, 1):
                code = line.split("#", 1)[0]
                # These take bare variable names as arguments, not calls.
                if DECLARATION.match(code):
                    continue
                for name in DEFINITION.findall(code):
                    defined.add(name)
                for name in CALL.findall(code):
                    called.setdefault(name, (path, number))

    missing = [
        (path, number, name)
        for name, (path, number) in sorted(called.items())
        if name not in defined
    ]

    for path, number, name in missing:
        print("%s:%d: %s" % (path, number, name))

    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
