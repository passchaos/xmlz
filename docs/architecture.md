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
using 32-bit indices and ranges. It is built from parser events with namespace
processing enabled, decoded/normalized text and attribute values, DTD attribute
defaults, and optional comments/PIs. The document owns an arena; input slices
remain borrowed, so the input must outlive the document.

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
count/from patterns and number formats, raw text from
`disable-output-escaping`, literal result elements, AVTs, and the core
instruction set into a `dom_builder` document,
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
groups, applies substitution groups, abstract-element rules, and identity
constraints, resolves `xs:include` / `xs:import` through a caller resolver,
validates attributes and simple values, applies wildcards and `xsi:type` /
`xsi:nil`, and collects errors with node paths. `xs:redefine` and abstract-type
enforcement are not implemented.

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
- `zig build c14n-diff` compares canonical forms against libxml2's `xmllint`.
- `zig build xslt-diff` compares XSLT result trees against libxslt via `lxml`.
- `zig build xsd-diff` compares schema validation results against libxml2 via
  `lxml`.
- `zig build bench` compares pull/DOM throughput against expat, pugixml, and
  libxml2 with reproducible generated input.
