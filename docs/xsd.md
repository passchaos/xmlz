# XML Schema

`xmlz.xsd` compiles XML Schema 1.0 documents and validates instances against
them, collecting all errors with node paths.

```zig
var schema_document = try xmlz.dom.Document.parse(allocator, schema_xml, .{});
defer schema_document.deinit();
var compiled = try xmlz.xsd.parse(allocator, &schema_document);
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
  `##targetNamespace`, and `##local`, and `processContents` skip/lax/strict.
- Global `xs:group` and `xs:attributeGroup` definitions, references, nested
  attribute groups, and circular group detection.
- Substitution groups, including transitive members and abstract head
  elements.
- Identity constraints: `xs:key`, `xs:unique`, and `xs:keyref`, including
  composite fields, nested selectors, and `refer` resolution.
- `xs:simpleContent` and `xs:complexContent` extension and restriction,
  including attribute inheritance from base types.
- `targetNamespace`, `elementFormDefault`, `attributeFormDefault`, and local
  `form` overrides.
- Instance `xsi:type` (type substitution) and `xsi:nil`.
- XML Schema regular expressions: branches, groups, classes, ranges,
  `\d \s \w \i \c`, `\p{...}` categories, and quantifiers.

## Limitations

- `xs:include`, `xs:import`, `xs:redefine`, and `xs:notation` are not
  implemented.
- Abstract types and `block`/`final` enforcement are not implemented.
- Substitution group members are not checked for valid type derivation from
  the head.
- `xsi:type` is used without checking that the named type is validly derived
  from the declared type.
- Wildcard namespace lists (as opposed to the `##` tokens) are not supported.
- Unicode category coverage in `\p{...}` is approximate for non-ASCII scripts.
- Duration ordering is a partial order; facets on durations use a simplified
  comparison.
- Validation does not inject default attribute values into the instance.
- Schema component validity checking is intentionally partial; malformed
  schemas are rejected, but not every XSD constraint on schema documents is
  enforced.

## Differential verification

```sh
zig build xsd-diff
```

The step compiles schemas and validates valid/invalid instances with both xmlz
and libxml2 through Python `lxml`, covering particles, occurrence ranges,
attributes, simple content, extension/restriction, namespaces, wildcards,
`xsi:type`, `xsi:nil`, built-in datatypes, and facets. Expected output:

```text
189/189 XSD differential checks passed
```
