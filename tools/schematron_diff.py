#!/usr/bin/env python3
"""Differential ISO Schematron checks: xmlz vs the ISO skeleton through lxml."""

import os
import subprocess
import sys
import tempfile

try:
    from lxml import etree
    from lxml.isoschematron import Schematron
except ImportError:  # pragma: no cover
    print("SKIP: lxml is not installed", file=sys.stderr)
    sys.exit(0)

SCH = "http://purl.oclc.org/dsdl/schematron"

CASES = [
    (
        "assert-report",
        f"""<schema xmlns="{SCH}">
          <pattern id="p">
            <rule context="item">
              <assert test="@id">item needs id</assert>
              <report test="@id='bad'">bad id</report>
            </rule>
          </pattern>
        </schema>""",
        [
            "<root><item id='a'/></root>",
            "<root><item/></root>",
            "<root><item id='bad'/></root>",
        ],
        None,
    ),
    (
        "context-predicates",
        f"""<schema xmlns="{SCH}">
          <pattern id="p">
            <rule context="item[@kind='a'] | other">
              <assert test="@id">id required</assert>
            </rule>
          </pattern>
        </schema>""",
        [
            "<root><item kind='a' id='1'/><item kind='b'/><other id='2'/></root>",
            "<root><item kind='a'/><item kind='b'/></root>",
            "<root><other/></root>",
        ],
        None,
    ),
    (
        "namespaces",
        f"""<schema xmlns="{SCH}">
          <ns prefix="q" uri="urn:q"/>
          <pattern id="p">
            <rule context="q:item">
              <assert test="@id">id required</assert>
            </rule>
          </pattern>
        </schema>""",
        [
            "<root xmlns:q='urn:q'><q:item id='1'/></root>",
            "<root xmlns:q='urn:q'><q:item/></root>",
            "<root><item/></root>",
        ],
        None,
    ),
    (
        "lets",
        f"""<schema xmlns="{SCH}">
          <let name="limit" value="2"/>
          <pattern id="p">
            <let name="label" value="'items'"/>
            <rule context="item">
              <let name="expected" value="count(../item)"/>
              <assert test="count(../item) &lt;= $limit">
                too many <value-of select="$label"/>: <value-of select="$expected"/>
              </assert>
            </rule>
          </pattern>
        </schema>""",
        [
            "<root><item/><item/></root>",
            "<root><item/><item/><item/></root>",
        ],
        None,
    ),
    (
        "phases",
        f"""<schema xmlns="{SCH}" defaultPhase="p2">
          <phase id="p1"><active pattern="a"/></phase>
          <phase id="p2"><active pattern="b"/></phase>
          <pattern id="a"><rule context="item"><assert test="@a">needs a</assert></rule></pattern>
          <pattern id="b"><rule context="item"><assert test="@b">needs b</assert></rule></pattern>
        </schema>""",
        [
            "<root><item a='1'/></root>",
            "<root><item b='1'/></root>",
        ],
        None,
    ),
    (
        "phase-override",
        f"""<schema xmlns="{SCH}" defaultPhase="p2">
          <phase id="p1"><active pattern="a"/></phase>
          <phase id="p2"><active pattern="b"/></phase>
          <pattern id="a"><rule context="item"><assert test="@a">needs a</assert></rule></pattern>
          <pattern id="b"><rule context="item"><assert test="@b">needs b</assert></rule></pattern>
        </schema>""",
        [
            "<root><item a='1'/></root>",
            "<root><item b='1'/></root>",
        ],
        "p1",
    ),
    (
        "message-parts",
        f"""<schema xmlns="{SCH}">
          <pattern id="p">
            <rule context="item">
              <assert test="@id">
                <name/> needs <value-of select="name(..)"/> id <value-of select="@id"/>
              </assert>
            </rule>
          </pattern>
        </schema>""",
        [
            "<root><item id='1'/></root>",
            "<root><item/></root>",
        ],
        None,
    ),
    (
        "multiple-patterns",
        f"""<schema xmlns="{SCH}">
          <pattern id="a">
            <rule context="item"><assert test="@id">id</assert></rule>
          </pattern>
          <pattern id="b">
            <rule context="root"><assert test="item">needs item</assert></rule>
          </pattern>
        </schema>""",
        [
            "<root><item id='1'/></root>",
            "<root/>",
            "<root><item/></root>",
        ],
        None,
    ),
    (
        "xpath-functions",
        f"""<schema xmlns="{SCH}">
          <pattern id="p">
            <rule context="item">
              <assert test="starts-with(@id, 'x') and string-length(@id) = 3">
                id must look like xNN
              </assert>
            </rule>
          </pattern>
        </schema>""",
        [
            "<root><item id='x12'/></root>",
            "<root><item id='y12'/></root>",
            "<root><item id='x1'/></root>",
        ],
        None,
    ),
    (
        "attribute-context",
        f"""<schema xmlns="{SCH}">
          <pattern id="p">
            <rule context="@id">
              <assert test="starts-with(., 'x')">id must start with x</assert>
            </rule>
          </pattern>
        </schema>""",
        [
            "<root><item id='x1'/></root>",
            "<root><item id='y1'/></root>",
        ],
        None,
    ),
]


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def main():
    if len(sys.argv) < 2:
        print("usage: schematron_diff.py PATH/TO/schematron", file=sys.stderr)
        return 2
    validator = sys.argv[1]
    checks = 0
    failures = 0
    for name, schema_source, instances, phase in CASES:
        try:
            schematron = Schematron(
                etree.fromstring(schema_source.encode()),
                phase=phase,
            )
        except Exception as error:  # noqa: BLE001 - report lxml failures
            print(f"SKIP {name}: libxml2 schema error: {error}")
            continue
        with tempfile.TemporaryDirectory() as directory:
            schema_path = os.path.join(directory, "schema.sch")
            with open(schema_path, "w", encoding="utf-8") as handle:
                handle.write(schema_source)
            for index, instance in enumerate(instances):
                instance_path = os.path.join(directory, f"instance-{index}.xml")
                with open(instance_path, "w", encoding="utf-8") as handle:
                    handle.write(instance)
                command = [validator, schema_path, instance_path]
                if phase is not None:
                    command.append(f"--phase={phase}")
                actual = run(command)
                if actual.returncode == 2:
                    failures += 1
                    print(
                        f"FAIL {name} instance {index}: xmlz schema error: "
                        f"{actual.stderr.strip()}"
                    )
                    continue
                expected_valid = schematron.validate(
                    etree.fromstring(instance.encode())
                )
                actual_valid = actual.returncode == 0
                checks += 1
                if expected_valid != actual_valid:
                    failures += 1
                    print(
                        f"FAIL {name} instance {index}: "
                        f"libxml2={'valid' if expected_valid else 'invalid'} "
                        f"xmlz={'valid' if actual_valid else 'invalid'}\n"
                        f"  instance: {instance}\n"
                        f"  lxml: {[e.message for e in schematron.error_log]}\n"
                        f"  xmlz: {actual.stderr.strip()}"
                    )
    print(f"{checks - failures}/{checks} Schematron differential checks passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
