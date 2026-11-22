//! XML serializer for `dom.Document`.
//!
//! The writer emits raw qualified names and namespace declarations preserved
//! by the DOM, so parsed documents round-trip without renaming. Character data
//! and attribute values are re-escaped, and CR is written as `&#13;` so line
//! ending normalization cannot lose it.

const std = @import("std");
const chars = @import("chars.zig");
const dom = @import("dom.zig");

pub const Options = struct {
    /// Emit an XML declaration at the start of the document.
    xml_declaration: bool = true,
    /// Emit the original DOCTYPE when one was parsed.
    emit_doctype: bool = false,
    /// Indentation unit. When non-null, block-structured elements are
    /// pretty-printed. Mixed-content elements stay inline to preserve text.
    indent: ?[]const u8 = null,
    /// Escape `>` as `&gt;` in character data. Escaping is always safe and
    /// avoids accidental `]]>` sequences.
    escape_gt: bool = true,
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
    if (options.xml_declaration) {
        try writer.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>");
        try writer.writeByte('\n');
    }
    if (options.emit_doctype) {
        if (doc.doctype) |doctype| {
            try writer.writeAll(doctype.raw);
            try writer.writeByte('\n');
        }
    }
    const root = doc.root();
    if (root != dom.null_node) {
        try writeNode(writer, doc, root, 0, options, options.indent != null);
    }
}

fn writeNode(
    writer: *std.Io.Writer,
    doc: *const dom.Document,
    id: dom.NodeId,
    depth: usize,
    options: Options,
    pretty: bool,
) Error!void {
    const node = doc.node(id);
    switch (node.kind) {
        .element => try writeElement(writer, doc, id, depth, options, pretty),
        .text => try escapeText(writer, node.value, options.escape_gt),
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
) Error!void {
    const node = doc.node(id);
    if (pretty) try writeIndent(writer, depth, options.indent.?);

    try writer.writeByte('<');
    try writer.writeAll(node.name);
    for (doc.attributesOf(id)) |attr| {
        try writer.writeByte(' ');
        try writer.writeAll(attr.name);
        try writer.writeAll("=\"");
        try escapeAttribute(writer, attr.value);
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

    var child = node.first_child;
    while (child != dom.null_node) : (child = doc.node(child).next_sibling) {
        const child_node = doc.node(child);
        if (block and child_node.kind == .text and
            isWhitespaceOnly(child_node.value))
        {
            continue;
        }
        try writeNode(writer, doc, child, depth + 1, options, block);
        if (block and child_node.kind == .text) try writer.writeByte('\n');
    }

    if (block) try writeIndent(writer, depth, options.indent.?);
    try writer.writeAll("</");
    try writer.writeAll(node.name);
    try writer.writeByte('>');
    if (pretty) try writer.writeByte('\n');
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

/// Escape character data.
pub fn escapeText(
    writer: *std.Io.Writer,
    text: []const u8,
    escape_gt: bool,
) Error!void {
    if (chars.findInvalidXmlChar(text)) |_| return error.InvalidCharacter;
    for (text) |byte| {
        switch (byte) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => if (escape_gt) try writer.writeAll("&gt;") else try writer.writeByte('>'),
            '\r' => try writer.writeAll("&#13;"),
            else => try writer.writeByte(byte),
        }
    }
}

/// Escape an attribute value using double quotes.
pub fn escapeAttribute(
    writer: *std.Io.Writer,
    value: []const u8,
) Error!void {
    if (chars.findInvalidXmlChar(value)) |_| return error.InvalidCharacter;
    for (value) |byte| {
        switch (byte) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '"' => try writer.writeAll("&quot;"),
            '\t' => try writer.writeAll("&#9;"),
            '\n' => try writer.writeAll("&#10;"),
            '\r' => try writer.writeAll("&#13;"),
            else => try writer.writeByte(byte),
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
