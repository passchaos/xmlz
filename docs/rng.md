# RELAX NG

`xmlz.rng` compiles RELAX NG schemas written in the XML syntax and validates
instance documents against them.

## API

```zig
const xmlz = @import("xmlz");

var schema_document = try xmlz.dom.Document.parse(allocator, schema_xml, .{});
defer schema_document.deinit();
var schema = try xmlz.rng.parse(allocator, &schema_document);
defer schema.deinit();

var instance_document = try xmlz.dom.Document.parse(allocator, instance_xml, .{});
defer instance_document.deinit();
var result = try xmlz.rng.validate(&schema, allocator, &instance_document);
defer result.deinit();
if (!result.isValid()) {
    for (result.errors) |validation_error| {
        // validation_error.node, validation_error.message
    }
}
```

Compact syntax schemas are parsed from UTF-8 text:

```zig
var schema = try xmlz.rng.parseCompact(allocator, compact_source);
defer schema.deinit();
```

Includes and external references use the resolver in `Options`:

```zig
var schema = try xmlz.rng.parseWithOptions(allocator, &schema_document, .{
    .resolver = .{ .context = &loader, .load = loadResource },
    .base = "main.rng",
});
```

## Supported

- `grammar` (including nested grammars used as patterns), `start`, `define`
  (including `combine="choice"` and `combine="interleave"`), `div`, `include`,
  `externalRef`, `ref`, and `parentRef` with scoped define lookup.
- `element` and `attribute` patterns with `name` shorthands, `name`,
  `anyName`, `nsName`, `choice`, and `except` name classes.
- `group`, `interleave`, `choice`, `optional`, `zeroOrMore`, `oneOrMore`,
  `mixed`, `list`, `text`, `empty`, and `notAllowed`.
- `data` and `value` patterns with the XML Schema datatype library
  (`http://www.w3.org/2001/XMLSchema-datatypes`), the compatibility library,
  and the empty library (`string`, `token`), including `except` patterns.
- The compact syntax (`rng.parseCompact`): declarations (`namespace`,
  `default namespace`, `datatypes`), `grammar`/`start`/`define` with
  `=`/`|=`/`&=` combine, nested grammars, `parent`, name classes with
  `*`/`p:*`/`except`, grouping with `,`/`&`/`|`, postfix `?`/`*`/`+`,
  `list`/`mixed`/`text`/`empty`/`notAllowed`, data/value patterns with
  parameters, literal concatenation (`~`), `\x{...}` escapes, quoted
  keywords, comments, annotations, `include` (with overrides and `inherit`),
  and `external`.
- Datatype parameters: `pattern`, `enumeration`, `minInclusive`,
  `maxInclusive`, `minExclusive`, `maxExclusive`, `length`, `minLength`,
  `maxLength`, `totalDigits`, and `fractionDigits`.
- Recursive grammars; nullable and derivative computations are guarded so
  recursive defines terminate.
- Whitespace-only text between child elements is ignored, matching libxml2's
  RELAX NG behavior.

## Limitations

- Unsupported datatype libraries are rejected at schema compile time.
- `notAllowed` inside repetition and other patterns that libxml2 rejects as
  invalid schemas may be accepted; schema-level constraint checking is
  intentionally partial.
- Validation errors report the first failing element only; nested failures are
  not expanded into a full diagnostic tree.

## Differential verification

```sh
zig build rng-diff
```

The step compares validity results against libxml2 through Python `lxml` for
sequences, attributes, choices, repetition, interleave, mixed content, name
classes, namespaces, data/value/list patterns, facets, includes, define
overrides, external references, catalog-resolved includes, and embedded
Schematron patterns. Expected output:

```text
77/77 RELAX NG differential checks passed
```

The `rng` command accepts `--catalog=FILE`; `include` and `externalRef`
resolve through the catalog before filesystem lookup. Multiple pattern
children of an `element` are implicitly grouped (the usual way to combine
attributes with content), and `sch:pattern` elements embedded in the grammar
are validated automatically.

Compact syntax is verified separately against XML-syntax twins:

```sh
zig build rng-compact-diff
```

```text
33/33 RELAX NG compact differential checks passed
```
