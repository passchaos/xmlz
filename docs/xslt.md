# XSLT 1.0

`xmlz.xslt` compiles XSLT 1.0 stylesheets and applies them to a source DOM,
producing a result DOM that can be serialized with the XML writer.

```zig
var stylesheet_document = try xmlz.dom.Document.parse(allocator, stylesheet, .{});
defer stylesheet_document.deinit();
var source_document = try xmlz.dom.Document.parse(allocator, source, .{});
defer source_document.deinit();

var result = try xmlz.xslt.transform(
    allocator,
    &stylesheet_document,
    &source_document,
    .{ .parameters = &.{
        .{ .name = "mode", .value = .{ .string = "full" } },
    } },
);
defer result.deinit();

const output = try result.toOwnedSlice(allocator);
defer allocator.free(output);
```

A stylesheet can also be compiled once and applied repeatedly:

```zig
var stylesheet = try xmlz.xslt.parse(allocator, &stylesheet_document);
defer stylesheet.deinit();

var result = try xmlz.xslt.apply(&stylesheet, &source_document, .{});
defer result.deinit();
```

## Supported

- Template rules with `match`, `name`, `mode`, `priority`, and the XSLT 1.0
  default priority rules.
- `xsl:apply-templates` (with `select`, `mode`, `with-param`, and `xsl:sort`),
  `xsl:call-template`, and built-in template rules.
- `xsl:for-each`, `xsl:if`, `xsl:choose`/`xsl:when`/`xsl:otherwise`.
- `xsl:value-of`, `xsl:text`, `xsl:copy`, `xsl:copy-of`, `xsl:comment`, and
  `xsl:processing-instruction`.
- `xsl:element` and `xsl:attribute` with attribute value templates for names
  and namespace URIs.
- Literal result elements, attribute value templates, namespace copying,
  `exclude-result-prefixes`, and `extension-element-prefixes` filtering.
- Local and global variables and parameters, including caller-supplied global
  parameters.
- `xsl:number` with a `value` expression, and same-name sibling numbering
  otherwise.
- `xsl:output` methods `xml` and `text`, `omit-xml-declaration`, `indent`, and
  `version`. Result serialization is always UTF-8.
- The XSLT `current()` function in expressions and predicates.

Match patterns are translated into XPath selectors and evaluated once against
the source document. This reuses the full XPath engine, including `//`,
predicates, attribute axes, and namespace-aware name tests, and gives XSLT
template priority its specified default behavior.

## Limitations

- `xsl:include`, `xsl:import`, `xsl:apply-imports`, `xsl:key`, `xsl:attribute-set`,
  `xsl:decimal-format`, `xsl:namespace-alias`, and `xsl:strip-space` /
  `xsl:preserve-space` are not implemented.
- Result tree fragments in variables are stored as strings; node-set operations
  on them are not supported.
- `disable-output-escaping`, `cdata-section-elements`, and DOCTYPE output are
  not emitted, and `xsl:output encoding` is recorded but not transcoded (the
  result is always UTF-8).
- The `html` output method is serialized as XML without a declaration; HTML
  void-element and raw-text rules are not implemented.
- `xsl:number` `count`, `from`, `level="multiple"`, and `level="any"` are not
  implemented.
- `format-number`, `key`, `document`, `generate-id`, `system-property`,
  `element-available`, and `function-available` are not available in
  expressions.
- Template conflict resolution uses a single import precedence; imported
  stylesheets are not supported.

## Differential verification

```sh
zig build xslt-diff
```

The step compares the result tree against libxslt through Python `lxml` for
templates, modes, parameters, sorting, copy instructions, namespaces, AVTs,
patterns, priorities, comments/PIs, and text output. Expected output:

```text
35/35 XSLT differential checks passed
```
