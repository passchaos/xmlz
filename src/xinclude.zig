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
const xmlbase = @import("xmlbase.zig");

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
        processor.builder.setDeclaration(declaration) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidInclude,
        };
    }
    if (document.doctype) |doctype| {
        processor.builder.setDoctype(doctype) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidInclude,
        };
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
                const element_base = try self.elementBase(source, base, id);
                defer {
                    if (element_base) |allocated| self.allocator.free(allocated);
                }
                const current_base = element_base orelse base;
                if (std.mem.eql(u8, node.ns, namespace_uri) and
                    std.mem.eql(u8, node.local, "include"))
                {
                    try self.processInclude(source, current_base, id, parent);
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
                    try self.copyNode(source, current_base, child, new_id, null);
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

    /// Resolve an element's `xml:base` against the base inherited from its
    /// output parent. Returns null when the element has no `xml:base`.
    fn elementBase(
        self: *Processor,
        source: *const dom.Document,
        base: []const u8,
        id: dom.NodeId,
    ) Error!?[]u8 {
        const value = source.attributeNs(
            id,
            namespace.xml_uri,
            "base",
        ) orelse return null;
        return xmlbase.resolve(self.allocator, base, value) catch
            return error.OutOfMemory;
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

        const root_base = try self.elementBase(
            &included,
            resource.uri,
            included_root,
        );
        defer {
            if (root_base) |allocated| self.allocator.free(allocated);
        }
        const included_base = root_base orelse resource.uri;

        self.stack.append(self.allocator, resource.uri) catch
            return error.OutOfMemory;
        defer _ = self.stack.pop();

        var child = included.node(included_root).first_child;
        while (child != dom.null_node) : (child = included.node(child).next_sibling) {
            try self.copyNode(
                &included,
                included_base,
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

/// Resolver that asserts the base URI passed for `inc.xml` and `leaf.xml`.
const BaseRecorder = struct {
    include_base: []const u8,
    include_uri: []const u8,
    include_data: []const u8,
    leaf_base: []const u8 = "",
    leaf_seen: bool = false,
};

fn loadWithBase(
    context: ?*anyopaque,
    href: []const u8,
    base: []const u8,
) ?Resource {
    const recorder: *BaseRecorder = @ptrCast(@alignCast(context.?));
    if (std.mem.eql(u8, href, "inc.xml")) {
        if (!std.mem.eql(u8, base, recorder.include_base)) return null;
        return .{ .uri = recorder.include_uri, .data = recorder.include_data };
    }
    if (std.mem.eql(u8, href, "leaf.xml")) {
        if (!std.mem.eql(u8, base, recorder.leaf_base)) return null;
        recorder.leaf_seen = true;
        return .{ .uri = "http://e/leaf.xml", .data = "<doc><leaf/></doc>" };
    }
    return null;
}

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

test "XInclude applies xml:base to include resolution" {
    const recorder_base =
        \\<root xmlns:xi="http://www.w3.org/2001/XInclude">
        \\  <wrap xml:base="http://e/a/"><xi:include href="inc.xml"/></wrap>
        \\</root>
    ;
    var recorder: BaseRecorder = .{
        .include_base = "http://e/a/",
        .include_uri = "http://e/a/inc.xml",
        .include_data = "<inc><leaf/></inc>",
    };
    var source = try parseSource(recorder_base);
    defer source.deinit();
    var document = try process(testing.allocator, &source, .{
        .resolver = .{ .context = &recorder, .load = loadWithBase },
    });
    defer document.deinit();
    const wrap = document.findChild(document.root(), "wrap") orelse
        return error.TestUnexpectedResult;
    try testing.expect(document.findChild(wrap, "leaf") != null);

    const include_base =
        \\<root xmlns:xi="http://www.w3.org/2001/XInclude" xml:base="http://e/root/">
        \\  <xi:include xml:base="sub/" href="inc.xml"/>
        \\</root>
    ;
    var include_recorder: BaseRecorder = .{
        .include_base = "http://e/root/sub/",
        .include_uri = "http://e/root/sub/inc.xml",
        .include_data = "<inc><leaf/></inc>",
    };
    var include_source = try parseSource(include_base);
    defer include_source.deinit();
    var include_document = try process(testing.allocator, &include_source, .{
        .resolver = .{
            .context = &include_recorder,
            .load = loadWithBase,
        },
    });
    defer include_document.deinit();
    try testing.expect(
        include_document.findChild(include_document.root(), "leaf") != null,
    );
}

test "XInclude applies included root xml:base to nested includes" {
    const recorder_source =
        \\<root xmlns:xi="http://www.w3.org/2001/XInclude">
        \\  <xi:include href="inc.xml"/>
        \\</root>
    ;
    var recorder: BaseRecorder = .{
        .include_base = "",
        .include_uri = "http://e/inc.xml",
        .include_data = "<inc xml:base=\"http://e/a/\">" ++
            "<xi:include xmlns:xi=\"http://www.w3.org/2001/XInclude\" " ++
            "href=\"leaf.xml\"/></inc>",
        .leaf_base = "http://e/a/",
    };
    var source = try parseSource(recorder_source);
    defer source.deinit();
    var document = try process(testing.allocator, &source, .{
        .resolver = .{ .context = &recorder, .load = loadWithBase },
    });
    defer document.deinit();
    try testing.expect(recorder.leaf_seen);
    try testing.expect(document.findChild(document.root(), "leaf") != null);
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
