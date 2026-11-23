#!/usr/bin/env python3
"""Benchmark XSLT throughput: xmlz vs libxslt through lxml.

The workload is a deterministic table document transformed by an identity
stylesheet. Both engines parse the source and compile the stylesheet once,
then apply the transform repeatedly in-process; xmlz uses the `xslt` tool's
`--repeat` option so parsing is likewise amortized.

Build the tool with optimizations for meaningful numbers:

    zig build -Doptimize=ReleaseFast xslt-bench

The libxslt column requires lxml and is skipped when it is unavailable.
"""

import argparse
import os
import subprocess
import sys
import tempfile
import time

DEFAULT_ROWS = 20000
DEFAULT_REPEAT = 20

IDENTITY_STYLESHEET = """<?xml version="1.0"?>
<xsl:stylesheet version="1.0"
  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:output encoding="utf-8"/>
  <xsl:template match="*">
    <xsl:copy><xsl:apply-templates/></xsl:copy>
  </xsl:template>
</xsl:stylesheet>
"""

REPORT_STYLESHEET = """<?xml version="1.0"?>
<xsl:stylesheet version="1.0"
  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:output encoding="utf-8" indent="yes"/>
  <xsl:template match="/">
    <report>
      <xsl:for-each select="table/row">
        <xsl:sort select="lastname"/>
        <xsl:sort select="firstname"/>
        <entry id="{id}" city="{city}"><xsl:value-of select="lastname"/>, <xsl:value-of select="firstname"/></entry>
      </xsl:for-each>
    </report>
  </xsl:template>
</xsl:stylesheet>
"""

IDENTITY_ATTRS_STYLESHEET = """<?xml version="1.0"?>
<xsl:stylesheet version="1.0"
  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:output encoding="utf-8"/>
  <xsl:template match="@*|node()">
    <xsl:copy><xsl:apply-templates select="@*|node()"/></xsl:copy>
  </xsl:template>
</xsl:stylesheet>
"""


def write_input(path, rows):
    with open(path, "w", encoding="utf-8") as handle:
        handle.write('<?xml version="1.0"?>\n<table>\n')
        for index in range(rows):
            handle.write(
                "  <row><id>%04d</id><firstname>Al</firstname>"
                "<lastname>Aranow</lastname><street>1 Any St.</street>"
                "<city>Anytown</city><state>AL</state><zip>22000</zip>"
                "</row>\n" % index
            )
        handle.write("</table>\n")


def bench_xmlz(tool, stylesheet, source, repeat):
    start = time.perf_counter()
    result = subprocess.run(
        [tool, "--repeat=%d" % repeat, stylesheet, source],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    elapsed = time.perf_counter() - start
    if result.returncode != 0:
        raise RuntimeError(result.stderr.decode(errors="replace"))
    return elapsed


def bench_libxslt(stylesheet, source, repeat):
    try:
        from lxml import etree
    except ImportError:
        return None
    style = etree.XSLT(etree.parse(stylesheet))
    document = etree.parse(source)
    start = time.perf_counter()
    for _ in range(repeat):
        result = style(document)
    if result is None:
        raise RuntimeError("libxslt produced no result")
    return time.perf_counter() - start


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tool", help="path to the xmlz xslt executable")
    parser.add_argument("--rows", type=int, default=DEFAULT_ROWS)
    parser.add_argument("--repeat", type=int, default=DEFAULT_REPEAT)
    args = parser.parse_args()

    with tempfile.TemporaryDirectory() as directory:
        source = os.path.join(directory, "input.xml")
        write_input(source, args.rows)
        size = os.path.getsize(source)
        results = []
        for name, text in (
            ("identity", IDENTITY_STYLESHEET),
            ("identity (attributes)", IDENTITY_ATTRS_STYLESHEET),
            ("sorted report", REPORT_STYLESHEET),
        ):
            stylesheet = os.path.join(directory, name.replace(" ", "-") + ".xsl")
            with open(stylesheet, "w", encoding="utf-8") as handle:
                handle.write(text)
            xmlz_seconds = bench_xmlz(
                args.tool,
                stylesheet,
                source,
                args.repeat,
            )
            libxslt_seconds = bench_libxslt(
                stylesheet,
                source,
                args.repeat,
            )
            results.append((name, xmlz_seconds, libxslt_seconds))

    print(
        "XSLT workloads: %d rows, %.1f MiB, %d iterations"
        % (args.rows, size / (1024 * 1024), args.repeat)
    )
    print("| Workload | Engine | Total (s) | Per transform (ms) |")
    print("| --- | --- | ---: | ---: |")
    for name, xmlz_seconds, libxslt_seconds in results:
        print(
            "| %s | xmlz | %.3f | %.2f |"
            % (name, xmlz_seconds, xmlz_seconds * 1000 / args.repeat)
        )
        if libxslt_seconds is None:
            print("| %s | libxslt (lxml) | skipped | lxml is not installed |" % name)
        else:
            print(
                "| %s | libxslt (lxml) | %.3f | %.2f |"
                % (
                    name,
                    libxslt_seconds,
                    libxslt_seconds * 1000 / args.repeat,
                )
            )
    return 0


if __name__ == "__main__":
    sys.exit(main())
