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
  match patterns, decimal, zero-padded, alphabetic, and Roman `format`
  tokens, and `grouping-separator`/`grouping-size`.
- `disable-output-escaping` on `xsl:value-of` and `xsl:text`, carried as raw
  text nodes and honored by the XML and HTML serializers.
- `xsl:decimal-format` declarations and `format-number()` patterns: grouping,
  optional and required digits, percent/per-mille scaling, negative
  subpatterns, named formats, and NaN/Infinity rendering.
- Result tree fragments from `xsl:variable`/`xsl:param` bodies: `copy-of`
  copies fragment markup, and string/number/boolean conversions use the
  fragment text.
- The EXSLT `exsl:node-set()` function, converting result tree fragments into
  node-sets in the shared document view. Conversions are cached per fragment,
  and converted nodes participate in template matching.
- `xsl:namespace-alias` for literal result elements and attributes, including
  result-prefix rewriting and namespace declarations.
- XSLT-specific functions `generate-id()`, `system-property()`,
  `element-available()`, and `function-available()`. Generated ids are stable
  within a transformation and deterministic (`id1`, `id2`, ...).
- `document()` through the `Options` resolver, with per-URI caching,
  `document('')` returning the principal stylesheet document, relative URI
  resolution against the stylesheet base (or an `xml:base` from the optional
  second argument), and template matching for nodes from loaded documents.
- `key()` and `id()` are scoped to the document containing the context node,
  including documents loaded by `document()`.
- `unparsed-entity-uri()` for unparsed entities declared in the source DTD.
- `xsl:output` methods `xml`, `html`, and `text`, `omit-xml-declaration`,
  `indent`, and `version`, `cdata-section-elements` (with `]]>` splitting),
  and `doctype-public`/`doctype-system` for XML and HTML output. HTML output
  uses HTML void elements, minimizes common boolean attributes, and keeps
  `script`/`style` content raw. `encoding` transcodes to UTF-8, UTF-16
  (with BOM), UTF-16LE/BE, ISO-8859-1, US-ASCII, and Windows-1252, emitting
  decimal character references for unrepresentable characters; unknown
  encodings fall back to UTF-8.
- The XSLT `current()` function in expressions and predicates.

Match patterns are translated into XPath selectors and evaluated once against
the source document. This reuses the full XPath engine, including `//`,
predicates, attribute axes, and namespace-aware name tests, and gives XSLT
template priority its specified default behavior.

## libxslt regression suite

The libxslt `tests/general` corpus is vendored under
`testdata/libxslt-general` and run with:

```sh
zig build xslt-suite
```

Each stylesheet is applied to its companion document and compared with the
reference output (structurally for XML, exactly for text). The current
baseline is **205 passed, 0 known differences, 28 include-only skips**.
Known differences are tracked in `tools/libxslt_suite.py`; unexpected
failures or newly fixed tests fail the gate.

The libxslt EXSLT corpus (`tests/exslt`) is vendored under
`testdata/libxslt-exslt` for the implemented modules:

```sh
zig build xslt-exslt-suite
```

Expected summary:

```text
libxslt EXSLT suite: 47 passed, 1 failed, 0 skipped
```

The single tracked difference (`common/object-type.1.xsl`) requires the
Saxon extension module, whose `saxon:expression()` returns an opaque
external value.

The libxslt REC corpus (`tests/REC` and `tests/REC2`, the examples from the
XSLT 1.0 specification) is vendored under `testdata/libxslt-rec`:

```sh
zig build xslt-rec-suite
```

Expected summary:

```text
libxslt REC suite: 79 passed, 1 failed, 3 skipped
```

The single tracked difference (`REC/test-10-3.xsl`) needs locale-aware
collation; libxslt skips it when the C library lacks locale support.

## Limitations

- XPath node-set operations directly on result tree fragments require the
  EXSLT `exsl:node-set()` extension; after conversion, normal node-set
  operations and template matching work.
- EXSLT `func:function` user-defined functions are supported (including
  recursion, parameter defaults, and `func:result` values/fragments);
  `libxslt:node-set` is accepted as an alias of `exsl:node-set`.
  `set:distinct`, `set:intersection`, `set:difference`, `set:has-same-node`,
  `set:leading`, `set:trailing`, `str:replace`, `str:tokenize`,
  `str:split`, `str:concat`, `str:padding`, `str:align`, `str:encode-uri`,
  `str:decode-uri`, `date:add`, `math:max`, `math:min`, `math:highest`,
  `math:lowest`, `math:power`, `math:abs`, `math:sqrt`, and
  `common:object-type` are implemented. The EXSLT regexp, remaining math,
  remaining string/date, crypto, dynamic, and Saxon modules are not
  implemented.
- Global variables are evaluated lazily on first use, so globals can
  reference each other in any order, including through templates applied
  from a global's body.
- Result tree fragments keep their type (`exsl:object-type` reports `RTF`)
  but act as node-sets in node-set contexts, matching libxslt. Parameters
  are passed through the built-in template rules like libxslt.
- Extension elements designated by `extension-element-prefixes` process
  `xsl:fallback` children; libxslt's built-in `test` extension element is
  also recognized.
- XHTML output inserts libxslt's Content-Type meta element when the output
  doctype identifies an XHTML DTD.
- `function-available()` reports XSLT functions in the XSLT namespace as
  available, as required by XSLT 1.0; libxslt reports them as unavailable
  unless registered as extensions.

## Differential verification

```sh
zig build xslt-diff
```

The step compares the result tree against libxslt through Python `lxml` for
templates, modes, parameters, sorting, copy instructions, namespaces, AVTs,
patterns, priorities, comments/PIs, text output, and catalog-resolved
includes. Expected output:

```text
87/87 XSLT differential checks passed
```

The `xslt` command accepts `--catalog=FILE`; includes, imports, and
`document()` calls resolve through the catalog before filesystem lookup.
