#!/usr/bin/env python3
"""Run the libxslt general regression suite against the xmlz xslt tool.

The suite lives in testdata/libxslt-general (MIT licensed, copied from the
libxslt repository). Each X.xsl uses X.xml as input and X.out as the expected
result; X.err marks tests that must fail.

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

# Tests that currently differ from libxslt. Empty: the suite passes in full.
KNOWN_FAILURES = set()


def tree_shape(element):
    if isinstance(element, etree._Comment):
        return ("comment", element.text or "")
    if isinstance(element, etree._ProcessingInstruction):
        return ("pi", element.target, element.text or "")
    attributes = sorted(
        (etree.QName(name).namespace or "", etree.QName(name).localname, value)
        for name, value in element.attrib.items()
    )
    return (
        "element",
        etree.QName(element).namespace or "",
        etree.QName(element).localname,
        tuple(attributes),
        element.text or "",
        tuple(tree_shape(child) for child in element),
        element.tail or "",
    )


def compare(expected, actual):
    try:
        expected_tree = etree.fromstring(expected)
    except etree.XMLSyntaxError:
        return expected == actual
    try:
        actual_tree = etree.fromstring(actual)
    except etree.XMLSyntaxError:
        return False
    return tree_shape(expected_tree) == tree_shape(actual_tree)


def main():
    if len(sys.argv) < 3:
        print(
            "usage: libxslt_suite.py SUITE_DIR PATH/TO/xslt",
            file=sys.stderr,
        )
        return 2
    suite_dir = sys.argv[1]
    tool = sys.argv[2]
    passed = 0
    skipped = 0
    failures = set()
    for name in sorted(os.listdir(suite_dir)):
        if not name.endswith(".xsl"):
            continue
        base = name[:-4]
        stylesheet = os.path.join(suite_dir, name)
        source = os.path.join(suite_dir, base + ".xml")
        expected_path = os.path.join(suite_dir, base + ".out")
        error_path = os.path.join(suite_dir, base + ".err")
        if not os.path.exists(expected_path) or not os.path.exists(source):
            skipped += 1
            continue
        expected = open(expected_path, "rb").read()
        expected_error = b""
        if os.path.exists(error_path):
            expected_error = open(error_path, "rb").read()
        result = subprocess.run(
            [
                tool,
                stylesheet,
                source,
                "--param=test=passed_value",
                "--param=test2=passed_value2",
            ],
            capture_output=True,
        )
        if expected_error.strip():
            # libxslt writes diagnostics but may still exit successfully;
            # require that xmlz reports something on stderr.
            ok = len(result.stderr.strip()) != 0
        elif result.returncode != 0:
            ok = False
        else:
            ok = compare(expected, result.stdout)
        if ok:
            passed += 1
        else:
            failures.add(name)

    unexpected = failures - KNOWN_FAILURES
    fixed = KNOWN_FAILURES - failures
    print(
        f"libxslt general suite: {passed} passed, "
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
