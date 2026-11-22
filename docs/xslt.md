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
- `xsl:key` declarations and the `key()` function, including multiple
  declarations with the same name, node-set key values, namespaced match
  patterns, global-variable use, and `key()` in template match patterns.
- `xsl:include` and `xsl:import` through a resolver, import precedence,
  duplicate named-template detection, and `xsl:apply-imports` (including
  `with-param`).
- `xsl:attribute-set` definitions, nested `use-attribute-sets`, application to
  literal result elements and `xsl:element`, and literal-attribute override.
- `xsl:strip-space` / `xsl:preserve-space` name tests, applied through a
  filtered source tree. As in XSLT 1.0 and libxslt, `xml:space` does not
  override these declarations.
- `xsl:number` with `value`, `level="single|multiple|any"`, `count`/`from`
  match patterns, and decimal, zero-padded, alphabetic, and Roman `format`
  tokens.
- `disable-output-escaping` on `xsl:value-of` and `xsl:text`, carried as raw
  text nodes and honored by the XML and HTML serializers.
- `xsl:decimal-format` declarations and `format-number()` patterns: grouping,
  optional and required digits, percent/per-mille scaling, negative
  subpatterns, named formats, and NaN/Infinity rendering.
- Result tree fragments from `xsl:variable`/`xsl:param` bodies: `copy-of`
  copies fragment markup, and string/number/boolean conversions use the
  fragment text.
- `xsl:namespace-alias` for literal result elements and attributes, including
  result-prefix rewriting and namespace declarations.
- `xsl:output` methods `xml`, `html`, and `text`, `omit-xml-declaration`,
  `indent`, and `version`. HTML output uses HTML void elements, minimizes
  common boolean attributes, and keeps `script`/`style` content raw. Result
  serialization is always UTF-8.
- The XSLT `current()` function in expressions and predicates.

Match patterns are translated into XPath selectors and evaluated once against
the source document. This reuses the full XPath engine, including `//`,
predicates, attribute axes, and namespace-aware name tests, and gives XSLT
template priority its specified default behavior.

## Limitations

- XPath node-set operations on result tree fragments (for example `$v/foo`
  or `count($v)`) are not supported; XSLT 1.0 requires an extension for those.
  Fragment markup is supported through `copy-of`.
- `cdata-section-elements` and DOCTYPE output are not emitted, and
  `xsl:output encoding` is recorded but not transcoded (the result is always
  UTF-8).
- HTML output is compact, does not insert a Content-Type `meta` element, and
  does not emit DOCTYPE declarations.
- `document`, `generate-id`, `system-property`, `element-available`, and
  `function-available` are not available in expressions.
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
73/73 XSLT differential checks passed
```
