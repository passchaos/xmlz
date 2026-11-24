//! Canonical XML 1.0/1.1 and Exclusive XML Canonicalization 1.0.
//!
//! Whole documents use `canonicalize`; XPath node-sets use
//! `canonicalizeNodes`, which applies namespace propagation and the
//! `xml:base`, `xml:lang`, and `xml:space` fixups required for document
//! subsets. For whole documents the C14N 1.0 and 1.1 forms are identical.

const std = @import("std");
const dom = @import("dom.zig");
const namespace = @import("namespace.zig");
const xpath = @import("xpath/root.zig");
const xpath_value = @import("xpath/value.zig");
const xmlbase = @import("xmlbase.zig");

pub const Version = enum { c14n_1_0, c14n_1_1 };

pub const Options = struct {
    version: Version = .c14n_1_0,
    /// Render comment nodes.
    comments: bool = false,
    /// Exclusive XML Canonicalization 1.0.
    exclusive: bool = false,
    /// Prefixes rendered as in Canonical XML even in exclusive mode. Use
    /// `#default` for the default namespace.
    inclusive_prefixes: []const []const u8 = &.{},
};

pub const SubsetOptions = struct {
    version: Version = .c14n_1_0,
    comments: bool = false,
    exclusive: bool = false,
    inclusive_prefixes: []const []const u8 = &.{},
    /// Apply the document-subset fixups for `xml:base`, `xml:lang`, and
    /// `xml:space`.
    fixup_inheritable: bool = true,
};

pub const Error = error{OutOfMemory};

/// Canonicalize an XPath node-set into a newly allocated UTF-8 buffer.
pub fn canonicalizeNodes(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
    nodes: []const xpath_value.NodeRef,
    options: SubsetOptions,
) Error![]u8 {
    var canonicalizer: Canonicalizer = .{
        .allocator = allocator,
        .document = document,
        .options = .{
            .version = options.version,
            .comments = options.comments,
            .exclusive = options.exclusive,
            .inclusive_prefixes = options.inclusive_prefixes,
        },
        .subset = try Subset.init(allocator, nodes),
        .fixup_inheritable = options.fixup_inheritable,
    };
    defer canonicalizer.deinit();
    errdefer canonicalizer.out.deinit(allocator);
    try canonicalizer.appendDocument();
    return canonicalizer.out.toOwnedSlice(allocator);
}

/// Canonicalize a whole document into a newly allocated UTF-8 buffer.
pub fn canonicalize(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
    options: Options,
) Error![]u8 {
    var canonicalizer: Canonicalizer = .{
        .allocator = allocator,
        .document = document,
        .options = options,
    };
    defer canonicalizer.deinit();
    errdefer canonicalizer.out.deinit(allocator);
    try canonicalizer.appendDocument();
    return canonicalizer.out.toOwnedSlice(allocator);
}

const AttributeEntry = struct {
    name: []const u8,
    local: []const u8,
    ns: []const u8,
    value: []const u8,
};

const AttributeKey = struct {
    element: dom.NodeId,
    index: u32,
};

const Subset = struct {
    nodes: std.AutoHashMap(dom.NodeId, void),
    attributes: std.AutoHashMap(AttributeKey, void),

    fn init(
        allocator: std.mem.Allocator,
        nodes: []const xpath_value.NodeRef,
    ) Error!Subset {
        var subset: Subset = .{
            .nodes = std.AutoHashMap(dom.NodeId, void).init(allocator),
            .attributes = std.AutoHashMap(AttributeKey, void).init(allocator),
        };
        for (nodes) |node| {
            switch (node) {
                .node => |id| try subset.nodes.put(id, {}),
                .attribute => |attribute| try subset.attributes.put(.{
                    .element = attribute.element,
                    .index = attribute.index,
                }, {}),
                .namespace_node => {},
            }
        }
        return subset;
    }

    fn deinit(self: *Subset, allocator: std.mem.Allocator) void {
        self.nodes.deinit();
        self.attributes.deinit();
        _ = allocator;
    }

    fn hasNode(self: *const Subset, id: dom.NodeId) bool {
        return self.nodes.contains(id);
    }

    fn hasAttribute(
        self: *const Subset,
        element: dom.NodeId,
        index: usize,
    ) bool {
        return self.attributes.contains(.{
            .element = element,
            .index = @intCast(index),
        });
    }
};

const Canonicalizer = struct {
    allocator: std.mem.Allocator,
    document: *const dom.Document,
    options: Options,
    out: std.ArrayList(u8) = .empty,
    /// Namespace bindings rendered by output ancestors, in document order.
    rendered: std.ArrayList(namespace.Binding) = .empty,
    subset: ?Subset = null,
    fixup_inheritable: bool = false,
    /// Base URIs of rendered ancestor elements, outermost first.
    output_bases: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *Canonicalizer) void {
        self.rendered.deinit(self.allocator);
        self.output_bases.deinit(self.allocator);
        if (self.subset) |*subset| subset.deinit(self.allocator);
    }

    fn appendDocument(self: *Canonicalizer) Error!void {
        const root = self.document.root();
        var passed_root = false;
        var child = self.document.node(self.document.documentNode()).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const node_value = self.document.node(child);
            if (child == root) passed_root = true;
            switch (node_value.kind) {
                .element => try self.appendElement(child),
                .comment => {
                    if (!self.options.comments) continue;
                    if (self.subset) |*subset| {
                        if (!subset.hasNode(child)) continue;
                    }
                    try self.appendOutsideNode(child, passed_root and child != root);
                },
                .processing_instruction => {
                    if (self.subset) |*subset| {
                        if (!subset.hasNode(child)) continue;
                    }
                    try self.appendOutsideNode(child, passed_root and child != root);
                },
                .text => {
                    if (self.subset) |*subset| {
                        if (!subset.hasNode(child)) continue;
                    }
                    try self.appendEscapedText(node_value.value);
                },
                .document => unreachable,
            }
        }
    }

    /// PIs and comments before the document element are followed by a
    /// newline; those after it are preceded by one. This separates them from
    /// the document element without adding a leading or trailing newline.
    fn appendOutsideNode(
        self: *Canonicalizer,
        id: dom.NodeId,
        seen_root: bool,
    ) Error!void {
        if (seen_root) try self.out.append(self.allocator, '\n');
        try self.appendNode(id);
        if (!seen_root) try self.out.append(self.allocator, '\n');
    }

    fn appendNode(self: *Canonicalizer, id: dom.NodeId) Error!void {
        const node_value = self.document.node(id);
        switch (node_value.kind) {
            .element => try self.appendElement(id),
            .text => {
                if (self.subset) |*subset| {
                    if (!subset.hasNode(id)) return;
                }
                try self.appendEscapedText(node_value.value);
            },
            .comment => {
                if (!self.options.comments) return;
                if (self.subset) |*subset| {
                    if (!subset.hasNode(id)) return;
                }
                try self.out.appendSlice(self.allocator, "<!--");
                try self.out.appendSlice(self.allocator, node_value.value);
                try self.out.appendSlice(self.allocator, "-->");
            },
            .processing_instruction => {
                if (self.subset) |*subset| {
                    if (!subset.hasNode(id)) return;
                }
                try self.out.appendSlice(self.allocator, "<?");
                try self.out.appendSlice(self.allocator, node_value.name);
                if (node_value.value.len != 0) {
                    try self.out.append(self.allocator, ' ');
                    try self.out.appendSlice(self.allocator, node_value.value);
                }
                try self.out.appendSlice(self.allocator, "?>");
            },
            .document => {},
        }
    }

    fn appendElement(self: *Canonicalizer, id: dom.NodeId) Error!void {
        const node_value = self.document.node(id);
        if (self.subset) |*subset| {
            if (!subset.hasNode(id)) {
                // The element itself is not in the node-set, but selected
                // descendants may still be rendered.
                var child = node_value.first_child;
                while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
                    try self.appendNode(child);
                }
                return;
            }
        }
        const mark = self.rendered.items.len;
        defer self.rendered.shrinkRetainingCapacity(mark);

        var owned_base: ?[]u8 = null;
        defer if (owned_base) |value| self.allocator.free(value);
        var base: []const u8 = "";
        if (self.subset != null and self.fixup_inheritable) {
            owned_base = xmlbase.elementBase(
                self.allocator,
                self.document,
                id,
                "",
            ) catch null;
            if (owned_base) |value| base = value;
        }
        try self.output_bases.append(self.allocator, base);
        defer _ = self.output_bases.pop();

        try self.out.append(self.allocator, '<');
        try self.out.appendSlice(self.allocator, node_value.name);
        try self.appendNamespaces(id);
        try self.appendAttributes(id);
        try self.out.append(self.allocator, '>');

        var child = node_value.first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            try self.appendNode(child);
        }

        try self.out.appendSlice(self.allocator, "</");
        try self.out.appendSlice(self.allocator, node_value.name);
        try self.out.append(self.allocator, '>');
    }

    fn appendNamespaces(self: *Canonicalizer, id: dom.NodeId) Error!void {
        const bindings = try self.document.inScopeNamespaces(self.allocator, id);
        defer self.allocator.free(bindings);
        std.mem.sort(namespace.Binding, bindings, {}, namespace.bindingLessThan);

        const element_prefix = prefixOf(self.document.node(id).name);
        const default_visible = element_prefix.len == 0;
        var has_default = false;
        for (bindings) |binding| {
            if (binding.prefix.len == 0) {
                has_default = true;
                break;
            }
        }

        // An element without a default namespace node still has to reset an
        // ancestor's default namespace in the canonical form.
        const context_default = self.renderedBinding("");
        const default_in_scope = context_default != null and
            context_default.?.len != 0;
        const reset_default = if (self.options.exclusive)
            (default_visible or self.inclusivePrefix("")) and default_in_scope
        else
            default_in_scope;
        if (!has_default and reset_default) {
            try self.appendDeclaration("", "");
            try self.pushBinding(.{ .prefix = "", .uri = "" });
        }

        for (bindings) |binding| {
            if (std.mem.eql(u8, binding.prefix, "xml")) continue;
            if (self.options.exclusive) {
                const utilized = if (binding.prefix.len == 0)
                    default_visible
                else
                    std.mem.eql(u8, element_prefix, binding.prefix) or
                        self.attributeUsesPrefix(id, binding.prefix);
                if (!utilized and !self.inclusivePrefix(binding.prefix)) {
                    continue;
                }
            }
            if (self.renderedBinding(binding.prefix)) |uri| {
                if (std.mem.eql(u8, uri, binding.uri)) continue;
            }
            try self.appendDeclaration(binding.prefix, binding.uri);
            try self.pushBinding(binding);
        }
    }

    fn appendAttributes(self: *Canonicalizer, id: dom.NodeId) Error!void {
        var entries: std.ArrayList(AttributeEntry) = .empty;
        defer entries.deinit(self.allocator);
        for (self.document.attributesOf(id), 0..) |attribute, index| {
            if (namespace.Resolver.isNamespaceDeclaration(attribute.name())) {
                continue;
            }
            if (self.subset) |*subset| {
                if (!subset.hasAttribute(id, index)) continue;
            }
            try entries.append(self.allocator, .{
                .name = attribute.name(),
                .local = attribute.localName(),
                .ns = self.document.ns(attribute.ns),
                .value = attribute.value(),
            });
        }
        var owned: std.ArrayList([]u8) = .empty;
        defer {
            for (owned.items) |value| self.allocator.free(value);
            owned.deinit(self.allocator);
        }
        if (self.subset != null and self.fixup_inheritable) {
            try self.appendInheritableFixups(id, &entries, &owned);
            try self.appendBaseFixup(id, &entries, &owned);
        }
        std.mem.sort(AttributeEntry, entries.items, {}, attributeLessThan);
        for (entries.items) |entry| {
            try self.out.append(self.allocator, ' ');
            try self.out.appendSlice(self.allocator, entry.name);
            try self.out.appendSlice(self.allocator, "=\"");
            try self.appendEscapedAttribute(entry.value);
            try self.out.append(self.allocator, '"');
        }
    }

    fn selectedAttribute(
        self: *const Canonicalizer,
        id: dom.NodeId,
        index: usize,
    ) bool {
        const subset = &(self.subset orelse return false);
        return subset.hasAttribute(id, index);
    }

    fn selectedAttributeValue(
        self: *const Canonicalizer,
        id: dom.NodeId,
        ns: []const u8,
        local: []const u8,
    ) ?[]const u8 {
        for (self.document.attributesOf(id), 0..) |attribute, index| {
            if (!std.mem.eql(u8, self.document.ns(attribute.ns), ns) or
                !std.mem.eql(u8, attribute.localName(), local))
            {
                continue;
            }
            if (!self.selectedAttribute(id, index)) return null;
            return attribute.value();
        }
        return null;
    }

    fn appendInheritableFixups(
        self: *Canonicalizer,
        id: dom.NodeId,
        entries: *std.ArrayList(AttributeEntry),
        owned: *std.ArrayList([]u8),
    ) Error!void {
        const inheritable = [_][]const u8{ "lang", "space" };
        for (inheritable) |local| {
            if (self.selectedAttributeValue(
                id,
                namespace.xml_uri,
                local,
            ) != null) {
                continue;
            }
            var current = self.document.node(id).parent;
            var found: ?[]const u8 = null;
            while (current != dom.null_node) {
                const node = self.document.node(current);
                if (node.kind != .element) break;
                for (self.document.attributesOf(current), 0..) |attribute, index| {
                    if (!std.mem.eql(u8, self.document.ns(attribute.ns), namespace.xml_uri) or
                        !std.mem.eql(u8, attribute.localName(), local))
                    {
                        continue;
                    }
                    const rendered = self.subset.?.hasNode(current) and
                        self.selectedAttribute(current, index);
                    if (!rendered) found = attribute.value();
                    break;
                }
                if (found != null) break;
                current = node.parent;
            }
            if (found) |value| {
                const name = try std.fmt.allocPrint(
                    self.allocator,
                    "xml:{s}",
                    .{local},
                );
                try owned.append(self.allocator, name);
                try entries.append(self.allocator, .{
                    .name = name,
                    .local = local,
                    .ns = namespace.xml_uri,
                    .value = value,
                });
            }
        }
    }

    fn appendBaseFixup(
        self: *Canonicalizer,
        id: dom.NodeId,
        entries: *std.ArrayList(AttributeEntry),
        owned: *std.ArrayList([]u8),
    ) Error!void {
        const base_owned = xmlbase.elementBase(
            self.allocator,
            self.document,
            id,
            "",
        ) catch null;
        defer if (base_owned) |value| self.allocator.free(value);
        const base: []const u8 = if (base_owned) |value| value else "";

        var selected_base = false;
        for (self.document.attributesOf(id), 0..) |attribute, index| {
            if (!std.mem.eql(u8, self.document.ns(attribute.ns), namespace.xml_uri) or
                !std.mem.eql(u8, attribute.localName(), "base"))
            {
                continue;
            }
            selected_base = self.selectedAttribute(id, index);
            break;
        }
        if (selected_base) {
            // C14N 1.1 replaces a selected xml:base value with the resolved
            // base URI. C14N 1.0 keeps the authored value.
            if (self.options.version == .c14n_1_1) {
                const value = try self.allocator.dupe(u8, base);
                try owned.append(self.allocator, value);
                for (entries.items) |*entry| {
                    if (std.mem.eql(u8, entry.ns, namespace.xml_uri) and
                        std.mem.eql(u8, entry.local, "base"))
                    {
                        entry.value = value;
                        break;
                    }
                }
            }
            return;
        }
        const current = if (self.output_bases.items.len > 1)
            self.output_bases.items[self.output_bases.items.len - 2]
        else
            "";
        if (base.len == 0 or std.mem.eql(u8, base, current)) return;
        const name = try self.allocator.dupe(u8, "xml:base");
        try owned.append(self.allocator, name);
        const value = try self.allocator.dupe(u8, base);
        try owned.append(self.allocator, value);
        try entries.append(self.allocator, .{
            .name = name,
            .local = "base",
            .ns = namespace.xml_uri,
            .value = value,
        });
    }

    fn appendDeclaration(
        self: *Canonicalizer,
        prefix: []const u8,
        uri: []const u8,
    ) Error!void {
        try self.out.append(self.allocator, ' ');
        if (prefix.len == 0) {
            try self.out.appendSlice(self.allocator, "xmlns");
        } else {
            try self.out.appendSlice(self.allocator, "xmlns:");
            try self.out.appendSlice(self.allocator, prefix);
        }
        try self.out.appendSlice(self.allocator, "=\"");
        try self.appendEscapedAttribute(uri);
        try self.out.append(self.allocator, '"');
    }

    fn appendEscapedText(self: *Canonicalizer, text: []const u8) Error!void {
        for (text) |byte| {
            switch (byte) {
                '&' => try self.out.appendSlice(self.allocator, "&amp;"),
                '<' => try self.out.appendSlice(self.allocator, "&lt;"),
                '>' => try self.out.appendSlice(self.allocator, "&gt;"),
                '\r' => try self.out.appendSlice(self.allocator, "&#xD;"),
                else => try self.out.append(self.allocator, byte),
            }
        }
    }

    fn appendEscapedAttribute(
        self: *Canonicalizer,
        value: []const u8,
    ) Error!void {
        for (value) |byte| {
            switch (byte) {
                '&' => try self.out.appendSlice(self.allocator, "&amp;"),
                '<' => try self.out.appendSlice(self.allocator, "&lt;"),
                '"' => try self.out.appendSlice(self.allocator, "&quot;"),
                '\t' => try self.out.appendSlice(self.allocator, "&#x9;"),
                '\n' => try self.out.appendSlice(self.allocator, "&#xA;"),
                '\r' => try self.out.appendSlice(self.allocator, "&#xD;"),
                else => try self.out.append(self.allocator, byte),
            }
        }
    }

    fn pushBinding(
        self: *Canonicalizer,
        binding: namespace.Binding,
    ) Error!void {
        try self.rendered.append(self.allocator, binding);
    }

    fn renderedBinding(
        self: *const Canonicalizer,
        prefix: []const u8,
    ) ?[]const u8 {
        var index = self.rendered.items.len;
        while (index > 0) {
            index -= 1;
            if (std.mem.eql(u8, self.rendered.items[index].prefix, prefix)) {
                return self.rendered.items[index].uri;
            }
        }
        return null;
    }

    fn attributeUsesPrefix(
        self: *const Canonicalizer,
        id: dom.NodeId,
        prefix: []const u8,
    ) bool {
        for (self.document.attributesOf(id), 0..) |attribute, index| {
            if (namespace.Resolver.isNamespaceDeclaration(attribute.name())) {
                continue;
            }
            if (self.subset) |*subset| {
                if (!subset.hasAttribute(id, index)) continue;
            }
            if (std.mem.eql(u8, attribute.prefixName(), prefix)) return true;
        }
        return false;
    }

    fn inclusivePrefix(self: *const Canonicalizer, prefix: []const u8) bool {
        if (!self.options.exclusive) return true;
        for (self.options.inclusive_prefixes) |candidate| {
            if (std.mem.eql(u8, candidate, "#default")) {
                if (prefix.len == 0) return true;
            } else if (std.mem.eql(u8, candidate, prefix)) {
                return true;
            }
        }
        return false;
    }
};

fn prefixOf(name: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, name, ':')) |colon| return name[0..colon];
    return "";
}

fn attributeLessThan(_: void, a: AttributeEntry, b: AttributeEntry) bool {
    const order = std.mem.order(u8, a.ns, b.ns);
    if (order != .eq) return order == .lt;
    return std.mem.order(u8, a.local, b.local) == .lt;
}

const testing = std.testing;

test "canonicalizes namespaces attributes and escaping" {
    const source =
        "<a z=\"1\" xmlns:p=\"urn:p\" a=\"2\" xmlns=\"urn:d\">" ++
        "<p:b p:x=\"&quot;&amp;&lt;&#9;&#10;&#13;&gt;\" y=\"&quot;&amp;&lt;&#9;&#10;&#13;&gt;\">" ++
        "&lt;&amp;&gt;&#13;</p:b></a>";
    var document = try dom.Document.parse(testing.allocator, source, .{});
    defer document.deinit();
    const result = try canonicalize(testing.allocator, &document, .{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings(
        "<a xmlns=\"urn:d\" xmlns:p=\"urn:p\" a=\"2\" z=\"1\">" ++
            "<p:b y=\"&quot;&amp;&lt;&#x9;&#xA;&#xD;>\" " ++
            "p:x=\"&quot;&amp;&lt;&#x9;&#xA;&#xD;>\">" ++
            "&lt;&amp;&gt;&#xD;</p:b></a>",
        result,
    );
}

test "canonicalizes namespace shadowing and undeclarations" {
    var document = try dom.Document.parse(
        testing.allocator,
        "<a xmlns:p='urn:one'><b xmlns:p='urn:two'><p:c/></b></a>",
        .{},
    );
    defer document.deinit();
    const result = try canonicalize(testing.allocator, &document, .{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings(
        "<a xmlns:p=\"urn:one\"><b xmlns:p=\"urn:two\">" ++
            "<p:c></p:c></b></a>",
        result,
    );

    var undeclared = try dom.Document.parse(
        testing.allocator,
        "<a xmlns='urn:a'><b xmlns=''><c/></b></a>",
        .{},
    );
    defer undeclared.deinit();
    const undeclared_result = try canonicalize(
        testing.allocator,
        &undeclared,
        .{},
    );
    defer testing.allocator.free(undeclared_result);
    try testing.expectEqualStrings(
        "<a xmlns=\"urn:a\"><b xmlns=\"\"><c></c></b></a>",
        undeclared_result,
    );

    var empty_default = try dom.Document.parse(
        testing.allocator,
        "<a xmlns=''><b/></a>",
        .{},
    );
    defer empty_default.deinit();
    const empty_result = try canonicalize(
        testing.allocator,
        &empty_default,
        .{},
    );
    defer testing.allocator.free(empty_result);
    try testing.expectEqualStrings("<a><b></b></a>", empty_result);
}

test "exclusive canonicalization renders only visible namespaces" {
    var document = try dom.Document.parse(
        testing.allocator,
        "<a xmlns='urn:a' xmlns:p='urn:p'><p:b><c/></p:b></a>",
        .{},
    );
    defer document.deinit();
    const result = try canonicalize(testing.allocator, &document, .{
        .exclusive = true,
    });
    defer testing.allocator.free(result);
    try testing.expectEqualStrings(
        "<a xmlns=\"urn:a\"><p:b xmlns:p=\"urn:p\">" ++
            "<c></c></p:b></a>",
        result,
    );

    const inclusive = try canonicalize(testing.allocator, &document, .{
        .exclusive = true,
        .inclusive_prefixes = &.{"p"},
    });
    defer testing.allocator.free(inclusive);
    try testing.expectEqualStrings(
        "<a xmlns=\"urn:a\" xmlns:p=\"urn:p\"><p:b><c></c></p:b></a>",
        inclusive,
    );

    var undeclared = try dom.Document.parse(
        testing.allocator,
        "<a xmlns='urn:a'><b xmlns=''><c/></b></a>",
        .{},
    );
    defer undeclared.deinit();
    const undeclared_result = try canonicalize(
        testing.allocator,
        &undeclared,
        .{ .exclusive = true },
    );
    defer testing.allocator.free(undeclared_result);
    try testing.expectEqualStrings(
        "<a xmlns=\"urn:a\"><b xmlns=\"\"><c></c></b></a>",
        undeclared_result,
    );
}

test "canonicalizes comments and processing instructions outside the root" {
    const source = "<?p1 a?><!--c1--><root/><!--c2--><?p3 d?>";
    var document = try dom.Document.parse(testing.allocator, source, .{
        .keep_comments = true,
        .keep_pis = true,
    });
    defer document.deinit();

    const with_comments = try canonicalize(testing.allocator, &document, .{
        .comments = true,
    });
    defer testing.allocator.free(with_comments);
    try testing.expectEqualStrings(
        "<?p1 a?>\n<!--c1-->\n<root></root>\n<!--c2-->\n<?p3 d?>",
        with_comments,
    );

    const without_comments = try canonicalize(testing.allocator, &document, .{});
    defer testing.allocator.free(without_comments);
    try testing.expectEqualStrings(
        "<?p1 a?>\n<root></root>\n<?p3 d?>",
        without_comments,
    );
}

test "canonicalizes DTD default attributes and empty elements" {
    const source =
        "<!DOCTYPE a [<!ATTLIST a x CDATA 'd' y CDATA 'z'>]><a y='v'/>";
    var document = try dom.Document.parse(testing.allocator, source, .{});
    defer document.deinit();
    const result = try canonicalize(testing.allocator, &document, .{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("<a x=\"d\" y=\"v\"></a>", result);
}

fn selectNodes(
    document: *const dom.Document,
    source: []const u8,
) ![]xpath_value.NodeRef {
    var expression = try xpath.Expression.parse(testing.allocator, source);
    defer expression.deinit();
    const context: xpath_value.Context = .{
        .document = document,
        .node = .{ .node = 0 },
    };
    var result = try expression.evaluate(testing.allocator, &context);
    defer result.deinit();
    return switch (result.value) {
        .node_set => |nodes| testing.allocator.dupe(
            xpath_value.NodeRef,
            nodes,
        ),
        else => error.TestUnexpectedResult,
    };
}

test "canonicalizes document subsets with namespace propagation" {
    var document = try dom.Document.parse(
        testing.allocator,
        "<root xmlns:a='urn:a'><a:child a:x='1'><a:leaf/></a:child></root>",
        .{},
    );
    defer document.deinit();

    const subtree =
        "/*/*/descendant-or-self::node() | " ++
        "/*/*/descendant-or-self::node()/@*";
    const nodes = try selectNodes(&document, subtree);
    defer testing.allocator.free(nodes);
    const result = try canonicalizeNodes(
        testing.allocator,
        &document,
        nodes,
        .{},
    );
    defer testing.allocator.free(result);
    try testing.expectEqualStrings(
        "<a:child xmlns:a=\"urn:a\" a:x=\"1\">" ++
            "<a:leaf></a:leaf></a:child>",
        result,
    );

    const element_only = try selectNodes(&document, "/*/*");
    defer testing.allocator.free(element_only);
    const element_result = try canonicalizeNodes(
        testing.allocator,
        &document,
        element_only,
        .{},
    );
    defer testing.allocator.free(element_result);
    try testing.expectEqualStrings(
        "<a:child xmlns:a=\"urn:a\"></a:child>",
        element_result,
    );
}

test "canonicalizes document subsets with inheritable attribute fixup" {
    var document = try dom.Document.parse(
        testing.allocator,
        "<root xml:lang='en' xml:space='preserve' " ++
            "xml:base='http://e/dir/'><child><leaf/></child></root>",
        .{},
    );
    defer document.deinit();
    const subtree =
        "/*/*/descendant-or-self::node() | " ++
        "/*/*/descendant-or-self::node()/@*";
    const nodes = try selectNodes(&document, subtree);
    defer testing.allocator.free(nodes);
    const result = try canonicalizeNodes(
        testing.allocator,
        &document,
        nodes,
        .{},
    );
    defer testing.allocator.free(result);
    try testing.expectEqualStrings(
        "<child xml:base=\"http://e/dir/\" xml:lang=\"en\" " ++
            "xml:space=\"preserve\"><leaf xml:lang=\"en\" " ++
            "xml:space=\"preserve\"></leaf></child>",
        result,
    );
}

test "canonicalizes xml:base fixup for C14N 1.0 and 1.1" {
    var document = try dom.Document.parse(
        testing.allocator,
        "<root xml:base='something/else'><child xml:base='bar/'>" ++
            "<leaf xml:base='foo'/></child></root>",
        .{},
    );
    defer document.deinit();
    const expression =
        "/*/*/*/descendant-or-self::node() | " ++
        "/*/*/*/descendant-or-self::node()/@*";
    const nodes = try selectNodes(&document, expression);
    defer testing.allocator.free(nodes);

    const c14n10 = try canonicalizeNodes(
        testing.allocator,
        &document,
        nodes,
        .{},
    );
    defer testing.allocator.free(c14n10);
    try testing.expectEqualStrings(
        "<leaf xml:base=\"foo\"></leaf>",
        c14n10,
    );

    const c14n11 = try canonicalizeNodes(
        testing.allocator,
        &document,
        nodes,
        .{ .version = .c14n_1_1 },
    );
    defer testing.allocator.free(c14n11);
    try testing.expectEqualStrings(
        "<leaf xml:base=\"something/bar/foo\"></leaf>",
        c14n11,
    );
}

test "canonicalizes document subset comments and exclusive namespaces" {
    var document = try dom.Document.parse(
        testing.allocator,
        "<root xmlns:a='urn:a' xmlns:b='urn:b'>" ++
            "<!--c--><a:child b:x='1'/></root>",
        .{ .keep_comments = true },
    );
    defer document.deinit();
    const comments = try selectNodes(
        &document,
        "/root/comment() | /root/*",
    );
    defer testing.allocator.free(comments);
    const with_comments = try canonicalizeNodes(
        testing.allocator,
        &document,
        comments,
        .{ .comments = true },
    );
    defer testing.allocator.free(with_comments);
    try testing.expectEqualStrings(
        "<!--c--><a:child xmlns:a=\"urn:a\" xmlns:b=\"urn:b\">" ++
            "</a:child>",
        with_comments,
    );
    const without_comments = try canonicalizeNodes(
        testing.allocator,
        &document,
        comments,
        .{},
    );
    defer testing.allocator.free(without_comments);
    try testing.expectEqualStrings(
        "<a:child xmlns:a=\"urn:a\" xmlns:b=\"urn:b\"></a:child>",
        without_comments,
    );

    const with_attribute = try selectNodes(
        &document,
        "/root/* | /root/*/@*",
    );
    defer testing.allocator.free(with_attribute);
    const exclusive = try canonicalizeNodes(
        testing.allocator,
        &document,
        with_attribute,
        .{ .exclusive = true },
    );
    defer testing.allocator.free(exclusive);
    try testing.expectEqualStrings(
        "<a:child xmlns:a=\"urn:a\" xmlns:b=\"urn:b\" " ++
            "b:x=\"1\"></a:child>",
        exclusive,
    );
}
