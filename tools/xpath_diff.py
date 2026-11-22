#!/usr/bin/env python3
"""Differential XPath checks: xmlz vs libxml2's xmllint."""

import subprocess
import sys
import tempfile
import os

XML = """<root>
  <item id="a" price="5"><name>Apple</name></item>
  <item id="b" price="15"><name>Banana</name></item>
  <item id="c" price="10"><name>Cherry</name></item>
  <note> hello   world </note>
  <!-- comment -->
  <?pi data?>
</root>
"""

NODE_EXPRESSIONS = [
    "//item",
    "//item[@id='b']",
    "//item/@price",
    "//item[1]",
    "//item[last()]",
    "//item[position() mod 2 = 1]",
    "//item[2]/preceding-sibling::item",
    "//item[1]/following::name",
    "//name/parent::item",
    "//item[contains(name, 'an')]",
    "//*[local-name() = 'item']",
    "//item[@price > 7]",
    "//item[@id='a' or @id='b']",
    "//item[@id][2]",
    "(//item)[last()]",
    "//item | //name",
    "//comment()",
    "//processing-instruction('pi')",
    "//item/@id/parent::item",
    "//item[1]/following-sibling::item",
    "//item[last()]/ancestor-or-self::*",
    "//item[last()]/descendant-or-self::*",
    "//item[not(@missing)]",
    "//item/@*",
    # libxml2 places an attribute after its parent's subtree for the
    # following axis; XPath 1.0 document order places attributes before the
    # parent's children. xmlz follows the specification, so this expression is
    # intentionally not compared.
    "//item[2]/@id/preceding::name",
]

SCALAR_EXPRESSIONS = [
    "count(//item)",
    "sum(//item/@price)",
    "string(//item[1]/name)",
    "normalize-space(//note)",
    "substring('12345', 2, 3)",
    "string-length('hello')",
    "concat('a', 'b', 'c')",
    "translate('abcabc', 'abc', 'AB')",
    "substring-before('1999/04/01', '/')",
    "substring-after('1999/04/01', '/')",
    "name(//item[1])",
    "local-name(//item[1])",
    "boolean(//item)",
    "1 + 2 * 3",
    "1 div 2",
]


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def main():
    if len(sys.argv) < 2:
        print("usage: xpath_diff.py PATH/TO/xpath-eval", file=sys.stderr)
        return 2
    evaluator = sys.argv[1]
    failures = 0
    checks = 0
    with tempfile.NamedTemporaryFile("w", suffix=".xml", delete=False) as handle:
        handle.write(XML)
        path = handle.name
    try:
        for expression in NODE_EXPRESSIONS:
            expected = run(["xmllint", "--xpath", f"count({expression})", path])
            actual = run([evaluator, path, expression, "count"])
            if expected.returncode == 0 and actual.returncode == 0:
                checks += 1
                if expected.stdout.strip() != actual.stdout.strip():
                    failures += 1
                    print(
                        f"FAIL count({expression})\n"
                        f"  xmllint: {expected.stdout.strip()!r}\n"
                        f"  xmlz:    {actual.stdout.strip()!r}"
                    )
        for expression in NODE_EXPRESSIONS + SCALAR_EXPRESSIONS:
            wrapped = f"string({expression})"
            expected = run(["xmllint", "--xpath", wrapped, path])
            actual = run([evaluator, path, wrapped, "string"])
            if expected.returncode != 0:
                print(f"SKIP {wrapped}: xmllint failed: {expected.stderr.strip()}")
                continue
            if actual.returncode != 0:
                failures += 1
                print(f"FAIL {wrapped}: xmlz failed: {actual.stderr.strip()}")
                continue
            checks += 1
            if expected.stdout.strip() != actual.stdout.strip():
                failures += 1
                print(
                    f"FAIL {wrapped}\n"
                    f"  xmllint: {expected.stdout.strip()!r}\n"
                    f"  xmlz:    {actual.stdout.strip()!r}"
                )
        print(f"{checks - failures}/{checks} XPath differential checks passed")
    finally:
        os.unlink(path)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
