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
  fallback, nested resources, circular detection, namespace inheritance,
  element-aware `xml:base` resolution, and the XPointer `element()` and
  `xpointer()` schemes and ID selection, with 12/12 differential checks
  against libxml2 (including catalog-aware resolution).
- **XML Base and xml:id.** `xmlbase.resolve` implements the full RFC 3986
  reference-resolution algorithm, `elementBase` applies `xml:base` along the
  ancestor chain, and `xml:id` matching uses the XML ID whitespace rules.
- **Canonical XML.** `c14n.canonicalize` emits Canonical XML 1.0/1.1 and
  Exclusive XML Canonicalization 1.0 forms for whole documents, and
  `c14n.canonicalizeNodes` canonicalizes XPath node-sets with namespace
  propagation plus `xml:base`/`xml:lang`/`xml:space` fixups. Both use
  specification namespace and attribute ordering, redundant-declaration
  suppression, and exact escaping, with 79/79 differential checks against
  libxml2.
- **XSLT 1.0.** `xslt.transform` compiles templates, modes, parameters,
  variables, sorting, copy instructions, AVTs, keys, includes/imports with
  precedence and `apply-imports`, attribute sets, whitespace stripping,
  multi-level `xsl:number` with count/from patterns and number formats,
  `disable-output-escaping`, `format-number()` with decimal formats, result
  tree fragments, namespace aliases, XSLT functions (`generate-id`,
  `system-property`, `element-available`, `function-available`,
  `document()` with resolver caching, `unparsed-entity-uri()`, EXSLT
  `exsl:node-set()`), CDATA
  sections, DOCTYPE declarations, HTML output, and output encodings,
  and the core instruction set. Match patterns compile into an inverted
  index that matches structural patterns by walking up from each candidate
  node, while predicate patterns and `id()`/`key()` fall back to the XPath
  engine; keys, `id()` values, and loaded documents are indexed lazily.
  Identity and sorted-report transforms run faster than libxslt, and the
  real-world DocBook HTML transform matches libxslt's output. There are
  87/87 differential checks against libxslt (including
  catalog-aware includes and `document()`), the complete libxslt general
  regression suite (`zig build xslt-suite`, 205 passed with no tracked
  differences), the libxslt EXSLT corpus (`zig build xslt-exslt-suite`,
  75 passed with one Saxon-module test tracked), the libxslt REC corpus
  (`zig build xslt-rec-suite`, 79 passed with one locale-collation test
  tracked), and libxslt's feature corpora (`zig build xslt-misc-suite`,
  27 passed with one debug-dump test tracked), and the real-world xmlspec
  transform. EXSLT `func:function`
  user-defined functions, `libxslt:node-set`, the `set:*` node-set
  functions, `str:replace`, `str:tokenize`, `str:split`, `str:concat`,
  `str:padding`, `str:align`, `str:encode-uri`, `str:decode-uri`, `date:add`,
  `math:max`, `math:min`, `math:highest`, `math:lowest`, `math:power`,
  `math:abs`, `math:sqrt`, the `date:*` dates-and-times module, and
  `common:object-type` are supported; globals
  are evaluated lazily and RTFs keep their type like libxslt. HTML/XHTML
  output matches libxslt's method auto-detection, charset meta elements,
  URI escaping, and formatting.
- **XML Schema 1.0.** `xsd.parse` compiles schema documents and
  `xsd.validate` checks instances against particles, attributes, simple and
  complex content, wildcards, groups, attribute groups, substitution groups,
  identity constraints, includes/imports/redefines, notation declarations,
  built-in datatypes, facets, Unicode 15.0 regex categories and blocks,
  abstract types, `block`/`final`, schema-component validity checks, and
  `xsi:type` / `xsi:nil`, with 328/328 differential checks against libxml2
  (including catalog-aware includes/imports, rejected invalid schemas, and
  embedded Schematron).
- **OASIS XML Catalogs.** `catalog.parse` resolves system/public identifiers
  and URIs through exact entries, rewrites, suffixes, delegates,
  `nextCatalog`, `prefer`, and `xml:base`, with 17/17 differential checks
  against libxml2's `xmlcatalog`; the `xinclude`, `xsd`, `xslt`, and `rng`
  tools consume catalogs via `--catalog=FILE`, falling back from `system` to
  `uri` entries like libxml2.
- **ISO Schematron.** `schematron.parse` compiles schemas and
  `schematron.validate` evaluates rule contexts, assertions, reports,
  diagnostics, properties, lets, namespaces, phases, abstract rules
  (`extends`), and abstract patterns (`is-a` with parameter substitution)
  with the XPath engine, with 42/42 differential checks against the ISO
  skeleton through lxml. `parsePatterns` compiles patterns embedded in RELAX
  NG grammars or XSD `xs:appinfo`, and the `rng`/`xsd` tools run them
  automatically. `writeSvrl` produces SVRL reports with active patterns,
  fired rules, findings, and diagnostic/property references.
- **RELAX NG.** `rng.parse` compiles XML-syntax grammars, `rng.parseCompact`
  parses the compact syntax (including `include`/`external`), and
  `rng.validate` checks instances against
  element/attribute name classes, group, choice, interleave, optional,
  repetition, mixed content, text, empty, data/value (XSD datatype libraries,
  facets, `except`), lists, recursive defines, includes, nested grammars,
  `parentRef`, external references, implicit grouping of multiple content
  children, and embedded Schematron patterns, with 86/86 differential checks
  against libxml2 (including catalog-aware includes) plus 33/33 compact-syntax
  checks.
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
  reaches 969 MB/s (905 MB/s with namespaces) and 1143 MB/s in opt-in trusted
  mode, 5.9x faster than expat and 6.7x faster than libxml2's reader. The
  validating DOM reaches 446 MB/s one-shot, 595 MB/s with a reusable arena
  (`dom.Document.parseIn`), and 518 MB/s in trusted mode — 4.4x faster than
  libxml2's DOM and faster than pugixml; see `docs/benchmarks.md`.

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
| XInclude 1.0 | Complete (XML/text, fallback, nesting, xml:base, XPointer) |
| Canonical XML | Complete (C14N 1.0/1.1, exclusive; whole documents and node-sets) |
| XML Base / xml:id | Complete (RFC 3986 resolution, base chains, ID normalization) |
| XSLT 1.0 | Core engine (templates, modes, params, sorting, copy, AVTs) |
| XML Schema 1.0 | Core validation (structures, datatypes, facets, groups, identity) |
| RELAX NG | XML and compact syntax (patterns, datatypes, includes, external refs) |
| ISO Schematron | Core rules, assertions/reports, lets, namespaces, phases, abstract patterns/rules |
| XML Catalogs | System/public/URI resolution, rewrites, delegates, next catalogs |

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
src/rng/                RELAX NG schema parser and validator
src/schematron/         ISO Schematron compiler and validator
src/catalog.zig         OASIS XML Catalogs resolution
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
zig build xslt-suite    # libxslt general regression suite (needs lxml)
zig build xslt-exslt-suite # libxslt EXSLT regression suite (needs lxml)
zig build xslt-rec-suite   # libxslt REC (XSLT specification) suite (needs lxml)
zig build xslt-misc-suite  # libxslt documents/keys/namespaces/numbers suite (needs lxml)
zig build xslt-xmlspec-suite # real-world XML 1.0 spec to HTML transform
zig build -Doptimize=ReleaseFast xslt-bench # XSLT throughput vs libxslt (needs lxml)
zig build xsd-diff      # XML Schema differential checks vs libxml2 (needs lxml)
zig build rng-diff      # RELAX NG differential checks vs libxml2 (needs lxml)
zig build rng-compact-diff # RELAX NG compact syntax checks vs XML twins (needs lxml)
zig build xinclude-diff # XInclude checks vs libxml2 xmllint
zig build schematron-diff # ISO Schematron checks vs the ISO skeleton (needs lxml)
zig build catalog-diff   # OASIS XML Catalogs checks vs libxml2 xmlcatalog
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
