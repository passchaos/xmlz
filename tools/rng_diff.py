#!/usr/bin/env python3
"""Differential RELAX NG checks: xmlz vs libxml2 (through lxml)."""

import os
import subprocess
import sys
import tempfile

try:
    from lxml import etree
except ImportError:  # pragma: no cover
    print("SKIP: lxml is not installed", file=sys.stderr)
    sys.exit(0)

RNG = "http://relaxng.org/ns/structure/1.0"

CASES = [
    (
        "element-sequence",
        f"""<element xmlns="{RNG}" name="root">
          <group>
            <element name="a"><empty/></element>
            <element name="b"><empty/></element>
          </group>
        </element>""",
        [
            "<root><a/><b/></root>",
            "<root>\n  <a/>\n  <b/>\n</root>",
            "<root><a/></root>",
            "<root><a/><c/></root>",
            "<root><b/><a/></root>",
        ],
    ),
    (
        "attributes-any-order",
        f"""<element xmlns="{RNG}" name="root">
          <group>
            <attribute name="a"><text/></attribute>
            <attribute name="b"><text/></attribute>
          </group>
        </element>""",
        [
            "<root a='1' b='2'/>",
            "<root b='2' a='1'/>",
            "<root a='1'/>",
            "<root a='1' b='2' c='3'/>",
        ],
    ),
    (
        "choice-repetition",
        f"""<element xmlns="{RNG}" name="root">
          <group>
            <oneOrMore>
              <choice>
                <element name="a"><text/></element>
                <element name="b"><empty/></element>
              </choice>
            </oneOrMore>
            <optional>
              <attribute name="id"><text/></attribute>
            </optional>
          </group>
        </element>""",
        [
            "<root><a>x</a><b/><a>y</a></root>",
            "<root id='1'><b/></root>",
            "<root/>",
            "<root><c/></root>",
            "<root><a>x</a><c/></root>",
        ],
    ),
    (
        "data-value-list",
        f"""<element xmlns="{RNG}" datatypeLibrary="http://www.w3.org/2001/XMLSchema-datatypes" name="root">
          <group>
            <element name="n"><data type="integer"/></element>
            <group>
              <element name="tag"><value>fixed</value></element>
              <element name="ids">
                <list><oneOrMore><data type="integer"/></oneOrMore></list>
              </element>
            </group>
          </group>
        </element>""",
        [
            "<root><n>42</n><tag>fixed</tag><ids>1 2 3</ids></root>",
            "<root><n>x</n><tag>fixed</tag><ids>1 2</ids></root>",
            "<root><n>1</n><tag>other</tag><ids>1</ids></root>",
            "<root><n>1</n><tag>fixed</tag><ids>1 x</ids></root>",
            "<root><n>1</n><tag>fixed</tag><ids></ids></root>",
        ],
    ),
    (
        "interleave",
        f"""<element xmlns="{RNG}" name="root">
          <interleave>
            <oneOrMore><element name="a"><empty/></element></oneOrMore>
            <oneOrMore><element name="b"><empty/></element></oneOrMore>
          </interleave>
        </element>""",
        [
            "<root><a/><b/><a/><b/></root>",
            "<root><b/><b/><a/></root>",
            "<root><a/><a/></root>",
            "<root><a/><b/><a/></root>",
        ],
    ),
    (
        "mixed-content",
        f"""<element xmlns="{RNG}" name="p">
          <mixed>
            <zeroOrMore>
              <element>
                <choice>
                  <name>b</name>
                  <name>i</name>
                </choice>
                <text/>
              </element>
            </zeroOrMore>
          </mixed>
        </element>""",
        [
            "<p>hello <b>bold</b> and <i>it</i></p>",
            "<p/>",
            "<p><u>x</u></p>",
        ],
    ),
    (
        "any-name-except",
        f"""<element xmlns="{RNG}" name="root">
          <zeroOrMore>
            <element>
              <anyName>
                <except><name>skip</name></except>
              </anyName>
              <empty/>
            </element>
          </zeroOrMore>
        </element>""",
        [
            "<root><a/><ns:b xmlns:ns='urn:x'/></root>",
            "<root><skip/></root>",
            "<root/>",
        ],
    ),
    (
        "namespaced-name",
        f"""<element xmlns="{RNG}" xmlns:p="urn:x" name="root">
          <element name="p:item"><text/></element>
        </element>""",
        [
            "<root><item xmlns='urn:x'>x</item></root>",
            "<root><item>x</item></root>",
            "<root><item xmlns='urn:y'>x</item></root>",
        ],
    ),
    (
        "text-pattern",
        f"""<element xmlns="{RNG}" name="e"><text/></element>""",
        [
            "<e/>",
            "<e>hello</e>",
            "<e><child/></e>",
        ],
    ),
    (
        "data-facets",
        f"""<element xmlns="{RNG}" datatypeLibrary="http://www.w3.org/2001/XMLSchema-datatypes" name="root">
          <data type="integer">
            <param name="minInclusive">10</param>
          </data>
        </element>""",
        [
            "<root>10</root>",
            "<root>11</root>",
            "<root>5</root>",
            "<root>x</root>",
        ],
    ),
    (
        "choice-attribute-element",
        f"""<element xmlns="{RNG}" name="root">
          <choice>
            <attribute name="a"><text/></attribute>
            <element name="x"><empty/></element>
          </choice>
        </element>""",
        [
            "<root a='1'/>",
            "<root><x/></root>",
            "<root a='1'><x/></root>",
            "<root/>",
        ],
    ),
    (
        "interleave-attribute-elements",
        f"""<element xmlns="{RNG}" name="root">
          <interleave>
            <attribute name="a"><text/></attribute>
            <group>
              <element name="x"><empty/></element>
              <element name="y"><empty/></element>
            </group>
          </interleave>
        </element>""",
        [
            "<root a='1'><x/><y/></root>",
            "<root><x/><y/></root>",
            "<root a='1'><y/><x/></root>",
        ],
    ),
    (
        "value-integer-lexical",
        f"""<element xmlns="{RNG}"
          datatypeLibrary="http://www.w3.org/2001/XMLSchema-datatypes"
          name="root">
          <value type="integer">1</value>
        </element>""",
        [
            "<root>1</root>",
            "<root>01</root>",
            "<root> 1 </root>",
            "<root>2</root>",
        ],
    ),
    (
        "parent-ref",
        f"""<grammar xmlns="{RNG}">
          <start><ref name="chain"/></start>
          <define name="chain">
            <grammar>
              <start>
                <element name="a">
                  <optional><parentRef name="chain"/></optional>
                </element>
              </start>
            </grammar>
          </define>
        </grammar>""",
        [
            "<a/>",
            "<a><a/></a>",
            "<a><a><a/></a></a>",
            "<b/>",
            "<a><b/></a>",
        ],
    ),
    (
        "data-except",
        f"""<element xmlns="{RNG}"
          datatypeLibrary="http://www.w3.org/2001/XMLSchema-datatypes"
          name="root">
          <data type="integer">
            <except><value>0</value></except>
          </data>
        </element>""",
        [
            "<root>5</root>",
            "<root>0</root>",
            "<root>x</root>",
        ],
    ),
]

BUNDLES = [
    (
        "include-grammar",
        {
            "main.rng": f"""<grammar xmlns="{RNG}">
              <include href="base.rng"/>
              <start combine="choice">
                <element name="root">
                  <oneOrMore><ref name="item"/></oneOrMore>
                </element>
              </start>
            </grammar>""",
            "base.rng": f"""<grammar xmlns="{RNG}">
              <start combine="choice"><element name="unused"><empty/></element></start>
              <define name="item">
                <element name="item"><text/></element>
              </define>
            </grammar>""",
        },
        [
            "<root><item>a</item><item>b</item></root>",
            "<root/>",
            "<root><other/></root>",
        ],
    ),
    (
        "include-override-define",
        {
            "main.rng": f"""<grammar xmlns="{RNG}">
              <include href="base.rng">
                <define name="item">
                  <element name="b"><text/></element>
                </define>
              </include>
              <start combine="choice">
                <element name="root"><ref name="item"/></element>
              </start>
            </grammar>""",
            "base.rng": f"""<grammar xmlns="{RNG}">
              <define name="item">
                <element name="a"><text/></element>
              </define>
            </grammar>""",
        },
        [
            "<root><b>x</b></root>",
            "<root><a>x</a></root>",
        ],
    ),
    (
        "external-ref",
        {
            "main.rng": f"""<element xmlns="{RNG}" name="root">
              <externalRef href="item.rng"/>
            </element>""",
            "item.rng": f"""<element xmlns="{RNG}" name="item"><text/></element>""",
        },
        [
            "<root><item>x</item></root>",
            "<root><other>x</other></root>",
        ],
    ),
    (
        "include-start-override",
        {
            "main.rng": f"""<grammar xmlns="{RNG}">
              <include href="base.rng">
                <start>
                  <element name="local"><empty/></element>
                </start>
              </include>
            </grammar>""",
            "base.rng": f"""<grammar xmlns="{RNG}">
              <start><element name="base"><empty/></element></start>
            </grammar>""",
        },
        [
            "<local/>",
            "<base/>",
        ],
    ),
]


def run(cmd):
    return subprocess.run(cmd, capture_output=True)


def main():
    if len(sys.argv) < 2:
        print("usage: rng_diff.py PATH/TO/rng", file=sys.stderr)
        return 2
    validator = sys.argv[1]
    checks = 0
    failures = 0
    for name, schema_source, instances in CASES:
        try:
            relaxng = etree.RelaxNG(etree.fromstring(schema_source.encode()))
        except Exception as error:  # noqa: BLE001 - report libxml2 failures
            print(f"SKIP {name}: libxml2 schema error: {error}")
            continue
        with tempfile.TemporaryDirectory() as directory:
            schema_path = os.path.join(directory, "schema.rng")
            with open(schema_path, "w", encoding="utf-8") as handle:
                handle.write(schema_source)
            for index, instance in enumerate(instances):
                instance_path = os.path.join(directory, f"instance-{index}.xml")
                with open(instance_path, "w", encoding="utf-8") as handle:
                    handle.write(instance)
                actual = run([validator, schema_path, instance_path])
                if actual.returncode == 2:
                    failures += 1
                    print(
                        f"FAIL {name} instance {index}: xmlz schema error: "
                        f"{actual.stderr.decode('utf-8', 'replace').strip()}"
                    )
                    continue
                expected_valid = relaxng.validate(
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
                        f"  lxml: {relaxng.error_log}\n"
                        f"  xmlz: {actual.stderr.decode('utf-8', 'replace').strip()}"
                    )
    for name, files, instances in BUNDLES:
        with tempfile.TemporaryDirectory() as directory:
            for filename, content in files.items():
                path = os.path.join(directory, filename)
                with open(path, "w", encoding="utf-8") as handle:
                    handle.write(content)
            main_path = os.path.join(directory, "main.rng")
            try:
                relaxng = etree.RelaxNG(etree.parse(main_path))
            except Exception as error:  # noqa: BLE001 - report libxml2 failures
                print(f"SKIP {name}: libxml2 schema error: {error}")
                continue
            for index, instance in enumerate(instances):
                instance_path = os.path.join(directory, f"instance-{index}.xml")
                with open(instance_path, "w", encoding="utf-8") as handle:
                    handle.write(instance)
                actual = run([validator, main_path, instance_path])
                if actual.returncode == 2:
                    failures += 1
                    print(
                        f"FAIL {name} instance {index}: xmlz schema error: "
                        f"{actual.stderr.decode('utf-8', 'replace').strip()}"
                    )
                    continue
                expected_valid = relaxng.validate(
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
                        f"  lxml: {relaxng.error_log}\n"
                        f"  xmlz: {actual.stderr.decode('utf-8', 'replace').strip()}"
                    )
    print(f"{checks - failures}/{checks} RELAX NG differential checks passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
