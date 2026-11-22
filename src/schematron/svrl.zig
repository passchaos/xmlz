//! SVRL (Schematron Validation Report Language) output.
//!
//! Produces the ISO Schematron report vocabulary: active patterns, fired
//! rules, failed assertions, successful reports, rendered text, and
//! diagnostic/property references. `location` uses XPath paths with
//! positional predicates for repeated siblings.

const std = @import("std");
const dom = @import("../dom.zig");
const xpath_value = @import("../xpath/value.zig");
const validate_mod = @import("validate.zig");

pub const namespace_uri = "http://purl.oclc.org/dsdl/svrl";

pub const Options = struct {
    title: []const u8 = "",
    schema_version: []const u8 = "",
};

pub fn write(
    out: *std.Io.Writer,
    result: *const validate_mod.Result,
    document: *const dom.Document,
    options: Options,
) !void {
    try out.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    try out.writeAll("<svrl:schematron-output xmlns:svrl=\"");
    try out.writeAll(namespace_uri);
    try out.writeByte('"');
    if (options.title.len != 0) {
        try out.writeAll(" title=\"");
        try writeEscapedAttribute(out, options.title);
        try out.writeByte('"');
    }
    if (options.schema_version.len != 0) {
        try out.writeAll(" schemaVersion=\"");
        try writeEscapedAttribute(out, options.schema_version);
        try out.writeByte('"');
    }
    try out.writeAll(">\n");

    for (result.active_patterns) |id| {
        try out.writeAll("  <svrl:active-pattern id=\"");
        try writeEscapedAttribute(out, id);
        try out.writeAll("\"/>\n");
    }
    for (result.fired_rules) |rule| {
        try out.writeAll("  <svrl:fired-rule context=\"");
        try writeEscapedAttribute(out, rule.context);
        try out.writeAll("\"/>\n");
    }
    for (result.failures) |failure| {
        const tag = if (failure.kind == .assert)
            "failed-assert"
        else
            "successful-report";
        try out.writeAll("  <svrl:");
        try out.writeAll(tag);
        try out.writeAll(" test=\"");
        try writeEscapedAttribute(out, failure.test_source);
        try out.writeAll("\" location=\"");
        try writeNodeLocation(out, document, failure.node_ref);
        try out.writeAll("\">\n    <svrl:text>");
        try writeEscapedText(out, failure.message);
        try out.writeAll("</svrl:text>\n");
        for (failure.diagnostics) |diagnostic| {
            try out.writeAll("    <svrl:diagnostic-reference diagnostic=\"");
            try writeEscapedAttribute(out, diagnostic.id);
            try out.writeAll("\">");
            try writeEscapedText(out, diagnostic.message);
            try out.writeAll("</svrl:diagnostic-reference>\n");
        }
        for (failure.properties) |property| {
            try out.writeAll("    <svrl:property-reference property=\"");
            try writeEscapedAttribute(out, property.id);
            try out.writeByte('"');
            if (property.scheme.len != 0) {
                try out.writeAll(" scheme=\"");
                try writeEscapedAttribute(out, property.scheme);
                try out.writeByte('"');
            }
            if (property.role.len != 0) {
                try out.writeAll(" role=\"");
                try writeEscapedAttribute(out, property.role);
                try out.writeByte('"');
            }
            try out.writeByte('>');
            try writeEscapedText(out, property.message);
            try out.writeAll("</svrl:property-reference>\n");
        }
        try out.writeAll("  </svrl:");
        try out.writeAll(tag);
        try out.writeAll(">\n");
    }
    try out.writeAll("</svrl:schematron-output>\n");
}

fn writeNodeLocation(
    out: *std.Io.Writer,
    document: *const dom.Document,
    node: xpath_value.NodeRef,
) !void {
    switch (node) {
        .attribute => |attribute| {
            try writeElementPath(out, document, attribute.element);
            try out.writeAll("/@");
            try out.writeAll(
                document.attributesOf(attribute.element)[attribute.index].name,
            );
        },
        .namespace_node => |namespace_node| {
            try writeElementPath(out, document, namespace_node.element);
            try out.writeAll("/namespace::");
            try out.writeAll(namespace_node.prefix);
        },
        .node => |id| {
            const value = document.node(id);
            switch (value.kind) {
                .document => try out.writeByte('/'),
                .element => try writeElementPath(out, document, id),
                .text => try writeChildPath(out, document, id, "text()", .text),
                .comment => try writeChildPath(
                    out,
                    document,
                    id,
                    "comment()",
                    .comment,
                ),
                .processing_instruction => try writeChildPath(
                    out,
                    document,
                    id,
                    "processing-instruction()",
                    .processing_instruction,
                ),
            }
        },
    }
}

fn writeElementPath(
    out: *std.Io.Writer,
    document: *const dom.Document,
    id: dom.NodeId,
) !void {
    const value = document.node(id);
    const parent = value.parent;
    if (parent != dom.null_node and
        document.node(parent).kind == .element)
    {
        try writeElementPath(out, document, parent);
    }
    try out.writeByte('/');
    try out.writeAll(value.name);

    var count: usize = 0;
    var position: usize = 0;
    var sibling = document.node(parent).first_child;
    while (sibling != dom.null_node) : (sibling = document.node(sibling).next_sibling) {
        const sibling_node = document.node(sibling);
        if (sibling_node.kind == .element and
            std.mem.eql(u8, sibling_node.name, value.name))
        {
            count += 1;
            if (sibling == id) position = count;
        }
    }
    if (count > 1) try out.print("[{d}]", .{position});
}

fn writeChildPath(
    out: *std.Io.Writer,
    document: *const dom.Document,
    id: dom.NodeId,
    label: []const u8,
    kind: dom.Kind,
) !void {
    const value = document.node(id);
    const parent = value.parent;
    if (parent != dom.null_node and
        document.node(parent).kind == .element)
    {
        try writeElementPath(out, document, parent);
    }
    try out.writeByte('/');
    try out.writeAll(label);

    var count: usize = 0;
    var position: usize = 0;
    var sibling = document.node(parent).first_child;
    while (sibling != dom.null_node) : (sibling = document.node(sibling).next_sibling) {
        if (document.node(sibling).kind == kind) {
            count += 1;
            if (sibling == id) position = count;
        }
    }
    if (count > 1) try out.print("[{d}]", .{position});
}

fn writeEscapedText(out: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| {
        switch (byte) {
            '&' => try out.writeAll("&amp;"),
            '<' => try out.writeAll("&lt;"),
            '>' => try out.writeAll("&gt;"),
            '\r' => try out.writeAll("&#13;"),
            else => try out.writeByte(byte),
        }
    }
}

fn writeEscapedAttribute(out: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| {
        switch (byte) {
            '&' => try out.writeAll("&amp;"),
            '<' => try out.writeAll("&lt;"),
            '>' => try out.writeAll("&gt;"),
            '"' => try out.writeAll("&quot;"),
            '\t' => try out.writeAll("&#9;"),
            '\n' => try out.writeAll("&#10;"),
            '\r' => try out.writeAll("&#13;"),
            else => try out.writeByte(byte),
        }
    }
}

const testing = std.testing;

test "SVRL writes findings, locations, and diagnostics" {
    const schema_mod = @import("schema.zig");
    var schema_document = try dom.Document.parse(
        testing.allocator,
        "<schema xmlns='http://purl.oclc.org/dsdl/schematron'>" ++
            "<pattern id='p'><rule context='item'>" ++
            "<assert test='@id' diagnostics='d1'>needs id</assert>" ++
            "<report test=\"@id='bad'\">bad id</report>" ++
            "</rule></pattern>" ++
            "<diagnostics><diagnostic id='d1'>missing id</diagnostic></diagnostics>" ++
            "</schema>",
        .{},
    );
    defer schema_document.deinit();
    var compiled = try schema_mod.parse(testing.allocator, &schema_document);
    defer compiled.deinit();

    var instance = try dom.Document.parse(
        testing.allocator,
        "<root><item/><item id='bad'/></root>",
        .{},
    );
    defer instance.deinit();
    var result = try validate_mod.validate(
        &compiled,
        testing.allocator,
        &instance,
        .{},
    );
    defer result.deinit();

    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    try write(&allocating.writer, &result, &instance, .{});
    const output = allocating.written();
    try testing.expect(std.mem.indexOf(
        u8,
        output,
        "<svrl:active-pattern id=\"p\"/>",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        output,
        "<svrl:fired-rule context=\"item\"/>",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        output,
        "test=\"@id\" location=\"/root/item[1]\"",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        output,
        "<svrl:text>needs id</svrl:text>",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        output,
        "<svrl:diagnostic-reference diagnostic=\"d1\">missing id" ++
            "</svrl:diagnostic-reference>",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        output,
        "test=\"@id='bad'\" location=\"/root/item[2]\"",
    ) != null);
}
