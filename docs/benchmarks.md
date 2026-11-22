# Benchmarks

Reproduce with:

```sh
zig build bench
```

The step generates a deterministic 16 MiB SVG-like document and runs each
parser in its own process. Every row reports the best of five timed iterations
after one warm-up. File reading is outside the timed region. Peak RSS is
`getrusage(RUSAGE_SELF).ru_maxrss`.

## Results (2026-11-22)

Platform: Ubuntu 24.04, x86-64, Zig 0.16.0, system expat, pugixml, and
libxml2.

| Parser | Mode | MB/s | Peak RSS |
| --- | --- | ---: | ---: |
| xmlz | pull, no namespaces | 751.65 | 17 MiB |
| xmlz | pull, namespaces | 681.38 | 17 MiB |
| xmlz | DOM, namespaces | 268.05 | 107 MiB |
| expat | SAX | 154.73 | 33 MiB |
| libxml2 | reader | 132.67 | 340 MiB |
| libxml2 | DOM | 70.21 | 340 MiB |
| pugixml | DOM | 536.14 | 87 MiB |

## Interpretation

- The pull parser is the apples-to-apples streaming comparison. xmlz is
  **4.9x faster than expat** and **5.1x faster than libxml2's reader** while
  performing full XML 1.0 and namespace well-formedness checking.
- The DOM is fully validating and namespace-aware. pugixml is faster but does
  not enforce every XML well-formedness and namespace constraint, and it uses
  in-situ mutation of the input buffer. xmlz's DOM still beats libxml2's DOM
  by about **3.8x**.
- xmlz's peak RSS includes the input buffer, the tree, decoded text, and
  namespace state. It is within roughly 25% of pugixml on this attribute-heavy
  document.

## Input shape

The generated document contains namespaces, nested groups, many short
attributes, text with entity references, and self-closing elements. The
generator is `bench/gen.zig`; the size target is 16 MiB and the output is
deterministic.
