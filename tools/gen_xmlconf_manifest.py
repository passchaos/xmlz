#!/usr/bin/env python3
"""Generate a flat manifest of the W3C XML conformance suite.

The official catalogs are XML documents that pull sibling catalogs in through
SYSTEM entity references. This script walks those references, tracks xml:base
and catalog profiles, and emits one JSON object per TEST element. The Zig
harness consumes the manifest at runtime so the conformance suite does not need
an XML parser to bootstrap itself.
"""

import argparse
import json
import os
import re
import sys

ENTITY_RE = re.compile(
    r'<!ENTITY\s+([A-Za-z_][\w.-]*)\s+SYSTEM\s+(["\'])(.*?)\2\s*>', re.S)
TEST_RE = re.compile(r'<TEST\b([^>]*)>(.*?)</TEST>', re.S)
TESTCASES_RE = re.compile(r'<TESTCASES\b([^>]*)>(.*?)</TESTCASES>', re.S)
ATTR_RE = re.compile(r'([\w:.-]+)\s*=\s*(["\'])(.*?)\2', re.S)
REF_RE = re.compile(r'&([A-Za-z_][\w.-]*);')


def parse_attrs(text):
    return {m.group(1): m.group(3) for m in ATTR_RE.finditer(text)}


def strip_comments(text):
    return re.sub(r'<!--.*?-->', '', text, flags=re.S)


def join_base(*parts):
    result = ''
    for part in parts:
        if not part:
            continue
        result = os.path.normpath(os.path.join(result, part))
    return result


def scan_tests(text, base, namespace, xml11, out):
    for match in TEST_RE.finditer(text):
        attrs = parse_attrs(match.group(1))
        uri = attrs.get('URI')
        if not uri:
            continue
        out.append({
            'uri': join_base(base, uri),
            'id': attrs.get('ID', ''),
            'type': attrs.get('TYPE', ''),
            'entities': attrs.get('ENTITIES', ''),
            'sections': attrs.get('SECTIONS', ''),
            'namespace': namespace,
            'xml11': xml11,
            'recommendation': attrs.get('RECOMMENDATION', ''),
            'edition': attrs.get('EDITION', ''),
            'version': attrs.get('VERSION', ''),
        })


def process_catalog(path, inherited_base, namespace, xml11, out, depth=0, suite_root=None):
    if depth > 8:
        return
    try:
        with open(path, 'r', encoding='utf-8', errors='replace') as handle:
            text = strip_comments(handle.read())
    except OSError:
        return
    if suite_root:
        relative = os.path.relpath(path, suite_root)
        inherited_base = os.path.dirname(relative)
        if 'namespaces' in relative.replace(os.sep, '/'):
            namespace = True
    entity_files = {
        m.group(1): os.path.normpath(os.path.join(os.path.dirname(path), m.group(3)))
        for m in ENTITY_RE.finditer(text)
    }

    pos = 0
    for match in TESTCASES_RE.finditer(text):
        scan_tests(text[pos:match.start()], inherited_base, namespace, xml11, out)
        attrs = parse_attrs(match.group(1))
        profile = attrs.get('PROFILE', '')
        base = join_base(inherited_base, attrs.get('xml:base', ''))
        block = match.group(2)
        block_namespace = namespace or 'namespace' in profile.lower()
        block_xml11 = xml11 or '1.1' in profile
        for name in set(REF_RE.findall(block)):
            target = entity_files.get(name)
            if target:
                process_catalog(
                    target,
                    base,
                    block_namespace,
                    block_xml11,
                    out,
                    depth + 1,
                    suite_root,
                )
        scan_tests(block, base, block_namespace, block_xml11, out)
        pos = match.end()
    scan_tests(text[pos:], inherited_base, namespace, xml11, out)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('suite', help='path to the xmlconf directory')
    parser.add_argument('output', help='path to write manifest JSON')
    args = parser.parse_args()
    suite = os.path.abspath(args.suite)

    entries = []
    process_catalog(
        os.path.join(suite, 'xmlconf.xml'), '', False, False, entries, 0, suite
    )

    seen = set()
    unique = []
    for entry in entries:
        key = (entry['uri'], entry['id'], entry['type'])
        if key in seen:
            continue
        seen.add(key)
        unique.append(entry)

    unique.sort(key=lambda e: (e['uri'], e['id']))
    with open(args.output, 'w', encoding='utf-8') as handle:
        json.dump(unique, handle, indent=1)
        handle.write('\n')
    counts = {}
    for entry in unique:
        counts[entry['type']] = counts.get(entry['type'], 0) + 1
    print(f"{len(unique)} tests: {counts}", file=sys.stderr)


if __name__ == '__main__':
    main()
