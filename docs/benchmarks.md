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
| xmlz | pull, trusted fast mode | 1089.46 | 16 MiB |
| xmlz | pull, no namespaces | 759.07 | 16 MiB |
| xmlz | pull, namespaces | 729.07 | 16 MiB |
| pugixml | DOM | 522.06 | 86 MiB |
| xmlz | DOM, reusable arena | 493.79 | 111 MiB |
| xmlz | DOM, trusted fast mode | 489.10 | 110 MiB |
| xmlz | DOM, namespaces | 390.33 | 110 MiB |
| expat | SAX | 155.79 | 33 MiB |
| libxml2 | reader | 134.94 | 340 MiB |
| libxml2 | DOM | 91.68 | 340 MiB |

## Interpretation

- The pull parser is the apples-to-apples streaming comparison. With
  namespaces xmlz is **4.7x faster than expat** and **5.4x faster than
  libxml2's reader** while performing full XML 1.0/1.1 and namespace
  well-formedness checking; trusted mode is **7.0x** and **8.1x** faster.
- `trusted` mode assumes the input is already well-formed and skips character,
  name, duplicate-attribute, and namespace-constraint validation. It is opt-in
  and never used for the conformance suite.
- The DOM is fully validating and namespace-aware. pugixml is faster but does
  not enforce every XML well-formedness and namespace constraint, and it uses
  in-situ mutation of the input buffer. xmlz's validating DOM beats libxml2's
  DOM by **4.3x** (libxml2's DOM row varies between runs) and is within
  **1.06x** of pugixml with a reusable arena or in trusted mode.
- `DOM, reusable arena` uses `dom.Document.parseIn` with an arena that is
  reset between parses. It avoids re-faulting fresh pages for every document,
  which matches the steady-state behavior of malloc-based parsers. It reaches
  **494 MB/s** while staying fully validating.
- Attribute values, element and attribute names, and literal character data
  are scanned sixteen or thirty-two bytes at a time; the tokenizer keeps its
  cursor in registers across a start tag and checks the common `name="value"`
  and single-space separator shapes directly; and the DOM copies attributes in
  a branch-free pass before handling the rare decode/normalization cases.
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
| identity | xmlz | 0.589 | 29.45 |
| identity | libxslt (lxml) | 1.021 | 51.06 |
| sorted report | xmlz | 0.606 | 30.32 |
| sorted report | libxslt (lxml) | 0.930 | 46.49 |

## Interpretation

- The identity transform is **1.9x faster than libxslt** and the sorted
  report is **1.4x faster**; libxslt is measured through lxml in-process so
  Python call overhead is included.
- Simple match patterns (`*`, name tests, `text()`, `@*`) are tested
  directly against each node instead of precomputing a match set, and child
  iteration no longer materializes node-sets for `apply-templates` without
  `select`.
- The merged source view aliases the parsed arrays until `document()` loads
  another document, copies skip in-scope namespace collection for
  namespace-free inputs, and result node storage is preallocated from the
  source size.
- Expression evaluation allocates directly in the transform arena instead
  of creating a per-evaluation arena, and single-step child/attribute name
  tests and simple `xsl:sort` keys use specialized paths.
