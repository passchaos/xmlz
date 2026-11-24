# Performance engineering notes

This page records how the hot paths behave and which optimizations were
measured to work or not. It complements `docs/benchmarks.md`, which holds the
competitive numbers; the notes here exist so future work does not repeat
experiments that were already rejected with evidence.

## Measurement method

- Wall-clock A/B runs are interleaved on one pinned core (`taskset -c 2`) and
  reported as the best of several rounds; the host is shared, so absolute
  times move by tens of percent while ratios stay meaningful.
- Retired instructions (`perf stat -e instructions`) are the layout-independent
  metric. They are stable to about 1%, so they decide close calls.
- The `xslt-bench` harness applies the transform 20 times per process, so its
  per-transform column includes about 28% amortized fixed cost (process
  startup, one parse, one compile, one serialization). Steady-state transform
  cost is lower: sorted report ~2.9 ms, identity ~3.5 ms per application.

## Performance model (measured)

| Workload | Instructions per transform | Notes |
| --- | ---: | --- |
| identity (`match="*"`) | ~72 M | ~200 instructions per copied node |
| identity (`@*\|node()`) | ~78 M | 137 instructions per copied attribute |
| sorted report | ~46.5 M | ~2,300 instructions per row |

- The identity transform runs at IPC ≈ 4.8 and the sorted report at IPC ≈ 5.7
  on a ~4 GHz core, so both are instruction-throughput bound: removing
  instructions removes time.
- A parsed `dom.Node` is exactly 64 bytes, one cache line per node, so a child
  visit touches one line. The sibling chain is a dependent load per visit;
  that chain and the one-line node records set the scan floor. Sorted report
  scans touch ~20 MB per transform and are within ~30% of the memory-bandwidth
  floor (~1.0 ms of the 1.28 ms spent in child scans).
- `dom.Attribute` is 32 bytes: two pointer/32-bit-length pairs plus the
  namespace index and flags. The parser rejects inputs above `maxInt(u32)`
  bytes and entity decoding is capped at 8 MiB, so the 32-bit lengths cannot
  truncate a parsed value. A full SVG parse writes ~48 MB of attribute
  records instead of ~60 MB; that write traffic is the DOM floor.
- `parser.Attribute` is 72 bytes but lives in a small per-element scratch
  array that stays in L1, so its size does not affect memory traffic.

## Techniques that work

- **Inline hot leaf helpers** so the per-node path has no out-of-line returns:
  slab string copy, result node creation, text append, simple child selects,
  the short-name comparator. This was the single largest source of wins
  (sorted report −11% from inlining the simple child select alone).
- **Move cold fallbacks out of the hot frame**: the general `evalOwned`
  paths behind `xsl:value-of` and attribute value templates stay `noinline`,
  which shrank the common frame from 472 to 280 bytes (sorted −2.5%).
- **Classify shapes at compile time**: copy bodies are tagged
  `plain_apply` / `identity_select` / `apply` / `instructions`; literal result
  element attributes record the attributes their body declares. Per-node
  field tests become one tag compare.
- **Reserve result storage from compile-time knowledge**: a for-each reserves
  the attributes its literal result elements declare, so the attribute array
  does not double-copy while rows are emitted.
- **Length-dispatched scalar/SIMD scans**: short markup spans use a scalar
  test, long text runs use the vector search (DOM plain-text check: CJK DOM
  −11% instructions).
- **Explicit unaligned vector loads** where LLVM reassembles a 16-byte chunk
  from narrower loads because one byte is already in a register (CJK text
  validator: CJK pull +2.3–2.9%, −1.7% instructions).
- **Fill parser events in place** (`Parser.nextInto`) and write start tags
  directly into the event slot: pull +3% raw, +2% with namespaces.
- **Byte-exact index addressing** in parsed-attribute copies: writing through
  a moving pointer instead of `out[i]` removed a scaled address computation
  (DOM +1.2%).
- **Transparent huge pages for one-shot parse arrays** (`madvise` hint in
  `dom.Builder.run`): best-case SVG DOM 526 MB/s with the hint versus
  372 MB/s without it under the same load. The hint is applied only when the
  reservation is at least 2 MiB.
- **32-byte attribute records**: storing names and values as pointer plus
  32-bit length instead of two 16-byte slices cut the record from 40 to
  32 bytes. On the 16 MiB SVG the DOM peak RSS fell from 85 MiB to
  76-78 MiB and the validating DOM rows were unchanged in instructions. An
  isolated writer run (one parse, sixty serializations, pinned P-core) moved
  from 6.74 G to 6.42 G retired instructions (−4.6%) and from 3.08-3.10 GB/s
  to 3.17-3.22 GB/s. Splitting the writer's raw-adjacent branch from the
  general attribute path kept the pointer/length fields live only where they
  are used; the first attempt that hoisted both slices for every attribute
  added spills and was reverted.
- **Build source DOM nodes in place**: reserve the next node slot with
  `addOneAssumeCapacity` and fill it directly instead of appending a
  64-byte stack temporary. On the 16 MiB SVG the validating DOM rows moved
  from 519-526 MB/s to 548-556 MB/s one-shot and from 626-643 MB/s to
  688-696 MB/s with a reusable arena; retired instructions fell about 0.3%
  and cycles about 7%. The result builder already used this pattern; the
  source DOM builder now matches it for elements and text.
- **Avoid by-value node copies in builder hot paths**: `appendChild` read
  `parent` and `first_child` through a 64-byte `Node` copy just to validate
  the child, and `Builder.attributesOf` copied the node to read its attribute
  range. Reading through pointers cut identity-transform cycles 3-4% and wall
  time about 5% in interleaved runs; the sorted report was unchanged.

## Rejected with evidence

All of these were implemented, measured, and reverted. The common cause is
that the hot functions are already fully inlined and aligned; "removing work"
by restructuring them adds branches or shifts the hot loop out of its
uop-cache slot.

- Replacing `executeCopy`'s two jump tables with direct branches: identity
  +5.6%, identity (attributes) +7.7%.
- Dispatching the lone attribute rule straight to `executeCopy` (skipping
  `applyTemplateNode` → `findTemplate` → `executeTemplate`): **+1.7%
  instructions** — the compiler already inlines that chain, so the shortcut
  only duplicates it.
- Dispatching identity children straight to `executeCopy` from
  `applyTemplateChildren`: identity +4.2%.
- Hoisting `dispatch.active` out of the child loop (split loops): +9.6%.
- `appendChildFresh` (skip validation and detach for fresh nodes), retried
  three times with and without `inline`: +6% to +19%. Removing all
  `appendChild` bounds checks alone is neutral, so validation is not the cost.
- Fusing element creation and linking into one call: +5.2% / +6.9%.
- Skipping the text-merge check in the identity dispatch: +5.5% (unstable).
- Splitting `evaluateAvt`'s cold paths out of line: neutral.
- Extracting namespace collection from `executeCopy`: frame 424 → 376 bytes,
  identity +8.2%.
- Fused multi-key sort scan, child-id cache, sort-key reuse between sort and
  body, batch extraction of literal-element lookups: all slower; the compact
  fused scan reduced instructions 2.7% but ran 4% slower because the separate
  scans overlap better with out-of-order execution.
- 16-byte `SortEntry` (key offset instead of a key slice) and untagged
  `SortValue`: +3% to +4.5%.
- `StartElement` passed by pointer instead of value: neutral.
- Namespace interning last-entry cache: −0.3% instructions but −2% wall.
- Explicit vector loads in the ASCII control block and the name scanner:
  +0.9% to +1.2% instructions; LLVM's narrower reassembly is better there.
- 16-byte unroll of the name scanner, 32-byte CJK validator over 10 code
  points, `@branchHint(.cold)` on the CJK block: neutral or worse.
- Huge-page hints for the XSLT result builder's reused arena: page faults
  dropped 16% but wall time rose 8–30% (the arena is reused, so there are no
  repeated faults to save, and huge-page zeroing plus `khugepaged` work
  dominate). The hint belongs to one-shot parse arrays only.
- Software prefetch of the next sibling in the XSLT child loops: identity
  +3.0% instructions and +2% cycles, sorted report +3.9% and +2-5%, wall
  neutral to 4% slower. The loops are instruction-bound, so the extra
  prefetch instruction costs more than the hidden load latency.

## Remaining architectural options

The remaining large levers are structural:

- **Split the node record** into a scan-hot 32-byte array and an auxiliary
  array. Scans would touch two nodes per cache line instead of one. The
  measured XSLT workloads run at IPC ~4 with negligible LLC misses, so they
  are instruction-bound; the split adds a second stream and address
  computations without removing instructions. A synthetic chain scan shows
  the density gain only on memory-bound scans. Not pursued without a
  memory-bound workload to justify it. This would rewrite every node access
  in the parser, DOM, writer, XPath, and XSLT; document order must stay
  depth-first.
- **Borrow names and values as offsets** into the input buffer to shrink
  `dom.Attribute` below 32 bytes. The pointer/32-bit-length form already cut
  the record to 32; a 24-byte offset form needs a document base pointer for
  every access, and result trees copy values into arena slabs, so the
  representation would need a tag. Attribute names are always input-borrowed
  today, which makes a 24-byte record possible but changes the public type.
- **Cross-application caches** (document analysis reused across repeated
  transforms) need an API change; they only pay off for batch callers and add
  pure overhead to single-shot transforms, so they are not pursued without a
  concrete batch-oriented API design.
