# OASIS XML Catalogs

`xmlz.catalog` parses [OASIS XML Catalogs 1.1](https://www.oasis-open.org/committees/entity/spec-2007-07-06.html)
and resolves external identifiers and URIs. Referenced catalogs
(`nextCatalog`, delegates) are loaded eagerly through a caller resolver.

## API

```zig
var catalog_document = try xmlz.dom.Document.parse(allocator, catalog_xml, .{});
defer catalog_document.deinit();
var catalog = try xmlz.catalog.parseWithOptions(
    allocator,
    &catalog_document,
    .{
        .resolver = .{ .context = &loader, .load = loadCatalog },
        .base = "file:///etc/xml/catalog",
    },
);
defer catalog.deinit();

const system = catalog.resolveSystem("http://example.org/x.dtd");
const public = catalog.resolvePublic("-//EXAMPLE//DTD X//EN");
const full = catalog.resolve("-//EXAMPLE//DTD X//EN", "http://example.org/x.dtd");
const uri = catalog.resolveUri("http://example.org/schema.xsd");
```

Resolution results are slices owned by the catalog arena; they remain valid
until `Catalog.deinit`. Rewrite and suffix results are allocated on demand.

## Supported

- `catalog`, `group`, `public`, `system`, `uri`, `rewriteSystem`, `rewriteURI`,
  `systemSuffix`, `uriSuffix`, `delegatePublic`, `delegateSystem`,
  `delegateURI`, and `nextCatalog`.
- `prefer="system|public"` on catalogs and groups for external-identifier
  resolution.
- `xml:base` on catalogs, groups, and entries; relative entry URIs are
  resolved against the catalog document base.
- Longest-prefix rewrite selection, longest-suffix suffix selection, public-ID
  whitespace normalization, and delegate/next-catalog traversal with a depth
  guard.
- Missing or unreadable referenced catalogs are skipped.

## Differences from libxml2

`resolve(publicId, systemId)` follows the specification's `prefer` ordering:
with `prefer="public"` a matching public entry wins over a matching system
entry. libxml2's `xmlcatalog resolve` always prefers the system identifier, so
this case is covered by unit tests rather than the differential harness.

## Integration

The `xinclude` tool accepts `--catalog=FILE` and consults the catalog before
filesystem lookup. Other tools can wrap their resolver callbacks the same way:
query `resolveSystem` (or `resolveUri`) and read the returned URI.

## Differential verification

```sh
zig build catalog-diff
```

The step compares resolution results with libxml2's `xmlcatalog` for exact
entries, rewrites, suffixes, `nextCatalog`, delegates, groups, and `xml:base`.
Expected output:

```text
17/17 catalog differential checks passed
```
