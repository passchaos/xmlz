# DTD Validation

Well-formedness is always enforced by the parser. DTD validity checking is an
optional second pass over the DOM:

```zig
var document = try xmlz.dom.Document.parse(allocator, source, .{});
defer document.deinit();

const dtd = document.dtd orelse return;
const issues = try xmlz.validation.validate(allocator, &document, dtd);
defer allocator.free(issues);

if (issues.len != 0) {
    for (issues) |issue| {
        // issue.kind, issue.node, issue.attribute, issue.name
    }
}
```

`validateWithOptions` accepts `.{ .strict_element_content = true }` to reject
whitespace character data in element-only content. The default is lenient,
matching libxml2 and common real-world XML.

## Implemented constraints

- Element declarations and content models: `EMPTY`, `ANY`, mixed content, and
  recursive sequence/choice models with `?`, `*`, and `+`.
- Attribute declarations: required/fixed/default values, CDATA, ID, IDREF,
  IDREFS, ENTITY, ENTITIES, NMTOKEN, NMTOKENS, NOTATION, and enumerations.
- Attribute default legality, including the distinction between syntactic
  errors (always invalid) and referential errors (only invalid when the default
  is actually used).
- ID uniqueness, IDREF resolution, and namespace-aware NCName rules for ID and
  IDREF values.
- Unparsed entity and notation references.
- Root element type matching the DOCTYPE name.
- Duplicate element and notation declarations, duplicate enumeration names,
  and duplicate names in mixed-content models.
- Standalone document declaration effects: external defaults and external
  declarations that change attribute or whitespace normalization.
- Parameter-entity declaration, group, and conditional-section nesting.
- Undeclared entity references accepted only because of the DTD/PE exception.

## Notes

- Validation needs the parser's DTD view. `Document.parse` stores it in
  `document.dtd`; the slices borrow the document's arena/scratch storage.
- External subsets are loaded when the parser has an allocator and resolver.
  Without a resolver, declarations in external subsets are unavailable and the
  document cannot be fully validated.
- Validity warnings (for example, duplicate attribute declarations across
  multiple `ATTLIST` declarations) are not reported as errors, matching the
  conformance suite and libxml2.
