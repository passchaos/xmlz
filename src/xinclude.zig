//! XInclude 1.0 processing over `dom.Document`.
//!
//! Supports `xi:include` with `parse="xml"` (default) and `parse="text"`,
//! `xi:fallback`, nested inclusions, circular detection, and namespace
//! declaration inheritance from the included document's root. XPointer is
//! rejected because xmlz does not implement XPointer.

const std = @import("std");
const dom = @import("dom.zig");
const dom_builder = @import("dom_builder.zig");
const encoding = @import("encoding.zig");
const namespace = @import("namespace.zig");

pub const namespace_uri = "http://www.w3.org/2001/XInclude";

pub const Error = error{
    OutOfMemory,
    MissingHref,
    ResourceNotFound,
    ParseFailed,
    CircularInclude,
    DepthLimitExceeded,
    InclusionLimitExceeded,
    UnsupportedXPointer,
    UnsupportedParseMode,
    InvalidInclude,
};

pub const Resource = struct {
    /// Resolved URI, used as the base for nested includes. Owned by the
    /// resolver and must remain valid for the processing call.
    uri: []const u8,
    data: []const u8,
};

pub const Resolver = struct {
    context: ?*anyopaque = null,
    load: *const fn (
        context: ?*anyopaque,
        href: []const u8,
        base: []const u8,
    ) ?Resource,
};

pub const Options = struct {
    resolver: ?Resolver = null,
    /// Base URI for the top-level document.
    base: []const u8 = "",
    max_depth: usize = 8,
    max_inclusions: usize = 100,
};

pub fn process(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
    options: Options,
) Error!dom.Document {
    var processor: Processor = .{
        .allocator = allocator,
        .options = options,
        .builder = dom_builder.Builder.init(allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidInclude,
        },
    };
    errdefer processor.builder.deinit();
    defer processor.deinit();
    if (document.declaration) |declaration| {
        processor.builder.setDeclaration(declaration);
    }
    if (document.doctype) |doctype| {
        processor.builder.setDoctype(doctype);
    }
    try processor.copyDocument(document, options.base);
    return processor.builder.finish() catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidInclude,
    };
}

const Processor = struct {
    allocator: std.mem.Allocator,
    options: Options,
    builder: dom_builder.Builder,
    inclusions: usize = 0,
    stack: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *Processor) void {
        self.stack.deinit(self.allocator);
    }

    fn copyDocument(self: *Processor, source: *const dom.Document, base: []const u8) Error!void {
        var child = source.node(0).first_child;
        while (child != dom.null_node) : (child = source.node(child).next_sibling) {
            try self.copyNode(source, base, child, self.builder.document(), null);
        }
    }

    fn copyNode(
        self: *Processor,
        source: *const dom.Document,
        base: []const u8,
        id: dom.NodeId,
        parent: dom.NodeId,
        inherited_root: ?dom.NodeId,
    ) Error!void {
        const node = source.node(id);
        switch (node.kind) {
            .element => {
                if (std.mem.eql(u8, node.ns, namespace_uri) and
                    std.mem.eql(u8, node.local, "include"))
                {
                    try self.processInclude(source, base, id, parent);
                    return;
                }
                if (std.mem.eql(u8, node.ns, namespace_uri) and
                    std.mem.eql(u8, node.local, "fallback"))
                {
                    return error.InvalidInclude;
                }

                const new_id = self.builder.createElementNs(
                    prefixOf(node),
                    node.local,
                    node.ns,
                ) catch |err| return mapBuilderError(err);
                for (source.attributesOf(id)) |attribute| {
                    if (namespace.Resolver.isNamespaceDeclaration(attribute.name)) {
                        self.builder.setAttribute(
                            new_id,
                            attribute.name,
                            attribute.value,
                        ) catch |err| return mapBuilderError(err);
                    } else if (attribute.ns.len == 0) {
                        self.builder.setAttribute(
                            new_id,
                            attribute.name,
                            attribute.value,
                        ) catch |err| return mapBuilderError(err);
                    } else {
                        self.builder.setAttributeNs(
                            new_id,
                            attribute.prefixName(),
                            attribute.localName(),
                            attribute.ns,
                            attribute.value,
                        ) catch |err| return mapBuilderError(err);
                    }
                }
                if (inherited_root) |root_id| {
                    for (source.attributesOf(root_id)) |attribute| {
                        if (!namespace.Resolver.isNamespaceDeclaration(attribute.name)) {
                            continue;
                        }
                        if (findAttribute(source.attributesOf(id), attribute.name) == null) {
                            self.builder.setAttribute(
                                new_id,
                                attribute.name,
                                attribute.value,
                            ) catch |err| return mapBuilderError(err);
                        }
                    }
                }
                self.builder.appendChild(parent, new_id) catch |err|
                    return mapBuilderError(err);

                var child = node.first_child;
                while (child != dom.null_node) : (child = source.node(child).next_sibling) {
                    try self.copyNode(source, base, child, new_id, null);
                }
            },
            .text => {
                const new_id = self.builder.createText(node.value) catch |err|
                    return mapBuilderError(err);
                self.builder.appendChild(parent, new_id) catch |err|
                    return mapBuilderError(err);
            },
            .comment => {
                const new_id = self.builder.createComment(node.value) catch |err|
                    return mapBuilderError(err);
                self.builder.appendChild(parent, new_id) catch |err|
                    return mapBuilderError(err);
            },
            .processing_instruction => {
                const new_id = self.builder.createProcessingInstruction(
                    node.name,
                    node.value,
                ) catch |err| return mapBuilderError(err);
                self.builder.appendChild(parent, new_id) catch |err|
                    return mapBuilderError(err);
            },
            .document => {
                var child = node.first_child;
                while (child != dom.null_node) : (child = source.node(child).next_sibling) {
                    try self.copyNode(source, base, child, parent, null);
                }
            },
        }
    }

    fn processInclude(
        self: *Processor,
        source: *const dom.Document,
        base: []const u8,
        id: dom.NodeId,
        parent: dom.NodeId,
    ) Error!void {
        const href = source.attribute(id, "href") orelse return error.MissingHref;
        if (source.attribute(id, "xpointer") != null) {
            return error.UnsupportedXPointer;
        }
        const mode = source.attribute(id, "parse") orelse "xml";
        if (!std.mem.eql(u8, mode, "xml") and
            !std.mem.eql(u8, mode, "text"))
        {
            return error.UnsupportedParseMode;
        }

        const resolver = self.options.resolver orelse {
            return self.useFallback(source, base, id, parent, error.ResourceNotFound);
        };
        const resource = resolver.load(resolver.context, href, base) orelse {
            return self.useFallback(source, base, id, parent, error.ResourceNotFound);
        };
        self.inclusions += 1;
        if (self.inclusions > self.options.max_inclusions) {
            return error.InclusionLimitExceeded;
        }

        if (std.mem.eql(u8, mode, "text")) {
            const new_id = self.builder.createText(resource.data) catch |err|
                return mapBuilderError(err);
            self.builder.appendChild(parent, new_id) catch |err|
                return mapBuilderError(err);
            return;
        }

        for (self.stack.items) |uri| {
            if (std.mem.eql(u8, uri, resource.uri)) {
                return self.useFallback(source, base, id, parent, error.CircularInclude);
            }
        }
        if (self.stack.items.len >= self.options.max_depth) {
            return self.useFallback(source, base, id, parent, error.DepthLimitExceeded);
        }

        const decoded = encoding.decodeAlloc(
            self.allocator,
            resource.data,
            64 * 1024 * 1024,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return self.useFallback(source, base, id, parent, error.ParseFailed),
        };
        defer self.allocator.free(decoded);
        var included = dom.Document.parse(self.allocator, decoded, .{
            .keep_comments = true,
            .keep_pis = true,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return self.useFallback(source, base, id, parent, error.ParseFailed),
        };
        defer included.deinit();
        const included_root = included.root();
        if (included_root == dom.null_node) {
            return self.useFallback(source, base, id, parent, error.ParseFailed);
        }

        self.stack.append(self.allocator, resource.uri) catch
            return error.OutOfMemory;
        defer _ = self.stack.pop();

        var child = included.node(included_root).first_child;
        while (child != dom.null_node) : (child = included.node(child).next_sibling) {
            try self.copyNode(
                &included,
                resource.uri,
                child,
                parent,
                included_root,
            );
        }
    }

    fn useFallback(
        self: *Processor,
        source: *const dom.Document,
        base: []const u8,
        id: dom.NodeId,
        parent: dom.NodeId,
        original: Error,
    ) Error!void {
        var child = source.node(id).first_child;
        while (child != dom.null_node) : (child = source.node(child).next_sibling) {
            const node = source.node(child);
            if (node.kind == .element and std.mem.eql(u8, node.ns, namespace_uri) and
                std.mem.eql(u8, node.local, "fallback"))
            {
                var fallback_child = node.first_child;
                while (fallback_child != dom.null_node) : (fallback_child = source.node(fallback_child).next_sibling) {
                    try self.copyNode(
                        source,
                        base,
                        fallback_child,
                        parent,
                        null,
                    );
                }
                return;
            }
        }
        return original;
    }
};

fn prefixOf(node: *const dom.Node) []const u8 {
    if (node.local.len == node.name.len or node.local.len >= node.name.len) {
        return "";
    }
    return node.name[0 .. node.name.len - node.local.len - 1];
}

fn findAttribute(
    attributes: []const dom.Attribute,
    name: []const u8,
) ?dom.Attribute {
    for (attributes) |attribute| {
        if (std.mem.eql(u8, attribute.name, name)) return attribute;
    }
    return null;
}

fn mapBuilderError(err: dom_builder.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidInclude,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const TestResource = struct {
    href: []const u8,
    uri: []const u8,
    data: []const u8,
};

const MapResolver = struct {
    resources: []const TestResource,
};

fn loadResource(
    context: ?*anyopaque,
    href: []const u8,
    base: []const u8,
) ?Resource {
    _ = base;
    const resolver: *const MapResolver = @ptrCast(@alignCast(context.?));
    for (resolver.resources) |resource| {
        if (std.mem.eql(u8, resource.href, href)) {
            return .{ .uri = resource.uri, .data = resource.data };
        }
    }
    return null;
}

const Source =
    \\<root xmlns:xi="http://www.w3.org/2001/XInclude">
    \\  <a/>
    \\  <xi:include href="inc.xml"/>
    \\  <b/>
    \\</root>
;

fn parseSource(source: []const u8) !dom.Document {
    return dom.Document.parse(testing.allocator, source, .{});
}

test "XInclude replaces include with included root children" {
    const resources = [_]TestResource{
        .{ .href = "inc.xml", .uri = "inc.xml", .data = "<inc><x/><y>text</y></inc>" },
    };
    var resolver: MapResolver = .{ .resources = &resources };
    var source = try parseSource(Source);
    defer source.deinit();

    var document = try process(testing.allocator, &source, .{
        .resolver = .{ .context = &resolver, .load = loadResource },
    });
    defer document.deinit();

    const root = document.root();
    try testing.expect(document.findChild(root, "a") != null);
    try testing.expect(document.findChild(root, "x") != null);
    const y = document.findChild(root, "y") orelse return error.TestUnexpectedResult;
    const text = try document.textContentAlloc(testing.allocator, y);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("text", text);
    try testing.expect(document.findChild(root, "b") != null);
}

test "XInclude uses fallback when the resource is missing" {
    const source_text =
        \\<root xmlns:xi="http://www.w3.org/2001/XInclude">
        \\  <xi:include href="missing.xml"><xi:fallback><f/></xi:fallback></xi:include>
        \\</root>
    ;
    var source = try parseSource(source_text);
    defer source.deinit();
    var document = try process(testing.allocator, &source, .{});
    defer document.deinit();
    const root = document.root();
    try testing.expect(document.findChild(root, "f") != null);
}

test "XInclude parse=text inserts character data" {
    const source_text =
        \\<root xmlns:xi="http://www.w3.org/2001/XInclude"><xi:include href="t.txt" parse="text"/></root>
    ;
    const resources = [_]TestResource{
        .{ .href = "t.txt", .uri = "t.txt", .data = "hello" },
    };
    var resolver: MapResolver = .{ .resources = &resources };
    var source = try parseSource(source_text);
    defer source.deinit();
    var document = try process(testing.allocator, &source, .{
        .resolver = .{ .context = &resolver, .load = loadResource },
    });
    defer document.deinit();
    const text = try document.textContentAlloc(testing.allocator, document.root());
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("hello", text);
}

test "XInclude handles nested includes and circularity" {
    const resources = [_]TestResource{
        .{ .href = "a.xml", .uri = "a.xml", .data = "<a><xi:include xmlns:xi=\"http://www.w3.org/2001/XInclude\" href=\"b.xml\"/></a>" },
        .{ .href = "b.xml", .uri = "b.xml", .data = "<b><leaf/></b>" },
    };
    var resolver: MapResolver = .{ .resources = &resources };
    const source_text =
        \\<root xmlns:xi="http://www.w3.org/2001/XInclude"><xi:include href="a.xml"/></root>
    ;
    var source = try parseSource(source_text);
    defer source.deinit();
    var document = try process(testing.allocator, &source, .{
        .resolver = .{ .context = &resolver, .load = loadResource },
    });
    defer document.deinit();
    const leaf = document.findChild(document.root(), "leaf");
    try testing.expect(leaf != null);

    const circular = [_]TestResource{
        .{ .href = "self.xml", .uri = "self.xml", .data = "<self><xi:include xmlns:xi=\"http://www.w3.org/2001/XInclude\" href=\"self.xml\"/></self>" },
    };
    var circular_resolver: MapResolver = .{ .resources = &circular };
    var circular_source = try parseSource(
        "<root xmlns:xi=\"http://www.w3.org/2001/XInclude\"><xi:include href=\"self.xml\"/></root>",
    );
    defer circular_source.deinit();
    try testing.expectError(
        error.CircularInclude,
        process(testing.allocator, &circular_source, .{
            .resolver = .{
                .context = &circular_resolver,
                .load = loadResource,
            },
        }),
    );
}

test "XInclude inherits namespace declarations from the included root" {
    const resources = [_]TestResource{
        .{ .href = "ns.xml", .uri = "ns.xml", .data = "<inc xmlns=\"urn:inc\"><x/></inc>" },
    };
    var resolver: MapResolver = .{ .resources = &resources };
    const source_text =
        \\<root xmlns:xi="http://www.w3.org/2001/XInclude"><xi:include href="ns.xml"/></root>
    ;
    var source = try parseSource(source_text);
    defer source.deinit();
    var document = try process(testing.allocator, &source, .{
        .resolver = .{ .context = &resolver, .load = loadResource },
    });
    defer document.deinit();
    const root = document.root();
    const child = document.findChild(root, "x") orelse
        return error.TestUnexpectedResult;
    try testing.expectEqualStrings("x", document.node(child).name);
    try testing.expectEqualStrings("urn:inc", document.node(child).ns);
    try testing.expectEqualStrings(
        "urn:inc",
        document.attribute(child, "xmlns") orelse "",
    );
}

test "XInclude reports malformed include attributes" {
    var source = try parseSource(
        "<root xmlns:xi=\"http://www.w3.org/2001/XInclude\"><xi:include/></root>",
    );
    defer source.deinit();
    try testing.expectError(
        error.MissingHref,
        process(testing.allocator, &source, .{}),
    );

    var xpointer = try parseSource(
        "<root xmlns:xi=\"http://www.w3.org/2001/XInclude\"><xi:include href=\"a\" xpointer=\"x\"/></root>",
    );
    defer xpointer.deinit();
    try testing.expectError(
        error.UnsupportedXPointer,
        process(testing.allocator, &xpointer, .{}),
    );
}
