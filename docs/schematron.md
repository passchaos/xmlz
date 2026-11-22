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
- Diagnostics: `diagnostics` declarations and `diagnostics` references on
  `assert`/`report`, rendered in the triggering context node and exposed as
  `Failure.diagnostics`. Unknown diagnostic IDs are skipped.
- Properties: `properties` declarations with `id`/`scheme`/`role` and
  `properties` references on `assert`/`report`, exposed as
  `Failure.properties`.
- Failed `assert` findings invalidate the document; successful `report`
  findings are recorded but do not affect `isValid()`.
- Embedded patterns: `parsePatterns` compiles `sch:pattern` elements carried
  by a host schema document, and `findEmbeddedPatterns` collects them
  (optionally restricted to an ancestor such as `xs:appinfo`). The `rng` and
  `xsd` tools run embedded patterns automatically and combine the results
  with grammar/schema validation.

## Limitations
- The generated SVRL report format is not produced; findings are returned as
  structured values. The CLI `--report` mode prints a tab-separated summary
  for differential testing.

## Differential verification

```sh
zig build schematron-diff
```

The step compares validity and rendered findings (messages and diagnostic
references) with the ISO Schematron skeleton through lxml for assertions,
reports, contexts, namespaces, lets, phases, message parts, diagnostics,
properties, and XPath functions. Expected output:

```text
37/37 Schematron differential checks passed
```

Embedded patterns are verified by the RELAX NG and XSD differential steps,
which extract patterns with lxml's `RNG2Schtrn.xsl`/`XSD2Schtrn.xsl` and
compare the combined grammar plus Schematron validity.
