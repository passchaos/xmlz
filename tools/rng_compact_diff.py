#!/usr/bin/env python3
"""Differential RELAX NG compact syntax checks.

Each case pairs a compact schema with an equivalent XML-syntax schema. The
compact schema is validated by xmlz; the XML twin is validated by libxml2
through lxml. Validity results must agree for every instance.
"""

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
XS = "http://www.w3.org/2001/XMLSchema-datatypes"

CASES = [
    (
        "compact-sequence-attributes",
        """element root {
          attribute id { text },
          element item { text },
          element item { text }
        }""",
        f"""<element xmlns="{RNG}" name="root">
          <group>
            <attribute name="id"><text/></attribute>
            <group>
              <element name="item"><text/></element>
              <element name="item"><text/></element>
            </group>
          </group>
        </element>""",
        [
            "<root id='1'><item>a</item><item>b</item></root>",
            "<root><item>a</item><item>b</item></root>",
            "<root id='1'><item>a</item></root>",
        ],
    ),
    (
        "compact-choice-repetition",
        """element root {
          (element a { text } | element b { empty })+,
          attribute id { text }?
        }""",
        f"""<element xmlns="{RNG}" name="root">
          <group>
            <oneOrMore>
              <choice>
                <element name="a"><text/></element>
                <element name="b"><empty/></element>
              </choice>
            </oneOrMore>
            <optional><attribute name="id"><text/></attribute></optional>
          </group>
        </element>""",
        [
            "<root><a>x</a><b/><a>y</a></root>",
            "<root id='1'><b/></root>",
            "<root/>",
            "<root><c/></root>",
        ],
    ),
    (
        "compact-namespaces",
        """default namespace = "urn:t"
namespace t = "urn:t"
element root {
  element * - t:skip { empty }*
}""",
        f"""<element xmlns="{RNG}" xmlns:t="urn:t" name="t:root">
          <zeroOrMore>
            <element>
              <anyName><except><name ns="urn:t">skip</name></except></anyName>
              <empty/>
            </element>
          </zeroOrMore>
        </element>""",
        [
            "<root xmlns='urn:t'><a/><b/></root>",
            "<root xmlns='urn:t'><skip/></root>",
            "<root xmlns='urn:t'><skip xmlns=''/></root>",
        ],
    ),
    (
        "compact-data-value-list",
        """element root {
          element n { xsd:integer { minInclusive = "10" } },
          element tag { "fixed" },
          element ids { list { xsd:integer+ } },
          element nonZero { xsd:integer - "0" }
        }""",
        f"""<element xmlns="{RNG}" datatypeLibrary="{XS}" name="root">
          <group>
            <element name="n">
              <data type="integer"><param name="minInclusive">10</param></data>
            </element>
            <group>
              <element name="tag"><value>fixed</value></element>
              <group>
                <element name="ids">
                  <list><oneOrMore><data type="integer"/></oneOrMore></list>
                </element>
                <element name="nonZero">
                  <data type="integer"><except><value>0</value></except></data>
                </element>
              </group>
            </group>
          </group>
        </element>""",
        [
            "<root><n>10</n><tag>fixed</tag><ids>1 2 3</ids><nonZero>5</nonZero></root>",
            "<root><n>5</n><tag>fixed</tag><ids>1</ids><nonZero>5</nonZero></root>",
            "<root><n>10</n><tag>other</tag><ids>1</ids><nonZero>5</nonZero></root>",
            "<root><n>10</n><tag>fixed</tag><ids>1</ids><nonZero>0</nonZero></root>",
        ],
    ),
    (
        "compact-grammar-refs",
        """grammar {
          start = tree
          tree = element tree {
            attribute name { text },
            tree*
          }
        }""",
        f"""<grammar xmlns="{RNG}">
          <start><ref name="tree"/></start>
          <define name="tree">
            <element name="tree">
              <group>
                <attribute name="name"><text/></attribute>
                <zeroOrMore><ref name="tree"/></zeroOrMore>
              </group>
            </element>
          </define>
        </grammar>""",
        [
            "<tree name='a'><tree name='b'/><tree name='c'/></tree>",
            "<tree><tree name='b'/></tree>",
        ],
    ),
    (
        "compact-parent-ref",
        """grammar {
          start = chain
          chain = grammar {
            start = element a { parent chain? }
          }
        }""",
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
            "<a><b/></a>",
        ],
    ),
    (
        "compact-interleave",
        """element root {
          (element a { empty }* & element b { empty }*)
        }""",
        f"""<element xmlns="{RNG}" name="root">
          <interleave>
            <zeroOrMore><element name="a"><empty/></element></zeroOrMore>
            <zeroOrMore><element name="b"><empty/></element></zeroOrMore>
          </interleave>
        </element>""",
        [
            "<root><a/><b/><a/></root>",
            "<root/>",
            "<root><c/></root>",
        ],
    ),
    (
        "compact-mixed",
        """element p {
          mixed {
            (element b { text } | element i { text })*
          }
        }""",
        f"""<element xmlns="{RNG}" name="p">
          <mixed>
            <zeroOrMore>
              <choice>
                <element name="b"><text/></element>
                <element name="i"><text/></element>
              </choice>
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
        "compact-escapes-annotations",
        """# comment
element \\x{72}oot {
  [ doc="yes" ]
  element item { empty } >> note
}""",
        f"""<element xmlns="{RNG}" name="root">
          <element name="item"><empty/></element>
        </element>""",
        [
            "<root><item/></root>",
            "<root><other/></root>",
        ],
    ),
]


BUNDLES = [
    (
        "compact-include",
        {
            "main.rnc": """grammar {
              include "base.rnc"
              start = element root { item+ }
            }""",
            "base.rnc": """item = element item { text }""",
        },
        {
            "main.rng": f"""<grammar xmlns="{RNG}">
              <include href="base.rng"/>
              <start><element name="root">
                <oneOrMore><ref name="item"/></oneOrMore>
              </element></start>
            </grammar>""",
            "base.rng": f"""<grammar xmlns="{RNG}">
              <define name="item">
                <element name="item"><text/></element>
              </define>
            </grammar>""",
        },
        [
            "<root><item>a</item><item>b</item></root>",
            "<root/>",
        ],
    ),
    (
        "compact-include-override",
        {
            "main.rnc": """grammar {
              include "base.rnc" {
                item = element b { text }
              }
              start = element root { item }
            }""",
            "base.rnc": """item = element a { text }""",
        },
        {
            "main.rng": f"""<grammar xmlns="{RNG}">
              <include href="base.rng">
                <define name="item">
                  <element name="b"><text/></element>
                </define>
              </include>
              <start><element name="root"><ref name="item"/></element></start>
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
        "compact-external",
        {
            "main.rnc": """element root { external "item.rnc" }""",
            "item.rnc": """element item { text }""",
        },
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
]

def run(cmd):
    return subprocess.run(cmd, capture_output=True)


def main():
    if len(sys.argv) < 2:
        print("usage: rng_compact_diff.py PATH/TO/rng", file=sys.stderr)
        return 2
    validator = sys.argv[1]
    checks = 0
    failures = 0
    for name, compact_source, xml_source, instances in CASES:
        try:
            relaxng = etree.RelaxNG(etree.fromstring(xml_source.encode()))
        except Exception as error:  # noqa: BLE001 - report libxml2 failures
            print(f"SKIP {name}: libxml2 schema error: {error}")
            continue
        with tempfile.TemporaryDirectory() as directory:
            compact_path = os.path.join(directory, "schema.rnc")
            with open(compact_path, "w", encoding="utf-8") as handle:
                handle.write(compact_source)
            for index, instance in enumerate(instances):
                instance_path = os.path.join(directory, f"instance-{index}.xml")
                with open(instance_path, "w", encoding="utf-8") as handle:
                    handle.write(instance)
                actual = run([validator, "--compact", compact_path, instance_path])
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
    for name, compact_files, xml_files, instances in BUNDLES:
        with tempfile.TemporaryDirectory() as directory:
            for filename, content in compact_files.items():
                path = os.path.join(directory, filename)
                with open(path, "w", encoding="utf-8") as handle:
                    handle.write(content)
            for filename, content in xml_files.items():
                path = os.path.join(directory, filename)
                with open(path, "w", encoding="utf-8") as handle:
                    handle.write(content)
            main_path = os.path.join(directory, "main.rnc")
            try:
                relaxng = etree.RelaxNG(
                    etree.parse(os.path.join(directory, "main.rng"))
                )
            except Exception as error:  # noqa: BLE001 - report libxml2 failures
                print(f"SKIP {name}: libxml2 schema error: {error}")
                continue
            for index, instance in enumerate(instances):
                instance_path = os.path.join(directory, f"instance-{index}.xml")
                with open(instance_path, "w", encoding="utf-8") as handle:
                    handle.write(instance)
                actual = run([validator, "--compact", main_path, instance_path])
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
    print(f"{checks - failures}/{checks} RELAX NG compact differential checks passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
