# xmlz

Reusable, allocation-free XML scanning primitives extracted from `../zsvg`.

The package is deliberately semantic-neutral:

- quote-aware tag/declaration end scanning (`markup`)
- permissive tag and attribute scanning (`XmlTag`, `AttributeIterator`, `attrValue`)
- bounded attribute probing (`AttributeList`, `AttributeSet`, caches)
- XML character-data spans with CDATA provenance (`CharacterDataIterator`)
- byte-encoding normalization (`encoding`)
- internal entity expansion with explicit limits (`internal_entities`)

It does not own SVG semantics, namespaces, layout, or rendering. `zsvg` keeps
its SVG-specific namespace context and attribute index as consumers of `xmlz`.

## Usage

```zig
const xmlz = @import("xmlz");

var pos: usize = 0;
while (xmlz.nextTag(source, &pos)) |tag| {
    const href = xmlz.attrValue(tag.attrs, "href");
    _ = href;
}
```

## Test

```sh
zig build test
```
