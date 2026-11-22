//! Mutable document builder that produces an immutable `dom.Document`.
//!
//! Names and values are copied into the builder's arena. After `finish` the
//! document owns the arena; do not call `deinit` on the builder.

const std = @import("std");
const chars = @import("chars.zig");
const dom = @import("dom.zig");
const namespace = @import("namespace.zig");
const parser_mod = @import("parser.zig");

pub const Error = error{
    OutOfMemory,
    InvalidName,
    InvalidTree,
    MultipleRoots,
    InvalidComment,
    InvalidProcessingInstruction,
    AlreadyFinished,
};

pub const Builder = struct {
    arena: std.heap.ArenaAllocator,
    nodes: std.ArrayList(dom.Node) = .empty,
    attr_lists: std.ArrayList(std.ArrayList(dom.Attribute)) = .empty,
    declaration: ?parser_mod.Declaration = null,
    doctype: ?parser_mod.Doctype = null,
    finished: bool = false,

    pub fn init(allocator: std.mem.Allocator) Error!Builder {
        var builder: Builder = .{ .arena = std.heap.ArenaAllocator.init(allocator) };
        errdefer builder.arena.deinit();
        _ = try builder.addNode(.{ .kind = .document });
        return builder;
    }

    pub fn deinit(self: *Builder) void {
        if (!self.finished) self.arena.deinit();
        self.finished = true;
    }

    pub fn document(self: *const Builder) dom.NodeId {
        _ = self;
        return 0;
    }

    pub fn setDeclaration(
        self: *Builder,
        declaration: parser_mod.Declaration,
    ) void {
        self.declaration = declaration;
    }

    pub fn setDoctype(self: *Builder, doctype: parser_mod.Doctype) void {
        self.doctype = doctype;
    }

    pub fn nodeAt(self: *const Builder, id: dom.NodeId) *const dom.Node {
        return &self.nodes.items[id];
    }

    pub fn createElement(self: *Builder, name: []const u8) Error!dom.NodeId {
        const owned = try self.dupe(name);
        const qname = namespace.splitQName(owned) catch return error.InvalidName;
        return self.addNode(.{
            .kind = .element,
            .name = owned,
            .local = qname.local,
        });
    }

    pub fn createElementNs(
        self: *Builder,
        prefix: []const u8,
        local: []const u8,
        uri: []const u8,
    ) Error!dom.NodeId {
        chars.validateNCName(prefix) catch {
            if (prefix.len != 0) return error.InvalidName;
        };
        chars.validateNCName(local) catch return error.InvalidName;
        const raw = if (prefix.len == 0)
            try self.dupe(local)
        else
            try std.fmt.allocPrint(
                self.arena.allocator(),
                "{s}:{s}",
                .{ prefix, local },
            );
        const owned_local = if (prefix.len == 0) raw else raw[prefix.len + 1 ..];
        return self.addNode(.{
            .kind = .element,
            .name = raw,
            .local = owned_local,
            .ns = try self.dupe(uri),
        });
    }

    pub fn createText(self: *Builder, value: []const u8) Error!dom.NodeId {
        return self.addNode(.{
            .kind = .text,
            .value = try self.dupe(value),
        });
    }

    pub fn createComment(self: *Builder, value: []const u8) Error!dom.NodeId {
        if (std.mem.indexOf(u8, value, "--") != null or
            (value.len != 0 and value[value.len - 1] == '-'))
        {
            return error.InvalidComment;
        }
        return self.addNode(.{
            .kind = .comment,
            .value = try self.dupe(value),
        });
    }

    pub fn createProcessingInstruction(
        self: *Builder,
        target: []const u8,
        data: []const u8,
    ) Error!dom.NodeId {
        chars.validateName(target) catch return error.InvalidName;
        if (std.ascii.eqlIgnoreCase(target, "xml")) {
            return error.InvalidProcessingInstruction;
        }
        if (std.mem.indexOf(u8, data, "?>") != null) {
            return error.InvalidProcessingInstruction;
        }
        return self.addNode(.{
            .kind = .processing_instruction,
            .name = try self.dupe(target),
            .value = try self.dupe(data),
        });
    }

    pub fn appendChild(
        self: *Builder,
        parent: dom.NodeId,
        child: dom.NodeId,
    ) Error!void {
        if (parent >= self.nodes.items.len or child >= self.nodes.items.len or
            child == 0)
        {
            return error.InvalidTree;
        }
        if (parent == child) return error.InvalidTree;
        if (self.isAncestor(child, parent)) return error.InvalidTree;
        if (parent == 0 and self.nodes.items[child].kind == .element) {
            if (self.firstElementChild(0) != dom.null_node) {
                return error.MultipleRoots;
            }
        }
        self.detach(child);
        self.nodes.items[child].parent = parent;
        const parent_node = &self.nodes.items[parent];
        if (parent_node.last_child != dom.null_node) {
            self.nodes.items[parent_node.last_child].next_sibling = child;
        } else {
            parent_node.first_child = child;
        }
        parent_node.last_child = child;
    }

    pub fn insertBefore(
        self: *Builder,
        parent: dom.NodeId,
        new_child: dom.NodeId,
        reference: dom.NodeId,
    ) Error!void {
        if (reference == dom.null_node) return self.appendChild(parent, new_child);
        if (parent >= self.nodes.items.len or new_child >= self.nodes.items.len or
            reference >= self.nodes.items.len or new_child == 0)
        {
            return error.InvalidTree;
        }
        if (self.nodes.items[reference].parent != parent) {
            return error.InvalidTree;
        }
        if (new_child == parent or self.isAncestor(new_child, parent)) {
            return error.InvalidTree;
        }
        if (parent == 0 and self.nodes.items[new_child].kind == .element) {
            if (self.firstElementChild(0) != dom.null_node) {
                return error.MultipleRoots;
            }
        }
        self.detach(new_child);

        var previous: dom.NodeId = dom.null_node;
        var scan = self.nodes.items[parent].first_child;
        while (scan != dom.null_node and scan != reference) : (scan = self.nodes.items[scan].next_sibling) {
            previous = scan;
        }
        if (previous == dom.null_node) {
            self.nodes.items[parent].first_child = new_child;
        } else {
            self.nodes.items[previous].next_sibling = new_child;
        }
        self.nodes.items[new_child].parent = parent;
        self.nodes.items[new_child].next_sibling = reference;
    }

    pub fn removeChild(
        self: *Builder,
        parent: dom.NodeId,
        child: dom.NodeId,
    ) Error!void {
        if (parent >= self.nodes.items.len or child >= self.nodes.items.len) {
            return error.InvalidTree;
        }
        if (self.nodes.items[child].parent != parent) {
            return error.InvalidTree;
        }
        self.detach(child);
    }

    pub fn setAttribute(
        self: *Builder,
        element: dom.NodeId,
        name: []const u8,
        value: []const u8,
    ) Error!void {
        if (element >= self.nodes.items.len or
            self.nodes.items[element].kind != .element)
        {
            return error.InvalidTree;
        }
        const owned_name = try self.dupe(name);
        const qname = namespace.splitQName(owned_name) catch return error.InvalidName;
        const list = &self.attr_lists.items[element];
        for (list.items) |*attribute| {
            if (std.mem.eql(u8, attribute.name, owned_name)) {
                attribute.value = try self.dupe(value);
                return;
            }
        }
        try list.append(self.arena.allocator(), .{
            .name = owned_name,
            .colon = if (qname.prefix.len == 0)
                0xFFFF
            else
                @intCast(qname.prefix.len),
            .ns = if (namespace.Resolver.isNamespaceDeclaration(owned_name))
                namespace.xmlns_uri
            else
                "",
            .value = try self.dupe(value),
        });
    }

    pub fn setAttributeNs(
        self: *Builder,
        element: dom.NodeId,
        prefix: []const u8,
        local: []const u8,
        uri: []const u8,
        value: []const u8,
    ) Error!void {
        if (element >= self.nodes.items.len or
            self.nodes.items[element].kind != .element)
        {
            return error.InvalidTree;
        }
        chars.validateNCName(prefix) catch {
            if (prefix.len != 0) return error.InvalidName;
        };
        chars.validateNCName(local) catch return error.InvalidName;
        const raw = if (prefix.len == 0)
            try self.dupe(local)
        else
            try std.fmt.allocPrint(
                self.arena.allocator(),
                "{s}:{s}",
                .{ prefix, local },
            );
        const list = &self.attr_lists.items[element];
        for (list.items) |*attribute| {
            if (std.mem.eql(u8, attribute.name, raw)) {
                attribute.value = try self.dupe(value);
                attribute.ns = try self.dupe(uri);
                return;
            }
        }
        try list.append(self.arena.allocator(), .{
            .name = raw,
            .colon = if (prefix.len == 0) 0xFFFF else @intCast(prefix.len),
            .ns = try self.dupe(uri),
            .value = try self.dupe(value),
        });
    }

    pub fn removeAttribute(
        self: *Builder,
        element: dom.NodeId,
        name: []const u8,
    ) Error!void {
        if (element >= self.nodes.items.len) return error.InvalidTree;
        const list = &self.attr_lists.items[element];
        for (list.items, 0..) |attribute, index| {
            if (std.mem.eql(u8, attribute.name, name)) {
                _ = list.orderedRemove(index);
                return;
            }
        }
    }

    pub fn finish(self: *Builder) Error!dom.Document {
        if (self.finished) return error.AlreadyFinished;
        const allocator = self.arena.allocator();
        var flat: std.ArrayList(dom.Attribute) = .empty;
        for (self.nodes.items, 0..) |*node, index| {
            const list = self.attr_lists.items[index];
            node.attr_start = @intCast(flat.items.len);
            node.attr_count = @intCast(list.items.len);
            try flat.appendSlice(allocator, list.items);
        }
        self.finished = true;
        return .{
            .arena = self.arena,
            .nodes = self.nodes.items,
            .attributes = flat.items,
            .declaration = self.declaration,
            .doctype = self.doctype,
        };
    }

    fn addNode(self: *Builder, node: dom.Node) Error!dom.NodeId {
        const allocator = self.arena.allocator();
        if (self.nodes.items.len >= std.math.maxInt(u32)) {
            return error.OutOfMemory;
        }
        const id: dom.NodeId = @intCast(self.nodes.items.len);
        try self.nodes.append(allocator, node);
        try self.attr_lists.append(allocator, .empty);
        return id;
    }

    fn dupe(self: *Builder, bytes: []const u8) Error![]const u8 {
        return self.arena.allocator().dupe(u8, bytes);
    }

    fn isAncestor(
        self: *const Builder,
        candidate: dom.NodeId,
        node: dom.NodeId,
    ) bool {
        var current = node;
        while (true) {
            if (current == candidate) return true;
            const parent = self.nodes.items[current].parent;
            if (parent == dom.null_node) return false;
            current = parent;
        }
    }

    fn firstElementChild(self: *const Builder, parent: dom.NodeId) dom.NodeId {
        var child = self.nodes.items[parent].first_child;
        while (child != dom.null_node) : (child = self.nodes.items[child].next_sibling) {
            if (self.nodes.items[child].kind == .element) return child;
        }
        return dom.null_node;
    }

    fn detach(self: *Builder, child: dom.NodeId) void {
        const parent = self.nodes.items[child].parent;
        if (parent == dom.null_node) return;
        var previous: dom.NodeId = dom.null_node;
        var scan = self.nodes.items[parent].first_child;
        while (scan != dom.null_node and scan != child) : (scan = self.nodes.items[scan].next_sibling) {
            previous = scan;
        }
        if (previous == dom.null_node) {
            self.nodes.items[parent].first_child = self.nodes.items[child].next_sibling;
        } else {
            self.nodes.items[previous].next_sibling = self.nodes.items[child].next_sibling;
        }
        if (self.nodes.items[parent].last_child == child) {
            self.nodes.items[parent].last_child = previous;
        }
        self.nodes.items[child].parent = dom.null_node;
        self.nodes.items[child].next_sibling = dom.null_node;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "builder creates a document that the writer round-trips" {
    var builder = try Builder.init(testing.allocator);
    defer builder.deinit();

    const root = try builder.createElement("svg");
    try builder.setAttribute(root, "width", "10");
    const rect = try builder.createElement("rect");
    try builder.setAttribute(rect, "x", "1");
    try builder.appendChild(root, rect);
    try builder.appendChild(root, try builder.createText("hello"));
    try builder.appendChild(builder.document(), root);

    var document = try builder.finish();
    defer document.deinit();

    try testing.expectEqual(root, document.root());
    try testing.expectEqualStrings("svg", document.node(root).name);
    try testing.expectEqualStrings("10", document.attribute(root, "width").?);
    try testing.expectEqual(rect, document.findChild(root, "rect").?);

    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    try @import("writer.zig").writeDocument(&allocating.writer, &document, .{
        .xml_declaration = false,
    });
    const output = try allocating.toOwnedSlice();
    defer testing.allocator.free(output);
    try testing.expect(std.mem.indexOf(u8, output, "<svg width=\"10\"><rect x=\"1\"/>hello</svg>") != null);
}

test "builder supports namespace elements and attributes" {
    var builder = try Builder.init(testing.allocator);
    defer builder.deinit();

    const root = try builder.createElement("root");
    try builder.setAttribute(root, "xmlns:p", "urn:p");
    const child = try builder.createElementNs("p", "child", "urn:p");
    try builder.setAttributeNs(child, "p", "attr", "urn:p", "v");
    try builder.appendChild(root, child);
    try builder.appendChild(builder.document(), root);

    var document = try builder.finish();
    defer document.deinit();

    try testing.expectEqualStrings("p:child", document.node(child).name);
    try testing.expectEqualStrings("urn:p", document.node(child).ns);
    try testing.expectEqualStrings("v", document.attributeNs(child, "urn:p", "attr").?);
}

test "builder inserts removes and updates nodes" {
    var builder = try Builder.init(testing.allocator);
    defer builder.deinit();

    const root = try builder.createElement("root");
    const a = try builder.createElement("a");
    const b = try builder.createElement("b");
    const c = try builder.createElement("c");
    try builder.appendChild(root, a);
    try builder.appendChild(root, c);
    try builder.insertBefore(root, b, c);
    try builder.setAttribute(root, "k", "v1");
    try builder.setAttribute(root, "k", "v2");
    try builder.removeChild(root, a);
    try builder.appendChild(builder.document(), root);

    var document = try builder.finish();
    defer document.deinit();

    try testing.expectEqual(@as(usize, 1), document.attributesOf(root).len);
    try testing.expectEqualStrings("v2", document.attribute(root, "k").?);
    try testing.expectEqual(b, document.node(root).first_child);
    try testing.expectEqual(c, document.node(b).next_sibling);
    try testing.expectEqual(dom.null_node, document.node(c).next_sibling);
}

test "builder rejects cycles multiple roots and invalid names" {
    var builder = try Builder.init(testing.allocator);
    defer builder.deinit();

    const root = try builder.createElement("root");
    const child = try builder.createElement("child");
    try builder.appendChild(root, child);
    try testing.expectError(error.InvalidTree, builder.appendChild(child, root));

    try builder.appendChild(builder.document(), root);
    const second = try builder.createElement("second");
    try testing.expectError(
        error.MultipleRoots,
        builder.appendChild(builder.document(), second),
    );
    try testing.expectError(error.InvalidName, builder.createElement("1bad"));
    try testing.expectError(
        error.InvalidComment,
        builder.createComment("bad -- comment"),
    );
    try testing.expectError(
        error.InvalidProcessingInstruction,
        builder.createProcessingInstruction("xml", "data"),
    );
}
