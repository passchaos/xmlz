#!/usr/bin/env python3
"""Run the libxslt EXSLT regression corpus against the xmlz xslt tool.

The corpus lives in testdata/libxslt-exslt (MIT licensed, copied from the
libxslt repository's tests/exslt). Each X.xsl uses X.xml as input and X.out
as the expected result; X.err marks tests that must fail.

Known failures are tracked explicitly so the gate reports regressions and
newly fixed tests. Update KNOWN_FAILURES when behavior changes intentionally.
"""

import os
import subprocess
import sys

try:
    from lxml import etree
except ImportError:  # pragma: no cover
    print("SKIP: lxml is not installed", file=sys.stderr)
    sys.exit(0)

from libxslt_suite import compare

# Tests that currently differ from libxslt.
# object-type.1.xsl needs the Saxon extension module: saxon:expression()
# returns an opaque external value, which libxslt reports as "external".
KNOWN_FAILURES = {
    "common/object-type.1.xsl",
}

MODULES = ("common", "functions", "math", "sets", "strings")


def main():
    if len(sys.argv) < 3:
        print(
            "usage: libxslt_exslt_suite.py SUITE_DIR PATH/TO/xslt",
            file=sys.stderr,
        )
        return 2
    suite_dir = sys.argv[1]
    tool = sys.argv[2]
    passed = 0
    skipped = 0
    failures = set()
    for module in MODULES:
        directory = os.path.join(suite_dir, module)
        if not os.path.isdir(directory):
            skipped += 1
            continue
        for name in sorted(os.listdir(directory)):
            if not name.endswith(".xsl"):
                continue
            base = name[:-4]
            stylesheet = os.path.join(directory, name)
            source = os.path.join(directory, base + ".xml")
            expected_path = os.path.join(directory, base + ".out")
            error_path = os.path.join(directory, base + ".err")
            if not os.path.exists(expected_path) or not os.path.exists(source):
                skipped += 1
                continue
            expected = open(expected_path, "rb").read()
            expected_error = b""
            if os.path.exists(error_path):
                expected_error = open(error_path, "rb").read()
            result = subprocess.run(
                [tool, stylesheet, source],
                capture_output=True,
            )
            if expected_error.strip():
                ok = len(result.stderr.strip()) != 0
            elif result.returncode != 0:
                ok = False
            else:
                ok = compare(expected, result.stdout)
            if ok:
                passed += 1
            else:
                failures.add(f"{module}/{name}")

    unexpected = failures - KNOWN_FAILURES
    fixed = KNOWN_FAILURES - failures
    print(
        f"libxslt EXSLT suite: {passed} passed, "
        f"{len(failures)} failed, {skipped} skipped"
    )
    for name in sorted(unexpected):
        print(f"REGRESSION {name}")
    for name in sorted(fixed):
        print(f"FIXED {name} (remove from KNOWN_FAILURES)")
    if unexpected or fixed:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
