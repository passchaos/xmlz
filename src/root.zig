const std = @import("std");

pub const encoding = @import("encoding.zig");
pub const internal_entities = @import("internal_entities.zig");
pub const markup = @import("markup.zig");
pub const character_data = @import("character_data.zig");
pub const chars = @import("chars.zig");
pub const entities = @import("entities.zig");
pub const parser = @import("parser.zig");
pub const sax = @import("sax.zig");
pub const xinclude = @import("xinclude.zig");
pub const namespace = @import("namespace.zig");
pub const xmlbase = @import("xmlbase.zig");
pub const dom = @import("dom.zig");
pub const dom_builder = @import("dom_builder.zig");
pub const writer = @import("writer.zig");
pub const c14n = @import("c14n.zig");
pub const xpath = @import("xpath/root.zig");
pub const xslt = @import("xslt/root.zig");
pub const xsd = @import("xsd/root.zig");
pub const rng = @import("rng/root.zig");
pub const schematron = @import("schematron/root.zig");
pub const catalog = @import("catalog.zig");
pub const validation = @import("validation.zig");

pub const CharacterDataIterator = character_data.Iterator;

/// Permissive SVG-fragment scanners, preserved for existing callers. The
/// conforming parser lives in `parser`; these helpers accept looser syntax.
pub const svg_scan = @import("svg_scan.zig");

pub const XmlTag = svg_scan.XmlTag;
pub const SourceRange = svg_scan.SourceRange;
pub const AttributeValue = svg_scan.AttributeValue;
pub const Attribute = svg_scan.Attribute;
pub const AttributeIterator = svg_scan.AttributeIterator;
pub const AttributeList = svg_scan.AttributeList;
pub const AttributeSet = svg_scan.AttributeSet;
pub const CachedAttributeList = svg_scan.CachedAttributeList;
pub const attrValue = svg_scan.attrValue;
pub const attrValueRange = svg_scan.attrValueRange;
pub const cachedAttributeList = svg_scan.cachedAttributeList;
pub const resetAttributeCache = svg_scan.resetAttributeCache;
pub const beginAttributeProbe = svg_scan.beginAttributeProbe;
pub const endAttributeProbe = svg_scan.endAttributeProbe;
pub const currentAttributeList = svg_scan.currentAttributeList;
pub const localName = svg_scan.localName;
pub const nextTag = svg_scan.nextTag;
pub const stripTags = svg_scan.stripTags;
pub const freeStrippedTags = svg_scan.freeStrippedTags;
pub const hasDoctypeDeclaration = svg_scan.hasDoctypeDeclaration;
pub const doctypeDeclarationRange = svg_scan.doctypeDeclarationRange;
pub const hasTextChildTag = svg_scan.hasTextChildTag;
pub const hasAnyChildTag = svg_scan.hasAnyChildTag;
pub const hasChildTag = svg_scan.hasChildTag;

test {
    std.testing.refAllDecls(@This());
    _ = encoding;
    _ = internal_entities;
    _ = markup;
    _ = character_data;
    _ = chars;
    _ = entities;
    _ = parser;
    _ = sax;
    _ = xinclude;
    _ = namespace;
    _ = xmlbase;
    _ = dom;
    _ = dom_builder;
    _ = writer;
    _ = c14n;
    _ = xpath;
    _ = xslt;
    _ = xsd;
    _ = rng;
    _ = schematron;
    _ = catalog;
    _ = validation;
    _ = svg_scan;
    _ = @import("fuzz_tests.zig");
}
