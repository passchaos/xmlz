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

- `xi:include` with `parse="xml"` (default) and `parse="text"`; XML
  inclusion inserts the resource's document element (as libxml2 does).
- `xpointer` with the `element()` scheme (`element(/1/2)`) and the
  `xpointer()` scheme (an XPath expression). Selected elements are included
  with their in-scope namespaces.
- `xi:fallback` when the resource is missing, malformed, circular, or exceeds
  the depth limit.
- Nested inclusions with a shared resolver and base URI tracking.
- `xml:base` on the include element, its ancestors, and the included document's
  root is applied to href resolution; fallback content inherits the base.
- Circular-inclusion detection and configurable depth/inclusion limits.
- Namespace declarations in scope on an included document element (or an
  XPointer-selected element) are preserved.
- `parse="text"` honors the XInclude `encoding` attribute for UTF-8,
  UTF-16/LE/BE, UTF-32/LE/BE, ISO-8859-1, US-ASCII, Windows-1251, and
  Windows-1252; UTF-8 is the default. Unsupported encodings trigger fallback.

## Limitations

- XPointer schemes other than `element()` and `xpointer()` are rejected
  (`error.UnsupportedXPointer`); XPointer evaluation failures are fatal and do
  not use fallback content.
- The included XML is parsed with the standard parser (well-formedness and
  namespace checking), without external entity resolution.

## Differential verification

```sh
zig build xinclude-diff
```

The step compares expanded documents against libxml2's `xmllint --xinclude`
for XML/text inclusion, fallback, nesting, namespaces, multiple includes, and
both XPointer schemes. Expected output:

```text
8/8 XInclude differential checks passed
```
