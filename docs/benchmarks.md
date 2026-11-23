# Benchmarks

Reproduce with:

```sh
zig build bench
```

The step generates a deterministic 16 MiB SVG-like document and runs each
parser in its own process. Every row reports the best of five timed iterations
after one warm-up. Each timed region covers parsing plus releasing the parsed
tree, so the comparison includes document lifetime cost. File reading is
outside the timed region. Peak RSS is `getrusage(RUSAGE_SELF).ru_maxrss`.

## Results (2026-11-23)

Platform: Ubuntu 24.04, x86-64 (i9-13900K), Zig 0.16.0, system expat,
pugixml, and libxml2. Each binary was run four times pinned to one P-core and
the best row kept, because the host was shared during measurement.

| Parser | Mode | MB/s | Peak RSS |
| --- | --- | ---: | ---: |
| xmlz | pull, trusted fast mode | 1179.57 | 16 MiB |
| xmlz | pull, no namespaces | 742.36 | 16 MiB |
| xmlz | pull, namespaces | 714.99 | 16 MiB |
| pugixml | DOM | 511.65 | 86 MiB |
| xmlz | DOM, trusted fast mode | 510.44 | 111 MiB |
| xmlz | DOM, reusable arena | 492.10 | 110 MiB |
| xmlz | DOM, namespaces | 388.55 | 110 MiB |
| expat | SAX | 155.94 | 33 MiB |
| libxml2 | reader | 135.28 | 340 MiB |
| libxml2 | DOM | 100.98 | 340 MiB |

## Interpretation

- The pull parser is the apples-to-apples streaming comparison. With
  namespaces xmlz is **4.6x faster than expat** and **5.3x faster than
  libxml2's reader** while performing full XML 1.0/1.1 and namespace
  well-formedness checking; trusted mode is **7.6x** and **8.7x** faster.
- `trusted` mode assumes the input is already well-formed and skips character,
  name, duplicate-attribute, and namespace-constraint validation. It is opt-in
  and never used for the conformance suite.
- The DOM is fully validating and namespace-aware. pugixml is faster but does
  not enforce every XML well-formedness and namespace constraint, and it uses
  in-situ mutation of the input buffer. xmlz's validating DOM beats libxml2's
  DOM by **3.9x** (libxml2's DOM row varies between runs), matches pugixml in
  trusted mode, and is within **1.04x** of it with a reusable arena.
- `DOM, reusable arena` uses `dom.Document.parseIn` with an arena that is
  reset between parses. It avoids re-faulting fresh pages for every document,
  which matches the steady-state behavior of malloc-based parsers. It reaches
  **492 MB/s** while staying fully validating.
- Attribute values, element and attribute names, and literal character data
  are scanned sixteen or thirty-two bytes at a time; text validation is folded
  into the markup-special scan; the tokenizer keeps its cursor in registers
  across a start tag and checks the common `name="value"` and single-space
  separator shapes directly; and the DOM copies attributes in a branch-free
  pass before handling the rare decode/normalization cases.
- Large node and attribute arrays request transparent huge pages on Linux
  (`MADV_HUGEPAGE`, best-effort) to cut first-touch page-fault overhead.
- xmlz's peak RSS includes the input buffer, the tree, decoded text, and
  namespace state. It is within roughly 30% of pugixml on this attribute-heavy
  document and about **3x lower** than libxml2.

## Input shape

The generated document contains namespaces, nested groups, many short
attributes, text with entity references, and self-closing elements. The
generator is `bench/gen.zig`; the size target is 16 MiB and the output is
deterministic.

## Serialization

Reproduce with:

```sh
zig build bench
```

Each engine parses the generated document once and then serializes it six
times into a preallocated `2 * input` byte memory buffer; the best timed
iteration is reported. pugixml loads with `parse_ws_pcdata` and saves with
`format_raw`; libxml2 uses `xmlSaveToBuffer` with `XML_SAVE_NO_DECL`; xmlz
writes the parsed XML declaration. The three outputs are byte-identical apart
from the newline xmlz emits after the declaration (16,778,022 bytes versus
16,778,021), so every engine moves the same payload.

## Results (2026-11-23)

Each binary was run six times pinned to one P-core and the best row kept,
because the host was shared during measurement.

| Serializer | MB/s | Peak RSS |
| --- | ---: | ---: |
| xmlz | 1424.25 | 123 MiB |
| pugixml | 1101.91 | 115 MiB |
| libxml2 | 263.95 | 357 MiB |

## Interpretation

- xmlz's writer is **1.3x faster than pugixml** and **5.4x faster than
  libxml2** while still validating XML 1.0 characters and escaping carriage
  returns, which neither comparison engine does.
- Text and attribute values are scanned once: the 32-byte SIMD pass flags
  escape bytes, XML 1.0 control characters, and non-ASCII bytes together, so
  UTF-8 validation no longer needs a separate pass. The median attribute value
  in this document is four bytes, so short values take an inline scalar check
  before falling back to the vector scanner.
- Start tags are assembled directly in the writer's free buffer, copying each
  element name, attribute name, and attribute value exactly once; values that
  need escaping or tags that outgrow the buffer switch to the generic path.
  End tags are written the same way.
- Namespace declarations that repeat an inherited binding are dropped, and the
  hot checks for `xmlns` / `xmlns:prefix` names are length tests rather than
  generic slice comparisons; that change alone cut writer time by about 10%.

## XSLT transformation

Reproduce with:

```sh
zig build -Doptimize=ReleaseFast xslt-bench
```

The benchmark generates a deterministic 3 MiB table document (20,000 rows)
and runs two workloads 20 times each: an identity transform (`xsl:copy` plus
`xsl:apply-templates` for every node) and a sorted report (`xsl:for-each`,
two `xsl:sort` keys, attribute value templates, and `xsl:value-of`). Both
engines parse the source and compile the stylesheet once; the per-transform
column amortizes parsing and serialization over the 20 applications.

## Results (2026-11-23)

| Workload | Engine | Total (s) | Per transform (ms) |
| --- | --- | ---: | ---: |
| identity | xmlz | 0.689 | 34.43 |
| identity | libxslt (lxml) | 1.146 | 57.32 |
| sorted report | xmlz | 0.538 | 26.88 |
| sorted report | libxslt (lxml) | 1.041 | 52.07 |

## Interpretation

- The identity transform is **1.7x faster than libxslt** and the sorted
  report is **1.9x faster**; libxslt is measured through lxml in-process so
  Python call overhead is included. Absolute times move with host load, so
  the ratio is the meaningful comparison.
- Simple match patterns (`*`, name tests, `text()`, `@*`) are tested
  directly against each node instead of precomputing a match set, and child
  iteration no longer materializes node-sets for `apply-templates` without
  `select`.
- The merged source view aliases the parsed arrays until `document()` loads
  another document, copies skip in-scope namespace collection for
  namespace-free inputs, and result node storage is preallocated from the
  source size.
- The source document's non-simple match patterns are indexed once and later
  lookups use a flag instead of a hash-map probe; result children skip the
  ancestor walk when they are freshly created; and string values borrow a
  single text child instead of building a temporary buffer.
- Expression evaluation allocates directly in the transform arena instead
  of creating a per-evaluation arena, and single-step child/attribute name
  tests and simple `xsl:sort` keys use specialized paths.
