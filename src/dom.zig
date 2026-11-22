//! Arena-backed XML document tree.
//!
//! The DOM is built from the pull parser with namespace processing enabled by
//! default. Nodes are stored in one contiguous array and reference each other
//! by 32-bit index, which keeps traversal cache-friendly and avoids per-node
//! allocations.
//!
//! Text and attribute values are entity-decoded and normalized. Slices may
//! borrow the input buffer (zero-copy), so the input must outlive the
//! `Document`. Allocations made during parsing live in the document arena and
//! are released by `deinit`.

const std = @import("std");
const chars = @import("chars.zig");
const parser_mod = @import("parser.zig");
const entities = @import("entities.zig");
const namespace = @import("namespace.zig");

pub const NodeId = u32;
pub const null_node: NodeId = std.math.maxInt(NodeId);

pub const Kind = enum {
    document,
    element,
    text,
    comment,
    processing_instruction,
};

pub const Attribute = struct {
    /// Raw qualified name as authored.
    name: []const u8,
    /// Byte offset of the first colon in the raw name, or 0xFFFF.
    colon: u16 = 0xFFFF,
    /// Resolved namespace URI; empty when the attribute has no namespace.
    ns: []const u8,
    /// Decoded and normalized value.
    value: []const u8,

    pub fn localName(self: Attribute) []const u8 {
        return if (self.colon == 0xFFFF) self.name else self.name[self.colon + 1 ..];
    }

    pub fn prefixName(self: Attribute) []const u8 {
        return if (self.colon == 0xFFFF) "" else self.name[0..self.colon];
    }
};

pub const Node = struct {
    kind: Kind,
    parent: NodeId = null_node,
    first_child: NodeId = null_node,
    last_child: NodeId = null_node,
    next_sibling: NodeId = null_node,
    /// Raw element name or PI target.
    name: []const u8 = "",
    local: []const u8 = "",
    /// Resolved namespace URI; empty when the element has no namespace.
    ns: []const u8 = "",
    /// Text/comment/PI payload.
    value: []const u8 = "",
    attr_start: u32 = 0,
    attr_count: u32 = 0,
};

pub const Options = struct {
    parser: parser_mod.Options = .{ .namespaces = true },
    keep_comments: bool = false,
    keep_pis: bool = false,
    /// Keep CDATA as a distinct text node instead of merging it into adjacent
    /// character data.
    preserve_cdata: bool = false,
};

pub const Error = parser_mod.Error || entities.DecodeError || error{OutOfMemory};

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    nodes: []Node,
    attributes: []Attribute,
    declaration: ?parser_mod.Declaration = null,
    doctype: ?parser_mod.Doctype = null,

    pub fn parse(
        allocator: std.mem.Allocator,
        input: []const u8,
        options: Options,
    ) Error!Document {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();

        var builder = Builder.init(arena_allocator, input, options);
        try builder.run();

        return .{
            .arena = arena,
            .nodes = builder.nodes.items,
            .attributes = builder.attributes.items,
            .declaration = builder.declaration,
            .doctype = builder.doctype,
        };
    }

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// The synthetic document node (always id 0).
    pub fn documentNode(self: *const Document) NodeId {
        _ = self;
        return 0;
    }

    /// The root element, or `null_node` when parsing produced no root.
    pub fn root(self: *const Document) NodeId {
        return self.nodes[0].first_child;
    }

    pub fn node(self: *const Document, id: NodeId) *const Node {
        return &self.nodes[id];
    }

    pub fn attributesOf(self: *const Document, id: NodeId) []const Attribute {
        const node_value = &self.nodes[id];
        return self.attributes[node_value.attr_start..][0..node_value.attr_count];
    }

    pub fn attribute(self: *const Document, id: NodeId, name: []const u8) ?[]const u8 {
        for (self.attributesOf(id)) |attr| {
            if (std.mem.eql(u8, attr.name, name)) return attr.value;
        }
        return null;
    }

    pub fn attributeNs(
        self: *const Document,
        id: NodeId,
        uri: []const u8,
        local: []const u8,
    ) ?[]const u8 {
        for (self.attributesOf(id)) |attr| {
            if (std.mem.eql(u8, attr.ns, uri) and
                std.mem.eql(u8, attr.localName(), local))
            {
                return attr.value;
            }
        }
        return null;
    }

    pub const ChildIterator = struct {
        doc: *const Document,
        next_id: NodeId,

        pub fn next(self: *ChildIterator) ?NodeId {
            const id = self.next_id;
            if (id == null_node) return null;
            self.next_id = self.doc.nodes[id].next_sibling;
            return id;
        }
    };

    pub fn children(self: *const Document, id: NodeId) ChildIterator {
        return .{ .doc = self, .next_id = self.nodes[id].first_child };
    }

    pub fn findChild(
        self: *const Document,
        id: NodeId,
        local: []const u8,
    ) ?NodeId {
        var child = self.nodes[id].first_child;
        while (child != null_node) : (child = self.nodes[child].next_sibling) {
            const node_value = &self.nodes[child];
            if (node_value.kind == .element and
                std.mem.eql(u8, node_value.local, local))
            {
                return child;
            }
        }
        return null;
    }

    pub fn findChildNs(
        self: *const Document,
        id: NodeId,
        uri: []const u8,
        local: []const u8,
    ) ?NodeId {
        var child = self.nodes[id].first_child;
        while (child != null_node) : (child = self.nodes[child].next_sibling) {
            const node_value = &self.nodes[child];
            if (node_value.kind == .element and
                std.mem.eql(u8, node_value.ns, uri) and
                std.mem.eql(u8, node_value.local, local))
            {
                return child;
            }
        }
        return null;
    }

    /// Concatenate all descendant character data into a newly allocated slice.
    pub fn textContentAlloc(
        self: *const Document,
        allocator: std.mem.Allocator,
        id: NodeId,
    ) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try self.appendTextContent(allocator, &out, id);
        return out.toOwnedSlice(allocator);
    }

    /// Append all descendant character data to an existing buffer.
    pub fn appendTextContent(
        self: *const Document,
        allocator: std.mem.Allocator,
        out: *std.ArrayList(u8),
        id: NodeId,
    ) !void {
        const node_value = &self.nodes[id];
        if (node_value.kind == .text) {
            try out.appendSlice(allocator, node_value.value);
            return;
        }
        var child = node_value.first_child;
        while (child != null_node) : (child = self.nodes[child].next_sibling) {
            try self.appendTextContent(allocator, out, child);
        }
    }
};

const Builder = struct {
    allocator: std.mem.Allocator,
    options: Options,
    parser: parser_mod.Parser,
    nodes: std.ArrayList(Node) = .empty,
    attributes: std.ArrayList(Attribute) = .empty,
    stack: [parser_mod.max_open_elements]NodeId = undefined,
    stack_len: usize = 0,
    declaration: ?parser_mod.Declaration = null,
    doctype: ?parser_mod.Doctype = null,

    fn init(
        allocator: std.mem.Allocator,
        input: []const u8,
        options: Options,
    ) Builder {
        var parser_options = options.parser;
        if (parser_options.allocator == null) parser_options.allocator = allocator;
        return .{
            .allocator = allocator,
            .options = options,
            .parser = parser_mod.Parser.init(input, parser_options),
        };
    }

    fn run(self: *Builder) Error!void {
        const counts = countStructural(self.parser.input);
        try self.nodes.ensureTotalCapacity(
            self.allocator,
            counts.lt + counts.lt / 2 + 16,
        );
        try self.attributes.ensureTotalCapacity(
            self.allocator,
            counts.eq + 16,
        );
        // Keep the parser's DTD scratch arena alive for the document lifetime:
        // resolved namespace URIs may point into it. Its allocations come from
        // the document arena, so they are released with the document.
        _ = try self.addNode(.{ .kind = .document });

        while (try self.parser.next()) |event| {
            switch (event) {
                .xml_declaration => |declaration| self.declaration = declaration,
                .doctype => |doctype| self.doctype = doctype,
                .start_element => |element| try self.startElement(element),
                .end_element => try self.endElement(),
                .text => |text| try self.appendText(text, false),
                .cdata => |data| try self.appendText(data, true),
                .comment => |data| {
                    if (!self.options.keep_comments) continue;
                    _ = try self.addChildNode(
                        self.currentParent(),
                        .{
                            .kind = .comment,
                            .value = try normalizeLineEndings(
                                self.allocator,
                                data,
                                self.parser.xmlVersion(),
                            ),
                        },
                    );
                },
                .processing_instruction => |pi| {
                    if (!self.options.keep_pis) continue;
                    _ = try self.addChildNode(
                        self.currentParent(),
                        .{
                            .kind = .processing_instruction,
                            .name = pi.target,
                            .value = try normalizeLineEndings(
                                self.allocator,
                                pi.data,
                                self.parser.xmlVersion(),
                            ),
                        },
                    );
                },
            }
        }
    }

    fn startElement(
        self: *Builder,
        element: parser_mod.StartElement,
    ) Error!void {
        const parent = self.currentParent();
        const element_local = if (element.colon == 0xFFFF)
            element.name
        else
            element.name[element.colon + 1 ..];

        const attr_start: u32 = @intCast(self.attributes.items.len);
        try self.attributes.ensureUnusedCapacity(
            self.allocator,
            element.attrs.len,
        );
        for (element.attrs) |attr| {
            var value = attr.value;
            if (attr.needs_decode) {
                value = try entities.decodeAttributeAlloc(
                    self.allocator,
                    attr.value,
                    self.parser.entityTable(),
                    .{},
                    .{
                        .version = self.parser.xmlVersion(),
                        .preserve_undeclared = true,
                        .preserve_external = true,
                    },
                );
            }
            if (attr.tokenized) {
                value = try normalizeTokenized(self.allocator, value);
            }
            const uri = if (namespace.Resolver.isNamespaceDeclaration(attr.name))
                namespace.xmlns_uri
            else
                attr.namespace_uri;
            self.attributes.appendAssumeCapacity(.{
                .name = attr.name,
                .colon = attr.colon,
                .ns = uri,
                .value = value,
            });
        }

        const id = try self.addNode(.{
            .kind = .element,
            .name = element.name,
            .local = element_local,
            .ns = element.namespace_uri,
            .attr_start = attr_start,
            .attr_count = @intCast(self.attributes.items.len - attr_start),
        });
        try self.appendChild(parent, id);

        if (!element.self_closing) {
            self.stack[self.stack_len] = id;
            self.stack_len += 1;
        }
    }

    fn endElement(self: *Builder) Error!void {
        if (self.stack_len == 0) return;
        self.stack_len -= 1;
    }

    fn appendText(
        self: *Builder,
        raw: []const u8,
        literal: bool,
    ) Error!void {
        if (self.stack_len == 0) return;
        const decoded = if (literal)
            try normalizeLineEndings(
                self.allocator,
                raw,
                self.parser.xmlVersion(),
            )
        else
            try entities.decodeTextAlloc(
                self.allocator,
                raw,
                self.parser.entityTable(),
                .{},
                .{
                    .version = self.parser.xmlVersion(),
                    .preserve_undeclared = true,
                    .preserve_external = true,
                },
            );
        if (decoded.len == 0) return;
        _ = try self.addChildNode(
            self.stack[self.stack_len - 1],
            .{ .kind = .text, .value = decoded },
        );
    }

    fn currentParent(self: *const Builder) NodeId {
        if (self.stack_len == 0) return 0;
        return self.stack[self.stack_len - 1];
    }

    fn addChildNode(self: *Builder, parent: NodeId, node: Node) Error!NodeId {
        const id = try self.addNode(node);
        try self.appendChild(parent, id);
        return id;
    }

    fn addNode(self: *Builder, node: Node) Error!NodeId {
        const id: NodeId = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, node);
        return id;
    }

    fn appendChild(self: *Builder, parent: NodeId, child: NodeId) Error!void {
        self.nodes.items[child].parent = parent;
        const parent_node = &self.nodes.items[parent];
        if (parent_node.last_child != null_node) {
            self.nodes.items[parent_node.last_child].next_sibling = child;
        } else {
            parent_node.first_child = child;
        }
        parent_node.last_child = child;
    }
};

fn countStructural(input: []const u8) struct { lt: usize, eq: usize } {
    const Vec = @Vector(32, u8);
    const lt: Vec = @splat('<');
    const eq: Vec = @splat('=');
    var lt_count: usize = 0;
    var eq_count: usize = 0;
    var index: usize = 0;
    while (index + 32 <= input.len) : (index += 32) {
        const chunk: Vec = input[index..][0..32].*;
        lt_count += @popCount(@as(u32, @bitCast(chunk == lt)));
        eq_count += @popCount(@as(u32, @bitCast(chunk == eq)));
    }
    while (index < input.len) : (index += 1) {
        if (input[index] == '<') lt_count += 1;
        if (input[index] == '=') eq_count += 1;
    }
    return .{ .lt = lt_count, .eq = eq_count };
}

fn normalizeLineEndings(
    allocator: std.mem.Allocator,
    raw: []const u8,
    version: chars.Version,
) Error![]const u8 {
    var needs_work = std.mem.indexOfScalar(u8, raw, '\r') != null;
    if (!needs_work and version == .xml_1_1) {
        needs_work = std.mem.indexOf(u8, raw, "\xC2\x85") != null or
            std.mem.indexOf(u8, raw, "\xE2\x80\xA8") != null;
    }
    if (!needs_work) return raw;

    var out: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < raw.len) {
        const byte = raw[index];
        if (byte == '\r') {
            try out.append(allocator, '\n');
            if (index + 1 < raw.len and raw[index + 1] == '\n') {
                index += 2;
            } else {
                index += 1;
            }
            continue;
        }
        if (version == .xml_1_1 and byte == 0xC2 and
            index + 1 < raw.len and raw[index + 1] == 0x85)
        {
            try out.append(allocator, '\n');
            index += 2;
            continue;
        }
        if (version == .xml_1_1 and byte == 0xE2 and
            index + 2 < raw.len and raw[index + 1] == 0x80 and
            raw[index + 2] == 0xA8)
        {
            try out.append(allocator, '\n');
            index += 3;
            continue;
        }
        try out.append(allocator, byte);
        index += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn normalizeTokenized(
    allocator: std.mem.Allocator,
    value: []const u8,
) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var pending_space = false;
    var started = false;
    for (value) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            if (started) pending_space = true;
            continue;
        }
        if (pending_space) {
            try out.append(allocator, ' ');
            pending_space = false;
        }
        try out.append(allocator, byte);
        started = true;
    }
    if (!started) return value[0..0];
    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "DOM parses elements attributes text and namespaces" {
    const input =
        \\<?xml version="1.0"?>
        \\<svg xmlns="http://www.w3.org/2000/svg" width="10">
        \\  <g id="layer"><rect x="1" y="2"/></g>
        \\  hello &amp; goodbye
        \\</svg>
    ;
    var doc = try Document.parse(testing.allocator, input, .{});
    defer doc.deinit();

    const root = doc.root();
    try testing.expect(root != null_node);
    try testing.expectEqualStrings("svg", doc.node(root).local);
    try testing.expectEqualStrings("http://www.w3.org/2000/svg", doc.node(root).ns);
    try testing.expectEqualStrings("10", doc.attribute(root, "width").?);

    const group = doc.findChild(root, "g").?;
    try testing.expectEqualStrings("layer", doc.attribute(group, "id").?);
    const rect = doc.findChild(group, "rect").?;
    try testing.expectEqualStrings("1", doc.attribute(rect, "x").?);
    try testing.expectEqualStrings("2", doc.attribute(rect, "y").?);

    const text = try doc.textContentAlloc(testing.allocator, root);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "hello & goodbye") != null);
}

test "DOM resolves prefixes and keeps namespace declarations" {
    const input =
        \\<root xmlns:p="urn:p" p:attr="v"><p:child xml:lang="en"/></root>
    ;
    var doc = try Document.parse(testing.allocator, input, .{});
    defer doc.deinit();

    const root = doc.root();
    try testing.expectEqualStrings("v", doc.attributeNs(root, "urn:p", "attr").?);
    var found_prefixed = false;
    for (doc.attributesOf(root)) |attr| {
        if (std.mem.eql(u8, attr.name, "p:attr")) {
            found_prefixed = true;
            try testing.expectEqualStrings("urn:p", attr.ns);
            try testing.expectEqualStrings("attr", attr.localName());
        }
    }
    try testing.expect(found_prefixed);
    const child = doc.findChildNs(root, "urn:p", "child").?;
    try testing.expectEqualStrings("en", doc.attributeNs(child, namespace.xml_uri, "lang").?);
}

test "DOM merges entity-expanded and CDATA text" {
    const input =
        "<!DOCTYPE doc [<!ENTITY who 'world'>]>" ++
        "<doc>hello &who;<![CDATA[!]]> tail</doc>";
    var doc = try Document.parse(testing.allocator, input, .{});
    defer doc.deinit();

    const text = try doc.textContentAlloc(testing.allocator, doc.root());
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("hello world! tail", text);
}

test "DOM preserves comments and processing instructions on request" {
    const input = "<doc><!-- note --><?pi data?><x/></doc>";
    var doc = try Document.parse(testing.allocator, input, .{
        .keep_comments = true,
        .keep_pis = true,
    });
    defer doc.deinit();

    var iterator = doc.children(doc.root());
    const comment = iterator.next().?;
    try testing.expectEqual(Kind.comment, doc.node(comment).kind);
    try testing.expectEqualStrings(" note ", doc.node(comment).value);
    const pi = iterator.next().?;
    try testing.expectEqual(Kind.processing_instruction, doc.node(pi).kind);
    try testing.expectEqualStrings("pi", doc.node(pi).name);
    try testing.expectEqualStrings("data", doc.node(pi).value);
    try testing.expectEqual(Kind.element, doc.node(iterator.next().?).kind);
}

test "DOM preserves CDATA nodes when requested" {
    const input = "<doc>a<![CDATA[b<c]]>d</doc>";
    var doc = try Document.parse(testing.allocator, input, .{
        .preserve_cdata = true,
    });
    defer doc.deinit();

    var iterator = doc.children(doc.root());
    try testing.expectEqualStrings("a", doc.node(iterator.next().?).value);
    try testing.expectEqualStrings("b<c", doc.node(iterator.next().?).value);
    try testing.expectEqualStrings("d", doc.node(iterator.next().?).value);
}

test "DOM reports malformed input" {
    try testing.expectError(
        error.MismatchedEndTag,
        Document.parse(testing.allocator, "<a></b>", .{}),
    );
    try testing.expectError(
        error.UndeclaredPrefix,
        Document.parse(testing.allocator, "<p:a/>", .{}),
    );
}

test "DOM releases memory on allocation failure" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        struct {
            fn parse(allocator: std.mem.Allocator) !void {
                var doc = try Document.parse(
                    allocator,
                    "<a x='1'>text<b/></a>",
                    .{},
                );
                doc.deinit();
            }
        }.parse,
        .{},
    );
}

test "DOM applies DTD attribute defaults with type normalization" {
    const input =
        "<!DOCTYPE doc [" ++
        "<!ELEMENT doc EMPTY>" ++
        "<!ATTLIST doc a CDATA \"x\" b NMTOKEN \"  y  z \">" ++
        "]><doc/>";
    var doc = try Document.parse(testing.allocator, input, .{});
    defer doc.deinit();

    const root = doc.root();
    try testing.expectEqualStrings("x", doc.attribute(root, "a").?);
    try testing.expectEqualStrings("y z", doc.attribute(root, "b").?);
}
