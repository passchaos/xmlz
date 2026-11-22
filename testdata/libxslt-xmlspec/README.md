# libxslt xmlspec regression test

Copied from the libxslt repository's `tests/xmlspec` directory. The
`REC-xml-2e.xsl` stylesheet (importing `diffspec.xsl` and `xmlspec.xsl`)
transforms the XML 1.0 Second Edition specification into HTML. This is a
real-world exercise of DTD loading, DTD-declared ID attributes and default
attributes, `xsl:strip-space`, imports, `apply-imports`, modes, `id()`, and
HTML output.

Licensed under the MIT license; see `COPYING`.

Run with:

```sh
zig build xslt-xmlspec-suite
```

Generated `idN` values differ between engines and are normalized before the
comparison. The corpus's `REC-xml-20001006-review.html` reference is not
used because it predates current libxslt's handling of erratum references
inside the table of contents.
