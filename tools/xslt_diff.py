#!/usr/bin/env python3
"""Differential XSLT 1.0 checks: xmlz vs libxslt (through lxml)."""

import os
import subprocess
import sys
import tempfile

try:
    from lxml import etree
except ImportError:  # pragma: no cover
    print("SKIP: lxml is not installed", file=sys.stderr)
    sys.exit(0)

STYLESHEETS = [
    (
        "apply-templates",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:template match="/"><out><xsl:apply-templates select="root/item"/></out></xsl:template>
        <xsl:template match="item"><item id="{@id}"><xsl:value-of select="name"/></item></xsl:template>
        </xsl:stylesheet>""",
        b"<root><item id='a'><name>Apple</name></item><item id='b'><name>Pear</name></item></root>",
        {},
    ),
    (
        "for-each-sort-if",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:template match="/">
          <xsl:variable name="limit" select="2"/>
          <list><xsl:for-each select="root/n">
            <xsl:sort select="." data-type="number"/>
            <n><xsl:value-of select="."/></n>
            <xsl:if test=". &gt; $limit"><big/></xsl:if>
          </xsl:for-each></list>
        </xsl:template>
        </xsl:stylesheet>""",
        b"<root><n>3</n><n>1</n><n>2</n></root>",
        {},
    ),
    (
        "choose",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:template match="/"><out><xsl:apply-templates select="root/item"/></out></xsl:template>
        <xsl:template match="item"><xsl:choose>
          <xsl:when test="@kind='a'"><a><xsl:value-of select="."/></a></xsl:when>
          <xsl:when test="@kind='b'"><b><xsl:value-of select="."/></b></xsl:when>
          <xsl:otherwise><other><xsl:value-of select="."/></other></xsl:otherwise>
        </xsl:choose></xsl:template>
        </xsl:stylesheet>""",
        b"<root><item kind='a'>A</item><item kind='b'>B</item><item>C</item></root>",
        {},
    ),
    (
        "copy-of",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:template match="/"><out><xsl:copy-of select="root/item"/></out></xsl:template>
        </xsl:stylesheet>""",
        b"<root><item id='a'><name>A</name></item><item id='b'><name>B</name></item></root>",
        {},
    ),
    (
        "call-template-params",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:template match="/"><out><xsl:call-template name="emit">
          <xsl:with-param name="prefix" select="'p-'"/>
        </xsl:call-template></out></xsl:template>
        <xsl:template name="emit">
          <xsl:param name="prefix" select="'x-'"/>
          <xsl:for-each select="root/item">
            <xsl:copy-of select="."/>
            <mark><xsl:value-of select="$prefix"/><xsl:value-of select="@id"/></mark>
          </xsl:for-each>
        </xsl:template>
        </xsl:stylesheet>""",
        b"<root><item id='a'><name>A</name></item></root>",
        {},
    ),
    (
        "global-param",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:param name="greeting" select="'hello'"/>
        <xsl:template match="/"><out><xsl:value-of select="$greeting"/></out></xsl:template>
        </xsl:stylesheet>""",
        b"<root/>",
        {"greeting": "hi"},
    ),
    (
        "literal-namespaces",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
          xmlns:o="urn:out" exclude-result-prefixes="o">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:template match="/"><o:root o:attr="v"><xsl:value-of select="root/a"/></o:root></xsl:template>
        </xsl:stylesheet>""",
        b"<root><a>text</a></root>",
        {},
    ),
    (
        "dynamic-element-attribute",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:template match="/"><out>
          <xsl:element name="item"><xsl:attribute name="id"><xsl:value-of select="root/@id"/></xsl:attribute><xsl:value-of select="root/a"/></xsl:element>
        </out></xsl:template>
        </xsl:stylesheet>""",
        b"<root id='r'><a>text</a></root>",
        {},
    ),
    (
        "comments-pis",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:template match="/"><out><!--note--><?pi data?><xsl:value-of select="root/a"/></out></xsl:template>
        </xsl:stylesheet>""",
        b"<root><a>text</a></root>",
        {},
    ),
    (
        "copy-and-apply",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:template match="/"><xsl:apply-templates select="root"/></xsl:template>
        <xsl:template match="*"><xsl:copy><xsl:apply-templates/></xsl:copy></xsl:template>
        <xsl:template match="text()"><xsl:value-of select="."/></xsl:template>
        </xsl:stylesheet>""",
        b"<root><a>one</a><b>two</b></root>",
        {},
    ),
    (
        "modes",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:template match="/"><out><xsl:apply-templates select="root/item" mode="upper"/></out></xsl:template>
        <xsl:template match="item" mode="upper"><u><xsl:value-of select="."/></u></xsl:template>
        <xsl:template match="item"><lower><xsl:value-of select="."/></lower></xsl:template>
        </xsl:stylesheet>""",
        b"<root><item>A</item><item>B</item></root>",
        {},
    ),
    (
        "builtin-templates",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:template match="/"><out><xsl:apply-templates select="root"/></out></xsl:template>
        </xsl:stylesheet>""",
        b"<root>text<a>nested</a></root>",
        {},
    ),
    (
        "priority",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:template match="/"><out><xsl:apply-templates select="root/item"/></out></xsl:template>
        <xsl:template match="item"><generic/></xsl:template>
        <xsl:template match="item[@kind='x']" priority="2"><special/></xsl:template>
        </xsl:stylesheet>""",
        b"<root><item kind='x'/><item kind='y'/></root>",
        {},
    ),
    (
        "number-value",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:template match="/"><out><xsl:number value="3"/><xsl:number value="2 div 4"/></out></xsl:template>
        </xsl:stylesheet>""",
        b"<root/>",
        {},
    ),
    (
        "key-basic",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:key name="byId" match="item" use="@id"/>
        <xsl:template match="/"><out>
          <xsl:value-of select="count(key('byId','a'))"/>
          <xsl:for-each select="key('byId','a')"><item><xsl:value-of select="@name"/></item></xsl:for-each>
          <xsl:apply-templates select="key('byId','b')"/>
        </out></xsl:template>
        <xsl:template match="item"><b><xsl:value-of select="@name"/></b></xsl:template>
        </xsl:stylesheet>""",
        b"<root><item id='a' name='A'/><item id='b' name='B'/></root>",
        {},
    ),
    (
        "key-multiple-and-nodeset",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:key name="byValue" match="item" use="tag"/>
        <xsl:key name="byValue" match="item" use="@id"/>
        <xsl:template match="/"><out>
          <xsl:value-of select="count(key('byValue','x'))"/>
          <xsl:value-of select="count(key('byValue','y'))"/>
          <xsl:value-of select="count(key('byValue','a'))"/>
          <xsl:value-of select="count(key('byValue','missing'))"/>
        </out></xsl:template>
        </xsl:stylesheet>""",
        b"<root><item id='a'><tag>x</tag><tag>y</tag></item><item id='b'><tag>x</tag></item></root>",
        {},
    ),
    (
        "key-global-variable",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:key name="special" match="item[@kind='x']" use="@id"/>
        <xsl:variable name="found" select="key('special','a')"/>
        <xsl:template match="/"><out>
          <xsl:value-of select="count($found)"/>
          <xsl:value-of select="count(key('special','b'))"/>
        </out></xsl:template>
        </xsl:stylesheet>""",
        b"<root><item id='a' kind='x'/><item id='b' kind='y'/></root>",
        {},
    ),
    (
        "key-in-pattern",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:key name="byId" match="item" use="@id"/>
        <xsl:template match="/"><out><xsl:apply-templates select="root/item"/></out></xsl:template>
        <xsl:template match="key('byId','a')"><special><xsl:value-of select="@id"/></special></xsl:template>
        <xsl:template match="item"><normal><xsl:value-of select="@id"/></normal></xsl:template>
        </xsl:stylesheet>""",
        b"<root><item id='a'/><item id='b'/></root>",
        {},
    ),
    (
        "key-namespaced",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
          xmlns:p="urn:p">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:key name="byId" match="p:item" use="@id"/>
        <xsl:template match="/"><out>
          <xsl:value-of select="count(key('byId','a'))"/>
          <xsl:for-each select="key('byId','a')"><item><xsl:value-of select="@name"/></item></xsl:for-each>
        </out></xsl:template>
        </xsl:stylesheet>""",
        b"<root xmlns:p='urn:p'><p:item id='a' name='A'/><p:item id='b' name='B'/></root>",
        {},
    ),
    (
        "html-void-boolean",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="html"/>
        <xsl:template match="/"><html><head><title>T</title></head><body><br/><img src="x"/><div/><input checked="checked"/><p>a &amp; b &lt; c</p></body></html></xsl:template>
        </xsl:stylesheet>""",
        b"<root/>",
        {},
    ),
    (
        "html-script-style",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="html"/>
        <xsl:template match="/"><html><body><script>if (a &lt; b) x();</script><style>a &gt; b {}</style><textarea>a &lt; b</textarea></body></html></xsl:template>
        </xsl:stylesheet>""",
        b"<root/>",
        {},
    ),
    (
        "html-boolean-attrs",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="html"/>
        <xsl:template match="/"><html><body><input checked="false" disabled="no" selected=""/><p/></body></html></xsl:template>
        </xsl:stylesheet>""",
        b"<root/>",
        {},
    ),
    (
        "attribute-set-literal",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:attribute-set name="base"><xsl:attribute name="a">1</xsl:attribute></xsl:attribute-set>
        <xsl:attribute-set name="derived" use-attribute-sets="base"><xsl:attribute name="b">2</xsl:attribute></xsl:attribute-set>
        <xsl:template match="/"><out><literal xsl:use-attribute-sets="derived"/></out></xsl:template>
        </xsl:stylesheet>""",
        b"<root/>",
        {},
    ),
    (
        "attribute-set-override",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:attribute-set name="s"><xsl:attribute name="a">set</xsl:attribute></xsl:attribute-set>
        <xsl:template match="/"><out><item xsl:use-attribute-sets="s" a="literal"/></out></xsl:template>
        </xsl:stylesheet>""",
        b"<root/>",
        {},
    ),
    (
        "attribute-set-avt-multiple",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:attribute-set name="first">
          <xsl:attribute name="a">first</xsl:attribute>
          <xsl:attribute name="id"><xsl:value-of select="@id"/></xsl:attribute>
        </xsl:attribute-set>
        <xsl:attribute-set name="second"><xsl:attribute name="a">second</xsl:attribute></xsl:attribute-set>
        <xsl:template match="/"><out><xsl:for-each select="root/item">
          <item xsl:use-attribute-sets="first second"/>
        </xsl:for-each></out></xsl:template>
        </xsl:stylesheet>""",
        b"<root><item id='x'/><item id='y'/></root>",
        {},
    ),
    (
        "attribute-set-dynamic-element",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:attribute-set name="s"><xsl:attribute name="a">1</xsl:attribute></xsl:attribute-set>
        <xsl:template match="/"><out><xsl:element name="dynamic" use-attribute-sets="s"/></out></xsl:template>
        </xsl:stylesheet>""",
        b"<root/>",
        {},
    ),
    (
        "strip-space-all",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:strip-space elements="*"/>
        <xsl:template match="/"><out><xsl:value-of select="count(//text())"/></out></xsl:template>
        </xsl:stylesheet>""",
        b"<root> <item> <a>x</a> </item> </root>",
        {},
    ),
    (
        "strip-space-specific",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:strip-space elements="item"/>
        <xsl:template match="/"><out><xsl:value-of select="count(//text())"/></out></xsl:template>
        </xsl:stylesheet>""",
        b"<root> <item> <a>x</a> </item> </root>",
        {},
    ),
    (
        "strip-space-preserve",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:strip-space elements="*"/>
        <xsl:preserve-space elements="pre"/>
        <xsl:template match="/"><out><xsl:value-of select="count(//text())"/></out></xsl:template>
        </xsl:stylesheet>""",
        b"<root> <pre> <a/> </pre> <other> <b/> </other> </root>",
        {},
    ),
    (
        "strip-space-namespaced",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
          xmlns:p="urn:p">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:strip-space elements="p:item"/>
        <xsl:template match="/"><out><xsl:value-of select="count(//text())"/></out></xsl:template>
        </xsl:stylesheet>""",
        b"<root xmlns:p='urn:p'> <p:item> <a/> </p:item> </root>",
        {},
    ),
    (
        "strip-space-xml-space",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:strip-space elements="*"/>
        <xsl:template match="/"><out><xsl:value-of select="count(//text())"/></out></xsl:template>
        </xsl:stylesheet>""",
        b"<root> <pre xml:space='preserve'> <a/> </pre> </root>",
        {},
    ),
    (
        "strip-space-copy-of",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:strip-space elements="*"/>
        <xsl:template match="/"><out><xsl:copy-of select="root"/></out></xsl:template>
        </xsl:stylesheet>""",
        b"<root> <a> x </a> </root>",
        {},
    ),
    (
        "number-levels",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:template match="/"><out>
          <xsl:for-each select="//item"><n><xsl:number level="single" count="*"/></n></xsl:for-each>
          <xsl:for-each select="//item"><m><xsl:number level="multiple" count="sec|item" format="1.1"/></m></xsl:for-each>
          <xsl:for-each select="//item"><a><xsl:number level="any" count="item"/></a></xsl:for-each>
        </out></xsl:template>
        </xsl:stylesheet>""",
        b"<doc><sec><item/><item/></sec><sec><item/></sec></doc>",
        {},
    ),
    (
        "number-ancestor",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:template match="/"><out><xsl:apply-templates select="//name"/></out></xsl:template>
        <xsl:template match="name"><n><xsl:number count="item"/></n></xsl:template>
        </xsl:stylesheet>""",
        b"<root><item><name>A</name></item><x/><item><name>B</name></item><item><name>C</name></item></root>",
        {},
    ),
    (
        "number-from",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:template match="/"><out>
          <xsl:for-each select="//item">
            <s><xsl:number level="single" count="item" from="sec"/></s>
            <m><xsl:number level="multiple" count="item" from="sec"/></m>
            <a><xsl:number level="any" count="item" from="sec"/></a>
          </xsl:for-each>
        </out></xsl:template>
        </xsl:stylesheet>""",
        b"<doc><sec><item/><item/></sec><sec><item/></sec></doc>",
        {},
    ),
    (
        "number-formats",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:template match="/"><out>
          <xsl:number value="3" format="1"/>
          <xsl:number value="3" format="01"/>
          <xsl:number value="3" format="a"/>
          <xsl:number value="3" format="A"/>
          <xsl:number value="3" format="i"/>
          <xsl:number value="3" format="I"/>
          <xsl:number value="3" format="1. "/>
          <xsl:number value="3" format="(1)"/>
          <xsl:number value="3" format="1.1"/>
        </out></xsl:template>
        </xsl:stylesheet>""",
        b"<root/>",
        {},
    ),
    (
        "number-default-any",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:template match="/"><out>
          <xsl:for-each select="//item"><n><xsl:number level="any"/></n></xsl:for-each>
        </out></xsl:template>
        </xsl:stylesheet>""",
        b"<doc><sec><item/><item/></sec><sec><item/></sec></doc>",
        {},
    ),
    (
        "disable-output-escaping",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:template match="/"><out>
          <xsl:value-of select="root/html" disable-output-escaping="yes"/>
          <xsl:text disable-output-escaping="yes">&lt;raw/&gt;</xsl:text>
          <escaped><xsl:value-of select="root/html"/></escaped>
        </out></xsl:template>
        </xsl:stylesheet>""",
        b"<root><html>&lt;b&gt;x&lt;/b&gt;</html></root>",
        {},
    ),
    (
        "disable-output-escaping-html",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="html"/>
        <xsl:template match="/"><out><xsl:value-of select="root/html" disable-output-escaping="yes"/></out></xsl:template>
        </xsl:stylesheet>""",
        b"<root><html>&lt;b&gt;x&lt;/b&gt;</html></root>",
        {},
    ),
    (
        "text-method",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="text"/>
        <xsl:template match="/"><xsl:value-of select="root/a"/></xsl:template>
        </xsl:stylesheet>""",
        b"<root><a>hello</a></root>",
        {},
    ),
    (
        "descending-sort",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:template match="/"><out><xsl:for-each select="root/n">
          <xsl:sort select="." data-type="number" order="descending"/>
          <n><xsl:value-of select="."/></n>
        </xsl:for-each></out></xsl:template>
        </xsl:stylesheet>""",
        b"<root><n>1</n><n>3</n><n>2</n></root>",
        {},
    ),
    (
        "copy-of-attributes",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:template match="/"><out><xsl:copy-of select="root/@*"/></out></xsl:template>
        </xsl:stylesheet>""",
        b"<root a='1' b='2'/>",
        {},
    ),
    (
        "namespaced-copy-of",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:template match="/"><out><xsl:copy-of select="root/p:item" xmlns:p="urn:p"/></out></xsl:template>
        </xsl:stylesheet>""",
        b"<root xmlns:p='urn:p'><p:item p:a='1'><p:child/></p:item></root>",
        {},
    ),
    (
        "pattern-predicate-priority",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:template match="/"><out><xsl:apply-templates select="root/item"/></out></xsl:template>
        <xsl:template match="item"><generic/></xsl:template>
        <xsl:template match="item[@kind='x']"><special/></xsl:template>
        </xsl:stylesheet>""",
        b"<root><item kind='x'/><item kind='y'/></root>",
        {},
    ),
    (
        "multi-step-pattern",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:template match="/"><out><xsl:apply-templates select="root/item/name"/></out></xsl:template>
        <xsl:template match="item/name"><n><xsl:value-of select="."/></n></xsl:template>
        <xsl:template match="name"><plain/></xsl:template>
        </xsl:stylesheet>""",
        b"<root><item><name>A</name></item><name>B</name></root>",
        {},
    ),
    (
        "attribute-pattern",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:template match="/"><out><xsl:apply-templates select="root/@*"/></out></xsl:template>
        <xsl:template match="@id"><id><xsl:value-of select="."/></id></xsl:template>
        <xsl:template match="@*"><other><xsl:value-of select="."/></other></xsl:template>
        </xsl:stylesheet>""",
        b"<root id='r' a='1'/>",
        {},
    ),
    (
        "text-comment-patterns",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:template match="/"><out><xsl:apply-templates select="root/node()"/></out></xsl:template>
        <xsl:template match="text()"><t><xsl:value-of select="."/></t></xsl:template>
        <xsl:template match="comment()"><!--copied--></xsl:template>
        </xsl:stylesheet>""",
        b"<root>alpha<!--inner-->beta</root>",
        {},
    ),
    (
        "dynamic-namespace-element",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:template match="/"><out>
          <xsl:element name="p:item" namespace="urn:p">
            <xsl:attribute name="p:a" namespace="urn:p">v</xsl:attribute>
            <xsl:value-of select="root/a"/>
          </xsl:element>
        </out></xsl:template>
        </xsl:stylesheet>""",
        b"<root><a>text</a></root>",
        {},
    ),
    (
        "variable-body",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:template match="/">
          <xsl:variable name="v">abc<xsl:value-of select="root/a"/></xsl:variable>
          <out><xsl:value-of select="$v"/></out>
        </xsl:template>
        </xsl:stylesheet>""",
        b"<root><a>def</a></root>",
        {},
    ),
    (
        "avt-braces",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:template match="/"><out a="{{literal}}-{root/@id}-{{x}}"><xsl:value-of select="root/a"/></out></xsl:template>
        </xsl:stylesheet>""",
        b"<root id='r'><a>text</a></root>",
        {},
    ),
    (
        "copy-attribute",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:template match="/"><out><xsl:apply-templates select="root/@*"/></out></xsl:template>
        <xsl:template match="@*"><xsl:copy/></xsl:template>
        </xsl:stylesheet>""",
        b"<root a='1' b='2'/>",
        {},
    ),
    (
        "number-level-single",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:template match="/"><out><xsl:apply-templates select="root/item"/></out></xsl:template>
        <xsl:template match="item"><n><xsl:number/></n></xsl:template>
        </xsl:stylesheet>""",
        b"<root><item/><other/><item/><item/></root>",
        {},
    ),
    (
        "default-priority-star",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:template match="/"><out><xsl:apply-templates select="root/*"/></out></xsl:template>
        <xsl:template match="*"><any><xsl:value-of select="."/></any></xsl:template>
        <xsl:template match="item"><named><xsl:value-of select="."/></named></xsl:template>
        </xsl:stylesheet>""",
        b"<root><item>A</item><other>B</other></root>",
        {},
    ),
    (
        "mode-with-param",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:template match="/"><out><xsl:apply-templates select="root/item" mode="m">
          <xsl:with-param name="suffix" select="'!'"/>
        </xsl:apply-templates></out></xsl:template>
        <xsl:template match="item" mode="m">
          <xsl:param name="suffix" select="'?'"/>
          <i><xsl:value-of select="."/><xsl:value-of select="$suffix"/></i>
        </xsl:template>
        </xsl:stylesheet>""",
        b"<root><item>A</item><item>B</item></root>",
        {},
    ),
    (
        "copy-with-body",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:template match="/"><out><xsl:apply-templates select="root/item"/></out></xsl:template>
        <xsl:template match="item"><xsl:copy><xsl:attribute name="seen">yes</xsl:attribute><xsl:apply-templates select="@*|node()"/></xsl:copy></xsl:template>
        <xsl:template match="@*|node()"><xsl:copy><xsl:apply-templates select="@*|node()"/></xsl:copy></xsl:template>
        </xsl:stylesheet>""",
        b"<root><item id='a'><name>A</name></item></root>",
        {},
    ),
    (
        "namespaced-pattern",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:template match="/"><out><xsl:apply-templates select="root/*"/></out></xsl:template>
        <xsl:template match="p:item" xmlns:p="urn:p"><p><xsl:value-of select="."/></p></xsl:template>
        <xsl:template match="*"><other><xsl:value-of select="."/></other></xsl:template>
        </xsl:stylesheet>""",
        b"<root xmlns:p='urn:p'><p:item>A</p:item><item>B</item></root>",
        {},
    ),
    (
        "pi-comment-avt",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:template match="/"><out>
          <xsl:comment>id={root/@id}</xsl:comment>
          <xsl:processing-instruction name="pi">value={root/a}</xsl:processing-instruction>
        </out></xsl:template>
        </xsl:stylesheet>""",
        b"<root id='r'><a>text</a></root>",
        {},
    ),
    (
        "xml-space-preserve",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:template match="/"><out xml:space="preserve">  <xsl:value-of select="root/a"/>  </out></xsl:template>
        </xsl:stylesheet>""",
        b"<root><a>text</a></root>",
        {},
    ),
    (
        "sort-text",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:template match="/"><out><xsl:for-each select="root/n">
          <xsl:sort select="." data-type="text"/>
          <n><xsl:value-of select="."/></n>
        </xsl:for-each></out></xsl:template>
        </xsl:stylesheet>""",
        b"<root><n>pear</n><n>apple</n><n>fig</n></root>",
        {},
    ),
    (
        "current-function",
        b"""<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        <xsl:output method="xml" omit-xml-declaration="yes"/>
        <xsl:template match="/"><out><xsl:for-each select="root/item">
          <xsl:value-of select="current()/@id"/>
        </xsl:for-each></out></xsl:template>
        </xsl:stylesheet>""",
        b"<root><item id='a'/><item id='b'/></root>",
        {},
    ),
]


BUNDLES = [
    (
        "include-named-template",
        {
            "main.xsl": """<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
              <xsl:output method="xml" omit-xml-declaration="yes"/>
              <xsl:include href="inc.xsl"/>
              <xsl:template match="/"><out><xsl:for-each select="root/a">
                <xsl:call-template name="emit"/>
              </xsl:for-each></out></xsl:template>
            </xsl:stylesheet>""",
            "inc.xsl": """<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
              <xsl:template name="emit"><inc><xsl:value-of select="."/></inc></xsl:template>
            </xsl:stylesheet>""",
        },
        "<root><a>x</a><a>y</a></root>",
        {},
    ),
    (
        "include-match-template",
        {
            "main.xsl": """<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
              <xsl:output method="xml" omit-xml-declaration="yes"/>
              <xsl:include href="inc.xsl"/>
              <xsl:template match="/"><out><xsl:apply-templates select="root/item"/></out></xsl:template>
            </xsl:stylesheet>""",
            "inc.xsl": """<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
              <xsl:template match="item"><item><xsl:value-of select="@id"/></item></xsl:template>
            </xsl:stylesheet>""",
        },
        "<root><item id='a'/><item id='b'/></root>",
        {},
    ),
    (
        "import-precedence",
        {
            "main.xsl": """<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
              <xsl:import href="base.xsl"/>
              <xsl:output method="xml" omit-xml-declaration="yes"/>
              <xsl:template match="/"><out><xsl:apply-templates select="root/item"/></out></xsl:template>
              <xsl:template match="item"><main><xsl:value-of select="@id"/></main></xsl:template>
            </xsl:stylesheet>""",
            "base.xsl": """<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
              <xsl:template match="item"><base><xsl:value-of select="@id"/></base></xsl:template>
            </xsl:stylesheet>""",
        },
        "<root><item id='a'/><item id='b'/></root>",
        {},
    ),
    (
        "apply-imports-params",
        {
            "main.xsl": """<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
              <xsl:import href="base.xsl"/>
              <xsl:output method="xml" omit-xml-declaration="yes"/>
              <xsl:template match="/"><out><xsl:value-of select="$v"/>
                <xsl:apply-templates select="root/item"/></out></xsl:template>
              <xsl:template match="item"><main><xsl:value-of select="@id"/>
                <xsl:apply-imports/>
              </main></xsl:template>
            </xsl:stylesheet>""",
            "base.xsl": """<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
              <xsl:variable name="v" select="'imported'"/>
              <xsl:template match="item"><xsl:param name="p" select="'D'"/><base><xsl:value-of select="@id"/><xsl:value-of select="$p"/></base></xsl:template>
            </xsl:stylesheet>""",
        },
        "<root><item id='a'/><item id='b'/></root>",
        {},
    ),
    (
        "nested-import",
        {
            "main.xsl": """<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
              <xsl:import href="mid.xsl"/>
              <xsl:output method="xml" omit-xml-declaration="yes"/>
              <xsl:template match="/"><out><xsl:apply-templates select="root/item"/></out></xsl:template>
            </xsl:stylesheet>""",
            "mid.xsl": """<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
              <xsl:import href="base.xsl"/>
            </xsl:stylesheet>""",
            "base.xsl": """<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
              <xsl:template match="item"><base><xsl:value-of select="@id"/></base></xsl:template>
            </xsl:stylesheet>""",
        },
        "<root><item id='a'/></root>",
        {},
    ),
    (
        "include-once",
        {
            "main.xsl": """<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
              <xsl:output method="xml" omit-xml-declaration="yes"/>
              <xsl:include href="shared.xsl"/>
              <xsl:template match="/"><out><xsl:call-template name="shared"/></out></xsl:template>
            </xsl:stylesheet>""",
            "shared.xsl": """<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
              <xsl:template name="shared"><shared/></xsl:template>
            </xsl:stylesheet>""",
        },
        "<root/>",
        {},
    ),
]


def run(cmd):
    return subprocess.run(cmd, capture_output=True)


def tree_shape(element):
    """Serialize an lxml node to a prefix-insensitive structural tuple."""
    if isinstance(element, etree._Comment):
        return ("comment", element.text or "")
    if isinstance(element, etree._ProcessingInstruction):
        return ("pi", element.target, element.text or "")
    attributes = sorted(
        (etree.QName(name).namespace or "", etree.QName(name).localname, value)
        for name, value in element.attrib.items()
    )
    return (
        "element",
        etree.QName(element).namespace or "",
        etree.QName(element).localname,
        tuple(attributes),
        element.text or "",
        tuple(tree_shape(child) for child in element),
        element.tail or "",
    )


def compare_xml(expected, actual):
    try:
        expected_tree = etree.fromstring(expected)
    except etree.XMLSyntaxError as error:
        return False, f"libxslt output is not XML: {error}"
    try:
        actual_tree = etree.fromstring(actual)
    except etree.XMLSyntaxError as error:
        return False, f"xmlz output is not XML: {error}"
    expected_shape = tree_shape(expected_tree)
    actual_shape = tree_shape(actual_tree)
    if expected_shape != actual_shape:
        return False, "trees differ"
    return True, ""


def main():
    if len(sys.argv) < 2:
        print("usage: xslt_diff.py PATH/TO/xslt", file=sys.stderr)
        return 2
    transformer = sys.argv[1]
    failures = 0
    checks = 0
    for name, stylesheet, source, params in STYLESHEETS:
        with tempfile.TemporaryDirectory() as directory:
            stylesheet_path = os.path.join(directory, "style.xsl")
            source_path = os.path.join(directory, "source.xml")
            with open(stylesheet_path, "wb") as handle:
                handle.write(stylesheet)
            with open(source_path, "wb") as handle:
                handle.write(source)

            command = [transformer, stylesheet_path, source_path]
            for key, value in params.items():
                command.append(f"--param={key}={value}")
            actual = run(command)

            try:
                transform = etree.XSLT(etree.fromstring(stylesheet))
                expected_result = transform(
                    etree.fromstring(source),
                    **{
                        key: etree.XSLT.strparam(value)
                        for key, value in params.items()
                    },
                )
            except Exception as error:  # noqa: BLE001 - report libxslt failures
                print(f"SKIP {name}: libxslt failed: {error}")
                continue

            checks += 1
            if actual.returncode != 0:
                failures += 1
                print(
                    f"FAIL {name}: xmlz failed: "
                    f"{actual.stderr.decode('utf-8', 'replace').strip()}"
                )
                continue

            method = "xml"
            output_element = etree.fromstring(stylesheet).find(
                "{http://www.w3.org/1999/XSL/Transform}output"
            )
            if output_element is not None and output_element.get("method"):
                method = output_element.get("method")
            if method == "text":
                expected_text = str(expected_result)
                actual_text = actual.stdout.decode("utf-8", "replace")
                if expected_text != actual_text:
                    failures += 1
                    print(
                        f"FAIL {name} (text)\n"
                        f"  libxslt: {expected_text!r}\n"
                        f"  xmlz:    {actual_text!r}"
                    )
                continue
            if method == "html":
                expected_html = etree.tostring(
                    expected_result,
                    method="html",
                    encoding="unicode",
                )
                actual_text = actual.stdout.decode("utf-8", "replace")
                if expected_html != actual_text:
                    failures += 1
                    print(
                        f"FAIL {name} (html)\n"
                        f"  libxslt: {expected_html!r}\n"
                        f"  xmlz:    {actual_text!r}"
                    )
                continue

            expected_xml = etree.tostring(
                expected_result,
                method="xml",
                xml_declaration=False,
                encoding="unicode",
            )
            actual_text = actual.stdout.decode("utf-8", "replace")
            matched, reason = compare_xml(expected_xml, actual_text)
            if not matched:
                failures += 1
                print(
                    f"FAIL {name}: {reason}\n"
                    f"  libxslt: {expected_xml!r}\n"
                    f"  xmlz:    {actual_text!r}"
                )
    for name, files, source, params in BUNDLES:
        with tempfile.TemporaryDirectory() as directory:
            for filename, content in files.items():
                path = os.path.join(directory, filename)
                with open(path, "w", encoding="utf-8") as handle:
                    handle.write(content)
            main_path = os.path.join(directory, "main.xsl")
            source_path = os.path.join(directory, "source.xml")
            with open(source_path, "w", encoding="utf-8") as handle:
                handle.write(source)
            command = [transformer, main_path, source_path]
            for key, value in params.items():
                command.append(f"--param={key}={value}")
            actual = run(command)
            try:
                transform = etree.XSLT(etree.parse(main_path))
                expected_result = transform(
                    etree.parse(source_path),
                    **{
                        key: etree.XSLT.strparam(value)
                        for key, value in params.items()
                    },
                )
            except Exception as error:  # noqa: BLE001 - report libxslt failures
                print(f"SKIP {name}: libxslt failed: {error}")
                continue
            checks += 1
            if actual.returncode != 0:
                failures += 1
                print(
                    f"FAIL {name}: xmlz failed: "
                    f"{actual.stderr.decode('utf-8', 'replace').strip()}"
                )
                continue
            method = "xml"
            output_element = etree.parse(main_path).find(
                "{http://www.w3.org/1999/XSL/Transform}output"
            )
            if output_element is not None and output_element.get("method"):
                method = output_element.get("method")
            if method == "text":
                expected_text = str(expected_result)
                actual_text = actual.stdout.decode("utf-8", "replace")
                if expected_text != actual_text:
                    failures += 1
                    print(
                        f"FAIL {name} (text)\n"
                        f"  libxslt: {expected_text!r}\n"
                        f"  xmlz:    {actual_text!r}"
                    )
                continue
            if method == "html":
                expected_html = etree.tostring(
                    expected_result,
                    method="html",
                    encoding="unicode",
                )
                actual_text = actual.stdout.decode("utf-8", "replace")
                if expected_html != actual_text:
                    failures += 1
                    print(
                        f"FAIL {name} (html)\n"
                        f"  libxslt: {expected_html!r}\n"
                        f"  xmlz:    {actual_text!r}"
                    )
                continue
            expected_xml = etree.tostring(
                expected_result,
                method="xml",
                xml_declaration=False,
                encoding="unicode",
            )
            actual_text = actual.stdout.decode("utf-8", "replace")
            matched, reason = compare_xml(expected_xml, actual_text)
            if not matched:
                failures += 1
                print(
                    f"FAIL {name}: {reason}\n"
                    f"  libxslt: {expected_xml!r}\n"
                    f"  xmlz:    {actual_text!r}"
                )
    print(f"{checks - failures}/{checks} XSLT differential checks passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
