#!/usr/bin/env python3
"""Fails when Swift source compares two Dates with `>=` or `<=`.

Some macOS 27.2 seed builds ship without Foundation's `Date.>=` and `Date.<=`.
An app built with the 27.2 SDK calls them directly and jumps to address 0 on
such a seed (see scripts/check_date_symbols.sh). That binary check only sees
the problem when CI builds with the 27.2 SDK or later; older SDKs have no
concrete `Date.>=`, so the same source compiles to Comparable's generic one
and the binary looks clean. This check reads the type-checked AST instead,
which names the operator and its operand types on every SDK.

Usage:
  check_date_operators.py --self-test            # the dump format is understood
  swiftc -dump-ast ... | check_date_operators.py # check one module's dump

App code compares Dates with `<` only, or with Date.isOnOrAfter /
Date.isOnOrBefore (macos/Sources/Moments/Design/DateOrder.swift).
"""

import re
import subprocess
import sys
import tempfile
from pathlib import Path

# A reference to an operator named >= or <=, e.g.
#   decl="Swift.(file).Comparable extension.>="
#   decl="Foundation.(file).Date.<=@/path/Date.swift:12:3"
OPERATOR = re.compile(r'decl="[^"]*\.(>=|<=)(?:@[^"]*)?"')
# ...whose operands are Dates, read from the reference's (substituted) type
# or its substitution map.
DATE_OPERANDS = re.compile(
    r'\((?:Foundation\.)?Date, (?:Foundation\.)?Date\) -> (?:Swift\.)?Bool'
    r'|Self -> (?:Foundation\.)?Date\b'
)
LOCATION = re.compile(r'location=(\S+?:\d+:\d+)')


def findings(dump):
    found = []
    lines = dump.splitlines()
    for index, line in enumerate(lines):
        if "declref_expr" not in line:
            continue
        operator = OPERATOR.search(line)
        if not operator:
            continue
        # Newer compilers print the substitution map on the lines after it.
        context = [line]
        for following in lines[index + 1:index + 6]:
            if "substitution" not in following:
                break
            context.append(following)
        context = "\n".join(context)
        if not DATE_OPERANDS.search(context):
            continue
        location = LOCATION.search(line)
        found.append((location.group(1) if location else "?", operator.group(1)))
    return found


def self_test():
    """Proves this toolchain's dump format is understood: flags a known
    `Date >= Date`, and leaves `<`, generic code and Int `>=` alone."""
    source = (
        "import Foundation\n"
        "let a = Date()\n"
        "let b = Date()\n"
        "let bad = a >= b\n"
        "let alsoBad = a <= b\n"
        "let fine = a < b\n"
        "let fineInt = 3 >= 2\n"
        "let fineSorted = [a, b].sorted()\n"
        "let fineRange = (a...b).contains(a)\n"
    )
    with tempfile.TemporaryDirectory() as folder:
        path = Path(folder) / "DateOperatorsSelfTest.swift"
        path.write_text(source)
        result = subprocess.run(
            ["swiftc", "-dump-ast", str(path)],
            capture_output=True, text=True,
        )
    if result.returncode != 0:
        print(result.stderr, file=sys.stderr)
        print("date operator check: swiftc -dump-ast failed in the self-test", file=sys.stderr)
        return 1
    lines = sorted({int(loc.rsplit(":", 2)[1]) for loc, _ in findings(result.stdout + result.stderr)})
    if lines != [4, 5]:
        print(f"date operator check: self-test flagged lines {lines}, expected [4, 5]", file=sys.stderr)
        print("date operator check: the -dump-ast format changed; update the patterns", file=sys.stderr)
        return 1
    print("date operator check: self-test OK")
    return 0


def main(argv):
    if argv[1:] == ["--self-test"]:
        return self_test()
    if len(argv) > 2:
        print(__doc__, file=sys.stderr)
        return 2
    dump = Path(argv[1]).read_text() if len(argv) == 2 else sys.stdin.read()
    if "source_file" not in dump:
        print("date operator check: input is not a swiftc -dump-ast dump", file=sys.stderr)
        return 2
    found = findings(dump)
    if found:
        print("date operator check: FAILED", file=sys.stderr)
        for location, operator in found:
            print(f"  {location}: Date {operator} Date", file=sys.stderr)
        print("date operator check: compare with `<`, or use Date.isOnOrAfter / isOnOrBefore.", file=sys.stderr)
        return 1
    print(f"date operator check: OK ({dump.count('(source_file')} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
