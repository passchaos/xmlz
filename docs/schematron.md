# Schematron

`xmlz.schematron` compiles ISO Schematron schemas and validates instance
documents. Rule contexts and assertion tests use the built-in XPath 1.0
engine.

## API

```zig
var schema_document = try xmlz.dom.Document.parse(allocator, schema_xml, .{});
defer schema_document.deinit();
var schema = try xmlz.schematron.parse(allocator, &schema_document);
defer schema.deinit();

var instance_document = try xmlz.dom.Document.parse(allocator, instance_xml, .{});
defer instance_document.deinit();
var result = try xmlz.schematron.validate(
    &schema,
    allocator,
    &instance_document,
    .{ .phase = "release" },
);
defer result.deinit();
for (result.failures) |failure| {
    // failure.node, failure.pattern_id, failure.kind, failure.message
}
```

## Supported

- ISO namespace `http://purl.oclc.org/dsdl/schematron`.
- `schema`, `ns`, `let`, `pattern`, `rule`, `assert`, `report`, `name`,
  `value-of`, and formatting elements inside messages.
- Rule contexts are XSLT-style patterns (`item`, `item[@kind='a']`, unions,
  `@id`, `text()`); relative contexts are anchored at the document root.
- `sch:ns` prefix declarations, with in-scope `xmlns` declarations as a
  fallback for XPath prefixes.
- Schema, pattern, and rule-level `sch:let` variables; rule-level variables are
  evaluated per context node.
- Phases: `defaultPhase`, `phase`/`active`, and an explicit phase selection.
  Patterns not selected by the phase are skipped.
- Abstract rules with `extends`, and abstract patterns with `is-a` and
  `param` substitution in `context`, `test`, `select`, `path`, and message
  text.
- Message rendering with literal text, `name` (context node or `path`), and
  `value-of`.
- Failed `assert` findings invalidate the document; successful `report`
  findings are recorded but do not affect `isValid()`.

## Limitations

- Diagnostics, properties, and embedded Schematron rules in XML Schema or
  RELAX NG are not supported.
- The generated SVRL report format is not produced; failures are returned as
  structured values.

## Differential verification

```sh
zig build schematron-diff
```

The step compares validity with the ISO Schematron skeleton through lxml for
assertions, reports, contexts, namespaces, lets, phases, message parts, and
XPath functions. Expected output:

```text
30/30 Schematron differential checks passed
```
