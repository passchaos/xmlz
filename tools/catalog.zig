//! Query an OASIS XML Catalog.
//!
//! Usage: catalog CATALOG system|public|uri ID
//!        catalog CATALOG resolve PUBLIC_ID SYSTEM_ID
//! Exit code: 0 resolved, 4 no entry, 2 error.
const std = @import("std");
const xmlz = @import("xmlz");

const Loader = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    buffers: std.ArrayList([]u8) = .empty,
    paths: std.ArrayList([]u8) = .empty,

    fn deinit(self: *Loader) void {
        for (self.buffers.items) |buffer| self.allocator.free(buffer);
        for (self.paths.items) |path| self.allocator.free(path);
        self.buffers.deinit(self.allocator);
        self.paths.deinit(self.allocator);
    }
};

fn loadResource(
    context: ?*anyopaque,
    href: []const u8,
    base: []const u8,
) ?xmlz.catalog.Resource {
    const loader: *Loader = @ptrCast(@alignCast(context.?));
    const path = resolvePath(loader.allocator, base, href) catch return null;
    const data = std.Io.Dir.cwd().readFileAlloc(
        loader.io,
        path,
        loader.allocator,
        .limited(64 * 1024 * 1024),
    ) catch {
        loader.allocator.free(path);
        return null;
    };
    loader.paths.append(loader.allocator, path) catch {
        loader.allocator.free(path);
        loader.allocator.free(data);
        return null;
    };
    loader.buffers.append(loader.allocator, data) catch {
        loader.allocator.free(data);
        return null;
    };
    return .{ .uri = path, .data = data };
}

fn resolvePath(
    allocator: std.mem.Allocator,
    base: []const u8,
    href: []const u8,
) ![]u8 {
    if (std.fs.path.isAbsolute(href)) return allocator.dupe(u8, href);
    const directory = std.fs.path.dirname(base) orelse ".";
    return std.fs.path.resolve(allocator, &.{ directory, href });
}

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const path = args.next() orelse return error.MissingCatalog;
    const kind = args.next() orelse return error.MissingQuery;
    const first = args.next() orelse return error.MissingQuery;

    const source = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        path,
        init.gpa,
        .limited(64 * 1024 * 1024),
    );
    defer init.gpa.free(source);
    const decoded = try xmlz.encoding.decodeAlloc(
        init.gpa,
        source,
        64 * 1024 * 1024,
    );
    defer init.gpa.free(decoded);
    var document = try xmlz.dom.Document.parse(init.gpa, decoded, .{});
    defer document.deinit();

    var loader: Loader = .{ .allocator = init.gpa, .io = init.io };
    defer loader.deinit();
    const base = try std.fs.path.resolve(init.gpa, &.{path});
    defer init.gpa.free(base);
    var catalog = try xmlz.catalog.parseWithOptions(init.gpa, &document, .{
        .resolver = .{ .context = &loader, .load = loadResource },
        .base = base,
    });
    defer catalog.deinit();

    var resolved: ?[]const u8 = null;
    if (std.mem.eql(u8, kind, "system")) {
        resolved = catalog.resolveSystem(first);
    } else if (std.mem.eql(u8, kind, "public")) {
        resolved = catalog.resolvePublic(first);
    } else if (std.mem.eql(u8, kind, "uri")) {
        resolved = catalog.resolveUri(first);
    } else if (std.mem.eql(u8, kind, "resolve")) {
        const second = args.next() orelse return error.MissingQuery;
        resolved = catalog.resolve(first, second);
    } else {
        return error.InvalidArgument;
    }

    if (resolved) |uri| {
        try std.Io.File.stdout().writeStreamingAll(init.io, uri);
        try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
        return;
    }
    std.process.exit(4);
}
