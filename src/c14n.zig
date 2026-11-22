//! Canonical XML 1.0/1.1 and Exclusive XML Canonicalization 1.0.
//!
//! The input is a whole document (the octet-stream form of the
//! specifications). Document-subset inputs, which additionally require
//! `xml:base` fixup and propagation of simple inheritable attributes, are not
//! supported yet. For whole documents the C14N 1.0 and 1.1 forms are
//! identical; the version is recorded for callers and future subset support.

const std = @import("std");
const dom = @import("dom.zig");
const namespace = @import("namespace.zig");

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

pub const Error = error{OutOfMemory};

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
    defer canonicalizer.rendered.deinit(allocator);
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

const Canonicalizer = struct {
    allocator: std.mem.Allocator,
    document: *const dom.Document,
    options: Options,
    out: std.ArrayList(u8) = .empty,
    /// Namespace bindings rendered by output ancestors, in document order.
    rendered: std.ArrayList(namespace.Binding) = .empty,

    fn appendDocument(self: *Canonicalizer) Error!void {
        var seen_root = false;
        var child = self.document.node(self.document.documentNode()).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const node_value = self.document.node(child);
            switch (node_value.kind) {
                .element => {
                    try self.appendElement(child);
                    seen_root = true;
                },
                .comment => {
                    if (!self.options.comments) continue;
                    try self.appendOutsideNode(child, seen_root);
                },
                .processing_instruction => try self.appendOutsideNode(
                    child,
                    seen_root,
                ),
                .text => try self.appendEscapedText(node_value.value),
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
            .text => try self.appendEscapedText(node_value.value),
            .comment => {
                if (!self.options.comments) return;
                try self.out.appendSlice(self.allocator, "<!--");
                try self.out.appendSlice(self.allocator, node_value.value);
                try self.out.appendSlice(self.allocator, "-->");
            },
            .processing_instruction => {
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
        const mark = self.rendered.items.len;
        defer self.rendered.shrinkRetainingCapacity(mark);

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
        for (self.document.attributesOf(id)) |attribute| {
            if (namespace.Resolver.isNamespaceDeclaration(attribute.name)) {
                continue;
            }
            try entries.append(self.allocator, .{
                .name = attribute.name,
                .local = attribute.localName(),
                .ns = attribute.ns,
                .value = attribute.value,
            });
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
        for (self.document.attributesOf(id)) |attribute| {
            if (namespace.Resolver.isNamespaceDeclaration(attribute.name)) {
                continue;
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
