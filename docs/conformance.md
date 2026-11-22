# W3C XML Conformance

xmlz ships the W3C XML Conformance Test Suite (2013-09-23 snapshot) and a
harness that classifies each test by the suite's own `TYPE` attribute.

## Reproduction

```sh
zig build conformance
```

Expected summary:

```text
W3C XML conformance: 2585 total, 2240 passed, 0 failed, 313 skipped (edition 1-4 only), 32 optional
  entities=parameter: 171/171 passed (0 failed)
  entities=unspecified: 571/571 passed (0 failed)
  entities=both: 62/62 passed (0 failed)
  entities=general: 71/71 passed (0 failed)
  entities=none: 1365/1365 passed (0 failed)
```

## Harness rules

| Suite `TYPE` | Required xmlz verdict |
| --- | --- |
| `valid` | parses to EOF and, when a DTD is present, validates without issues |
| `invalid` | parses to EOF and, when a DTD is present, produces at least one validity issue |
| `not-wf` | rejected |
| `error` | either verdict; reported as optional |

Entries are skipped when any of the following applies:

- the suite marks the test for XML 1.0 editions 1-4 only (`EDITION` without
  `5`). xmlz implements the Fifth Edition productions, so those tests assert
  the opposite verdict. xmlz implements the Fifth Edition character and name productions, so
  those tests assert the opposite verdict.

Namespace tests run with `Parser.Options.namespaces = true`. XML 1.1
documents are detected from the declaration; the parser normalizes NEL/LS line
ends, enforces restricted-character rules, and permits 1.0-version external
entities inside 1.1 documents. All XML 1.0 (Fifth Edition), XML 1.1, and
Namespaces 1.0/1.1 tests in the suite pass. External subsets and external parsed entities are
resolved relative to the document under test. The harness supplies an allocator and a file resolver to
the parser; the parser itself never touches the filesystem.

## Notes

- The `invalid` class is expected to parse; DTD validity is checked by the
  optional validation pass described in `docs/validation.md`. The core parser
  remains a non-validating parser, so validity constraints do not affect
  well-formedness.
- The suite contains mutually inconsistent verdicts around parameter-entity
  nesting: `ibm-not-wf-p28a-ibm28an01` expects rejection, while the Fifth
  Edition errata tests (`E14`, `invalid--005`, `invalid--006`) expect parsing.
  xmlz rejects a declaration that begins inside a parameter entity and
  continues outside it, and accepts the converse, matching the errata and the
  behaviour of libxml2 and expat.
- Optional (`error`) tests are counted but do not affect the pass/fail gate.
