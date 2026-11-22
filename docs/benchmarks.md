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

## Results (2026-11-22)

Platform: Ubuntu 24.04, x86-64, Zig 0.16.0, system expat, pugixml, and
libxml2.

| Parser | Mode | MB/s | Peak RSS |
| --- | --- | ---: | ---: |
| xmlz | pull, trusted fast mode | 875.82 | 17 MiB |
| xmlz | pull, no namespaces | 590.53 | 17 MiB |
| xmlz | pull, namespaces | 558.08 | 17 MiB |
| xmlz | DOM, trusted fast mode | 428.47 | 111 MiB |
| xmlz | DOM, namespaces | 332.40 | 111 MiB |
| xmlz | DOM, reusable arena | 404.88 | 111 MiB |
| expat | SAX | 154.86 | 33 MiB |
| libxml2 | reader | 134.81 | 340 MiB |
| libxml2 | DOM | 71.49 | 340 MiB |
| pugixml | DOM | 520.21 | 87 MiB |

## Interpretation

- The pull parser is the apples-to-apples streaming comparison. With
  namespaces xmlz is **3.6x faster than expat** and **4.1x faster than
  libxml2's reader** while performing full XML 1.0/1.1 and namespace
  well-formedness checking; trusted mode is **5.7x** and **6.5x** faster.
- `trusted` mode assumes the input is already well-formed and skips character,
  name, duplicate-attribute, and namespace-constraint validation. It is opt-in
  and never used for the conformance suite.
- The DOM is fully validating and namespace-aware. pugixml is faster but does
  not enforce every XML well-formedness and namespace constraint, and it uses
  in-situ mutation of the input buffer. xmlz's DOM beats libxml2's DOM by
  over **4x** in this run (libxml2's DOM row varies between runs), is within
  **1.6x** of pugixml in validating mode, and within **1.3x** in trusted mode.
- `DOM, reusable arena` uses `dom.Document.parseIn` with an arena that is
  reset between parses. It avoids re-faulting fresh pages for every document,
  which matches the steady-state behavior of malloc-based parsers. It reaches
  **405 MB/s** while staying fully validating.
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
