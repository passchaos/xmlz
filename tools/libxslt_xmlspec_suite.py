#!/usr/bin/env python3
"""Run libxslt's real-world xmlspec regression test.

The corpus lives in testdata/libxslt-xmlspec (MIT licensed, copied from the
libxslt repository's tests/xmlspec). REC-xml-2e.xsl transforms the XML 1.0
Second Edition specification into HTML; the reference output was generated
by libxslt's own test harness. Generated `idN` values differ per engine, so
they are normalized before comparing.
"""

import os
import re
import subprocess
import sys

GENERATED_ID = re.compile(rb"id[0-9]+")


def normalize(data):
    return GENERATED_ID.sub(b"id", data)


def main():
    if len(sys.argv) < 3:
        print(
            "usage: libxslt_xmlspec_suite.py SUITE_DIR PATH/TO/xslt",
            file=sys.stderr,
        )
        return 2
    suite_dir = sys.argv[1]
    tool = sys.argv[2]
    stylesheet = os.path.join(suite_dir, "REC-xml-2e.xsl")
    source = os.path.join(suite_dir, "REC-xml-20001006.xml")
    expected_path = os.path.join(suite_dir, "REC-xml-20001006.html")
    expected = normalize(open(expected_path, "rb").read())
    result = subprocess.run(
        [tool, stylesheet, source],
        capture_output=True,
    )
    if result.returncode != 0:
        print(
            "libxslt xmlspec suite: FAILED (exit %d): %s"
            % (result.returncode, result.stderr.decode(errors="replace")),
            file=sys.stderr,
        )
        return 1
    actual = normalize(result.stdout)
    if actual != expected:
        print("libxslt xmlspec suite: FAILED (output differs)")
        return 1
    print("libxslt xmlspec suite: 1 passed, 0 failed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
