# XML Base and xml:id

`xmlz.xmlbase` implements XML Base (Second Edition) URI resolution and the
`xml:id` whitespace rules from XML ID.

```zig
const resolved = try xmlz.xmlbase.resolve(
    allocator,
    "http://example.com/a/index.xml",
    "../b/",
);
defer allocator.free(resolved); // "http://example.com/b/"

const base = try xmlz.xmlbase.elementBase(
    allocator,
    &document,
    element_id,
    "http://example.com/docs/main.xml",
);
defer if (base) |value| allocator.free(value);
```

## Reference resolution

`xmlbase.resolve` implements RFC 3986 section 5.2: scheme, authority, path,
query, and fragment parsing, reference merging, and the `remove_dot_segments`
algorithm. The unit tests cover the complete normal and abnormal example tables
from RFC 3986 section 5.4, including empty references, query-only and
fragment-only references, and excess `..` segments.

## Element base URIs

`xmlbase.elementBase` walks an element's ancestor chain, applies every
`xml:base` attribute from the root down, and resolves each value against the
current base. The optional `document_uri` supplies the retrieval URI of the
document itself. The result is null when neither the document URI nor any
`xml:base` provides a base.

## xml:id

`xmlbase.normalizeId` trims and collapses XML whitespace (`#x20`, `#x9`,
`#xD`, `#xA`) as required for `xml:id` values. `xmlbase.xmlIdEquals` performs
the same comparison without allocating, which is what the XPath `id()`
function uses when matching `xml:id` attributes.

## XInclude integration

`xinclude.process` applies `xml:base` while walking the source document:

- The base passed to the resolver for an `xi:include` href includes any
  `xml:base` on the include element and its ancestors.
- An included document's root `xml:base` becomes the base for nested includes
  in that document.
- Fallback content inherits the base of the include element.

## Verification

Unit tests cover the RFC 3986 example tables, ancestor-chain base resolution,
`xml:id` normalization, and XInclude base propagation. Run them with:

```sh
zig build test
```
