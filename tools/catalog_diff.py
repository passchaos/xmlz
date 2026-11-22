#!/usr/bin/env python3
"""Differential OASIS XML Catalogs checks: xmlz vs libxml2's xmlcatalog."""

import os
import subprocess
import sys
import tempfile

CATALOG_NS = "urn:oasis:names:tc:entity:xmlns:xml:catalog"

CASES = [
    (
        "exact-entries",
        {
            "catalog.xml": f"""<catalog xmlns="{CATALOG_NS}">
              <system systemId="http://example.org/sys.dtd" uri="sys.dtd"/>
              <public publicId="-//P//Q" uri="pub.dtd"/>
              <uri name="http://example.org/u" uri="u.xml"/>
            </catalog>""",
        },
        [
            ("system", "http://example.org/sys.dtd"),
            ("system", "http://example.org/missing.dtd"),
            ("public", "-//P//Q"),
            ("public", "-//X//Y"),
            ("uri", "http://example.org/u"),
        ],
    ),
    (
        "rewrites",
        {
            "catalog.xml": f"""<catalog xmlns="{CATALOG_NS}">
              <rewriteSystem systemIdStartString="http://example.org/dir/"
                rewritePrefix="local/"/>
              <rewriteURI uriStartString="http://example.org/r/"
                rewritePrefix="r/"/>
            </catalog>""",
        },
        [
            ("system", "http://example.org/dir/a/b.dtd"),
            ("system", "http://example.org/other/a.dtd"),
            ("uri", "http://example.org/r/x"),
        ],
    ),
    (
        "prefer-system",
        {
            "catalog.xml": f"""<catalog xmlns="{CATALOG_NS}">
              <public publicId="-//P//Q" uri="pub.dtd"/>
              <system systemId="sys.dtd" uri="sys-local.dtd"/>
            </catalog>""",
        },
        [
            ("resolve", "-//P//Q", "sys.dtd"),
            ("resolve", "-//P//Q", "other.dtd"),
            ("resolve", "-//X//Y", "sys.dtd"),
        ],
    ),
    (
        "next-catalog",
        {
            "catalog.xml": f"""<catalog xmlns="{CATALOG_NS}">
              <nextCatalog catalog="next.xml"/>
            </catalog>""",
            "next.xml": f"""<catalog xmlns="{CATALOG_NS}">
              <system systemId="http://example.org/next.dtd" uri="next.dtd"/>
            </catalog>""",
        },
        [
            ("system", "http://example.org/next.dtd"),
            ("system", "http://example.org/missing.dtd"),
        ],
    ),
    (
        "delegate-system",
        {
            "catalog.xml": f"""<catalog xmlns="{CATALOG_NS}">
              <delegateSystem systemIdStartString="http://example.org/delegated/"
                catalog="sub.xml"/>
            </catalog>""",
            "sub.xml": f"""<catalog xmlns="{CATALOG_NS}">
              <system systemId="http://example.org/delegated/x.dtd"
                uri="delegated.dtd"/>
            </catalog>""",
        },
        [
            ("system", "http://example.org/delegated/x.dtd"),
            ("system", "http://example.org/other/x.dtd"),
        ],
    ),
    (
        "group-prefer",
        {
            "catalog.xml": f"""<catalog xmlns="{CATALOG_NS}">
              <group prefer="public">
                <public publicId="-//P//Q" uri="pub.dtd"/>
              </group>
              <system systemId="sys.dtd" uri="sys-local.dtd"/>
            </catalog>""",
        },
        [
            ("resolve", "-//P//Q", "sys.dtd"),
        ],
    ),
    (
        "xml-base",
        {
            "catalog.xml": f"""<catalog xmlns="{CATALOG_NS}" xml:base="sub/">
              <system systemId="http://example.org/a.dtd" uri="a.dtd"/>
            </catalog>""",
        },
        [
            ("system", "http://example.org/a.dtd"),
        ],
    ),
]


def run(cmd, stdin=None):
    return subprocess.run(cmd, capture_output=True, text=True, input=stdin)


def query_xmlcatalog(path, kind, args):
    if kind == "uri":
        result = run(["xmlcatalog", path, args[0]])
        if result.returncode != 0:
            return None
        lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
        for line in reversed(lines):
            if line.startswith("No entry"):
                return None
            return line
        return None
    command = f'{kind} "{args[0]}"\n'
    if kind == "resolve":
        command = f'resolve "{args[0]}" "{args[1]}"\n'
    result = run(["xmlcatalog", "--shell", path], stdin=command)
    for line in result.stdout.splitlines():
        line = line.strip()
        if not line.startswith(">"):
            continue
        value = line[1:].strip()
        if not value or value.startswith("No entry"):
            return None
        return value
    return None


def main():
    if len(sys.argv) < 2:
        print("usage: catalog_diff.py PATH/TO/catalog", file=sys.stderr)
        return 2
    resolver = sys.argv[1]
    checks = 0
    failures = 0
    for name, files, queries in CASES:
        with tempfile.TemporaryDirectory() as directory:
            for filename, content in files.items():
                path = os.path.join(directory, filename)
                with open(path, "w", encoding="utf-8") as handle:
                    handle.write(content)
            catalog_path = os.path.join(directory, "catalog.xml")
            for query in queries:
                kind = query[0]
                args = query[1:]
                expected = query_xmlcatalog(catalog_path, kind, args)
                command = [resolver, catalog_path, kind, *args]
                actual = run(command)
                if actual.returncode not in (0, 4):
                    failures += 1
                    print(
                        f"FAIL {name} {query}: xmlz failed: "
                        f"{actual.stderr.strip()}"
                    )
                    continue
                actual_value = (
                    actual.stdout.strip() if actual.returncode == 0 else None
                )
                checks += 1
                if expected != actual_value:
                    failures += 1
                    print(
                        f"FAIL {name} {query}\n"
                        f"  xmlcatalog: {expected!r}\n"
                        f"  xmlz:       {actual_value!r}"
                    )
    print(f"{checks - failures}/{checks} catalog differential checks passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
