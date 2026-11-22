#!/usr/bin/env python3
"""Differential XInclude checks: xmlz vs libxml2's xmllint."""

import os
import subprocess
import sys
import tempfile

try:
    from lxml import etree
except ImportError:  # pragma: no cover
    print("SKIP: lxml is not installed", file=sys.stderr)
    sys.exit(0)

CASES = [
    (
        "basic-include",
        {
            "main.xml": """<root xmlns:xi="http://www.w3.org/2001/XInclude">
              <a/><xi:include href="inc.xml"/><b/>
            </root>""",
            "inc.xml": "<doc><x>1</x><y>2</y></doc>",
        },
    ),
    (
        "nested-include",
        {
            "main.xml": """<root xmlns:xi="http://www.w3.org/2001/XInclude">
              <xi:include href="inc.xml"/>
            </root>""",
            "inc.xml": """<doc xmlns:xi="http://www.w3.org/2001/XInclude">
              <x/><xi:include href="leaf.xml"/>
            </doc>""",
            "leaf.xml": "<leaf>text</leaf>",
        },
    ),
    (
        "fallback-missing",
        {
            "main.xml": """<root xmlns:xi="http://www.w3.org/2001/XInclude">
              <xi:include href="missing.xml"><xi:fallback><fb/></xi:fallback></xi:include>
            </root>""",
        },
    ),
    (
        "parse-text",
        {
            "main.xml": """<root xmlns:xi="http://www.w3.org/2001/XInclude">
              <xi:include href="t.txt" parse="text"/>
            </root>""",
            "t.txt": "hello world",
        },
    ),
    (
        "xpointer-element",
        {
            "main.xml": """<root xmlns:xi="http://www.w3.org/2001/XInclude">
              <xi:include href="inc.xml" xpointer="element(/1/2)"/>
            </root>""",
            "inc.xml": "<doc><part id='p1'><a/><b/></part><part id='p2'><c/></part></doc>",
        },
    ),
    (
        "xpointer-xpath",
        {
            "main.xml": """<root xmlns:xi="http://www.w3.org/2001/XInclude">
              <xi:include href="inc.xml" xpointer="xpointer(/doc/part[1])"/>
            </root>""",
            "inc.xml": "<doc><part id='p1'><a/><b/></part><part id='p2'><c/></part></doc>",
        },
    ),
    (
        "namespaced-include",
        {
            "main.xml": """<root xmlns:xi="http://www.w3.org/2001/XInclude">
              <xi:include href="inc.xml"/>
            </root>""",
            "inc.xml": """<doc xmlns:p="urn:p"><p:x p:a="1"/><p:y/></doc>""",
        },
    ),
    (
        "multiple-includes",
        {
            "main.xml": """<root xmlns:xi="http://www.w3.org/2001/XInclude">
              <xi:include href="a.xml"/><xi:include href="b.xml"/>
            </root>""",
            "a.xml": "<a><x/></a>",
            "b.xml": "<b><y/></b>",
        },
    ),
    (
        "xpointer-element-id",
        {
            "main.xml": """<root xmlns:xi="http://www.w3.org/2001/XInclude">
              <xi:include href="ids.xml" xpointer="element(p2)"/>
            </root>""",
            "ids.xml": "<doc><part xml:id='p1'><a/></part><part xml:id='p2'><b/></part></doc>",
        },
    ),
    (
        "xpointer-id-shorthand",
        {
            "main.xml": """<root xmlns:xi="http://www.w3.org/2001/XInclude">
              <xi:include href="ids.xml" xpointer="p1"/>
            </root>""",
            "ids.xml": "<doc><part xml:id='p1'><a/></part><part xml:id='p2'><b/></part></doc>",
        },
    ),
]


CATALOG_CASES = [
    (
        "catalog-system",
        {
            "catalog.xml": """<catalog xmlns="urn:oasis:names:tc:entity:xmlns:xml:catalog">
              <system systemId="http://example.org/inc.xml" uri="inc.xml"/>
            </catalog>""",
            "inc.xml": "<inc><x/></inc>",
            "main.xml": """<root xmlns:xi="http://www.w3.org/2001/XInclude">
              <xi:include href="http://example.org/inc.xml"/>
            </root>""",
        },
    ),
    (
        "catalog-next",
        {
            "catalog.xml": """<catalog xmlns="urn:oasis:names:tc:entity:xmlns:xml:catalog">
              <nextCatalog catalog="next.xml"/>
            </catalog>""",
            "next.xml": """<catalog xmlns="urn:oasis:names:tc:entity:xmlns:xml:catalog">
              <system systemId="http://example.org/inc.xml" uri="inc.xml"/>
            </catalog>""",
            "inc.xml": "<inc><y/></inc>",
            "main.xml": """<root xmlns:xi="http://www.w3.org/2001/XInclude">
              <xi:include href="http://example.org/inc.xml"/>
            </root>""",
        },
    ),
]

def run(cmd):
    return subprocess.run(cmd, capture_output=True)


def run_env(cmd, env):
    return subprocess.run(cmd, capture_output=True, env=env)


def main():
    if len(sys.argv) < 2:
        print("usage: xinclude_diff.py PATH/TO/xinclude", file=sys.stderr)
        return 2
    processor = sys.argv[1]
    checks = 0
    failures = 0
    for name, files in CASES:
        with tempfile.TemporaryDirectory() as directory:
            for filename, content in files.items():
                path = os.path.join(directory, filename)
                with open(path, "w", encoding="utf-8") as handle:
                    handle.write(content)
            main_path = os.path.join(directory, "main.xml")
            expected = run(["xmllint", "--xinclude", main_path])
            if expected.returncode != 0:
                print(
                    f"SKIP {name}: xmllint failed: "
                    f"{expected.stderr.decode('utf-8', 'replace').strip()}"
                )
                continue
            actual = run([processor, main_path])
            checks += 1
            if actual.returncode != 0:
                failures += 1
                print(
                    f"FAIL {name}: xmlz failed: "
                    f"{actual.stderr.decode('utf-8', 'replace').strip()}"
                )
                continue
            try:
                expected_tree = etree.fromstring(expected.stdout)
            except etree.XMLSyntaxError as error:
                print(f"SKIP {name}: xmllint output is not XML: {error}")
                checks -= 1
                continue
            try:
                actual_tree = etree.fromstring(actual.stdout)
            except etree.XMLSyntaxError as error:
                failures += 1
                print(
                    f"FAIL {name}: xmlz output is not XML: {error}\n"
                    f"  xmlz: {actual.stdout!r}"
                )
                continue
            expected_c14n = etree.tostring(expected_tree, method="c14n")
            actual_c14n = etree.tostring(actual_tree, method="c14n")
            if expected_c14n != actual_c14n:
                failures += 1
                print(
                    f"FAIL {name}\n"
                    f"  libxml2: {expected_c14n!r}\n"
                    f"  xmlz:    {actual_c14n!r}"
                )
    for name, files in CATALOG_CASES:
        with tempfile.TemporaryDirectory() as directory:
            for filename, content in files.items():
                path = os.path.join(directory, filename)
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "w", encoding="utf-8") as handle:
                    handle.write(content)
            main_path = os.path.join(directory, "main.xml")
            catalog_path = os.path.join(directory, "catalog.xml")
            env = os.environ.copy()
            env["XML_CATALOG_FILES"] = catalog_path
            expected = run_env(
                ["xmllint", "--nonet", "--xinclude", main_path],
                env,
            )
            if expected.returncode != 0:
                print(
                    f"SKIP {name}: xmllint failed: "
                    f"{expected.stderr.decode('utf-8', 'replace').strip()}"
                )
                continue
            actual = run([processor, f"--catalog={catalog_path}", main_path])
            checks += 1
            if actual.returncode != 0:
                failures += 1
                print(
                    f"FAIL {name}: xmlz failed: "
                    f"{actual.stderr.decode('utf-8', 'replace').strip()}"
                )
                continue
            try:
                expected_tree = etree.fromstring(expected.stdout)
                actual_tree = etree.fromstring(actual.stdout)
            except etree.XMLSyntaxError as error:
                failures += 1
                print(f"FAIL {name}: output is not XML: {error}")
                continue
            expected_c14n = etree.tostring(expected_tree, method="c14n")
            actual_c14n = etree.tostring(actual_tree, method="c14n")
            if expected_c14n != actual_c14n:
                failures += 1
                print(
                    f"FAIL {name}\n"
                    f"  libxml2: {expected_c14n!r}\n"
                    f"  xmlz:    {actual_c14n!r}"
                )
    print(f"{checks - failures}/{checks} XInclude differential checks passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
