//! OASIS XML Catalogs 1.1 resolution.
//!
//! A catalog is parsed eagerly, including `nextCatalog` and delegate catalog
//! references loaded through a caller resolver. Resolution supports `system`,
//! `public`, and `uri` entries, rewrites, suffixes, delegates, `prefer`, and
//! `xml:base`. Results are allocated in the catalog arena.

const std = @import("std");
const dom = @import("dom.zig");
const encoding = @import("encoding.zig");
const namespace = @import("namespace.zig");
const xmlbase = @import("xmlbase.zig");

pub const namespace_uri = "urn:oasis:names:tc:entity:xmlns:xml:catalog";

pub const Error = error{
    OutOfMemory,
    InvalidCatalog,
};

pub const Resource = struct {
    uri: []const u8 = "",
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
    /// Base URI of the root catalog document.
    base: []const u8 = "",
};

pub const Catalog = struct {
    arena: std.heap.ArenaAllocator,
    root: *const CatalogFile,
    catalogs: []const *CatalogFile,
    documents: []const *dom.Document,

    pub fn deinit(self: *Catalog) void {
        for (self.documents) |document| document.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn resolveSystem(self: *Catalog, system_id: []const u8) ?[]const u8 {
        return self.resolveSystemIn(self.root, system_id, 0);
    }

    pub fn resolvePublic(self: *Catalog, public_id: []const u8) ?[]const u8 {
        const normalized = self.normalizePublicId(public_id) catch return null;
        return self.resolvePublicIn(self.root, normalized, 0);
    }

    /// Full external-identifier resolution using the catalog's `prefer`
    /// setting.
    pub fn resolve(
        self: *Catalog,
        public_id: ?[]const u8,
        system_id: ?[]const u8,
    ) ?[]const u8 {
        const normalized = if (public_id) |id|
            self.normalizePublicId(id) catch return null
        else
            null;
        if (self.root.prefer_public) {
            if (normalized) |id| {
                if (self.resolvePublicIn(self.root, id, 0)) |uri| return uri;
            }
            if (system_id) |id| {
                if (self.resolveSystemIn(self.root, id, 0)) |uri| return uri;
            }
        } else {
            if (system_id) |id| {
                if (self.resolveSystemIn(self.root, id, 0)) |uri| return uri;
            }
            if (normalized) |id| {
                if (self.resolvePublicIn(self.root, id, 0)) |uri| return uri;
            }
        }
        return null;
    }

    pub fn resolveUri(self: *Catalog, uri: []const u8) ?[]const u8 {
        return self.resolveUriIn(self.root, uri, 0);
    }

    fn resolveSystemIn(
        self: *Catalog,
        catalog: *const CatalogFile,
        id: []const u8,
        depth: usize,
    ) ?[]const u8 {
        if (depth > 64) return null;
        for (catalog.entries) |entry| {
            switch (entry) {
                .system => |mapping| {
                    if (std.mem.eql(u8, mapping.id, id)) return mapping.uri;
                },
                else => {},
            }
        }
        var best_prefix: ?[]const u8 = null;
        var best_rewrite: ?[]const u8 = null;
        for (catalog.entries) |entry| {
            switch (entry) {
                .rewrite_system => |rewrite| {
                    if (!std.mem.startsWith(u8, id, rewrite.start)) continue;
                    if (best_prefix) |current| {
                        if (rewrite.start.len <= current.len) continue;
                    }
                    best_prefix = rewrite.start;
                    best_rewrite = rewrite.prefix;
                },
                else => {},
            }
        }
        if (best_rewrite) |prefix| {
            const remainder = id[best_prefix.?.len..];
            return std.mem.concat(self.arena.allocator(), u8, &.{
                prefix,
                remainder,
            }) catch null;
        }
        var best_suffix: ?[]const u8 = null;
        var best_suffix_uri: ?[]const u8 = null;
        for (catalog.entries) |entry| {
            switch (entry) {
                .system_suffix => |suffix| {
                    if (!std.mem.endsWith(u8, id, suffix.suffix)) continue;
                    if (best_suffix) |current| {
                        if (suffix.suffix.len <= current.len) continue;
                    }
                    best_suffix = suffix.suffix;
                    best_suffix_uri = suffix.uri;
                },
                else => {},
            }
        }
        if (best_suffix) |suffix| {
            const head = id[0 .. id.len - suffix.len];
            return std.mem.concat(self.arena.allocator(), u8, &.{
                head,
                best_suffix_uri.?,
            }) catch null;
        }
        for (catalog.entries) |entry| {
            switch (entry) {
                .delegate_system => |delegate| {
                    if (!std.mem.startsWith(u8, id, delegate.start)) continue;
                    if (self.resolveSystemIn(delegate.catalog, id, depth + 1)) |uri| {
                        return uri;
                    }
                },
                else => {},
            }
        }
        for (catalog.entries) |entry| {
            switch (entry) {
                .next_catalog => |next| {
                    if (self.resolveSystemIn(next, id, depth + 1)) |uri| return uri;
                },
                else => {},
            }
        }
        return null;
    }

    fn resolvePublicIn(
        self: *Catalog,
        catalog: *const CatalogFile,
        id: []const u8,
        depth: usize,
    ) ?[]const u8 {
        if (depth > 64) return null;
        for (catalog.entries) |entry| {
            switch (entry) {
                .public => |mapping| {
                    if (std.mem.eql(u8, mapping.id, id)) return mapping.uri;
                },
                else => {},
            }
        }
        for (catalog.entries) |entry| {
            switch (entry) {
                .delegate_public => |delegate| {
                    if (!std.mem.startsWith(u8, id, delegate.start)) continue;
                    if (self.resolvePublicIn(delegate.catalog, id, depth + 1)) |uri| {
                        return uri;
                    }
                },
                else => {},
            }
        }
        for (catalog.entries) |entry| {
            switch (entry) {
                .next_catalog => |next| {
                    if (self.resolvePublicIn(next, id, depth + 1)) |uri| return uri;
                },
                else => {},
            }
        }
        return null;
    }

    fn resolveUriIn(
        self: *Catalog,
        catalog: *const CatalogFile,
        id: []const u8,
        depth: usize,
    ) ?[]const u8 {
        if (depth > 64) return null;
        for (catalog.entries) |entry| {
            switch (entry) {
                .uri => |mapping| {
                    if (std.mem.eql(u8, mapping.id, id)) return mapping.uri;
                },
                else => {},
            }
        }
        var best_prefix: ?[]const u8 = null;
        var best_rewrite: ?[]const u8 = null;
        for (catalog.entries) |entry| {
            switch (entry) {
                .rewrite_uri => |rewrite| {
                    if (!std.mem.startsWith(u8, id, rewrite.start)) continue;
                    if (best_prefix) |current| {
                        if (rewrite.start.len <= current.len) continue;
                    }
                    best_prefix = rewrite.start;
                    best_rewrite = rewrite.prefix;
                },
                else => {},
            }
        }
        if (best_rewrite) |prefix| {
            return std.mem.concat(self.arena.allocator(), u8, &.{
                prefix,
                id[best_prefix.?.len..],
            }) catch null;
        }
        var best_suffix: ?[]const u8 = null;
        var best_suffix_uri: ?[]const u8 = null;
        for (catalog.entries) |entry| {
            switch (entry) {
                .uri_suffix => |suffix| {
                    if (!std.mem.endsWith(u8, id, suffix.suffix)) continue;
                    if (best_suffix) |current| {
                        if (suffix.suffix.len <= current.len) continue;
                    }
                    best_suffix = suffix.suffix;
                    best_suffix_uri = suffix.uri;
                },
                else => {},
            }
        }
        if (best_suffix) |suffix| {
            return std.mem.concat(self.arena.allocator(), u8, &.{
                id[0 .. id.len - suffix.len],
                best_suffix_uri.?,
            }) catch null;
        }
        for (catalog.entries) |entry| {
            switch (entry) {
                .delegate_uri => |delegate| {
                    if (!std.mem.startsWith(u8, id, delegate.start)) continue;
                    if (self.resolveUriIn(delegate.catalog, id, depth + 1)) |uri| {
                        return uri;
                    }
                },
                else => {},
            }
        }
        for (catalog.entries) |entry| {
            switch (entry) {
                .next_catalog => |next| {
                    if (self.resolveUriIn(next, id, depth + 1)) |uri| return uri;
                },
                else => {},
            }
        }
        return null;
    }

    fn normalizePublicId(
        self: *Catalog,
        id: []const u8,
    ) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var pending_space = false;
        var started = false;
        for (id) |byte| {
            if (byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n') {
                if (started) pending_space = true;
                continue;
            }
            if (pending_space) {
                try out.append(self.arena.allocator(), ' ');
                pending_space = false;
            }
            try out.append(self.arena.allocator(), byte);
            started = true;
        }
        return out.toOwnedSlice(self.arena.allocator());
    }
};

const CatalogFile = struct {
    prefer_public: bool = false,
    entries: []const Entry = &.{},
};

const Entry = union(enum) {
    public: Mapping,
    system: Mapping,
    uri: Mapping,
    rewrite_system: Rewrite,
    rewrite_uri: Rewrite,
    system_suffix: Suffix,
    uri_suffix: Suffix,
    delegate_public: Delegate,
    delegate_system: Delegate,
    delegate_uri: Delegate,
    next_catalog: *const CatalogFile,
};

const Mapping = struct {
    id: []const u8,
    uri: []const u8,
};

const Rewrite = struct {
    start: []const u8,
    prefix: []const u8,
};

const Suffix = struct {
    suffix: []const u8,
    uri: []const u8,
};

const Delegate = struct {
    start: []const u8,
    catalog: *const CatalogFile,
};

pub fn parse(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
) Error!Catalog {
    return parseWithOptions(allocator, document, .{});
}

pub fn parseWithOptions(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
    options: Options,
) Error!Catalog {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var compiler: Compiler = .{
        .arena = arena.allocator(),
        .backing_allocator = allocator,
        .options = options,
        .cache = std.StringHashMap(*CatalogFile).init(arena.allocator()),
    };
    errdefer compiler.deinitDocuments();
    const root = try compiler.buildFile(document, options.base);
    const catalogs = try compiler.files.toOwnedSlice(compiler.arena);
    const documents = try compiler.documents.toOwnedSlice(compiler.arena);
    return .{
        .arena = arena,
        .root = root,
        .catalogs = catalogs,
        .documents = documents,
    };
}

const Compiler = struct {
    arena: std.mem.Allocator,
    backing_allocator: std.mem.Allocator,
    options: Options,
    files: std.ArrayList(*CatalogFile) = .empty,
    documents: std.ArrayList(*dom.Document) = .empty,
    cache: std.StringHashMap(*CatalogFile),

    fn deinitDocuments(self: *Compiler) void {
        for (self.documents.items) |document| document.deinit();
    }

    fn buildFile(
        self: *Compiler,
        document: *const dom.Document,
        base: []const u8,
    ) Error!*CatalogFile {
        const root_id = document.root();
        if (root_id == dom.null_node) return error.InvalidCatalog;
        const root_node = document.node(root_id);
        if (root_node.kind != .element or
            !std.mem.eql(u8, document.ns(root_node.ns), namespace_uri) or
            !std.mem.eql(u8, root_node.local, "catalog"))
        {
            return error.InvalidCatalog;
        }
        const file = try self.arena.create(CatalogFile);
        file.* = .{};
        try self.files.append(self.arena, file);
        if (base.len != 0) {
            try self.cache.put(try self.arena.dupe(u8, base), file);
        }
        var entries: std.ArrayList(Entry) = .empty;
        const prefer_public = try self.preferFor(document, root_id, false);
        try self.collectEntries(
            document,
            root_id,
            base,
            prefer_public,
            &entries,
        );
        file.* = .{
            .prefer_public = prefer_public,
            .entries = try entries.toOwnedSlice(self.arena),
        };
        return file;
    }

    fn preferFor(
        self: *Compiler,
        document: *const dom.Document,
        id: dom.NodeId,
        inherited: bool,
    ) Error!bool {
        _ = self;
        const value = document.attribute(id, "prefer") orelse
            return inherited;
        if (std.mem.eql(u8, value, "public")) return true;
        if (std.mem.eql(u8, value, "system")) return false;
        return error.InvalidCatalog;
    }

    fn collectEntries(
        self: *Compiler,
        document: *const dom.Document,
        parent: dom.NodeId,
        base: []const u8,
        prefer_public: bool,
        entries: *std.ArrayList(Entry),
    ) Error!void {
        var child = document.node(parent).first_child;
        while (child != dom.null_node) : (child = document.node(child).next_sibling) {
            const node = document.node(child);
            if (node.kind != .element or
                !std.mem.eql(u8, document.ns(node.ns), namespace_uri))
            {
                continue;
            }
            const entry_base = try self.elementBase(document, child, base);
            if (std.mem.eql(u8, node.local, "group")) {
                const group_prefer = try self.preferFor(
                    document,
                    child,
                    prefer_public,
                );
                try self.collectEntries(
                    document,
                    child,
                    entry_base,
                    group_prefer,
                    entries,
                );
                continue;
            }
            if (std.mem.eql(u8, node.local, "public")) {
                try entries.append(self.arena, .{ .public = .{
                    .id = try self.normalizePublic(
                        try self.requiredAttribute(document, child, "publicId"),
                    ),
                    .uri = try self.resolveReference(
                        entry_base,
                        try self.requiredAttribute(document, child, "uri"),
                    ),
                } });
                continue;
            }
            if (std.mem.eql(u8, node.local, "system")) {
                try entries.append(self.arena, .{ .system = .{
                    .id = try self.arena.dupe(
                        u8,
                        try self.requiredAttribute(document, child, "systemId"),
                    ),
                    .uri = try self.resolveReference(
                        entry_base,
                        try self.requiredAttribute(document, child, "uri"),
                    ),
                } });
                continue;
            }
            if (std.mem.eql(u8, node.local, "uri")) {
                try entries.append(self.arena, .{ .uri = .{
                    .id = try self.arena.dupe(
                        u8,
                        try self.requiredAttribute(document, child, "name"),
                    ),
                    .uri = try self.resolveReference(
                        entry_base,
                        try self.requiredAttribute(document, child, "uri"),
                    ),
                } });
                continue;
            }
            if (std.mem.eql(u8, node.local, "rewriteSystem") or
                std.mem.eql(u8, node.local, "rewriteURI"))
            {
                const is_system = std.mem.eql(
                    u8,
                    node.local,
                    "rewriteSystem",
                );
                const start = try self.requiredAttribute(
                    document,
                    child,
                    if (is_system) "systemIdStartString" else "uriStartString",
                );
                const prefix = try self.resolveReference(
                    entry_base,
                    try self.requiredAttribute(document, child, "rewritePrefix"),
                );
                try entries.append(self.arena, if (is_system)
                    .{ .rewrite_system = .{
                        .start = try self.arena.dupe(u8, start),
                        .prefix = prefix,
                    } }
                else
                    .{ .rewrite_uri = .{
                        .start = try self.arena.dupe(u8, start),
                        .prefix = prefix,
                    } });
                continue;
            }
            if (std.mem.eql(u8, node.local, "systemSuffix") or
                std.mem.eql(u8, node.local, "uriSuffix"))
            {
                const is_system = std.mem.eql(
                    u8,
                    node.local,
                    "systemSuffix",
                );
                const suffix = try self.requiredAttribute(
                    document,
                    child,
                    if (is_system) "systemIdSuffix" else "uriSuffix",
                );
                const uri = try self.resolveReference(
                    entry_base,
                    try self.requiredAttribute(document, child, "uri"),
                );
                try entries.append(self.arena, if (is_system)
                    .{ .system_suffix = .{
                        .suffix = try self.arena.dupe(u8, suffix),
                        .uri = uri,
                    } }
                else
                    .{ .uri_suffix = .{
                        .suffix = try self.arena.dupe(u8, suffix),
                        .uri = uri,
                    } });
                continue;
            }
            if (std.mem.eql(u8, node.local, "delegatePublic") or
                std.mem.eql(u8, node.local, "delegateSystem") or
                std.mem.eql(u8, node.local, "delegateURI"))
            {
                const is_public = std.mem.eql(
                    u8,
                    node.local,
                    "delegatePublic",
                );
                const is_system = std.mem.eql(
                    u8,
                    node.local,
                    "delegateSystem",
                );
                const start = try self.requiredAttribute(
                    document,
                    child,
                    if (is_public)
                        "publicIdStartString"
                    else if (is_system)
                        "systemIdStartString"
                    else
                        "uriStartString",
                );
                const reference = try self.requiredAttribute(
                    document,
                    child,
                    "catalog",
                );
                const catalog = try self.loadCatalog(reference, entry_base);
                if (catalog == null) continue;
                try entries.append(self.arena, if (is_public)
                    .{ .delegate_public = .{
                        .start = try self.normalizePublic(start),
                        .catalog = catalog.?,
                    } }
                else if (is_system)
                    .{ .delegate_system = .{
                        .start = try self.arena.dupe(u8, start),
                        .catalog = catalog.?,
                    } }
                else
                    .{ .delegate_uri = .{
                        .start = try self.arena.dupe(u8, start),
                        .catalog = catalog.?,
                    } });
                continue;
            }
            if (std.mem.eql(u8, node.local, "nextCatalog")) {
                const reference = try self.requiredAttribute(
                    document,
                    child,
                    "catalog",
                );
                const catalog = try self.loadCatalog(reference, entry_base);
                if (catalog == null) continue;
                try entries.append(self.arena, .{ .next_catalog = catalog.? });
                continue;
            }
        }
    }

    fn loadCatalog(
        self: *Compiler,
        href: []const u8,
        base: []const u8,
    ) Error!?*CatalogFile {
        const resolved = try self.resolveReference(base, href);
        if (self.cache.get(resolved)) |file| return file;
        const resolver = self.options.resolver orelse return null;
        const resource = resolver.load(
            resolver.context,
            href,
            base,
        ) orelse return null;
        const uri = if (resource.uri.len != 0) resource.uri else resolved;
        const decoded = encoding.decodeAlloc(
            self.arena,
            try self.arena.dupe(u8, resource.data),
            64 * 1024 * 1024,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        const document = try self.arena.create(dom.Document);
        document.* = dom.Document.parse(
            self.backing_allocator,
            decoded,
            .{},
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        try self.documents.append(self.arena, document);
        return try self.buildFile(document, uri);
    }

    fn elementBase(
        self: *Compiler,
        document: *const dom.Document,
        id: dom.NodeId,
        file_base: []const u8,
    ) Error![]const u8 {
        var chain: std.ArrayList(dom.NodeId) = .empty;
        var current = id;
        while (true) {
            try chain.append(self.arena, current);
            const parent = document.node(current).parent;
            if (parent == dom.null_node) break;
            current = parent;
        }
        var base = try self.arena.dupe(u8, file_base);
        var index = chain.items.len;
        while (index > 0) {
            index -= 1;
            const node_id = chain.items[index];
            const node = document.node(node_id);
            if (node.kind != .element) continue;
            const value = document.attributeNs(
                node_id,
                namespace.xml_uri,
                "base",
            ) orelse continue;
            if (base.len == 0) {
                base = try self.arena.dupe(u8, value);
            } else {
                base = xmlbase.resolve(self.arena, base, value) catch
                    return error.InvalidCatalog;
            }
        }
        return base;
    }

    fn resolveReference(
        self: *Compiler,
        base: []const u8,
        reference: []const u8,
    ) Error![]const u8 {
        if (reference.len == 0) return self.arena.dupe(u8, "");
        if (base.len == 0) return self.arena.dupe(u8, reference);
        return xmlbase.resolve(self.arena, base, reference) catch
            return error.InvalidCatalog;
    }

    fn requiredAttribute(
        self: *Compiler,
        document: *const dom.Document,
        id: dom.NodeId,
        name: []const u8,
    ) Error![]const u8 {
        _ = self;
        return document.attribute(id, name) orelse
            return error.InvalidCatalog;
    }

    fn normalizePublic(self: *Compiler, id: []const u8) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var pending_space = false;
        var started = false;
        for (id) |byte| {
            if (byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n') {
                if (started) pending_space = true;
                continue;
            }
            if (pending_space) {
                try out.append(self.arena, ' ');
                pending_space = false;
            }
            try out.append(self.arena, byte);
            started = true;
        }
        return out.toOwnedSlice(self.arena);
    }
};

const testing = std.testing;

fn parseCatalog(
    source: []const u8,
    options: Options,
) !Catalog {
    var document = try dom.Document.parse(testing.allocator, source, .{});
    defer document.deinit();
    return parseWithOptions(testing.allocator, &document, options);
}

const TestResource = struct {
    href: []const u8,
    uri: []const u8,
    data: []const u8,
};

const TestResolver = struct {
    resources: []const TestResource,
};

fn loadTestResource(
    context: ?*anyopaque,
    href: []const u8,
    base: []const u8,
) ?Resource {
    _ = base;
    const resolver: *const TestResolver = @ptrCast(@alignCast(context.?));
    for (resolver.resources) |resource| {
        if (std.mem.eql(u8, resource.href, href)) {
            return .{ .uri = resource.uri, .data = resource.data };
        }
    }
    return null;
}

test "catalog resolves exact entries and rewrites" {
    const source =
        "<catalog xmlns='" ++ namespace_uri ++ "'>" ++
        "<system systemId='http://e/sys.dtd' uri='sys.dtd'/>" ++
        "<public publicId='-//P//Q' uri='pub.dtd'/>" ++
        "<uri name='http://e/u' uri='u.xml'/>" ++
        "<rewriteSystem systemIdStartString='http://e/dir/' rewritePrefix='local/'/>" ++
        "<rewriteURI uriStartString='http://e/r/' rewritePrefix='r/'/>" ++
        "</catalog>";
    var catalog = try parseCatalog(source, .{});
    defer catalog.deinit();
    try testing.expectEqualStrings(
        "sys.dtd",
        catalog.resolveSystem("http://e/sys.dtd").?,
    );
    try testing.expectEqualStrings(
        "pub.dtd",
        catalog.resolvePublic("-//P//Q").?,
    );
    try testing.expectEqualStrings(
        "u.xml",
        catalog.resolveUri("http://e/u").?,
    );
    try testing.expectEqualStrings(
        "local/a/b",
        catalog.resolveSystem("http://e/dir/a/b").?,
    );
    try testing.expectEqualStrings(
        "r/a",
        catalog.resolveUri("http://e/r/a").?,
    );
    try testing.expect(catalog.resolveSystem("http://e/missing") == null);
}

test "catalog prefers system or public identifiers" {
    const system_first =
        "<catalog xmlns='" ++ namespace_uri ++ "'>" ++
        "<public publicId='-//P//Q' uri='pub.dtd'/>" ++
        "<system systemId='sys.dtd' uri='sys.dtd'/>" ++
        "</catalog>";
    var first = try parseCatalog(system_first, .{});
    defer first.deinit();
    try testing.expectEqualStrings(
        "sys.dtd",
        first.resolve("-//P//Q", "sys.dtd").?,
    );
    try testing.expectEqualStrings(
        "pub.dtd",
        first.resolve("-//P//Q", "other.dtd").?,
    );

    const public_first =
        "<catalog xmlns='" ++ namespace_uri ++ "' prefer='public'>" ++
        "<public publicId='-//P//Q' uri='pub.dtd'/>" ++
        "<system systemId='sys.dtd' uri='sys.dtd'/>" ++
        "</catalog>";
    var second = try parseCatalog(public_first, .{});
    defer second.deinit();
    try testing.expectEqualStrings(
        "pub.dtd",
        second.resolve("-//P//Q", "sys.dtd").?,
    );
}

test "catalog resolves suffixes and xml:base" {
    const source =
        "<catalog xmlns='" ++ namespace_uri ++ "' xml:base='sub/'>" ++
        "<systemSuffix systemIdSuffix='b.dtd' uri='suffix.dtd'/>" ++
        "<uriSuffix uriSuffix='.x' uri='local.y'/>" ++
        "<system systemId='http://e/a.dtd' uri='a.dtd'/>" ++
        "</catalog>";
    var catalog = try parseCatalog(source, .{});
    defer catalog.deinit();
    try testing.expectEqualStrings(
        "sub/a.dtd",
        catalog.resolveSystem("http://e/a.dtd").?,
    );
    try testing.expectEqualStrings(
        "http://e/a/sub/suffix.dtd",
        catalog.resolveSystem("http://e/a/b.dtd").?,
    );
    try testing.expectEqualStrings(
        "http://e/a/sub/local.y",
        catalog.resolveUri("http://e/a/.x").?,
    );
}

test "catalog follows nextCatalog and delegates" {
    const resources = [_]TestResource{
        .{
            .href = "next.xml",
            .uri = "next.xml",
            .data = "<catalog xmlns='" ++ namespace_uri ++ "'>" ++
                "<system systemId='http://e/next.dtd' uri='next.dtd'/>" ++
                "</catalog>",
        },
        .{
            .href = "sub.xml",
            .uri = "sub.xml",
            .data = "<catalog xmlns='" ++ namespace_uri ++ "'>" ++
                "<system systemId='http://e/delegated/x.dtd' " ++
                "uri='delegated.dtd'/>" ++
                "</catalog>",
        },
    };
    var resolver: TestResolver = .{ .resources = &resources };
    const source =
        "<catalog xmlns='" ++ namespace_uri ++ "'>" ++
        "<delegateSystem systemIdStartString='http://e/delegated/' " ++
        "catalog='sub.xml'/>" ++
        "<nextCatalog catalog='next.xml'/>" ++
        "</catalog>";
    var catalog = try parseCatalog(source, .{
        .resolver = .{ .context = &resolver, .load = loadTestResource },
    });
    defer catalog.deinit();
    try testing.expectEqualStrings(
        "delegated.dtd",
        catalog.resolveSystem("http://e/delegated/x.dtd").?,
    );
    try testing.expectEqualStrings(
        "next.dtd",
        catalog.resolveSystem("http://e/next.dtd").?,
    );
}
