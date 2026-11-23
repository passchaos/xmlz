# Architecture

xmlz is organized as a layered engine. Each layer has a narrow contract and can
be used independently.

```text
chars / encoding / markup / character_data
                 |
              parser  <--- entities
                 |
        +--------+---------+
        |                  |
       sax               dom --- validation
                          |
                  +-------+--------+
                  |                |
               writer           xpath / xinclude / c14n
                                  |
                            xslt / xsd
```

## Pull parser

`parser.Parser` is a single-pass, zero-copy XML 1.0/1.1 tokenizer. It borrows
names, attribute values, text, CDATA, comments, PIs, and doctype data from the
input. Open-element names and attributes live in fixed inline arrays, so the
common path performs no allocation.

DTD parsing builds a declaration model in an optional scratch arena:
element content models, attribute types/defaults, notations, entities, and
parameter entities. Internal and external subsets, conditional sections, and
entity replacement frames are supported. External resolution is provided by a
caller-installed resolver; the parser never touches the filesystem.

Namespaces are an optional layer with a binding stack, reserved-prefix rules,
and duplicate expanded-attribute checks. The parser can emit resolved
prefix/local/URI metadata for elements and attributes.

## DOM

`dom.Document` stores nodes in one contiguous array and attributes in another,
using 32-bit indices and ranges. Namespace URIs are interned into a per-document
table so each node and attribute holds a 32-bit table index; boolean state is
packed into flag words, keeping records at 80 and 40 bytes. The tree is built
from parser events with namespace processing enabled, decoded/normalized text
and attribute values, DTD attribute defaults, and optional comments/PIs. The document owns an arena; input slices
remain borrowed, so the input must outlive the document. `Document.parseIn`
parses into a caller-owned arena that is reset with retained capacity, which
avoids re-faulting pages when parsing many similarly sized documents. On Linux,
large node/attribute arrays request transparent huge pages as a best-effort
hint to reduce first-touch page-fault overhead.

`dom_builder.Builder` is the mutable counterpart. It copies names and values
into its arena, supports element/text/comment/PI creation, namespace-aware
attributes, insert/remove operations, and produces an immutable `Document` on
`finish`.

## Validation

`validation.validate` is a separate pass over a DOM plus the parser's DTD view.
It implements the XML validity constraints: content models, attribute types and
defaults, required/fixed values, ID uniqueness, IDREF resolution, entity and
notation references, root element type, duplicate declarations, standalone
declaration effects, and parameter-entity nesting. The core parser remains a
non-validating parser.

## XPath and XInclude

`xpath` is a standalone XPath 1.0 lexer/parser/evaluator over `dom.Document`.
It supports all core axes including `namespace` (in-scope namespace nodes with
specification ordering), predicates, operators, variables, and the core
function library. `xinclude.process` expands
XInclude 1.0 includes using a resolver, with fallback, text mode, nesting, and
circular detection.

## Canonicalization

`c14n.canonicalize` serializes a whole document in Canonical XML 1.0/1.1 or
Exclusive XML Canonicalization 1.0 form. It renders in-scope namespaces with
lexicographic ordering, suppresses redundant declarations, sorts attributes by
namespace URI then local name, expands empty elements, escapes character data
and attribute values per the specifications, and handles comments and PIs
outside the document element. Whole-document C14N 1.0 and 1.1 forms are
identical; document-subset fixups (`xml:base`, inherited `xml:lang`/`xml:space`)
are not implemented.

## XML Base and xml:id

`xmlbase` implements RFC 3986 reference resolution, applies `xml:base` along an
element's ancestor chain, and normalizes `xml:id` values. XInclude uses it to
pass element-aware base URIs to the resolver, including the base established by
an included document's root, and XPath `id()` matches `xml:id` with the
required whitespace normalization.

## XSLT

`xslt` compiles stylesheet instruction trees and translates match patterns
into XPath selectors that are evaluated once per transform. Template conflict
resolution follows XSLT priority and document order. The runtime executes
templates, modes, parameters, variables, sorting, copy instructions, keys,
includes/imports with import precedence and `apply-imports`, attribute sets,
whitespace stripping via a filtered source tree, multi-level numbering with
count/from patterns and number formats, decimal formats with
`format-number()`, raw text from `disable-output-escaping`, literal result
elements, AVTs, and the core instruction set into a `dom_builder` document,
reusing the XPath engine for expressions, `current()`, and `key()`. Result
serialization supports XML, HTML (void elements, boolean attributes, raw
script/style text), and text output; result-tree-fragment node sets are not
implemented.

## XML Schema

`xsd` compiles schema documents into element, attribute, and type components.
Simple types resolve to built-in datatype kinds with inherited facets; complex
types resolve to flattened particles and attribute uses, including
simple/complex content extension and restriction. Instance validation walks the
tree with a backtracking particle matcher, expands model and attribute
groups, applies substitution groups, abstract-element and abstract-type rules,
`block`/`final` exclusions, identity constraints, resolves `xs:include` /
`xs:import` / `xs:redefine` through a caller resolver, validates attributes and
simple values, applies wildcards and `xsi:type` / `xsi:nil`, and collects
errors with node paths.

## RELAX NG

`rng` parses both the RELAX NG XML syntax and the compact syntax into a
pattern tree with resolved `define` references, including `div`, `include`,
and `externalRef` (XML syntax). Instance
validation computes pattern derivatives over attributes (order-independent),
child elements, and text runs. Attributes are consumed first, then the
residual pattern is matched against the children; interleave, choice,
optional, and repetition are handled by derivative rules, and nullable
computations are guarded for recursive grammars. Data and value patterns use
the XML Schema datatype library with facet parameters; the empty datatype
library exposes `string` and `token`.

## Schematron

`schematron` compiles ISO Schematron rules into XPath context patterns and
assertion tests. Validation evaluates each active pattern's rules against the
instance, binds schema/pattern/rule-level `let` variables, renders failure
messages from text and `name`/`value-of` parts, and records failed assertions
and successful reports separately. Phases select the active patterns.

## XML Catalogs

`catalog` parses OASIS XML Catalog documents into ordered entry lists,
including groups, rewrites, suffixes, delegates, and `nextCatalog` references.
Referenced catalogs are loaded through a caller resolver with cycle-safe
caching. Resolution follows the specification's `prefer` ordering, applies
`xml:base`, selects the longest matching rewrite prefix or suffix, and returns
arena-owned URI strings. CLI tools share `tools/file_loader.zig`, which tries
`system` entries and then falls back to `uri` entries before touching the
filesystem, matching libxml2's entity loader.

## Trusted mode

`Parser.Options.trusted = true` skips character, name, duplicate-attribute, and
namespace-constraint validation for inputs the caller has already verified. The
default mode performs full well-formedness checking and passes the W3C suite.
Trusted mode exists for throughput-sensitive trusted pipelines; it is never used
by the conformance harness.

## Testing

- Unit tests cover every layer, including deterministic mutation smoke tests.
- `zig build conformance` runs the W3C XML 1.0/1.1 and Namespaces suites,
  including DTD validity checks for tests with a DTD.
- `zig build xpath-diff` compares XPath results against libxml2's `xmllint`.
- `zig build c14n-diff` compares canonical forms against libxml2's `xmllint`
  for whole documents and against lxml element canonicalization for
  node-sets.
- `zig build xinclude-diff` compares expanded documents against libxml2's
  `xmllint --xinclude`, including XPointer selection.
- `zig build xslt-diff` compares XSLT result trees against libxslt via `lxml`,
  including catalog-resolved includes.
- `zig build xsd-diff` compares schema validation results against libxml2 via
  `lxml`, including catalog-resolved includes/imports and invalid schemas
  that both implementations must reject.
- `zig build rng-diff` compares RELAX NG validation results against libxml2 via
  `lxml`, including catalog-resolved includes.
- `zig build rng-compact-diff` validates compact-syntax schemas against
  equivalent XML-syntax twins using libxml2.
- `zig build schematron-diff` compares Schematron validity with the ISO
  Schematron skeleton through lxml.
- `zig build catalog-diff` compares catalog resolution with libxml2's
  `xmlcatalog`.
- `zig build bench` compares pull/DOM throughput against expat, pugixml, and
  libxml2 with reproducible generated input.
