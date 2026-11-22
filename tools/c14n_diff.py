#!/usr/bin/env python3
"""Differential canonicalization checks: xmlz vs libxml2's xmllint."""

import os
import subprocess
import sys
import tempfile

try:
    from lxml import etree
except ImportError:  # pragma: no cover
    etree = None

DOCUMENTS = [
    '<a z="1" a="2"><b/></a>',
    '<a xmlns="urn:d" xmlns:p="urn:p" xmlns:q="urn:q">'
    '<p:b q:x="1" y="2"><c/></p:b></a>',
    '<a xmlns="urn:a" xmlns:p="urn:one"><b xmlns="" xmlns:p="urn:two">'
    '<p:c/></b><d/></a>',
    '<?p1 a?><!--c1--><root><!--in--><?in x?><b/></root><!--c2--><?p3 d?>',
    '<!DOCTYPE a [<!ENTITY e "E&amp;N">]><a><![CDATA[x<y&z]]>&e;&#13;</a>',
    '<!DOCTYPE a [<!ATTLIST a x CDATA "d" y CDATA #IMPLIED>]><a y="v"/>',
    '<a xml:lang="en" xml:space="preserve" xml:base="http://e/x/" '
    'xml:id="i"><b/></a>',
    '<a b="x&#9;y&#10;z&#13;w&gt;&quot;&amp;&lt;">t&gt;&amp;&lt;&#13;</a>',
    '<a xmlns:p="urn:x" xmlns:q="urn:x" xmlns="urn:x"><p:b q:c="1"/></a>',
    '<root xmlns="urn:root" xmlns:a="urn:a" xmlns:b="urn:b">'
    '<a:child xmlns:c="urn:c"><b:leaf c:attr="v"/></a:child></root>',
    '<a title="h\u00e9llo \U0001f600">h\u00e9llo \U0001f600</a>',
    '<a xmlns="urn:a"/>',
    '<a xmlns="urn:a"><b xmlns=""><c xmlns="urn:c"><d/></c></b></a>',
    '<a xmlns=""/>',
    '<a xmlns="" xmlns:p="urn:p"><p:b/></a>',
    '<a xmlns:z="urn:a" xmlns:a="urn:z" z:x="1" a:y="2"/>',
    '<a xmlns:q="urn:q" xmlns:p="urn:p" xmlns="urn:d"><p:b q:c="1"/></a>',
    '<a xmlns="urn:a"><b xmlns="" xmlns:p="urn:p"><p:c/></b></a>',
    '<a>x<![CDATA[y]]>z</a>',
    '<?pi?><a><?pi a>b?></a><?pi2 data?>',
    '<a xmlns:p="urn:one"><b xmlns:p="urn:two"><p:c/></b><p:d/></a>',
    '<a xmlns:p="urn:x"><b xmlns:p="urn:x"><p:c/></b></a>',
    '<a xmlns:p="urn:x"><b xmlns:p="urn:y"><c xmlns:p="urn:x"><p:d/></c></b></a>',
]

MODES = [
    ("c14n 1.0", ["--c14n"], ["--comments"]),
    ("c14n 1.1", ["--c14n11"], ["--comments", "--c14n11"]),
    ("exclusive c14n", ["--exc-c14n"], ["--comments", "--exclusive"]),
]


SUBSET_CASES = [
    (
        "namespaced-subtree",
        "<root xmlns:a='urn:a'><a:child a:x='1'><a:leaf/></a:child></root>",
        "/*/*",
        False,
    ),
    (
        "namespaced-subtree-exclusive",
        "<root xmlns:a='urn:a'><a:child a:x='1'><a:leaf/></a:child></root>",
        "/*/*",
        True,
    ),
    (
        "default-namespace-reset",
        "<root xmlns='urn:a'><child xmlns=''><leaf/></child></root>",
        "/*/*",
        False,
    ),
    (
        "inherited-default-namespace",
        "<root xmlns='urn:a'><child><leaf>t</leaf></child></root>",
        "/*/*",
        False,
    ),
    (
        "attribute-namespaces",
        "<root xmlns:a='urn:a' xmlns:b='urn:b'><a:child b:x='1'/></root>",
        "/*/*",
        False,
    ),
    (
        "attribute-namespaces-exclusive",
        "<root xmlns:a='urn:a' xmlns:b='urn:b'><a:child b:x='1'/></root>",
        "/*/*",
        True,
    ),
    (
        "nested-default-namespaces",
        "<root xmlns='urn:a'><child xmlns='urn:b'><leaf xmlns=''/></child></root>",
        "/*/*",
        False,
    ),
    (
        "leaf-namespace-propagation",
        "<root xmlns:a='urn:a'><a:child><a:leaf a:v='1'/></a:child></root>",
        "/*/*/*",
        False,
    ),
    (
        "mixed-attributes",
        "<root xmlns:p='urn:p' xmlns:q='urn:q'>"
        "<child q:b='2' p:a='1' c='3'/></root>",
        "/*/*",
        False,
    ),
    (
        "text-escaping",
        "<root><child>a&amp;b&lt;c&gt;d</child></root>",
        "/*/*",
        False,
    ),
]

def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def run_bytes(cmd):
    return subprocess.run(cmd, capture_output=True)


def main():
    if len(sys.argv) < 2:
        print("usage: c14n_diff.py PATH/TO/c14n", file=sys.stderr)
        return 2
    canonicalizer = sys.argv[1]
    failures = 0
    checks = 0
    for index, document in enumerate(DOCUMENTS):
        with tempfile.NamedTemporaryFile(
            "w", suffix=".xml", delete=False, encoding="utf-8"
        ) as handle:
            handle.write(document)
            path = handle.name
        try:
            for label, xmllint_args, xmlz_args in MODES:
                expected = run(["xmllint", *xmllint_args, path])
                if expected.returncode != 0:
                    print(
                        f"SKIP document {index} {label}: "
                        f"xmllint failed: {expected.stderr.strip()}"
                    )
                    continue
                actual = run([canonicalizer, path, *xmlz_args])
                checks += 1
                if actual.returncode != 0:
                    failures += 1
                    print(
                        f"FAIL document {index} {label}: "
                        f"xmlz failed: {actual.stderr.strip()}"
                    )
                    continue
                if expected.stdout != actual.stdout:
                    failures += 1
                    print(
                        f"FAIL document {index} {label}\n"
                        f"  input:   {document!r}\n"
                        f"  xmllint: {expected.stdout!r}\n"
                        f"  xmlz:    {actual.stdout!r}"
                    )
        finally:
            os.unlink(path)
    for name, document, xpath, exclusive in SUBSET_CASES:
        if etree is None:
            print(f"SKIP subset {name}: lxml is not installed")
            continue
        with tempfile.NamedTemporaryFile(
            "w", suffix=".xml", delete=False, encoding="utf-8"
        ) as handle:
            handle.write(document)
            path = handle.name
        try:
            tree = etree.fromstring(document.encode())
            elements = tree.xpath(xpath)
            if not elements:
                print(f"SKIP subset {name}: xpath selected nothing")
                continue
            expected = etree.tostring(
                elements[0],
                method="c14n",
                exclusive=exclusive,
                with_comments=False,
            )
            expression = (
                f"{xpath}/descendant-or-self::node() | "
                f"{xpath}/descendant-or-self::node()/@*"
            )
            args = [canonicalizer, path, f"--select={expression}"]
            if exclusive:
                args.append("--exclusive")
            actual = run_bytes(args)
            checks += 1
            if actual.returncode != 0:
                failures += 1
                print(
                    f"FAIL subset {name}: xmlz failed: "
                    f"{actual.stderr.decode('utf-8', 'replace').strip()}"
                )
                continue
            if actual.stdout != expected:
                failures += 1
                print(
                    f"FAIL subset {name}\n"
                    f"  libxml2: {expected!r}\n"
                    f"  xmlz:    {actual.stdout!r}"
                )
        finally:
            os.unlink(path)
    print(f"{checks - failures}/{checks} canonicalization differential checks passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
