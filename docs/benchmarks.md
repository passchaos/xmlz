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
| xmlz | pull, trusted fast mode | 1149.39 | 17 MiB |
| xmlz | pull, no namespaces | 973.02 | 17 MiB |
| xmlz | pull, namespaces | 905.82 | 17 MiB |
| xmlz | DOM, trusted fast mode, reusable arena | 725.18 | 111 MiB |
| xmlz | DOM, reusable arena | 591.11 | 111 MiB |
| xmlz | DOM, trusted fast mode | 523.79 | 111 MiB |
| pugixml | DOM | 513.52 | 87 MiB |
| xmlz | DOM, namespaces | 444.25 | 111 MiB |
| expat | SAX | 155.44 | 33 MiB |
| libxml2 | reader | 135.16 | 356 MiB |
| libxml2 | DOM | 93.12 | 356 MiB |

## Interpretation

- The pull parser is the apples-to-apples streaming comparison. With
  namespaces xmlz is **5.8x faster than expat** and **6.7x faster than
  libxml2's reader** while performing full XML 1.0/1.1 and namespace
  well-formedness checking; trusted mode is **7.4x** and **8.5x** faster.
- `trusted` mode assumes the input is already well-formed and skips character,
  name, duplicate-attribute, and namespace-constraint validation. It is opt-in
  and never used for the conformance suite.
- The DOM is fully validating and namespace-aware. pugixml does not enforce
  every XML well-formedness and namespace constraint, it uses in-situ
  mutation of the input buffer, and its DOM row loads with `parse_default`,
  which drops the 186,144 whitespace-only text nodes that xmlz retains for
  round-tripping. xmlz's validating DOM beats libxml2's DOM by
  **4.8x** (libxml2's DOM row varies between runs) and beats pugixml with a
  fresh allocator (524 versus 514 MB/s) even though it retains every text node.
  In trusted fast mode with a reusable arena it is **1.41x faster than
  pugixml** (725 versus 514 MB/s); the fully validating namespace-aware
  reusable-arena row is **1.15x faster** than pugixml's non-validating DOM.
- `DOM, reusable arena` uses `dom.Document.parseIn` with an arena that is
  reset between parses. It avoids re-faulting fresh pages for every document,
  which matches the steady-state behavior of malloc-based parsers. It reaches
  **591 MB/s** while staying fully validating.
- Attribute values, element and attribute names, and literal character data
  are scanned sixteen or thirty-two bytes at a time; text validation is folded
  into the markup-special scan; the tokenizer keeps its cursor in registers
  across a start tag and checks the common `name="value"` and single-space
  separator shapes directly; and the DOM copies attributes in a branch-free
  pass before handling the rare decode/normalization cases.
- Name validation uses a 256-entry character-class table with a scalar prefix
  loop and switches to the vector classifier only for names longer than
  sixteen bytes. Ordinary markup names are a handful of bytes, where the
  vector constant setup and mask chain cost more than the table lookups they
  replace; this alone lifted the validating pull parser by about 25% and the
  validating DOM by about 13%.
- The text scanner also records whether a span contains a reference or a
  carriage return, so the DOM builder borrows plain spans instead of rescanning
  them for entity decoding. On a 16 MB single-text-node document that lifts DOM
  parsing from 1.5-2.0 GB/s to 6.3-9.7 GB/s (pugixml: 1.6-1.7 GB/s).
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

## Non-ASCII input

Reproduce with:

```sh
zig build bench-cjk
```

The generator's `cjk` shape emits a deterministic 16 MiB document with ASCII
element and attribute names and CJK attribute values and character data (plus
one `&amp;` per element), which exercises UTF-8 validation and the decoded
text path. The step runs the same engine binaries as `zig build bench` on that
input; the numbers below were measured sequentially, pinned, best of four.

| Engine | Mode | MB/s |
| --- | --- | ---: |
| xmlz | pull, trusted fast mode | 2363.67 |
| pugixml | DOM | 1177.14 |
| xmlz | pull, no namespaces | 1121.87 |
| xmlz | pull, namespaces | 1027.60 |
| xmlz | DOM, trusted fast mode | 836.47 |
| xmlz | DOM, reusable arena | 728.61 |
| xmlz | DOM, namespaces | 575.35 |
| expat | SAX | 309.40 |
| libxml2 | reader | 141.60 |
| libxml2 | DOM | 108.01 |

Serialization on the same input: xmlz **2566.68 MB/s**, pugixml 2030.82,
libxml2 452.01.

- The pull parser is **3.3x faster than expat** and **7.3x faster than
  libxml2's reader** with namespaces enabled while validating UTF-8; trusted
  mode is **7.6x** and **16.7x** faster.
- Serialization is **1.26x faster than pugixml** and **5.68x faster than
  libxml2**; parsed trees skip writer-side UTF-8 revalidation.
- pugixml's non-validating DOM is faster than xmlz's validating one on this
  shape because it neither checks UTF-8 nor copies attribute values out of the
  in-situ buffer. xmlz's validating DOM still beats libxml2's by **5.3x**.

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
| xmlz | 1421.09 | 126 MiB |
| pugixml | 1093.81 | 115 MiB |
| libxml2 | 266.17 | 356 MiB |

## Interpretation

- xmlz's writer is **1.30x faster than pugixml** and **5.3x faster than
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
- Parsed documents record that every character was validated at parse time,
  so the serializer skips re-validating UTF-8. On CJK-heavy documents that
  lifts serialization from about 0.3 GB/s to 2.2-2.8 GB/s (pugixml: 1.9-2.1
  GB/s); the ASCII benchmark pays about 3% for the extra branch and stays
  ahead of both engines.

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
| identity | xmlz | 0.297 | 14.83 |
| identity | libxslt (lxml) | 1.023 | 51.17 |
| sorted report | xmlz | 0.207 | 10.36 |
| sorted report | libxslt (lxml) | 0.881 | 44.03 |

## Interpretation

- The identity transform is **3.5x faster than libxslt** and the sorted
  report is **4.3x faster**; libxslt is measured through lxml in-process so
  Python call overhead is included, and the xmlz column also serializes the
  result while lxml only builds the result tree. Repeated applications reuse
  one arena in the CLI, so a batch does not remap the result tree each time,
  short result strings pack into arena-owned slabs instead of paying one
  allocation each, and simple child selects in `xsl:value-of` and attribute
  value templates read the text directly instead of building node sets.
  Absolute times move with host load, so the ratio is the meaningful
  comparison.
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
