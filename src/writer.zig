//! XML serializer for `dom.Document`.
//!
//! The writer emits raw qualified names and namespace declarations preserved
//! by the DOM, so parsed documents round-trip without renaming. Character data
//! and attribute values are re-escaped, and CR is written as `&#13;` so line
//! ending normalization cannot lose it.

const std = @import("std");
const chars = @import("chars.zig");
const dom = @import("dom.zig");

/// Explicit DOCTYPE declaration supplied by a caller such as the XSLT engine.
pub const Doctype = struct {
    name: []const u8,
    public_id: ?[]const u8 = null,
    system_id: ?[]const u8 = null,
};

/// Element expanded name used by `cdata_elements`.
pub const ExpandedName = struct {
    uri: []const u8,
    local: []const u8,
};

pub const Options = struct {
    /// Emit an XML declaration at the start of the document.
    xml_declaration: bool = true,
    /// Emit the original DOCTYPE when one was parsed.
    emit_doctype: bool = false,
    /// Emit an explicit DOCTYPE instead of the parsed one.
    doctype: ?Doctype = null,
    /// Indentation unit. When non-null, block-structured elements are
    /// pretty-printed. Mixed-content elements stay inline to preserve text.
    indent: ?[]const u8 = null,
    /// Escape `>` as `&gt;` in character data. Escaping is always safe and
    /// avoids accidental `]]>` sequences.
    escape_gt: bool = true,
    /// Elements whose text children are serialized as CDATA sections.
    cdata_elements: []const ExpandedName = &.{},
    /// Encoding name written into the XML declaration; null omits the
    /// encoding pseudo-attribute (libxslt omits it for default UTF-8 output).
    encoding_label: ?[]const u8 = null,
    /// When set, insert an XHTML Content-Type meta element into <head>.
    html_meta_charset: ?[]const u8 = null,
};

pub const Error = std.Io.Writer.Error || error{
    InvalidCharacter,
    InvalidComment,
    InvalidProcessingInstruction,
    InvalidName,
};

pub fn writeDocument(
    writer: *std.Io.Writer,
    doc: *const dom.Document,
    options: Options,
) Error!void {
    const version = documentVersion(doc);
    if (options.xml_declaration) {
        try writer.writeAll("<?xml version=\"");
        if (doc.declaration) |declaration| {
            try writer.writeAll(declaration.version);
        } else {
            try writer.writeAll("1.0");
        }
        try writer.writeByte('"');
        if (options.encoding_label) |label| {
            try writer.writeAll(" encoding=\"");
            try writer.writeAll(label);
            try writer.writeByte('"');
        }
        if (doc.declaration) |declaration| {
            if (declaration.standalone) |standalone| {
                try writer.writeAll(if (standalone)
                    " standalone=\"yes\""
                else
                    " standalone=\"no\"");
            }
        }
        try writer.writeAll("?>");
        try writer.writeByte('\n');
    }
    if (options.doctype) |doctype| {
        try writeDoctype(writer, doctype);
        try writer.writeByte('\n');
    } else if (options.emit_doctype) {
        if (doc.doctype) |doctype| {
            try writer.writeAll(doctype.raw);
            try writer.writeByte('\n');
        }
    }
    // Serialize every document child, not just the root element: an XSLT
    // result can consist solely of text, comments, or processing
    // instructions.
    var child = doc.node(doc.documentNode()).first_child;
    while (child != dom.null_node) : (child = doc.node(child).next_sibling) {
        try writeNode(
            writer,
            doc,
            child,
            0,
            options,
            options.indent != null,
            version,
            "",
        );
    }
}

fn documentVersion(doc: *const dom.Document) chars.Version {
    if (doc.declaration) |declaration| {
        if (std.mem.eql(u8, declaration.version, "1.1")) return .xml_1_1;
    }
    return .xml_1_0;
}

/// Write an explicit DOCTYPE declaration.
pub fn writeDoctype(writer: *std.Io.Writer, doctype: Doctype) Error!void {
    try writer.writeAll("<!DOCTYPE ");
    try writer.writeAll(doctype.name);
    if (doctype.public_id) |public_id| {
        try writer.writeAll(" PUBLIC \"");
        try writer.writeAll(public_id);
        try writer.writeByte('"');
        if (doctype.system_id) |system_id| {
            try writer.writeAll(" \"");
            try writer.writeAll(system_id);
            try writer.writeByte('"');
        }
    } else if (doctype.system_id) |system_id| {
        try writer.writeAll(" SYSTEM \"");
        try writer.writeAll(system_id);
        try writer.writeByte('"');
    }
    try writer.writeByte('>');
}

fn isCdataElement(options: Options, node: *const dom.Node) bool {
    for (options.cdata_elements) |name| {
        if (std.mem.eql(u8, name.uri, node.ns) and
            std.mem.eql(u8, name.local, node.local))
        {
            return true;
        }
    }
    return false;
}

fn writeCdata(
    writer: *std.Io.Writer,
    text: []const u8,
    version: chars.Version,
) Error!void {
    if (chars.findInvalidLiteralCharVersion(text, version)) |_| {
        if (version == .xml_1_0) return error.InvalidCharacter;
        // Restricted characters cannot appear literally inside a CDATA
        // section, so fall back to escaped character data.
        return escapeTextVersion(writer, text, true, version);
    }
    try writer.writeAll("<![CDATA[");
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, text, index, "]]>")) |match| {
        try writer.writeAll(text[index .. match + 2]);
        try writer.writeAll("]]><![CDATA[");
        index = match + 2;
    }
    try writer.writeAll(text[index..]);
    try writer.writeAll("]]>");
}

fn writeNode(
    writer: *std.Io.Writer,
    doc: *const dom.Document,
    id: dom.NodeId,
    depth: usize,
    options: Options,
    pretty: bool,
    version: chars.Version,
    default_ns: []const u8,
) Error!void {
    const node = doc.node(id);
    switch (node.kind) {
        .element => try writeElement(
            writer,
            doc,
            id,
            depth,
            options,
            pretty,
            version,
            default_ns,
        ),
        .text => {
            if (node.raw_text) {
                try writer.writeAll(node.value);
            } else {
                try escapeTextVersion(
                    writer,
                    node.value,
                    options.escape_gt,
                    version,
                );
            }
        },
        .comment => {
            if (pretty) try writeIndent(writer, depth, options.indent.?);
            try writeComment(writer, node.value);
            if (pretty) try writer.writeByte('\n');
        },
        .processing_instruction => {
            if (pretty) try writeIndent(writer, depth, options.indent.?);
            try writePi(writer, node.name, node.value);
            if (pretty) try writer.writeByte('\n');
        },
        .document => unreachable,
    }
}

fn writeElement(
    writer: *std.Io.Writer,
    doc: *const dom.Document,
    id: dom.NodeId,
    depth: usize,
    options: Options,
    pretty: bool,
    version: chars.Version,
    default_ns: []const u8,
) Error!void {
    const node = doc.node(id);
    if (pretty) try writeIndent(writer, depth, options.indent.?);

    try writer.writeByte('<');
    try writer.writeAll(node.name);
    const prefixed = std.mem.indexOfScalar(u8, node.name, ':') != null;
    var declared_default: ?[]const u8 = null;
    for (doc.attributesOf(id)) |attr| {
        if (std.mem.eql(u8, attr.name, "xmlns")) declared_default = attr.value;
    }
    var child_default = default_ns;
    if (!prefixed) {
        if (declared_default) |value| {
            child_default = value;
        } else if (!std.mem.eql(u8, node.ns, default_ns)) {
            // An unprefixed element in no namespace under a default namespace
            // needs an undeclaration; a namespaced element needs a binding.
            try writer.writeAll(" xmlns=\"");
            try escapeAttributeVersion(writer, node.ns, version);
            try writer.writeByte('"');
            child_default = node.ns;
        }
    }
    for (doc.attributesOf(id)) |attr| {
        if (std.mem.eql(u8, attr.name, "xmlns")) {
            // Skip a default-namespace declaration that repeats the
            // inherited binding.
            if (std.mem.eql(u8, attr.value, default_ns)) continue;
        } else if (std.mem.startsWith(u8, attr.name, "xmlns:")) {
            const prefix = attr.name["xmlns:".len..];
            if (std.mem.eql(u8, prefix, "xml") and
                std.mem.eql(u8, attr.value, "http://www.w3.org/XML/1998/namespace"))
            {
                continue;
            }
            if (ancestorBindsPrefix(doc, id, prefix, attr.value)) continue;
        }
        try writer.writeByte(' ');
        try writer.writeAll(attr.name);
        try writer.writeAll("=\"");
        try escapeAttributeVersion(writer, attr.value, version);
        try writer.writeByte('"');
    }

    if (node.first_child == dom.null_node) {
        try writer.writeAll("/>");
        if (pretty) try writer.writeByte('\n');
        return;
    }
    try writer.writeByte('>');

    const block = pretty and isBlockElement(doc, id);
    if (block) try writer.writeByte('\n');

    if (options.html_meta_charset) |charset| {
        if (std.mem.eql(u8, node.local, "head") and
            !hasContentTypeMeta(doc, id))
        {
            if (block) try writeIndent(writer, depth + 1, options.indent.?);
            try writer.writeAll(
                "<meta http-equiv=\"Content-Type\" content=\"text/html; " ++
                    "charset=",
            );
            try escapeAttributeVersion(writer, charset, version);
            try writer.writeAll("\" />");
            if (block) try writer.writeByte('\n');
        }
    }

    var child = node.first_child;
    const cdata = isCdataElement(options, node);
    while (child != dom.null_node) : (child = doc.node(child).next_sibling) {
        const child_node = doc.node(child);
        const child_cdata = cdata and child_node.kind == .text and
            !child_node.raw_text;
        if (block and child_node.kind == .text and
            isWhitespaceOnly(child_node.value) and !child_cdata)
        {
            continue;
        }
        if (child_cdata) {
            try writeCdata(writer, child_node.value, version);
        } else {
            try writeNode(
                writer,
                doc,
                child,
                depth + 1,
                options,
                block,
                version,
                child_default,
            );
        }
        if (block and child_node.kind == .text) try writer.writeByte('\n');
    }

    if (block) try writeIndent(writer, depth, options.indent.?);
    try writer.writeAll("</");
    try writer.writeAll(node.name);
    try writer.writeByte('>');
    if (pretty) try writer.writeByte('\n');
}

fn ancestorBindsPrefix(
    doc: *const dom.Document,
    id: dom.NodeId,
    prefix: []const u8,
    uri: []const u8,
) bool {
    var current = doc.node(id).parent;
    while (current != dom.null_node) {
        const node = doc.node(current);
        if (node.kind != .element) break;
        for (doc.attributesOf(current)) |attr| {
            if (attr.name.len != "xmlns:".len + prefix.len) continue;
            if (!std.mem.startsWith(u8, attr.name, "xmlns:")) continue;
            if (!std.mem.eql(u8, attr.name["xmlns:".len..], prefix)) continue;
            return std.mem.eql(u8, attr.value, uri);
        }
        current = node.parent;
    }
    return false;
}

fn hasContentTypeMeta(doc: *const dom.Document, id: dom.NodeId) bool {
    var child = doc.node(id).first_child;
    while (child != dom.null_node) : (child = doc.node(child).next_sibling) {
        const node = doc.node(child);
        if (node.kind != .element) continue;
        if (!std.mem.eql(u8, node.local, "meta")) continue;
        if (doc.attribute(child, "http-equiv") != null or
            doc.attribute(child, "charset") != null)
        {
            return true;
        }
    }
    return false;
}

fn isBlockElement(doc: *const dom.Document, id: dom.NodeId) bool {
    const node = doc.node(id);
    var child = node.first_child;
    var has_markup = false;
    while (child != dom.null_node) : (child = doc.node(child).next_sibling) {
        const child_node = doc.node(child);
        if (child_node.kind == .text) {
            if (!isWhitespaceOnly(child_node.value)) return false;
        } else {
            has_markup = true;
        }
    }
    return has_markup;
}

fn isWhitespaceOnly(value: []const u8) bool {
    for (value) |byte| {
        if (!chars.isWhitespace(byte)) return false;
    }
    return true;
}

fn writeIndent(writer: *std.Io.Writer, depth: usize, unit: []const u8) Error!void {
    for (0..depth) |_| try writer.writeAll(unit);
}

fn writeComment(writer: *std.Io.Writer, value: []const u8) Error!void {
    if (std.mem.indexOf(u8, value, "--") != null or
        (value.len != 0 and value[value.len - 1] == '-'))
    {
        return error.InvalidComment;
    }
    try writer.writeAll("<!--");
    try writer.writeAll(value);
    try writer.writeAll("-->");
}

fn writePi(writer: *std.Io.Writer, target: []const u8, data: []const u8) Error!void {
    chars.validateName(target) catch return error.InvalidName;
    if (std.ascii.eqlIgnoreCase(target, "xml")) {
        return error.InvalidProcessingInstruction;
    }
    if (std.mem.indexOf(u8, data, "?>") != null) {
        return error.InvalidProcessingInstruction;
    }
    try writer.writeAll("<?");
    try writer.writeAll(target);
    if (data.len != 0) {
        try writer.writeByte(' ');
        try writer.writeAll(data);
    }
    try writer.writeAll("?>");
}

/// Escape XML 1.0 character data.
pub fn escapeText(
    writer: *std.Io.Writer,
    text: []const u8,
    escape_gt: bool,
) Error!void {
    return escapeTextVersion(writer, text, escape_gt, .xml_1_0);
}

/// Escape character data for the given XML version.
pub fn escapeTextVersion(
    writer: *std.Io.Writer,
    text: []const u8,
    escape_gt: bool,
    version: chars.Version,
) Error!void {
    if (chars.findInvalidLiteralCharVersion(text, version)) |bad| {
        if (version == .xml_1_0) return error.InvalidCharacter;
        // In XML 1.1 restricted characters are legal values but must be
        // written as character references.
        _ = bad;
    }
    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        switch (byte) {
            '&' => {
                try writer.writeAll("&amp;");
                index += 1;
            },
            '<' => {
                try writer.writeAll("&lt;");
                index += 1;
            },
            '>' => {
                try writer.writeAll(if (escape_gt) "&gt;" else ">");
                index += 1;
            },
            '\r' => {
                try writer.writeAll("&#13;");
                index += 1;
            },
            '\n', '\t' => {
                try writer.writeByte(byte);
                index += 1;
            },
            else => {
                if (byte < 0x80) {
                    if (version == .xml_1_1 and chars.isRestrictedChar11(byte)) {
                        try writer.print("&#x{X};", .{byte});
                    } else {
                        try writer.writeByte(byte);
                    }
                    index += 1;
                    continue;
                }
                const length = std.unicode.utf8ByteSequenceLength(byte) catch
                    return error.InvalidCharacter;
                if (index + length > text.len) return error.InvalidCharacter;
                const codepoint = std.unicode.utf8Decode(text[index..][0..length]) catch
                    return error.InvalidCharacter;
                if (!chars.isXmlCharVersion(codepoint, version)) {
                    return error.InvalidCharacter;
                }
                if (version == .xml_1_1 and
                    (chars.isRestrictedChar11(codepoint) or
                        codepoint == 0x85 or codepoint == 0x2028))
                {
                    try writer.print("&#x{X};", .{codepoint});
                } else {
                    try writer.writeAll(text[index..][0..length]);
                }
                index += length;
            },
        }
    }
}

/// Escape an XML 1.0 attribute value using double quotes.
pub fn escapeAttribute(
    writer: *std.Io.Writer,
    value: []const u8,
) Error!void {
    return escapeAttributeVersion(writer, value, .xml_1_0);
}

/// Escape an attribute value for the given XML version.
pub fn escapeAttributeVersion(
    writer: *std.Io.Writer,
    value: []const u8,
    version: chars.Version,
) Error!void {
    if (version == .xml_1_0) {
        if (chars.findInvalidXmlChar(value)) |_| return error.InvalidCharacter;
    }
    var index: usize = 0;
    while (index < value.len) {
        const byte = value[index];
        switch (byte) {
            '&' => {
                try writer.writeAll("&amp;");
                index += 1;
            },
            '<' => {
                try writer.writeAll("&lt;");
                index += 1;
            },
            '"' => {
                try writer.writeAll("&quot;");
                index += 1;
            },
            '\t' => {
                try writer.writeAll("&#9;");
                index += 1;
            },
            '\n' => {
                try writer.writeAll("&#10;");
                index += 1;
            },
            '\r' => {
                try writer.writeAll("&#13;");
                index += 1;
            },
            else => {
                if (byte < 0x80) {
                    if (version == .xml_1_1 and chars.isRestrictedChar11(byte)) {
                        try writer.print("&#x{X};", .{byte});
                    } else {
                        try writer.writeByte(byte);
                    }
                    index += 1;
                    continue;
                }
                const length = std.unicode.utf8ByteSequenceLength(byte) catch
                    return error.InvalidCharacter;
                if (index + length > value.len) return error.InvalidCharacter;
                const codepoint = std.unicode.utf8Decode(value[index..][0..length]) catch
                    return error.InvalidCharacter;
                if (!chars.isXmlCharVersion(codepoint, version)) {
                    return error.InvalidCharacter;
                }
                if (version == .xml_1_1 and
                    (chars.isRestrictedChar11(codepoint) or
                        codepoint == 0x85 or codepoint == 0x2028))
                {
                    try writer.print("&#x{X};", .{codepoint});
                } else {
                    try writer.writeAll(value[index..][0..length]);
                }
                index += length;
            },
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn render(doc: *const dom.Document, options: Options) ![]u8 {
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    try writeDocument(&allocating.writer, doc, options);
    return allocating.toOwnedSlice();
}

test "writer round-trips a namespace-aware document" {
    const input =
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\">" ++
        "<g id=\"layer\"><rect x=\"1\"/></g>hello &amp; goodbye</svg>";
    var doc = try dom.Document.parse(testing.allocator, input, .{});
    defer doc.deinit();

    const output = try render(&doc, .{ .xml_declaration = false });
    defer testing.allocator.free(output);

    var reparsed = try dom.Document.parse(testing.allocator, output, .{});
    defer reparsed.deinit();
    try testing.expectEqualStrings(
        doc.node(doc.root()).name,
        reparsed.node(reparsed.root()).name,
    );
    const original_text = try doc.textContentAlloc(testing.allocator, doc.root());
    defer testing.allocator.free(original_text);
    const reparsed_text = try reparsed.textContentAlloc(
        testing.allocator,
        reparsed.root(),
    );
    defer testing.allocator.free(reparsed_text);
    try testing.expectEqualStrings(original_text, reparsed_text);
}

test "writer escapes text and attribute values" {
    const input = "<doc a=\"x &amp; y &#10; z\">a &lt; b &amp; c &#13;</doc>";
    var doc = try dom.Document.parse(testing.allocator, input, .{});
    defer doc.deinit();

    const output = try render(&doc, .{ .xml_declaration = false });
    defer testing.allocator.free(output);

    try testing.expect(std.mem.indexOf(u8, output, "a=\"x &amp; y &#10; z\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "a &lt; b &amp; c &#13;") != null);
    try testing.expect(std.mem.indexOf(u8, output, "&#13;") != null);
}

test "writer pretty prints block elements and preserves mixed content" {
    const input = "<root><a><b/></a><p>text <i>x</i> tail</p></root>";
    var doc = try dom.Document.parse(testing.allocator, input, .{});
    defer doc.deinit();

    const output = try render(&doc, .{
        .xml_declaration = false,
        .indent = "  ",
    });
    defer testing.allocator.free(output);

    try testing.expect(std.mem.indexOf(u8, output, "<root>\n  <a>\n    <b/>\n  </a>\n") != null);
    try testing.expect(std.mem.indexOf(u8, output, "<p>text <i>x</i> tail</p>") != null);
}

test "writer emits comments and processing instructions" {
    const input = "<doc><!-- note --><?pi data?></doc>";
    var doc = try dom.Document.parse(testing.allocator, input, .{
        .keep_comments = true,
        .keep_pis = true,
    });
    defer doc.deinit();

    const output = try render(&doc, .{ .xml_declaration = false });
    defer testing.allocator.free(output);
    try testing.expect(std.mem.indexOf(u8, output, "<!-- note -->") != null);
    try testing.expect(std.mem.indexOf(u8, output, "<?pi data?>") != null);
}

test "writer rejects invalid comment and PI payloads" {
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    try testing.expectError(
        error.InvalidComment,
        writeComment(&allocating.writer, "bad -- comment"),
    );
    try testing.expectError(
        error.InvalidProcessingInstruction,
        writePi(&allocating.writer, "pi", "bad ?> data"),
    );
    try testing.expectError(
        error.InvalidProcessingInstruction,
        writePi(&allocating.writer, "xml", "data"),
    );
}

test "writer preserves XML 1.1 restricted characters as references" {
    const input = "<?xml version=\"1.1\"?><doc>&#x1;&#x85;</doc>";
    var doc = try dom.Document.parse(testing.allocator, input, .{});
    defer doc.deinit();

    const output = try render(&doc, .{});
    defer testing.allocator.free(output);
    try testing.expect(std.mem.indexOf(u8, output, "version=\"1.1\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "&#x1;") != null);
    try testing.expect(std.mem.indexOf(u8, output, "&#x85;") != null);

    var reparsed = try dom.Document.parse(testing.allocator, output, .{});
    defer reparsed.deinit();
    const original = try doc.textContentAlloc(testing.allocator, doc.root());
    defer testing.allocator.free(original);
    const round_tripped = try reparsed.textContentAlloc(
        testing.allocator,
        reparsed.root(),
    );
    defer testing.allocator.free(round_tripped);
    try testing.expectEqualStrings(original, round_tripped);
    try testing.expectEqual(@as(u8, 1), round_tripped[0]);
    try testing.expectEqual(@as(u8, 0x85), round_tripped[round_tripped.len - 1]);
}
