# W3C XML Conformance

xmlz ships the W3C XML Conformance Test Suite (2013-09-23 snapshot) and a
harness that classifies each test by the suite's own `TYPE` attribute.

## Reproduction

```sh
zig build conformance
```

Expected summary:

```text
W3C XML conformance: 2585 total, 1926 passed, 0 failed, 635 skipped (XML 1.1/namespace), 24 optional
  entities=parameter: 169/169 passed (0 failed)
  entities=unspecified: 471/471 passed (0 failed)
  entities=both: 61/61 passed (0 failed)
  entities=general: 17/17 passed (0 failed)
  entities=none: 1208/1208 passed (0 failed)
```

## Harness rules

| Suite `TYPE` | Required xmlz verdict |
| --- | --- |
| `valid` | parses to EOF |
| `invalid` | parses to EOF (DTD validity is not checked) |
| `not-wf` | rejected |
| `error` | either verdict; reported as optional |

Entries are skipped when any of the following applies:

- the suite marks the test as XML 1.1 (`VERSION="1.1"` or an XML 1.1 profile),
- the test is in the namespace test catalogues,
- the suite marks the test for XML 1.0 editions 1-4 only (`EDITION` without
  `5`). xmlz implements the Fifth Edition character and name productions, so
  those tests assert the opposite verdict.

External subsets and external parsed entities are resolved relative to the
document under test. The harness supplies an allocator and a file resolver to
the parser; the parser itself never touches the filesystem.

## Notes

- The `invalid` class is expected to parse. DTD validity constraints
  (ID uniqueness, element content models, attribute types, root element type)
  are not enforced by the core parser.
- The suite contains mutually inconsistent verdicts around parameter-entity
  nesting: `ibm-not-wf-p28a-ibm28an01` expects rejection, while the Fifth
  Edition errata tests (`E14`, `invalid--005`, `invalid--006`) expect parsing.
  xmlz rejects a declaration that begins inside a parameter entity and
  continues outside it, and accepts the converse, matching the errata and the
  behaviour of libxml2 and expat.
- Optional (`error`) tests are counted but do not affect the pass/fail gate.
