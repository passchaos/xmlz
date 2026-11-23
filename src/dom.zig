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
const builtin = @import("builtin");
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
    /// True when tokenized normalization changed the decoded value.
    normalization_changed: bool = false,
    /// True when a character reference produced tab, LF, or CR.
    whitespace_char_ref: bool = false,

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
    /// Text produced with XSLT disable-output-escaping; serializers emit it raw.
    raw_text: bool = false,
    /// DTD validation provenance for element-only content.
    has_whitespace_char_ref_text: bool = false,
    has_nel_ls_text: bool = false,
    has_cdata_text: bool = false,
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
    /// False for documents parsed into a caller-owned arena via `parseIn`.
    owns_arena: bool = true,
    nodes: []Node,
    attributes: []Attribute,
    declaration: ?parser_mod.Declaration = null,
    doctype: ?parser_mod.Doctype = null,
    /// DTD view from the parser. Slices borrow the parser's input/scratch
    /// storage, which the DOM keeps alive for the document lifetime.
    dtd: ?parser_mod.Dtd = null,
    /// True when every character in the tree was validated while parsing, so
    /// serializers can skip their own character checks.
    chars_validated: bool = false,

    pub fn parse(
        allocator: std.mem.Allocator,
        input: []const u8,
        options: Options,
    ) Error!Document {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();

        // DTD expansion scratch storage must live in the document arena so
        // the DTD view stays valid and is released with the document.
        var effective = options;
        effective.parser.allocator = arena_allocator;
        var builder = Builder.init(arena_allocator, input, effective);
        try builder.run();

        return .{
            .arena = arena,
            .nodes = builder.nodes.items,
            .attributes = builder.attributes.items,
            .declaration = builder.declaration,
            .doctype = builder.doctype,
            .dtd = builder.parser.dtd(),
            .chars_validated = !effective.parser.trusted,
        };
    }

    /// Parse into a caller-owned arena that is reset (retaining capacity)
    /// before parsing. Reusing the arena across parses avoids re-faulting
    /// pages for similarly sized documents. The returned document borrows the
    /// arena: `deinit()` does not release it, and resetting or deinitializing
    /// the arena invalidates the document.
    pub fn parseIn(
        arena: *std.heap.ArenaAllocator,
        input: []const u8,
        options: Options,
    ) Error!Document {
        _ = arena.reset(.retain_capacity);
        // See `parse`: keep DTD scratch storage in the document arena.
        var effective = options;
        effective.parser.allocator = arena.allocator();
        const arena_allocator = arena.allocator();

        var builder = Builder.init(arena_allocator, input, effective);
        try builder.run();

        return .{
            .arena = undefined,
            .owns_arena = false,
            .nodes = builder.nodes.items,
            .attributes = builder.attributes.items,
            .declaration = builder.declaration,
            .doctype = builder.doctype,
            .dtd = builder.parser.dtd(),
            .chars_validated = !effective.parser.trusted,
        };
    }

    pub fn deinit(self: *Document) void {
        if (self.owns_arena) self.arena.deinit();
        self.* = undefined;
    }

    /// The synthetic document node (always id 0).
    pub fn documentNode(self: *const Document) NodeId {
        _ = self;
        return 0;
    }

    /// The root element, or `null_node` when parsing produced no root.
    pub fn root(self: *const Document) NodeId {
        var child = self.nodes[0].first_child;
        while (child != null_node) : (child = self.nodes[child].next_sibling) {
            if (self.nodes[child].kind == .element) return child;
        }
        return null_node;
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

    /// Collect the in-scope namespaces of an element, nearest declaration
    /// first. The implicit `xml` binding is always present. Prefixes
    /// undeclared with an empty URI and an undeclared default namespace are
    /// omitted, matching the XPath data model.
    pub fn inScopeNamespaces(
        self: *const Document,
        allocator: std.mem.Allocator,
        id: NodeId,
    ) ![]namespace.Binding {
        var out: std.ArrayList(namespace.Binding) = .empty;
        errdefer out.deinit(allocator);
        if (self.nodes[id].kind != .element) {
            return out.toOwnedSlice(allocator);
        }

        var seen: std.ArrayList([]const u8) = .empty;
        defer seen.deinit(allocator);
        try seen.append(allocator, "xml");
        try out.append(allocator, .{
            .prefix = "xml",
            .uri = namespace.xml_uri,
        });

        var current = id;
        while (true) {
            for (self.attributesOf(current)) |attr| {
                if (!namespace.Resolver.isNamespaceDeclaration(attr.name)) {
                    continue;
                }
                const prefix = if (attr.name.len == 5)
                    ""
                else
                    attr.name["xmlns:".len..];
                var shadowed = false;
                for (seen.items) |seen_prefix| {
                    if (std.mem.eql(u8, seen_prefix, prefix)) {
                        shadowed = true;
                        break;
                    }
                }
                if (shadowed) continue;
                try seen.append(allocator, prefix);
                // An empty URI undeclares the prefix, so it binds no namespace.
                if (attr.value.len == 0) continue;
                try out.append(allocator, .{
                    .prefix = prefix,
                    .uri = attr.value,
                });
            }
            const parent = self.nodes[current].parent;
            if (parent == null_node or self.nodes[parent].kind != .element) break;
            current = parent;
        }
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
    /// DTD view from the parser. Slices borrow the parser's input/scratch
    /// storage, which the DOM keeps alive for the document lifetime.
    dtd: ?parser_mod.Dtd = null,

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
        hintHugePages(@ptrCast(self.nodes.items.ptr), self.nodes.capacity * @sizeOf(Node));
        hintHugePages(
            @ptrCast(self.attributes.items.ptr),
            self.attributes.capacity * @sizeOf(Attribute),
        );
        // Keep the parser's DTD scratch arena alive for the document lifetime:
        // resolved namespace URIs may point into it. Its allocations come from
        // the document arena, so they are released with the document.
        _ = try self.addNode(.{ .kind = .document });

        while (try self.parser.next()) |event| {
            switch (event) {
                .xml_declaration => |declaration| self.declaration = declaration,
                .doctype => |doctype| {
                    self.doctype = doctype;
                    // External entity bodies are parsed through input frames,
                    // so the top-level size estimate misses their nodes and
                    // attributes. Reserve up front instead of growing the
                    // arrays many times while entity content streams in.
                    if (self.parser.entityTable().hasExternalParsed()) {
                        try self.nodes.ensureUnusedCapacity(
                            self.allocator,
                            external_content_nodes,
                        );
                        try self.attributes.ensureUnusedCapacity(
                            self.allocator,
                            external_content_attributes,
                        );
                    }
                },
                .start_element => |element| try self.startElement(element),
                .end_element => try self.endElement(),
                .text => |text| try self.appendText(
                    text,
                    if (self.parser.text_needs_decode) .decode else .verbatim,
                ),
                .cdata => |data| {
                    try self.appendText(data, .normalize);
                    if (self.stack_len != 0) {
                        self.nodes.items[self.stack[self.stack_len - 1]]
                            .has_cdata_text = true;
                    }
                },
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
        // Copy the borrowed names and values in one branch-free pass. Entity
        // decoding and tokenized normalization are rare, so they are handled
        // afterwards instead of branching on every attribute here.
        const out: []Attribute = if (element.attrs.len == 0)
            &.{}
        else
            self.attributes.items.ptr[attr_start..][0..element.attrs.len];
        for (element.attrs, out) |attr, *dst| {
            dst.* = .{
                .name = attr.name,
                .colon = attr.colon,
                .ns = attr.namespace_uri,
                .value = attr.value,
                .whitespace_char_ref = attr.whitespace_char_ref,
            };
        }
        self.attributes.items.len += element.attrs.len;
        if (element.attrs_need_work) {
            for (out, element.attrs) |*dst, attr| {
                if (attr.needs_decode or attr.tokenized) {
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
                        const normalized = try normalizeTokenized(
                            self.allocator,
                            value,
                        );
                        dst.normalization_changed = !std.mem.eql(
                            u8,
                            value,
                            normalized,
                        );
                        value = normalized;
                    }
                    dst.value = value;
                }
            }
        }
        if (!self.parser.options.namespaces) {
            for (out, element.attrs) |*dst, attr| {
                if (namespace.Resolver.isNamespaceDeclaration(attr.name)) {
                    dst.ns = namespace.xmlns_uri;
                }
            }
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

    const TextMode = enum {
        /// Entity references must be expanded.
        decode,
        /// CDATA needs line-ending normalization only.
        normalize,
        /// The parser already proved the span is plain.
        verbatim,
    };

    fn appendText(
        self: *Builder,
        raw: []const u8,
        mode: TextMode,
    ) Error!void {
        if (self.stack_len == 0) return;
        // Entity decoding also normalizes XML line endings, so only CDATA
        // needs the separate normalization pass.
        const decoded = switch (mode) {
            .decode => try entities.decodeTextAlloc(
                self.allocator,
                raw,
                self.parser.entityTable(),
                .{},
                .{
                    .version = self.parser.xmlVersion(),
                    .preserve_undeclared = true,
                    .preserve_external = true,
                    .normalize_line_endings = self.parser.xmlVersion() == .xml_1_1 or
                        self.parser.text_has_cr,
                },
            ),
            .normalize => try normalizeLineEndings(
                self.allocator,
                raw,
                self.parser.xmlVersion(),
            ),
            .verbatim => raw,
        };
        const parent = self.stack[self.stack_len - 1];
        _ = try self.addChildNode(parent, .{ .kind = .text, .value = decoded });
        if (self.parser.text_whitespace_char_ref) {
            self.nodes.items[parent].has_whitespace_char_ref_text = true;
        }
        if (self.parser.text_has_nel_ls) {
            self.nodes.items[parent].has_nel_ls_text = true;
        }
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

/// Best-effort Linux hint so large node/attribute arrays use transparent
/// huge pages, which cuts page-fault overhead on first touch.
fn hintHugePages(pointer: [*]const u8, length: usize) void {
    if (builtin.os.tag != .linux or length < 2 * 1024 * 1024) return;
    const page_size = std.heap.page_size_min;
    const start = @intFromPtr(pointer) & ~(page_size - 1);
    const end = std.mem.alignForward(
        usize,
        @intFromPtr(pointer) + length,
        page_size,
    );
    const aligned: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(start);
    std.posix.madvise(aligned, end - start, std.posix.MADV.HUGEPAGE) catch {};
}

/// Node and attribute reservation for documents that pull in external
/// parsed entities. Real-world lookup tables (DocBook localization, glossaries)
/// expand to tens of thousands of nodes from a tiny top-level document.
const external_content_nodes = 32768;
const external_content_attributes = 32768;

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

test "DOM parses into a reusable arena" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var first = try Document.parseIn(
        &arena,
        "<root><item id='a'>one</item></root>",
        .{},
    );
    defer first.deinit();
    const first_root = first.root();
    try testing.expectEqualStrings("root", first.node(first_root).local);
    const first_item = first.findChild(first_root, "item").?;
    try testing.expectEqualStrings("a", first.attribute(first_item, "id").?);
    try testing.expectEqualStrings("one", first.node(first.node(first_item).first_child).value);

    // Resetting the arena invalidates the first document; parse a new one.
    var second = try Document.parseIn(
        &arena,
        "<other><entry>two</entry></other>",
        .{},
    );
    defer second.deinit();
    const second_root = second.root();
    try testing.expectEqualStrings("other", second.node(second_root).local);
    const entry = second.findChild(second_root, "entry").?;
    try testing.expectEqualStrings("two", second.node(second.node(entry).first_child).value);
}

fn testDtdResolver(
    _: ?*anyopaque,
    system_id: []const u8,
    _: ?[]const u8,
    _: ?[]const u8,
) ?@import("parser.zig").ExternalResource {
    if (!std.mem.eql(u8, system_id, "t.dtd")) return null;
    return .{
        .uri = "t.dtd",
        .data = "<!ELEMENT doc ANY>" ++
            "<!ELEMENT term EMPTY>" ++
            "<!ATTLIST doc xmlns:p CDATA #FIXED \"urn:p\" p:kind CDATA \"k\">" ++
            "<!ATTLIST term id ID #IMPLIED term CDATA #IMPLIED>",
    };
}

test "parser applies DTD namespace and ID declarations" {
    const input = "<!DOCTYPE doc SYSTEM 't.dtd'>" ++
        "<doc><term id='x' term='T'/></doc>";
    var doc = try Document.parse(testing.allocator, input, .{
        .parser = .{
            .namespaces = true,
            .allocator = testing.allocator,
            .resolver = .{ .context = null, .resolve = testDtdResolver },
        },
    });
    defer doc.deinit();
    const root = doc.root();
    try testing.expectEqualStrings("urn:p", doc.attribute(root, "xmlns:p").?);
    try testing.expectEqualStrings("k", doc.attribute(root, "p:kind").?);
    for (doc.attributesOf(root)) |attr| {
        if (std.mem.eql(u8, attr.name, "p:kind")) {
            try testing.expectEqualStrings("urn:p", attr.ns);
        }
    }
    var saw_id = false;
    for (doc.dtd.?.attributes) |decl| {
        if (std.mem.eql(u8, decl.element, "term") and
            std.mem.eql(u8, decl.name, "id") and
            decl.attr_type == .id)
        {
            saw_id = true;
        }
    }
    try testing.expect(saw_id);
}

test "DOM decodes mixed references and normalizes line endings" {
    const input = "<!DOCTYPE d [<!ENTITY e 'EE'>]><d>&amp;x&e;y\r</d>";
    var doc = try Document.parse(testing.allocator, input, .{});
    defer doc.deinit();
    const text = try doc.textContentAlloc(testing.allocator, doc.root());
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("&xEEy\n", text);
}
