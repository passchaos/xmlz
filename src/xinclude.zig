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
const xpath = @import("xpath/root.zig");

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
            try self.copyNode(source, base, child, self.builder.document(), null, null);
        }
    }

    fn copyNode(
        self: *Processor,
        source: *const dom.Document,
        base: []const u8,
        id: dom.NodeId,
        parent: dom.NodeId,
        inherited_root: ?dom.NodeId,
        extra_namespaces: ?[]const namespace.Binding,
    ) Error!void {
        const node = source.node(id);
        switch (node.kind) {
            .element => {
                const element_base = try self.elementBase(source, base, id);
                defer {
                    if (element_base) |allocated| self.allocator.free(allocated);
                }
                const current_base = element_base orelse base;
                if (std.mem.eql(u8, source.ns(node.ns), namespace_uri) and
                    std.mem.eql(u8, node.localName(), "include"))
                {
                    try self.processInclude(source, current_base, id, parent);
                    return;
                }
                if (std.mem.eql(u8, source.ns(node.ns), namespace_uri) and
                    std.mem.eql(u8, node.localName(), "fallback"))
                {
                    return error.InvalidInclude;
                }

                const new_id = self.builder.createElementNs(
                    prefixOf(node),
                    node.localName(),
                    source.ns(node.ns),
                ) catch |err| return mapBuilderError(err);
                for (source.attributesOf(id)) |attribute| {
                    if (namespace.Resolver.isNamespaceDeclaration(attribute.name())) {
                        self.builder.setAttribute(
                            new_id,
                            attribute.name(),
                            attribute.value(),
                        ) catch |err| return mapBuilderError(err);
                    } else if (source.ns(attribute.ns).len == 0) {
                        self.builder.setAttribute(
                            new_id,
                            attribute.name(),
                            attribute.value(),
                        ) catch |err| return mapBuilderError(err);
                    } else {
                        self.builder.setAttributeNs(
                            new_id,
                            attribute.prefixName(),
                            attribute.localName(),
                            source.ns(attribute.ns),
                            attribute.value(),
                        ) catch |err| return mapBuilderError(err);
                    }
                }
                if (inherited_root) |root_id| {
                    for (source.attributesOf(root_id)) |attribute| {
                        const attribute_name = attribute.name();
                        if (!namespace.Resolver.isNamespaceDeclaration(attribute_name)) {
                            continue;
                        }
                        if (findAttribute(source.attributesOf(id), attribute_name) == null) {
                            self.builder.setAttribute(
                                new_id,
                                attribute_name,
                                attribute.value(),
                            ) catch |err| return mapBuilderError(err);
                        }
                    }
                }
                if (extra_namespaces) |bindings| {
                    for (bindings) |binding| {
                        if (std.mem.eql(u8, binding.prefix, "xml")) continue;
                        var name_buffer: [256]u8 = undefined;
                        const name = if (binding.prefix.len == 0)
                            "xmlns"
                        else
                            std.fmt.bufPrint(
                                &name_buffer,
                                "xmlns:{s}",
                                .{binding.prefix},
                            ) catch return error.InvalidInclude;
                        if (findAttribute(source.attributesOf(id), name) != null) {
                            continue;
                        }
                        self.builder.setAttribute(
                            new_id,
                            name,
                            binding.uri,
                        ) catch |err| return mapBuilderError(err);
                    }
                }
                self.builder.appendChild(parent, new_id) catch |err|
                    return mapBuilderError(err);

                var child = node.first_child;
                while (child != dom.null_node) : (child = source.node(child).next_sibling) {
                    try self.copyNode(source, current_base, child, new_id, null, null);
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
                    try self.copyNode(source, base, child, parent, null, null);
                }
            },
        }
    }

    /// Decode a `parse="text"` resource. The `encoding` attribute selects the
    /// byte encoding; UTF-8 is the default.
    fn decodeText(
        self: *Processor,
        source: *const dom.Document,
        id: dom.NodeId,
        data: []const u8,
    ) Error![]u8 {
        const target = if (source.attribute(id, "encoding")) |name|
            encoding.decodeEncodingName(name) orelse return error.ParseFailed
        else
            encoding.DecodeEncoding.utf8;
        return encoding.decodeWithEncodingAlloc(
            self.allocator,
            data,
            target,
            64 * 1024 * 1024,
        ) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.ParseFailed,
        };
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
        const xpointer = source.attribute(id, "xpointer");
        const mode = source.attribute(id, "parse") orelse "xml";
        if (!std.mem.eql(u8, mode, "xml") and
            !std.mem.eql(u8, mode, "text"))
        {
            return error.UnsupportedParseMode;
        }
        if (xpointer != null and !std.mem.eql(u8, mode, "xml")) {
            return self.useFallback(
                source,
                base,
                id,
                parent,
                error.UnsupportedXPointer,
            );
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
            const decoded = self.decodeText(source, id, resource.data) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return self.useFallback(source, base, id, parent, err),
            };
            defer self.allocator.free(decoded);
            const new_id = self.builder.createText(decoded) catch |err|
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

        if (xpointer) |pointer| {
            // XPointer evaluation failures are fatal errors, not resource
            // errors, so fallback content is not used.
            const selected = self.selectXPointer(&included, pointer) catch |err|
                switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return err,
                };
            defer self.allocator.free(selected);
            for (selected) |selected_id| {
                var extra: ?[]namespace.Binding = null;
                if (included.node(selected_id).kind == .element) {
                    extra = included.inScopeNamespaces(
                        self.allocator,
                        selected_id,
                    ) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                    };
                }
                defer if (extra) |bindings| self.allocator.free(bindings);
                try self.copyNode(
                    &included,
                    included_base,
                    selected_id,
                    parent,
                    null,
                    extra,
                );
            }
            return;
        }

        // The document element itself is the included content; its base URI
        // and namespace declarations are preserved.
        try self.copyNode(
            &included,
            included_base,
            included_root,
            parent,
            null,
            null,
        );
    }

    fn selectXPointer(
        self: *Processor,
        included: *const dom.Document,
        pointer: []const u8,
    ) Error![]const dom.NodeId {
        const trimmed = std.mem.trim(u8, pointer, " \t\r\n");
        if (std.mem.startsWith(u8, trimmed, "element(") and
            trimmed.len > "element()".len and
            trimmed[trimmed.len - 1] == ')')
        {
            return self.selectElementPointer(
                included,
                trimmed["element(".len .. trimmed.len - 1],
            );
        }
        if (std.mem.startsWith(u8, trimmed, "xpointer(") and
            trimmed.len > "xpointer()".len and
            trimmed[trimmed.len - 1] == ')')
        {
            return self.selectXPathPointer(
                included,
                trimmed["xpointer(".len .. trimmed.len - 1],
            );
        }
        if (isNCNamePointer(trimmed)) {
            return self.selectElementById(included, trimmed);
        }
        return error.UnsupportedXPointer;
    }

    /// The `element()` scheme selects a child sequence (`/1/2`) or an element
    /// by ID.
    fn selectElementPointer(
        self: *Processor,
        included: *const dom.Document,
        content: []const u8,
    ) Error![]const dom.NodeId {
        if (content.len != 0 and content[0] == '/') {
            return self.selectElementScheme(included, content);
        }
        if (isNCNamePointer(content)) {
            return self.selectElementById(included, content);
        }
        return error.UnsupportedXPointer;
    }

    fn selectElementById(
        self: *Processor,
        included: *const dom.Document,
        id: []const u8,
    ) Error![]const dom.NodeId {
        for (included.nodes, 0..) |*node, index| {
            if (node.kind != .element) continue;
            const node_id: dom.NodeId = @intCast(index);
            if (included.attributeNs(node_id, namespace.xml_uri, "id")) |value| {
                if (xmlbase.xmlIdEquals(value, id)) {
                    return self.singleNode(node_id);
                }
            }
            if (!self.hasDtdIdAttribute(included, node, "id")) continue;
            if (included.attribute(node_id, "id")) |value| {
                if (std.mem.eql(u8, value, id)) {
                    return self.singleNode(node_id);
                }
            }
        }
        return error.UnsupportedXPointer;
    }

    fn hasDtdIdAttribute(
        self: *Processor,
        included: *const dom.Document,
        node: *const dom.Node,
        name: []const u8,
    ) bool {
        _ = self;
        const dtd = included.dtd orelse return false;
        for (dtd.attributes) |decl| {
            if (decl.attr_type == .id and
                std.mem.eql(u8, decl.element, node.name) and
                std.mem.eql(u8, decl.name, name))
            {
                return true;
            }
        }
        return false;
    }

    fn singleNode(self: *Processor, id: dom.NodeId) Error![]const dom.NodeId {
        const out = try self.allocator.alloc(dom.NodeId, 1);
        out[0] = id;
        return out;
    }

    fn selectElementScheme(
        self: *Processor,
        included: *const dom.Document,
        path: []const u8,
    ) Error![]const dom.NodeId {
        if (path.len == 0 or path[0] != '/') {
            return error.UnsupportedXPointer;
        }
        var current = included.documentNode();
        if (path.len == 1) {
            const out = try self.allocator.alloc(dom.NodeId, 1);
            out[0] = current;
            return out;
        }
        var tokens = std.mem.tokenizeScalar(u8, path[1..], '/');
        var steps: usize = 0;
        while (tokens.next()) |token| {
            const index = std.fmt.parseInt(usize, token, 10) catch
                return error.UnsupportedXPointer;
            if (index == 0) return error.UnsupportedXPointer;
            var child = included.node(current).first_child;
            var count: usize = 0;
            var next: dom.NodeId = dom.null_node;
            while (child != dom.null_node) : (child = included.node(child).next_sibling) {
                if (included.node(child).kind != .element) continue;
                count += 1;
                if (count == index) {
                    next = child;
                    break;
                }
            }
            if (next == dom.null_node) return error.UnsupportedXPointer;
            current = next;
            steps += 1;
        }
        if (steps == 0) return error.UnsupportedXPointer;
        const out = try self.allocator.alloc(dom.NodeId, 1);
        out[0] = current;
        return out;
    }

    fn selectXPathPointer(
        self: *Processor,
        included: *const dom.Document,
        source: []const u8,
    ) Error![]const dom.NodeId {
        var expression = xpath.Expression.parse(
            self.allocator,
            source,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.UnsupportedXPointer,
        };
        defer expression.deinit();
        const context: xpath.Context = .{
            .document = included,
            .node = .{ .node = 0 },
        };
        var result = expression.evaluate(self.allocator, &context) catch |err|
            switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.UnsupportedXPointer,
            };
        defer result.deinit();
        const nodes = switch (result.value) {
            .node_set => |nodes| nodes,
            else => return error.UnsupportedXPointer,
        };
        var out: std.ArrayList(dom.NodeId) = .empty;
        for (nodes) |node| {
            switch (node) {
                .node => |id| try out.append(self.allocator, id),
                else => return error.UnsupportedXPointer,
            }
        }
        std.mem.sort(dom.NodeId, out.items, {}, nodeIdLessThan);
        var write: usize = 0;
        for (out.items) |id| {
            if (write == 0 or out.items[write - 1] != id) {
                out.items[write] = id;
                write += 1;
            }
        }
        out.shrinkRetainingCapacity(write);
        return out.toOwnedSlice(self.allocator);
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
            if (node.kind == .element and std.mem.eql(u8, source.ns(node.ns), namespace_uri) and
                std.mem.eql(u8, node.localName(), "fallback"))
            {
                var fallback_child = node.first_child;
                while (fallback_child != dom.null_node) : (fallback_child = source.node(fallback_child).next_sibling) {
                    try self.copyNode(
                        source,
                        base,
                        fallback_child,
                        parent,
                        null,
                        null,
                    );
                }
                return;
            }
        }
        return original;
    }
};

fn nodeIdLessThan(_: void, a: dom.NodeId, b: dom.NodeId) bool {
    return a < b;
}

fn isNCNamePointer(text: []const u8) bool {
    if (text.len == 0) return false;
    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        if (byte >= 0x80) {
            index += 1;
            continue;
        }
        const start = index == 0;
        const valid = if (start)
            std.ascii.isAlphabetic(byte) or byte == '_'
        else
            std.ascii.isAlphanumeric(byte) or byte == '_' or
                byte == '-' or byte == '.';
        if (!valid) return false;
        index += 1;
    }
    return true;
}

fn prefixOf(node: *const dom.Node) []const u8 {
    if (node.localName().len == node.name.len or node.localName().len >= node.name.len) {
        return "";
    }
    return node.name[0 .. node.name.len - node.localName().len - 1];
}

fn findAttribute(
    attributes: []const dom.Attribute,
    name: []const u8,
) ?dom.Attribute {
    for (attributes) |attribute| {
        if (std.mem.eql(u8, attribute.name(), name)) return attribute;
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

test "XInclude includes the document element of the resource" {
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
    const inc = document.findChild(root, "inc") orelse
        return error.TestUnexpectedResult;
    try testing.expect(document.findChild(inc, "x") != null);
    const y = document.findChild(inc, "y") orelse
        return error.TestUnexpectedResult;
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

test "XInclude parse=text decodes the encoding attribute" {
    const latin1_text =
        \\<root xmlns:xi="http://www.w3.org/2001/XInclude"><xi:include href="t.txt" parse="text" encoding="ISO-8859-1"/></root>
    ;
    const latin1_resources = [_]TestResource{
        .{ .href = "t.txt", .uri = "t.txt", .data = "caf\xE9" },
    };
    var latin1_resolver: MapResolver = .{ .resources = &latin1_resources };
    var latin1_source = try parseSource(latin1_text);
    defer latin1_source.deinit();
    var latin1_document = try process(testing.allocator, &latin1_source, .{
        .resolver = .{ .context = &latin1_resolver, .load = loadResource },
    });
    defer latin1_document.deinit();
    const latin1_value = try latin1_document.textContentAlloc(
        testing.allocator,
        latin1_document.root(),
    );
    defer testing.allocator.free(latin1_value);
    try testing.expectEqualStrings("caf\xC3\xA9", latin1_value);

    const utf16_text =
        \\<root xmlns:xi="http://www.w3.org/2001/XInclude"><xi:include href="u.txt" parse="text" encoding="UTF-16"/></root>
    ;
    const utf16_resources = [_]TestResource{
        .{ .href = "u.txt", .uri = "u.txt", .data = "\xFF\xFEh\x00i\x00" },
    };
    var utf16_resolver: MapResolver = .{ .resources = &utf16_resources };
    var utf16_source = try parseSource(utf16_text);
    defer utf16_source.deinit();
    var utf16_document = try process(testing.allocator, &utf16_source, .{
        .resolver = .{ .context = &utf16_resolver, .load = loadResource },
    });
    defer utf16_document.deinit();
    const utf16_value = try utf16_document.textContentAlloc(
        testing.allocator,
        utf16_document.root(),
    );
    defer testing.allocator.free(utf16_value);
    try testing.expectEqualStrings("hi", utf16_value);
}

test "XInclude parse=text falls back for bad encodings" {
    const source_text =
        \\<root xmlns:xi="http://www.w3.org/2001/XInclude"><xi:include href="t.txt" parse="text" encoding="x-unknown"><xi:fallback><fb/></xi:fallback></xi:include></root>
    ;
    const resources = [_]TestResource{
        .{ .href = "t.txt", .uri = "t.txt", .data = "data" },
    };
    var resolver: MapResolver = .{ .resources = &resources };
    var source = try parseSource(source_text);
    defer source.deinit();
    var document = try process(testing.allocator, &source, .{
        .resolver = .{ .context = &resolver, .load = loadResource },
    });
    defer document.deinit();
    try testing.expect(document.findChild(document.root(), "fb") != null);
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
    const included_a = document.findChild(document.root(), "a") orelse
        return error.TestUnexpectedResult;
    const included_b = document.findChild(included_a, "b") orelse
        return error.TestUnexpectedResult;
    try testing.expect(document.findChild(included_b, "leaf") != null);

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
    const inc = document.findChild(root, "inc") orelse
        return error.TestUnexpectedResult;
    try testing.expectEqualStrings("urn:inc", document.ns(document.node(inc).ns));
    try testing.expectEqualStrings(
        "urn:inc",
        document.attribute(inc, "xmlns") orelse "",
    );
    const child = document.findChild(inc, "x") orelse
        return error.TestUnexpectedResult;
    try testing.expectEqualStrings("x", document.node(child).name);
    try testing.expectEqualStrings("urn:inc", document.ns(document.node(child).ns));
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
    const wrap_inc = document.findChild(wrap, "inc") orelse
        return error.TestUnexpectedResult;
    try testing.expect(document.findChild(wrap_inc, "leaf") != null);

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
    const included = include_document.findChild(
        include_document.root(),
        "inc",
    ) orelse return error.TestUnexpectedResult;
    try testing.expect(include_document.findChild(included, "leaf") != null);
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
    const inc = document.findChild(document.root(), "inc") orelse
        return error.TestUnexpectedResult;
    const doc = document.findChild(inc, "doc") orelse
        return error.TestUnexpectedResult;
    try testing.expect(document.findChild(doc, "leaf") != null);
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
    const resources = [_]TestResource{
        .{ .href = "a", .uri = "a", .data = "<doc/>" },
    };
    var resolver: MapResolver = .{ .resources = &resources };
    try testing.expectError(
        error.UnsupportedXPointer,
        process(testing.allocator, &xpointer, .{
            .resolver = .{ .context = &resolver, .load = loadResource },
        }),
    );
}

test "XInclude supports element and xpointer schemes" {
    const resources = [_]TestResource{
        .{
            .href = "inc.xml",
            .uri = "inc.xml",
            .data = "<doc><part id='p1'><a/><b/></part>" ++
                "<part id='p2'><c/></part></doc>",
        },
    };
    var resolver: MapResolver = .{ .resources = &resources };

    var element_source = try parseSource(
        "<root xmlns:xi='http://www.w3.org/2001/XInclude'>" ++
            "<xi:include href='inc.xml' xpointer='element(/1/2)'/></root>",
    );
    defer element_source.deinit();
    var element_document = try process(testing.allocator, &element_source, .{
        .resolver = .{ .context = &resolver, .load = loadResource },
    });
    defer element_document.deinit();
    const element_text = try element_document.textContentAlloc(
        testing.allocator,
        element_document.root(),
    );
    defer testing.allocator.free(element_text);
    try testing.expectEqualStrings("", element_text);
    const element_root = element_document.root();
    const part = element_document.findChild(element_root, "part") orelse
        return error.TestUnexpectedResult;
    try testing.expectEqualStrings(
        "p2",
        element_document.attribute(part, "id").?,
    );
    try testing.expect(element_document.findChild(part, "c") != null);

    var xpath_source = try parseSource(
        "<root xmlns:xi='http://www.w3.org/2001/XInclude'>" ++
            "<xi:include href='inc.xml' xpointer='xpointer(/doc/part[1])'/></root>",
    );
    defer xpath_source.deinit();
    var xpath_document = try process(testing.allocator, &xpath_source, .{
        .resolver = .{ .context = &resolver, .load = loadResource },
    });
    defer xpath_document.deinit();
    const xpath_root = xpath_document.root();
    const first = xpath_document.findChild(xpath_root, "part") orelse
        return error.TestUnexpectedResult;
    try testing.expectEqualStrings(
        "p1",
        xpath_document.attribute(first, "id").?,
    );
    try testing.expect(xpath_document.findChild(first, "a") != null);
    try testing.expect(xpath_document.findChild(first, "b") != null);

    var fallback_source = try parseSource(
        "<root xmlns:xi='http://www.w3.org/2001/XInclude'>" ++
            "<xi:include href='inc.xml' xpointer='element(/1/9)'>" ++
            "<xi:fallback><fb/></xi:fallback></xi:include></root>",
    );
    defer fallback_source.deinit();
    try testing.expectError(
        error.UnsupportedXPointer,
        process(testing.allocator, &fallback_source, .{
            .resolver = .{ .context = &resolver, .load = loadResource },
        }),
    );
}

test "XInclude XPointer selects elements by xml:id" {
    const resources = [_]TestResource{
        .{
            .href = "ids.xml",
            .uri = "ids.xml",
            .data = "<doc><part xml:id='p1'><a/></part>" ++
                "<part xml:id='p2'><b/></part></doc>",
        },
    };
    var resolver: MapResolver = .{ .resources = &resources };

    var id_source = try parseSource(
        "<root xmlns:xi='http://www.w3.org/2001/XInclude'>" ++
            "<xi:include href='ids.xml' xpointer='element(p2)'/></root>",
    );
    defer id_source.deinit();
    var id_document = try process(testing.allocator, &id_source, .{
        .resolver = .{ .context = &resolver, .load = loadResource },
    });
    defer id_document.deinit();
    const id_root = id_document.root();
    const id_part = id_document.findChild(id_root, "part") orelse
        return error.TestUnexpectedResult;
    try testing.expect(id_document.findChild(id_part, "b") != null);

    var shorthand_source = try parseSource(
        "<root xmlns:xi='http://www.w3.org/2001/XInclude'>" ++
            "<xi:include href='ids.xml' xpointer='p1'/></root>",
    );
    defer shorthand_source.deinit();
    var shorthand_document = try process(testing.allocator, &shorthand_source, .{
        .resolver = .{ .context = &resolver, .load = loadResource },
    });
    defer shorthand_document.deinit();
    const shorthand_root = shorthand_document.root();
    const shorthand_part = shorthand_document.findChild(
        shorthand_root,
        "part",
    ) orelse return error.TestUnexpectedResult;
    try testing.expect(shorthand_document.findChild(shorthand_part, "a") != null);
}
