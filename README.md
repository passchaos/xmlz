# xmlz

A zero-copy XML 1.0 engine in Zig, built for correctness, security, and speed.

xmlz is not a wrapper around an existing parser. It implements the XML 1.0
(Fifth Edition) character, name, markup, DTD, and entity productions directly,
then exposes them through a pull parser and reusable lexical primitives.

## Highlights

- **Zero-copy pull parser.** Names, attribute values, text, CDATA, comments,
  processing instructions, and doctype data borrow the input slice. A normal
  document is tokenized without heap allocation.
- **Full well-formedness checking.** XML declarations, element nesting,
  attribute syntax and duplicate detection, character-reference validity,
  comment/PI rules, `]]>` rejection, root-element rules, and trailing-content
  rules are enforced with byte-accurate error positions.
- **DTD support.** `ELEMENT`, `ATTLIST`, `ENTITY`, and `NOTATION` declarations
  are parsed and validated. Internal and external subsets, internal/external
  parameter entities, conditional `INCLUDE`/`IGNORE` sections, first-declaration
  binding, and the `PE Between Declarations` constraint are implemented.
- **Entity expansion with limits.** Internal and external parsed entities are
  expanded inline as a content stream, with recursion detection, frame limits,
  and bounded output. Unparsed (`NDATA`) entities are rejected where required.
- **Encoding normalization.** UTF-8, UTF-16 LE/BE, UTF-32 LE/BE, ISO-8859-1,
  Windows-1251, Windows-1252, and BOM handling are provided before scanning.
  Declared encodings are validated instead of silently ignored.
- **Namespaces in XML 1.0.** QName validation, binding stacks, reserved
  prefixes, default-namespace rules, duplicate expanded attributes, and
  namespace-aware URI normalization are enforced at pull-parser level.
- **W3C conformance evidence.** The repository ships the W3C XML conformance
  suite and a harness. xmlz passes **2240/2240 applicable tests** across
  XML 1.0 (Fifth Edition), XML 1.1, and Namespaces 1.0/1.1 (see
  `docs/conformance.md`).
- **DOM and writer.** The arena-backed DOM exposes resolved namespaces,
  decoded/normalized values, DTD attribute defaults, child traversal, and text
  content queries. The writer round-trips documents with correct escaping and
  optional safe pretty printing. A mutable `dom_builder.Builder` supports
  programmatic construction with namespace-aware elements and attributes.
- **XPath 1.0.** Location paths, all core axes including `namespace`,
  predicates, operators, variables, and the core function library are
  implemented over the DOM, with namespace-aware name tests and 82/82
  differential checks against libxml2.
- **XInclude 1.0.** `xinclude.process` expands includes with XML/text modes,
  fallback, nested resources, circular detection, namespace inheritance, and
  element-aware `xml:base` resolution.
- **XML Base and xml:id.** `xmlbase.resolve` implements the full RFC 3986
  reference-resolution algorithm, `elementBase` applies `xml:base` along the
  ancestor chain, and `xml:id` matching uses the XML ID whitespace rules.
- **Canonical XML.** `c14n.canonicalize` emits Canonical XML 1.0/1.1 and
  Exclusive XML Canonicalization 1.0 forms with specification namespace and
  attribute ordering, redundant-declaration suppression, and exact escaping,
  with 69/69 differential checks against libxml2.
- **XSLT 1.0.** `xslt.transform` compiles templates, modes, parameters,
  variables, sorting, copy instructions, AVTs, and the core instruction set,
  reusing the XPath engine for match patterns and expressions, with 35/35
  differential checks against libxslt.
- **XML Schema 1.0.** `xsd.parse` compiles schema documents and
  `xsd.validate` checks instances against particles, attributes, simple and
  complex content, wildcards, built-in datatypes, facets, and `xsi:type` /
  `xsi:nil`, with 152/152 differential checks against libxml2.
- **SAX-style callbacks.** `sax.parse` adapts the pull parser to start/end,
  characters, CDATA, comment, PI, doctype, and declaration callbacks, with
  synthetic end events for self-closing elements.
- **Optional DTD validation.** Content models, attribute types/defaults,
  required/fixed values, ID/IDREF rules, entity/notation references, root type,
  standalone declaration effects, and PE nesting are checked over the DOM. The
  validation pass is separate from the non-validating pull parser.
- **Legacy primitives preserved.** The allocation-free tag/attribute scanners
  extracted from `zsvg` remain available and are used by the pull parser's
  fast paths.
- **Measured performance.** On a 16 MiB SVG-like document the pull parser
  reaches 652 MB/s (587 MB/s with namespaces) and 824 MB/s in opt-in trusted
  mode, 5.3x faster than expat and 6.1x faster than libxml2's reader; see
  `docs/benchmarks.md`.

## Status

| Area | State |
| --- | --- |
| XML 1.0 core + DTD | Complete, W3C suite green |
| DTD validation | Complete, W3C validity tests green |
| XML 1.1 | Complete, W3C suite green |
| Namespaces 1.0 / 1.1 | Complete, W3C suite green |
| DOM tree | Complete |
| DOM builder | Complete |
| Writer/serializer | Complete |
| XPath 1.0 | Complete (all axes, core library, differential checks) |
| XInclude 1.0 | Complete (XML/text, fallback, nesting, xml:base) |
| Canonical XML | Complete (C14N 1.0/1.1, exclusive; whole documents) |
| XML Base / xml:id | Complete (RFC 3986 resolution, base chains, ID normalization) |
| XSLT 1.0 | Core engine (templates, modes, params, sorting, copy, AVTs) |
| XML Schema 1.0 | Core validation (structures, datatypes, facets, wildcards) |

## Quick start

```zig
const std = @import("std");
const xmlz = @import("xmlz");

pub fn main() !void {
    const source = "<svg width=\"10\"><rect fill=\"red\"/></svg>";
    var parser = xmlz.parser.Parser.init(source, .{});
    defer parser.deinit();

    while (try parser.next()) |event| {
        switch (event) {
            .start_element => |element| {
                std.debug.print("element {s}\n", .{element.name});
                for (element.attrs) |attr| {
                    std.debug.print("  {s} = {s}\n", .{ attr.name, attr.value });
                }
            },
            .text => |text| std.debug.print("text {s}\n", .{text}),
            else => {},
        }
    }
}
```

To resolve external DTDs or parsed entities, provide an allocator and a
resolver:

```zig
var parser = xmlz.parser.Parser.init(source, .{
    .allocator = allocator,
    .resolver = .{
        .context = &my_context,
        .resolve = myResolve,
    },
});
defer parser.deinit();
```

The resolver owns the returned bytes and must keep them valid for the parser's
lifetime. Without a resolver, external references remain declared-but-opaque
and external subsets are not read.

## Programmatic documents

```zig
var builder = try xmlz.dom_builder.Builder.init(allocator);
defer builder.deinit();

const root = try builder.createElement("svg");
try builder.setAttribute(root, "width", "10");
const rect = try builder.createElement("rect");
try builder.setAttribute(rect, "x", "1");
try builder.appendChild(root, rect);
try builder.appendChild(builder.document(), root);

var document = try builder.finish();
defer document.deinit();
```

After `finish` the document owns the builder arena; the builder must not be
used again. Namespace-aware creation is available through `createElementNs`
and `setAttributeNs`.

## Trusted fast mode

`Parser.Options.trusted = true` skips character, name, duplicate-attribute,
and namespace-constraint validation for inputs the caller has already verified.
It is intended for trusted internal pipelines and never affects the default
validating behavior or the conformance suite.

## XML 1.1

The parser detects `version="1.1"`, normalizes NEL and LINE SEPARATOR line
ends, enforces XML 1.1 restricted-character rules, and allows earlier-version
external entities inside a 1.1 document. The writer emits the document version
and escapes restricted characters as numeric references.

## Security defaults

- Undeclared entity references are rejected unless the document has an external
  subset or internal parameter-entity references (the XML 1.0 `Entity Declared`
  rule) or the caller opts into permissive mode.
- Entity expansion has frame, recursion, expansion-count, and output-byte
  limits.
- Element depth and attributes-per-element limits are enforced.
- External entities are never fetched unless the caller installs a resolver.
- `NDATA` (unparsed) entity references are rejected in content.

## Repository layout

```
src/parser.zig          pull parser, DTD, entity frames
src/sax.zig             callback facade over the pull parser
src/chars.zig           XML Char / Name productions and scanners
src/entities.zig        entity tables and reference decoding
src/encoding.zig        byte-encoding detection and normalization
src/markup.zig          quote-aware tag/declaration end scanners
src/character_data.zig  character-data spans with CDATA provenance
src/dom.zig             arena-backed document tree
src/dom_builder.zig     programmatic document construction
src/validation.zig      optional DTD validity checking
src/writer.zig          XML serializer
src/c14n.zig            Canonical XML 1.0/1.1 and exclusive C14N
src/xinclude.zig        XInclude 1.0 processing
src/xmlbase.zig         XML Base resolution and xml:id normalization
src/xpath/              XPath 1.0 lexer, parser, AST, evaluator
src/xslt/               XSLT 1.0 stylesheet compiler and transformer
src/xsd/                XML Schema datatypes, regex, compiler, validator
src/namespace.zig       Namespaces in XML 1.0 resolver
src/root.zig            public API surface
tools/conformance.zig   W3C suite harness
bench/                  reproducible benchmarks
tools/gen_xmlconf_manifest.py
testdata/xmlconf        W3C XML conformance suite + generated manifest
```

## Architecture

See `docs/architecture.md` for the layer map, DTD model, trusted-mode
trade-offs, and testing strategy.

## Test

```sh
zig build test          # unit tests
zig build conformance   # W3C XML conformance suite
zig build check         # both
zig build bench         # parser/DOM benchmarks vs expat, pugixml, libxml2
zig build xpath-diff    # XPath differential checks vs libxml2 xmllint
zig build c14n-diff     # canonicalization differential checks vs libxml2
zig build xslt-diff     # XSLT differential checks vs libxslt (needs lxml)
zig build xsd-diff      # XML Schema differential checks vs libxml2 (needs lxml)
zig build test          # includes deterministic mutation/fuzz smoke tests
```

The conformance step needs `testdata/xmlconf/manifest.json`. Regenerate it with:

```sh
python3 tools/gen_xmlconf_manifest.py testdata/xmlconf testdata/xmlconf/manifest.json
```

## Design notes

The parser keeps its hot path allocation-free by storing open-element names and
attributes in fixed inline arrays. Allocations are used only when a document
actually needs parameter-entity expansion, external subsets, or external parsed
entities; those allocations live in a per-parser arena released by `deinit()`.

Text scanning uses a 16-byte vectorized search for `<`, `&`, and `]`. Attribute
lookups use a bounded hash list, and the legacy scanner APIs remain available
for consumers that only need tag extents or one attribute.
