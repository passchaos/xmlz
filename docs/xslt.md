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
- `document()` with resolver caching, percent-decoded local URIs, and
  XPointer `xpointer()`/`element()`/xml:id fragments.
- DTD-aware parsing: the `xslt` CLI parses stylesheets and sources with
  external DTD loading and entity substitution like libxslt, so
  DTD-declared ID attributes, default attribute values, and default
  namespace declarations are visible to `id()` and to templates.
  `document()`-loaded documents use the configured resolver for their
  external subsets.
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

Match patterns are compiled into an inverted index. Simple patterns (`*`,
`name`, `text()`, `@*`, `@name`, ...) are bucketed by node kind and expanded
name. Multi-step patterns and unions (`chapter/title`, `a//b`, `foo|bar`) are
compiled into structural step chains and matched by walking up from the
candidate node, so no document-wide selection is needed. Patterns with
predicates or `id()`/`key()` calls fall back to evaluating the equivalent
XPath selector once per document, and only for documents that are actually
transformed. The index preserves XSLT template priority, import precedence,
and rule order.

Keys and `id()` lookups are indexed per document on first use. Loading a
document with `document()` therefore costs nothing until a node from it is
matched, keyed, or looked up, which matters for large lookup tables (DocBook
localization data, glossaries, symbol tables).

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
libxslt EXSLT suite: 75 passed, 1 failed, 1 skipped
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

libxslt's feature corpora for `documents`, `encoding`, `keys`, `namespaces`,
`numbers`, and `reports` are vendored under `testdata/libxslt-misc`:

```sh
zig build xslt-misc-suite
```

Expected summary:

```text
libxslt misc suite: 27 passed, 1 failed, 0 skipped
```

The tracked difference (`namespaces/extra2.xsl`) asserts xsltproc's
`--debug` template/variable dump, which is not a diagnostic the library
reproduces.

The real-world xmlspec test (transforming the XML 1.0 Second Edition
specification into HTML) is vendored under `testdata/libxslt-xmlspec`:

```sh
zig build xslt-xmlspec-suite
```

Expected summary:

```text
libxslt xmlspec suite: 1 passed, 0 failed
```

Generated `idN` values are normalized before the comparison. The test
exercises external DTD loading, DTD-declared ID and default attributes,
`xsl:strip-space`, imports, `apply-imports`, modes, `id()`, and HTML output.

## Performance

```sh
zig build -Doptimize=ReleaseFast xslt-bench
```

The benchmark parses once and applies the stylesheet in-process repeatedly
for both engines. On a 20 000-row, 3 MiB document (Zig 0.16.0, Ubuntu 24.04,
x86-64):

| Workload | xmlz | libxslt (lxml) |
| --- | ---: | ---: |
| identity transform | 30.8 ms | 51.0 ms |
| sorted report | 28.9 ms | 45.5 ms |

The vendored xmlspec workload (XML 1.0 Second Edition to HTML) is a second
real-world test. It exercises `xsl:number` heavily (`level="any"`,
`level="multiple"`, count/from patterns), `//` paths, and a large result
tree: about 10.8 ms per transform against 11.0 ms for libxslt through lxml
(median of 30 runs).

The real-world DocBook HTML transform (`tests/docbook` from libxslt,
`html/docbook.xsl` over `test/gdp-handbook.xml`, with the full 440 KiB
DocBook 4.1.2 DTD loaded) produces output identical to the libxslt
reference. A full single run takes about 39 ms, including parsing the
source document with its 440 KiB DTD and compiling the 40-file stylesheet
(libxslt's parse+compile+transform is about 44 ms); a repeated in-process
transform takes about 19 ms against 23.5 ms for libxslt through lxml
(median of 30 runs on the same machine).

The hot paths are designed for repeated transforms:

- Template matching uses the inverted index described above. Structural
  patterns never scan a document; predicate patterns are evaluated once per
  document, and documents loaded by `document()` are indexed lazily.
- `xsl:call-template`, global variables, and attribute sets use name
  indexes instead of scanning the stylesheet.
- `xsl:number` count/from patterns are tested with the structural matcher
  when possible; node membership uses a bitmap, and `level="any"` counts
  use binary searches over match sets (or a lazy per-document name index)
  instead of walking the document backwards.
- `//name` paths traverse descendants once and test each node directly,
  including non-positional predicates, instead of materializing every
  descendant and filtering children.
- `xsl:strip-space`/`xsl:preserve-space` declarations are folded into
  per-name lookup tables instead of scanning every rule per element.
- `id()` uses a per-document hash index built from DTD-declared ID
  attributes and `xml:id`, and `key()` indexes each document on first use.
- Single-step XPath paths and forward-axis steps avoid redundant
  allocations, sorting, and deduplication. Variables live on a fixed stack,
  so calling a template no longer copies the caller's bindings.
- Entity declarations use a hashed table allocated on first declaration;
  DocBook's DTD declares thousands of entities, and expansion validates
  each declaration only once.
- DTD element and attribute declarations are indexed for duplicate checks,
  attribute defaults, and external entity expansion. Conditional-section
  and parameter-entity processing copies whole runs of bytes instead of
  working byte by byte, and tracks parameter-entity boundaries as compact
  spans instead of a per-byte id array.
- Documents that declare external parsed entities reserve node and
  attribute storage up front, so a tiny document that expands to tens of
  thousands of nodes does not regrow its DOM arrays repeatedly.

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
  `str:decode-uri`, the `date:*` dates-and-times functions (`date-time`,
  `date`, `time`, year/month/day/week fields, `add`, `add-duration`,
  `difference`, `duration`, `seconds`, and `sum`), `math:max`, `math:min`,
  `math:highest`, `math:lowest`, `math:power`, `math:abs`, `math:sqrt`, and
  `common:object-type` are implemented. The EXSLT regexp, remaining math,
  remaining string functions, crypto, dynamic, and Saxon modules are not
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
