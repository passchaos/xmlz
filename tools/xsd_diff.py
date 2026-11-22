#!/usr/bin/env python3
"""Differential XML Schema validation: xmlz vs libxml2 through lxml."""

import os
import subprocess
import sys
import tempfile

try:
    from lxml import etree
except ImportError:  # pragma: no cover
    print("SKIP: lxml is not installed", file=sys.stderr)
    sys.exit(0)

XS = "http://www.w3.org/2001/XMLSchema"

CASES = [
    (
        "sequence-attributes",
        f"""<xs:schema xmlns:xs="{XS}">
          <xs:element name="root">
            <xs:complexType>
              <xs:sequence>
                <xs:element name="item" type="xs:string" minOccurs="1" maxOccurs="unbounded"/>
              </xs:sequence>
              <xs:attribute name="id" type="xs:integer" use="required"/>
            </xs:complexType>
          </xs:element>
        </xs:schema>""",
        [
            "<root id='1'><item>a</item><item>b</item></root>",
            "<root><item>a</item></root>",
            "<root id='x'><item>a</item></root>",
            "<root id='1'/>",
            "<root id='1'><item>a</item><extra/></root>",
            "<root id='1'><item>a</item><item/></root>",
        ],
    ),
    (
        "simple-enumeration",
        f"""<xs:schema xmlns:xs="{XS}">
          <xs:simpleType name="color">
            <xs:restriction base="xs:string">
              <xs:enumeration value="red"/>
              <xs:enumeration value="blue"/>
            </xs:restriction>
          </xs:simpleType>
          <xs:element name="color" type="color"/>
        </xs:schema>""",
        [
            "<color>red</color>",
            "<color>blue</color>",
            "<color>green</color>",
            "<color></color>",
        ],
    ),
    (
        "namespaced-qualified",
        f"""<xs:schema xmlns:xs="{XS}" targetNamespace="urn:t"
          xmlns:t="urn:t" elementFormDefault="qualified">
          <xs:element name="root" type="t:Root"/>
          <xs:complexType name="Root">
            <xs:sequence>
              <xs:element name="child" type="xs:string"/>
            </xs:sequence>
          </xs:complexType>
        </xs:schema>""",
        [
            "<root xmlns='urn:t'><child>x</child></root>",
            "<root xmlns='urn:t'><child xmlns=''>x</child></root>",
            "<root><child>x</child></root>",
            "<root xmlns='urn:t'><child>x</child><child>y</child></root>",
        ],
    ),
    (
        "complex-extension",
        f"""<xs:schema xmlns:xs="{XS}" targetNamespace="urn:t"
          xmlns:t="urn:t" elementFormDefault="qualified">
          <xs:element name="root" type="t:Derived"/>
          <xs:complexType name="Base">
            <xs:sequence><xs:element name="a" type="xs:string"/></xs:sequence>
          </xs:complexType>
          <xs:complexType name="Derived">
            <xs:complexContent>
              <xs:extension base="t:Base">
                <xs:sequence><xs:element name="b" type="xs:string"/></xs:sequence>
              </xs:extension>
            </xs:complexContent>
          </xs:complexType>
        </xs:schema>""",
        [
            "<root xmlns='urn:t'><a>1</a><b>2</b></root>",
            "<root xmlns='urn:t'><b>2</b><a>1</a></root>",
            "<root xmlns='urn:t'><a>1</a></root>",
            "<root xmlns='urn:t'><a>1</a><b>2</b><b>3</b></root>",
        ],
    ),
    (
        "choice",
        f"""<xs:schema xmlns:xs="{XS}">
          <xs:element name="root">
            <xs:complexType>
              <xs:choice>
                <xs:element name="a" type="xs:string"/>
                <xs:element name="b" type="xs:string"/>
              </xs:choice>
            </xs:complexType>
          </xs:element>
        </xs:schema>""",
        [
            "<root><a>x</a></root>",
            "<root><b>x</b></root>",
            "<root><a>x</a><b>y</b></root>",
            "<root/>",
        ],
    ),
    (
        "all",
        f"""<xs:schema xmlns:xs="{XS}">
          <xs:element name="root">
            <xs:complexType>
              <xs:all>
                <xs:element name="a" type="xs:string"/>
                <xs:element name="b" type="xs:string"/>
              </xs:all>
            </xs:complexType>
          </xs:element>
        </xs:schema>""",
        [
            "<root><a>x</a><b>y</b></root>",
            "<root><b>y</b><a>x</a></root>",
            "<root><a>x</a></root>",
            "<root><a>x</a><a>y</a></root>",
        ],
    ),
    (
        "list-union",
        f"""<xs:schema xmlns:xs="{XS}">
          <xs:simpleType name="ints">
            <xs:list itemType="xs:integer"/>
          </xs:simpleType>
          <xs:simpleType name="value">
            <xs:union memberTypes="xs:integer xs:boolean"/>
          </xs:simpleType>
          <xs:element name="numbers" type="ints"/>
          <xs:element name="value" type="value"/>
        </xs:schema>""",
        [
            "<numbers>1 2 3</numbers>",
            "<numbers>1 x 3</numbers>",
            "<numbers></numbers>",
            "<value>42</value>",
            "<value>true</value>",
            "<value>hello</value>",
        ],
    ),
    (
        "attribute-use",
        f"""<xs:schema xmlns:xs="{XS}">
          <xs:element name="root">
            <xs:complexType>
              <xs:attribute name="a" type="xs:string"/>
              <xs:attribute name="b" type="xs:string" use="required"/>
              <xs:attribute name="c" type="xs:string" use="prohibited"/>
            </xs:complexType>
          </xs:element>
        </xs:schema>""",
        [
            "<root b='x'/>",
            "<root a='x'/>",
            "<root b='x' c='y'/>",
            "<root b='x' d='y'/>",
            "<root b='x' a='y'/>",
        ],
    ),
    (
        "occurrences",
        f"""<xs:schema xmlns:xs="{XS}">
          <xs:element name="root">
            <xs:complexType>
              <xs:sequence>
                <xs:element name="a" type="xs:string" minOccurs="0"/>
                <xs:element name="b" type="xs:string" minOccurs="2" maxOccurs="3"/>
              </xs:sequence>
            </xs:complexType>
          </xs:element>
        </xs:schema>""",
        [
            "<root><b>1</b><b>2</b></root>",
            "<root><a>x</a><b>1</b><b>2</b></root>",
            "<root><b>1</b></root>",
            "<root><b>1</b><b>2</b><b>3</b><b>4</b></root>",
        ],
    ),
    (
        "simple-content-extension",
        f"""<xs:schema xmlns:xs="{XS}" targetNamespace="urn:t"
          xmlns:t="urn:t" elementFormDefault="qualified">
          <xs:element name="root" type="t:Derived"/>
          <xs:complexType name="Base">
            <xs:simpleContent>
              <xs:extension base="xs:string">
                <xs:attribute name="a" type="xs:string"/>
              </xs:extension>
            </xs:simpleContent>
          </xs:complexType>
          <xs:complexType name="Derived">
            <xs:simpleContent>
              <xs:extension base="t:Base">
                <xs:attribute name="b" type="xs:string" use="required"/>
              </xs:extension>
            </xs:simpleContent>
          </xs:complexType>
        </xs:schema>""",
        [
            "<root xmlns='urn:t' b='x'>text</root>",
            "<root xmlns='urn:t' a='y' b='x'>text</root>",
            "<root xmlns='urn:t'>text</root>",
            "<root xmlns='urn:t' b='x'><child/></root>",
        ],
    ),
    (
        "nested-anonymous",
        f"""<xs:schema xmlns:xs="{XS}">
          <xs:element name="root">
            <xs:complexType>
              <xs:sequence>
                <xs:element name="item">
                  <xs:complexType>
                    <xs:sequence>
                      <xs:element name="name" type="xs:string"/>
                    </xs:sequence>
                    <xs:attribute name="id" type="xs:integer" use="required"/>
                  </xs:complexType>
                </xs:element>
              </xs:sequence>
            </xs:complexType>
          </xs:element>
        </xs:schema>""",
        [
            "<root><item id='1'><name>x</name></item></root>",
            "<root><item><name>x</name></item></root>",
            "<root><item id='x'><name>x</name></item></root>",
            "<root><item id='1'/></root>",
        ],
    ),
    (
        "global-ref",
        f"""<xs:schema xmlns:xs="{XS}">
          <xs:element name="item" type="xs:string"/>
          <xs:element name="root">
            <xs:complexType>
              <xs:sequence>
                <xs:element ref="item" minOccurs="1" maxOccurs="2"/>
              </xs:sequence>
            </xs:complexType>
          </xs:element>
        </xs:schema>""",
        [
            "<root><item>x</item></root>",
            "<root><item>x</item><item>y</item></root>",
            "<root/>",
            "<root><item>x</item><item>y</item><item>z</item></root>",
        ],
    ),
    (
        "numeric-facets",
        f"""<xs:schema xmlns:xs="{XS}">
          <xs:simpleType name="score">
            <xs:restriction base="xs:integer">
              <xs:minInclusive value="0"/>
              <xs:maxInclusive value="100"/>
            </xs:restriction>
          </xs:simpleType>
          <xs:element name="score" type="score"/>
        </xs:schema>""",
        [
            "<score>0</score>",
            "<score>100</score>",
            "<score>50</score>",
            "<score>-1</score>",
            "<score>101</score>",
        ],
    ),
    (
        "pattern-facet",
        f"""<xs:schema xmlns:xs="{XS}">
          <xs:simpleType name="code">
            <xs:restriction base="xs:string">
              <xs:pattern value="[A-Z]{{2}}[0-9]{{3}}"/>
            </xs:restriction>
          </xs:simpleType>
          <xs:element name="code" type="code"/>
        </xs:schema>""",
        [
            "<code>AB123</code>",
            "<code>ab123</code>",
            "<code>AB12</code>",
            "<code>AB1234</code>",
        ],
    ),
    (
        "nillable",
        f"""<xs:schema xmlns:xs="{XS}">
          <xs:element name="root" nillable="true" type="xs:string"/>
        </xs:schema>""",
        [
            "<root>text</root>",
            "<root xmlns:xsi='http://www.w3.org/2001/XMLSchema-instance' xsi:nil='true'/>",
            "<root xmlns:xsi='http://www.w3.org/2001/XMLSchema-instance' xsi:nil='true'>text</root>",
        ],
    ),
    (
        "mixed-content",
        f"""<xs:schema xmlns:xs="{XS}">
          <xs:element name="root">
            <xs:complexType mixed="true">
              <xs:sequence>
                <xs:element name="b" type="xs:string" minOccurs="0" maxOccurs="unbounded"/>
              </xs:sequence>
            </xs:complexType>
          </xs:element>
        </xs:schema>""",
        [
            "<root>text<b>bold</b>tail</root>",
            "<root><b>bold</b></root>",
            "<root><c/></root>",
        ],
    ),
    (
        "complex-restriction",
        f"""<xs:schema xmlns:xs="{XS}" targetNamespace="urn:t"
          xmlns:t="urn:t" elementFormDefault="qualified">
          <xs:element name="root" type="t:Derived"/>
          <xs:complexType name="Base">
            <xs:sequence>
              <xs:element name="a" type="xs:string"/>
              <xs:element name="b" type="xs:string"/>
            </xs:sequence>
          </xs:complexType>
          <xs:complexType name="Derived">
            <xs:complexContent>
              <xs:restriction base="t:Base">
                <xs:sequence>
                  <xs:element name="a" type="xs:string"/>
                </xs:sequence>
              </xs:restriction>
            </xs:complexContent>
          </xs:complexType>
        </xs:schema>""",
        [
            "<root xmlns='urn:t'><a>x</a></root>",
            "<root xmlns='urn:t'><a>x</a><b>y</b></root>",
            "<root xmlns='urn:t'/>",
        ],
    ),
    (
        "simple-content-restriction",
        f"""<xs:schema xmlns:xs="{XS}" targetNamespace="urn:t" xmlns:t="urn:t">
          <xs:element name="root" type="t:Restricted"/>
          <xs:complexType name="Base">
            <xs:simpleContent>
              <xs:extension base="xs:string">
                <xs:attribute name="id" type="xs:integer"/>
              </xs:extension>
            </xs:simpleContent>
          </xs:complexType>
          <xs:complexType name="Restricted">
            <xs:simpleContent>
              <xs:restriction base="t:Base">
                <xs:maxLength value="3"/>
                <xs:attribute name="id" type="xs:integer"/>
              </xs:restriction>
            </xs:simpleContent>
          </xs:complexType>
        </xs:schema>""",
        [
            "<root xmlns='urn:t'>abc</root>",
            "<root xmlns='urn:t' id='1'>abc</root>",
            "<root xmlns='urn:t'>abcd</root>",
            "<root xmlns='urn:t' id='x'>abc</root>",
        ],
    ),
    (
        "attribute-wildcard",
        f"""<xs:schema xmlns:xs="{XS}">
          <xs:element name="root">
            <xs:complexType>
              <xs:attribute name="a" type="xs:string"/>
              <xs:anyAttribute namespace="##any" processContents="skip"/>
            </xs:complexType>
          </xs:element>
        </xs:schema>""",
        [
            "<root a='x'/>",
            "<root a='x' b='y'/>",
            "<root xmlns:p='urn:p' p:a='x'/>",
        ],
    ),
    (
        "wildcard-other",
        f"""<xs:schema xmlns:xs="{XS}" targetNamespace="urn:t" xmlns:t="urn:t">
          <xs:element name="root">
            <xs:complexType>
              <xs:sequence>
                <xs:any namespace="##other" processContents="skip"
                  minOccurs="0" maxOccurs="unbounded"/>
              </xs:sequence>
            </xs:complexType>
          </xs:element>
        </xs:schema>""",
        [
            "<root xmlns='urn:t'/>",
            "<root xmlns='urn:t'><a xmlns=''/></root>",
            "<root xmlns='urn:t'><a xmlns='urn:x'/></root>",
            "<root xmlns='urn:t'><a xmlns='urn:t'/></root>",
        ],
    ),
    (
        "recursive-type",
        f"""<xs:schema xmlns:xs="{XS}">
          <xs:element name="node" type="Node"/>
          <xs:complexType name="Node">
            <xs:sequence>
              <xs:element name="child" type="Node" minOccurs="0" maxOccurs="unbounded"/>
            </xs:sequence>
            <xs:attribute name="name" type="xs:string"/>
          </xs:complexType>
        </xs:schema>""",
        [
            "<node name='a'/>",
            "<node name='a'><child name='b'/></node>",
            "<node name='a'><child name='b'><child name='c'/></child></node>",
            "<node><child/></node>",
        ],
    ),
    (
        "any-type",
        f"""<xs:schema xmlns:xs="{XS}">
          <xs:element name="root"/>
        </xs:schema>""",
        [
            "<root/>",
            "<root><anything a='1'>text</anything></root>",
        ],
    ),
    (
        "default-fixed",
        f"""<xs:schema xmlns:xs="{XS}">
          <xs:element name="root">
            <xs:complexType>
              <xs:attribute name="a" type="xs:string" default="x"/>
              <xs:attribute name="b" type="xs:string" fixed="y"/>
            </xs:complexType>
          </xs:element>
          <xs:element name="fixed" type="xs:string" fixed="v"/>
        </xs:schema>""",
        [
            "<root/>",
            "<root a='z'/>",
            "<root b='y'/>",
            "<root b='z'/>",
            "<fixed>v</fixed>",
            "<fixed>w</fixed>",
        ],
    ),
    (
        "date-types",
        f"""<xs:schema xmlns:xs="{XS}">
          <xs:element name="date" type="xs:date"/>
          <xs:element name="dateTime" type="xs:dateTime"/>
        </xs:schema>""",
        [
            "<date>2024-02-29</date>",
            "<date>2023-02-29</date>",
            "<date>2024-13-01</date>",
            "<dateTime>2024-02-29T12:30:00Z</dateTime>",
            "<dateTime>2024-02-29T24:00:00Z</dateTime>",
            "<dateTime>2024-02-29T24:00:01Z</dateTime>",
        ],
    ),
    (
        "whitespace-facet",
        f"""<xs:schema xmlns:xs="{XS}">
          <xs:simpleType name="token3">
            <xs:restriction base="xs:token">
              <xs:maxLength value="3"/>
            </xs:restriction>
          </xs:simpleType>
          <xs:element name="value" type="token3"/>
        </xs:schema>""",
        [
            "<value>abc</value>",
            "<value>  abc  </value>",
            "<value>ab cd</value>",
            "<value>abcd</value>",
        ],
    ),
    (
        "multiple-patterns",
        f"""<xs:schema xmlns:xs="{XS}">
          <xs:simpleType name="code">
            <xs:restriction base="xs:string">
              <xs:pattern value="[A-Z]+"/>
              <xs:pattern value="[0-9]+"/>
            </xs:restriction>
          </xs:simpleType>
          <xs:element name="code" type="code"/>
        </xs:schema>""",
        [
            "<code>ABC</code>",
            "<code>123</code>",
            "<code>A1</code>",
            "<code>abc</code>",
        ],
    ),
    (
        "all-optional",
        f"""<xs:schema xmlns:xs="{XS}">
          <xs:element name="root">
            <xs:complexType>
              <xs:all>
                <xs:element name="a" type="xs:string" minOccurs="0"/>
                <xs:element name="b" type="xs:string" minOccurs="0"/>
              </xs:all>
            </xs:complexType>
          </xs:element>
        </xs:schema>""",
        [
            "<root/>",
            "<root><a>x</a></root>",
            "<root><b>y</b></root>",
            "<root><a>x</a><b>y</b></root>",
        ],
    ),
    (
        "optional-sequence",
        f"""<xs:schema xmlns:xs="{XS}">
          <xs:element name="root">
            <xs:complexType>
              <xs:sequence minOccurs="0">
                <xs:element name="a" type="xs:string"/>
                <xs:element name="b" type="xs:string"/>
              </xs:sequence>
            </xs:complexType>
          </xs:element>
        </xs:schema>""",
        [
            "<root/>",
            "<root><a>x</a><b>y</b></root>",
            "<root><a>x</a></root>",
        ],
    ),
    (
        "qualified-attributes",
        f"""<xs:schema xmlns:xs="{XS}" targetNamespace="urn:t"
          xmlns:t="urn:t" attributeFormDefault="qualified">
          <xs:element name="root">
            <xs:complexType>
              <xs:attribute name="a" type="xs:string" use="required"/>
            </xs:complexType>
          </xs:element>
        </xs:schema>""",
        [
            "<root xmlns='urn:t' xmlns:t='urn:t' t:a='x'/>",
            "<root xmlns='urn:t' a='x'/>",
            "<root xmlns='urn:t'/>",
        ],
    ),
    (
        "global-attribute-ref",
        f"""<xs:schema xmlns:xs="{XS}">
          <xs:attribute name="code" type="xs:integer"/>
          <xs:element name="root">
            <xs:complexType>
              <xs:attribute ref="code" use="required"/>
            </xs:complexType>
          </xs:element>
        </xs:schema>""",
        [
            "<root code='1'/>",
            "<root code='x'/>",
            "<root/>",
        ],
    ),
    (
        "element-only-text",
        f"""<xs:schema xmlns:xs="{XS}">
          <xs:element name="root">
            <xs:complexType>
              <xs:sequence>
                <xs:element name="a" type="xs:string"/>
              </xs:sequence>
            </xs:complexType>
          </xs:element>
        </xs:schema>""",
        [
            "<root><a>x</a></root>",
            "<root>text<a>x</a></root>",
            "<root> <a>x</a> </root>",
        ],
    ),
    (
        "empty-complex-type",
        f"""<xs:schema xmlns:xs="{XS}">
          <xs:element name="root">
            <xs:complexType/>
          </xs:element>
        </xs:schema>""",
        [
            "<root/>",
            "<root><a/></root>",
            "<root>text</root>",
        ],
    ),
    (
        "optional-choice-branch",
        f"""<xs:schema xmlns:xs="{XS}">
          <xs:element name="root">
            <xs:complexType>
              <xs:choice>
                <xs:element name="a" type="xs:string" minOccurs="0"/>
                <xs:element name="b" type="xs:string"/>
              </xs:choice>
            </xs:complexType>
          </xs:element>
        </xs:schema>""",
        [
            "<root/>",
            "<root><a>x</a></root>",
            "<root><b>x</b></root>",
            "<root><a>x</a><b>y</b></root>",
        ],
    ),
    (
        "xsi-type",
        f"""<xs:schema xmlns:xs="{XS}" targetNamespace="urn:t" xmlns:t="urn:t"
          elementFormDefault="qualified">
          <xs:element name="root" type="t:Base"/>
          <xs:complexType name="Base">
            <xs:sequence><xs:element name="a" type="xs:string"/></xs:sequence>
          </xs:complexType>
          <xs:complexType name="Derived">
            <xs:complexContent>
              <xs:extension base="t:Base">
                <xs:sequence><xs:element name="b" type="xs:string"/></xs:sequence>
              </xs:extension>
            </xs:complexContent>
          </xs:complexType>
        </xs:schema>""",
        [
            "<root xmlns='urn:t' xmlns:t='urn:t' xmlns:xsi='http://www.w3.org/2001/XMLSchema-instance' xsi:type='t:Derived'><a>1</a><b>2</b></root>",
            "<root xmlns='urn:t' xmlns:t='urn:t' xmlns:xsi='http://www.w3.org/2001/XMLSchema-instance' xsi:type='t:Derived'><a>1</a></root>",
            "<root xmlns='urn:t' xmlns:t='urn:t' xmlns:xsi='http://www.w3.org/2001/XMLSchema-instance' xsi:type='t:Base'><a>1</a></root>",
            "<root xmlns='urn:t' xmlns:t='urn:t'><a>1</a><b>2</b></root>",
        ],
    ),
    (
        "xml-attributes-not-implicit",
        f"""<xs:schema xmlns:xs="{XS}">
          <xs:element name="root">
            <xs:complexType>
              <xs:attribute name="a" type="xs:string"/>
            </xs:complexType>
          </xs:element>
        </xs:schema>""",
        [
            "<root a='1'/>",
            "<root xml:lang='en'/>",
            "<root a='1' xml:space='preserve'/>",
        ],
    ),
    (
        "decimal-digits",
        f"""<xs:schema xmlns:xs="{XS}">
          <xs:simpleType name="price">
            <xs:restriction base="xs:decimal">
              <xs:totalDigits value="5"/>
              <xs:fractionDigits value="2"/>
            </xs:restriction>
          </xs:simpleType>
          <xs:element name="price" type="price"/>
        </xs:schema>""",
        [
            "<price>123.45</price>",
            "<price>1234.56</price>",
            "<price>12.345</price>",
            "<price>0.5</price>",
        ],
    ),
    (
        "date-facets",
        f"""<xs:schema xmlns:xs="{XS}">
          <xs:simpleType name="day">
            <xs:restriction base="xs:date">
              <xs:minInclusive value="2024-01-01"/>
              <xs:maxInclusive value="2024-12-31"/>
            </xs:restriction>
          </xs:simpleType>
          <xs:element name="day" type="day"/>
        </xs:schema>""",
        [
            "<day>2024-06-01</day>",
            "<day>2023-12-31</day>",
            "<day>2025-01-01</day>",
            "<day>2024-12-31</day>",
        ],
    ),
    (
        "any-attribute-lax",
        f"""<xs:schema xmlns:xs="{XS}">
          <xs:attribute name="code" type="xs:integer"/>
          <xs:element name="root">
            <xs:complexType>
              <xs:anyAttribute namespace="##any" processContents="lax"/>
            </xs:complexType>
          </xs:element>
        </xs:schema>""",
        [
            "<root code='1'/>",
            "<root code='x'/>",
            "<root other='y'/>",
        ],
    ),
    (
        "any-wildcard",
        f"""<xs:schema xmlns:xs="{XS}">
          <xs:element name="root">
            <xs:complexType>
              <xs:sequence>
                <xs:any namespace="##any" processContents="skip"
                  minOccurs="0" maxOccurs="unbounded"/>
              </xs:sequence>
            </xs:complexType>
          </xs:element>
        </xs:schema>""",
        [
            "<root/>",
            "<root><a/></root>",
            "<root><a/><b/></root>",
        ],
    ),
]


def run(cmd):
    return subprocess.run(cmd, capture_output=True)


def main():
    if len(sys.argv) < 2:
        print("usage: xsd_diff.py PATH/TO/xsd", file=sys.stderr)
        return 2
    validator = sys.argv[1]
    checks = 0
    failures = 0
    for name, schema_source, instances in CASES:
        try:
            lxml_schema = etree.XMLSchema(etree.fromstring(schema_source.encode()))
        except Exception as error:  # noqa: BLE001 - report libxml2 failures
            print(f"SKIP {name}: libxml2 schema error: {error}")
            continue
        with tempfile.TemporaryDirectory() as directory:
            schema_path = os.path.join(directory, "schema.xsd")
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
                        f"FAIL {name} instance {index}: xmlz schema/validation "
                        f"error: {actual.stderr.decode('utf-8', 'replace').strip()}"
                    )
                    continue
                expected_valid = lxml_schema.validate(
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
                        f"  lxml: {lxml_schema.error_log}\n"
                        f"  xmlz: {actual.stderr.decode('utf-8', 'replace').strip()}"
                    )
    print(f"{checks - failures}/{checks} XSD differential checks passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
