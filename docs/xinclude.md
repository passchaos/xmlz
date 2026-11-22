# XInclude

`xmlz.xinclude.process` expands XInclude 1.0 elements in a parsed document:

```zig
var document = try xmlz.dom.Document.parse(allocator, source, .{});
defer document.deinit();

var expanded = try xmlz.xinclude.process(allocator, &document, .{
    .base = "file:///docs/main.xml",
    .resolver = .{ .context = &resolver, .load = load },
});
defer expanded.deinit();
```

The resolver receives `(context, href, base)` and returns a `Resource` with the
resolved URI and bytes, or null when the resource is unavailable.

## Supported

- `xi:include` with `parse="xml"` (default) and `parse="text"`.
- `xi:fallback` when the resource is missing, malformed, circular, or exceeds
  the depth limit.
- Nested inclusions with a shared resolver and base URI tracking.
- `xml:base` on the include element, its ancestors, and the included document's
  root is applied to href resolution; fallback content inherits the base.
- Circular-inclusion detection and configurable depth/inclusion limits.
- Namespace declarations from the included document's root are inherited by its
  first-level children.

## Limitations

- XPointer is rejected (`error.UnsupportedXPointer`).
- `parse="text"` treats the resource as UTF-8 text; the XInclude `encoding`
  attribute is not consulted.
- The included XML is parsed with the standard parser (well-formedness and
  namespace checking), without external entity resolution.
