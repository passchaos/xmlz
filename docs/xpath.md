# XPath 1.0

xmlz includes a standalone XPath 1.0 engine over the arena DOM.

```zig
var document = try xmlz.dom.Document.parse(allocator, source, .{});
defer document.deinit();

var expression = try xmlz.xpath.Expression.parse(
    allocator,
    "//d:item[@price > 7]/@id",
);
defer expression.deinit();

const namespaces = [_]xmlz.namespace.Binding{
    .{ .prefix = "d", .uri = "urn:default" },
};
var context: xmlz.xpath.Context = .{
    .document = &document,
    .node = .{ .node = 0 },
    .namespaces = &namespaces,
};
var result = try expression.evaluate(allocator, &context);
defer result.deinit();

switch (result.value) {
    .node_set => |nodes| for (nodes) |node| { /* ... */ },
    .string => |text| { /* ... */ },
    .number => |number| { /* ... */ },
    .boolean => |boolean| { /* ... */ },
}
```

## Supported

- Location paths, absolute and relative, with `//` abbreviation.
- Axes: `ancestor`, `ancestor-or-self`, `attribute`, `child`, `descendant`,
  `descendant-or-self`, `following`, `following-sibling`, `parent`,
  `preceding`, `preceding-sibling`, `self`.
- Node tests: name tests (including `prefix:*`), `node()`, `text()`,
  `comment()`, `processing-instruction('target')`.
- Predicates with position and size context.
- Operators: `or`, `and`, `=`, `!=`, `<`, `<=`, `>`, `>=`, `+`, `-`, `*`,
  `div`, `mod`, unary `-`, and `|`.
- Variables (`$name`) supplied through `Context.variables`.
- Core function library: `last`, `position`, `count`, `local-name`,
  `namespace-uri`, `name`, `string`, `concat`, `starts-with`, `contains`,
  `substring-before`, `substring-after`, `substring`, `string-length`,
  `normalize-space`, `translate`, `boolean`, `not`, `true`, `false`, `lang`,
  `number`, `sum`, `floor`, `ceiling`, `round`, `id`.

## Namespace rules

XPath 1.0 name tests use the namespace bindings supplied in
`Context.namespaces`. Unprefixed name tests match names in **no namespace**,
not the document's default namespace. A prefixed name test with no matching
binding returns `error.UndefinedPrefix`.

## Known differences

- The `namespace` axis currently returns an empty node-set. Namespace nodes are
  not represented in the DOM node model.
- `id()` uses the document's `id` and `xml:id` attributes. XPath technically
  requires DTD-declared ID attributes; xmlz's fallback is intentionally
  permissive.
- For the `following` axis on an attribute, xmlz follows the XPath 1.0
  document-order rule (attributes precede the parent's children). libxml2
  places attributes after the parent's subtree. The differential harness
  documents this divergence and excludes that expression.

## Differential verification

```sh
zig build xpath-diff
```

The step runs 65 count/string comparisons against libxml2's `xmllint` on a
shared document. Expected output:

```text
65/65 XPath differential checks passed
```
