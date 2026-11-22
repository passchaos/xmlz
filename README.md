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
- **Encoding normalization.** UTF-8, UTF-16 LE/BE, UTF-32 LE/BE, Windows-1251,
  and BOM handling are provided before scanning. Declared encodings are
  validated instead of silently ignored.
- **Namespaces in XML 1.0.** QName validation, binding stacks, reserved
  prefixes, default-namespace rules, duplicate expanded attributes, and
  namespace-aware URI normalization are enforced at pull-parser level.
- **W3C conformance evidence.** The repository ships the W3C XML conformance
  suite and a harness. xmlz currently passes **1971/1971 applicable XML 1.0
  and Namespaces 1.0 tests** (the remaining suite entries are XML 1.1; see
  `docs/conformance.md`).
- **Legacy primitives preserved.** The allocation-free tag/attribute scanners
  extracted from `zsvg` remain available and are used by the pull parser's
  fast paths.

## Status

| Area | State |
| --- | --- |
| XML 1.0 core + DTD | Complete, W3C suite green |
| Namespaces in XML | Complete, W3C suite green |
| DOM tree | In progress |
| Writer/serializer | In progress |
| XML 1.1 | Not implemented |
| XPath / XSD / XSLT | Out of scope for the core engine |

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
src/chars.zig           XML Char / Name productions and scanners
src/entities.zig        entity tables and reference decoding
src/encoding.zig        byte-encoding detection and normalization
src/markup.zig          quote-aware tag/declaration end scanners
src/character_data.zig  character-data spans with CDATA provenance
src/root.zig            public API surface
tools/conformance.zig   W3C suite harness
tools/gen_xmlconf_manifest.py
testdata/xmlconf        W3C XML conformance suite + generated manifest
```

## Test

```sh
zig build test          # unit tests
zig build conformance   # W3C XML conformance suite
zig build check         # both
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
