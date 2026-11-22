# XML Schema

`xmlz.xsd` compiles XML Schema 1.0 documents and validates instances against
them, collecting all errors with node paths.

```zig
var schema_document = try xmlz.dom.Document.parse(allocator, schema_xml, .{});
defer schema_document.deinit();
var compiled = try xmlz.xsd.parseWithOptions(allocator, &schema_document, .{
    .resolver = .{ .context = &loader, .load = load },
    .base = "file:///schemas/main.xsd",
});
defer compiled.deinit();

var instance = try xmlz.dom.Document.parse(allocator, instance_xml, .{});
defer instance.deinit();
var result = try xmlz.xsd.validate(&compiled, allocator, &instance);
defer result.deinit();

for (result.errors) |validation_error| {
    std.debug.print("{s}: {s}\n", .{
        validation_error.path,
        validation_error.message,
    });
}
```

## Supported

- Global and local `xs:element` / `xs:attribute` declarations, including
  `ref`, `nillable`, `default`, `fixed`, `use`, and `form`.
- Named and anonymous `xs:simpleType` and `xs:complexType` declarations.
- Simple types: `xs:restriction` (built-in or user base), `xs:list`,
  `xs:union`, and the facets `enumeration`, `pattern`, `length`, `minLength`,
  `maxLength`, `minInclusive`, `maxInclusive`, `minExclusive`, `maxExclusive`,
  `totalDigits`, `fractionDigits`, and `whiteSpace`.
- Built-in datatypes: string family (`string`, `normalizedString`, `token`,
  `language`, `Name`, `NCName`, `NMTOKEN(S)`, `ID`, `IDREF(S)`, `ENTITY(IES)`,
  `anyURI`, `QName`, `NOTATION`), numeric types (`decimal`, all integer
  derivations, `float`, `double`), `boolean`, `duration`, the date/time family,
  `hexBinary`, and `base64Binary`.
- Complex content: `xs:sequence`, `xs:choice`, `xs:all`, occurrence ranges,
  `mixed`, `xs:any` / `xs:anyAttribute` wildcards with `##any`, `##other`,
  `##targetNamespace`, `##local`, explicit namespace URI lists, and
  `processContents` skip/lax/strict.
- Global `xs:group` and `xs:attributeGroup` definitions, references, nested
  attribute groups, and circular group detection.
- `xs:include` (including chameleon includes) and `xs:import` through a
  resolver, with per-document namespaces/forms and circular-include detection.
- `xs:redefine` for simple types, complex types, groups, and attribute groups;
  self-references inside a redefinition resolve to the included original.
- `xs:notation` declarations and `xs:NOTATION` value checking against declared
  notation names.
- Substitution groups, including transitive members, abstract head elements,
  member type derivation checks, and `block`/`final` exclusion enforcement.
- Identity constraints: `xs:key`, `xs:unique`, and `xs:keyref`, including
  composite fields, nested selectors, and `refer` resolution.
- `xs:simpleContent` and `xs:complexContent` extension and restriction,
  including attribute inheritance from base types.
- `targetNamespace`, `elementFormDefault`, `attributeFormDefault`, and local
  `form` overrides.
- Instance `xsi:type` (type substitution) with derivation validity and
  `block` enforcement, abstract type rejection, and `xsi:nil`.
- XML Schema regular expressions: branches, groups, classes, ranges,
  `\d \s \w \i \c`, `\p{...}` categories and `\p{Is...}` blocks, and
  quantifiers. Categories and blocks come from generated Unicode 15.0 tables;
  unknown names are rejected at schema compile time. `\s` is exactly
  `[#x20\t\n\r]`, `\d` is `\p{Nd}`, and `\w` is everything outside
  `\p{P}`, `\p{Z}`, and `\p{C}`.
- Duration facets use the XML Schema partial order; incomparable values (such
  as `P1M` and `P30D`) fail relational facets.

## Limitations

- libxml2 2.9.14's `\p{...}` category lookup only recognizes the first
  codepoint of large CJK and Hangul ranges; xmlz follows the Unicode data.
  Differential regex cases therefore cover scripts where libxml2 agrees, and
  CJK/Hangul categories are covered by unit tests.
- Validation does not inject default attribute values into the instance.
- Schema-component validity covers global/local declaration restrictions,
  reference combinations, `xs:all` occurrences, facet applicability and facet
  values, enumeration/default/fixed lexical validity, import namespace rules,
  and identity-constraint selector restrictions. Exhaustive derivation and
  unique-particle-attribution checks are not implemented.

## Differential verification

```sh
zig build xsd-diff
```

The step compiles schemas and validates valid/invalid instances with both xmlz
and libxml2 through Python `lxml`, covering particles, occurrence ranges,
attributes, simple content, extension/restriction, namespaces, wildcards,
`xsi:type`, `xsi:nil`, built-in datatypes, facets, Unicode categories and
blocks, catalog-resolved includes/imports, and invalid schemas that libxml2
rejects. Expected output:

```text
322/322 XSD differential checks passed
```

The `xsd` command accepts `--catalog=FILE`; `xs:include`, `xs:import`, and
`xs:redefine` resolve through the catalog before filesystem lookup.
