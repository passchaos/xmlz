//! Shared file loader with optional OASIS XML Catalog support for CLI tools.

const std = @import("std");
const xmlz = @import("xmlz");

pub const Loaded = struct {
    uri: []const u8,
    data: []const u8,
};

pub const Loader = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    catalog: ?*xmlz.catalog.Catalog = null,
    buffers: std.ArrayList([]u8) = .empty,
    paths: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *Loader) void {
        for (self.buffers.items) |buffer| self.allocator.free(buffer);
        for (self.paths.items) |path| self.allocator.free(path);
        self.buffers.deinit(self.allocator);
        self.paths.deinit(self.allocator);
    }

    /// Load a referenced resource, consulting the catalog before the
    /// filesystem. Like libxml2's entity loader, a system identifier lookup
    /// falls back to URI entries when no `system` match exists.
    pub fn load(self: *Loader, href: []const u8, base: []const u8) ?Loaded {
        if (self.catalog) |catalog| {
            if (catalogLookup(catalog, href)) |resolved| {
                return self.loadPath(resolved);
            }
            if (base.len != 0) {
                const absolute = resolvePath(
                    self.allocator,
                    base,
                    href,
                ) catch null;
                if (absolute) |value| {
                    defer self.allocator.free(value);
                    if (catalogLookup(catalog, value)) |resolved| {
                        return self.loadPath(resolved);
                    }
                }
            }
        }
        const path = resolvePath(self.allocator, base, href) catch return null;
        defer self.allocator.free(path);
        return self.loadPath(path);
    }

    /// Parse a catalog file. The loader's current catalog (if any) is not used
    /// while parsing; nested catalog references are loaded from the
    /// filesystem.
    pub fn loadCatalog(self: *Loader, path: []const u8) !xmlz.catalog.Catalog {
        const source = try std.Io.Dir.cwd().readFileAlloc(
            self.io,
            path,
            self.allocator,
            .limited(64 * 1024 * 1024),
        );
        defer self.allocator.free(source);
        const decoded = try xmlz.encoding.decodeAlloc(
            self.allocator,
            source,
            64 * 1024 * 1024,
        );
        defer self.allocator.free(decoded);
        var document = try xmlz.dom.Document.parse(
            self.allocator,
            decoded,
            .{},
        );
        defer document.deinit();
        const base = try std.fs.path.resolve(self.allocator, &.{path});
        defer self.allocator.free(base);
        return xmlz.catalog.parseWithOptions(self.allocator, &document, .{
            .resolver = .{ .context = self, .load = loadCatalogResource },
            .base = base,
        });
    }

    fn loadPath(self: *Loader, path: []const u8) ?Loaded {
        const owned_path = self.allocator.dupe(u8, path) catch return null;
        const data = std.Io.Dir.cwd().readFileAlloc(
            self.io,
            owned_path,
            self.allocator,
            .limited(64 * 1024 * 1024),
        ) catch {
            self.allocator.free(owned_path);
            return null;
        };
        self.paths.append(self.allocator, owned_path) catch {
            self.allocator.free(owned_path);
            self.allocator.free(data);
            return null;
        };
        self.buffers.append(self.allocator, data) catch {
            self.allocator.free(data);
            return null;
        };
        return .{ .uri = owned_path, .data = data };
    }
};

fn catalogLookup(catalog: *xmlz.catalog.Catalog, id: []const u8) ?[]const u8 {
    if (catalog.resolveSystem(id)) |resolved| return resolved;
    return catalog.resolveUri(id);
}

pub fn loadCatalogResource(
    context: ?*anyopaque,
    href: []const u8,
    base: []const u8,
) ?xmlz.catalog.Resource {
    const loader: *Loader = @ptrCast(@alignCast(context.?));
    const loaded = loader.load(href, base) orelse return null;
    return .{ .uri = loaded.uri, .data = loaded.data };
}

pub fn resolvePath(
    allocator: std.mem.Allocator,
    base: []const u8,
    href: []const u8,
) ![]u8 {
    if (std.fs.path.isAbsolute(href)) {
        return percentDecode(allocator, href);
    }
    const directory = std.fs.path.dirname(base) orelse ".";
    const resolved = try std.fs.path.resolve(allocator, &.{ directory, href });
    defer allocator.free(resolved);
    // Filesystem paths are not URIs: decode percent escapes such as %20.
    return percentDecode(allocator, resolved);
}

fn percentDecode(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, text, '%') == null) {
        return allocator.dupe(u8, text);
    }
    var out: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == '%' and index + 2 < text.len) {
            const high = hexValue(text[index + 1]);
            const low = hexValue(text[index + 2]);
            if (high != null and low != null) {
                try out.append(allocator, high.? << 4 | low.?);
                index += 3;
                continue;
            }
        }
        try out.append(allocator, text[index]);
        index += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn hexValue(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}
