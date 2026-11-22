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
SVRL = "http://purl.oclc.org/dsdl/svrl"


def normalize(text):
    return " ".join(text.split())


def expected_findings(report):
    """Extract (kind, message, diagnostics) from an SVRL report."""
    findings = []
    if report is None:
        return findings
    for element in report.iter():
        if not isinstance(element.tag, str):
            continue
        local = etree.QName(element).localname
        if local not in ("failed-assert", "successful-report"):
            continue
        text_element = element.find(f"{{{SVRL}}}text")
        message = "".join(text_element.itertext()) if text_element is not None else ""
        diagnostics = []
        for reference in element.findall(f"{{{SVRL}}}diagnostic-reference"):
            diagnostics.append((
                reference.get("diagnostic"),
                normalize("".join(reference.itertext())),
            ))
        findings.append((local, normalize(message), diagnostics))
    return findings


def actual_findings(output):
    """Parse the tool's --report lines."""
    findings = []
    current = None
    for line in output.splitlines():
        parts = line.split("\t")
        if parts[0] in ("failed-assert", "successful-report") and len(parts) >= 3:
            current = (
                parts[0],
                normalize("\t".join(parts[2:])),
                [],
            )
            findings.append(current)
        elif parts[0] == "diagnostic" and len(parts) >= 3 and current is not None:
            current[2].append((parts[1], normalize("\t".join(parts[2:]))))
    return findings

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
    (
        "abstract-rule-extends",
        f"""<schema xmlns="{SCH}">
          <pattern id="p">
            <rule abstract="true" id="base">
              <assert test="@id">id required</assert>
            </rule>
            <rule context="item">
              <extends rule="base"/>
              <assert test="@kind">kind required</assert>
            </rule>
          </pattern>
        </schema>""",
        [
            "<root><item id='1' kind='a'/></root>",
            "<root><item kind='a'/></root>",
            "<root><item id='1'/></root>",
        ],
        None,
    ),
    (
        "diagnostics",
        f"""<schema xmlns="{SCH}">
          <pattern id="p">
            <rule context="item">
              <assert test="@id" diagnostics="d1 d2">item needs id</assert>
            </rule>
          </pattern>
          <diagnostics>
            <diagnostic id="d1">missing id</diagnostic>
            <diagnostic id="d2">kind is <value-of select="@kind"/></diagnostic>
          </diagnostics>
        </schema>""",
        [
            "<root><item id='1' kind='k'/></root>",
            "<root><item kind='k'/></root>",
            "<root><item/></root>",
        ],
        None,
    ),
    (
        "diagnostics-report",
        f"""<schema xmlns="{SCH}">
          <pattern id="p">
            <rule context="item">
              <report test="@id='bad'" diagnostics="d3">bad id</report>
            </rule>
          </pattern>
          <diagnostics>
            <diagnostic id="d3">value is <value-of select="@id"/></diagnostic>
          </diagnostics>
        </schema>""",
        [
            "<root><item id='ok'/></root>",
            "<root><item id='bad'/></root>",
        ],
        None,
    ),
    (
        "properties",
        f"""<schema xmlns="{SCH}">
          <pattern id="p">
            <rule context="item">
              <assert test="@id" properties="p1">item needs id</assert>
            </rule>
          </pattern>
          <properties>
            <property id="p1" scheme="urn:s" role="error">bad <value-of select="name()"/></property>
          </properties>
        </schema>""",
        [
            "<root><item id='1'/></root>",
            "<root><item/></root>",
        ],
        None,
    ),
    (
        "abstract-pattern-params",
        f"""<schema xmlns="{SCH}">
          <ns prefix="h" uri="urn:h"/>
          <pattern abstract="true" id="table">
            <rule context="$row">
              <assert test="@$attr">attribute required</assert>
            </rule>
          </pattern>
          <pattern is-a="table" id="htmlTable">
            <param name="row" value="h:row"/>
            <param name="attr" value="id"/>
          </pattern>
        </schema>""",
        [
            "<root xmlns:h='urn:h'><h:row id='1'/></root>",
            "<root xmlns:h='urn:h'><h:row/></root>",
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
                store_report=True,
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
                command = [validator, "--report", schema_path, instance_path]
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
                    continue
                expected = expected_findings(schematron.validation_report)
                found = actual_findings(actual.stdout + actual.stderr)
                if expected != found:
                    failures += 1
                    print(
                        f"FAIL {name} instance {index}: findings differ\n"
                        f"  instance: {instance}\n"
                        f"  lxml: {expected}\n"
                        f"  xmlz: {found}"
                    )
    print(f"{checks - failures}/{checks} Schematron differential checks passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
