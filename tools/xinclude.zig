//! Expand XInclude elements in an XML document.
//!
//! Usage: xinclude FILE
const std = @import("std");
const xmlz = @import("xmlz");

const Loader = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    catalog: ?*xmlz.catalog.Catalog = null,
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
) ?xmlz.xinclude.Resource {
    const loader: *Loader = @ptrCast(@alignCast(context.?));
    if (loader.catalog) |catalog| {
        if (catalog.resolveSystem(href)) |resolved| {
            return loadPath(loader, resolved);
        }
        if (base.len != 0) {
            const absolute = resolvePath(
                loader.allocator,
                base,
                href,
            ) catch null;
            if (absolute) |resolved_href| {
                defer loader.allocator.free(resolved_href);
                if (catalog.resolveSystem(resolved_href)) |resolved| {
                    return loadPath(loader, resolved);
                }
            }
        }
    }
    const path = resolvePath(loader.allocator, base, href) catch return null;
    return loadPath(loader, path);
}

fn loadCatalogResource(
    context: ?*anyopaque,
    href: []const u8,
    base: []const u8,
) ?xmlz.catalog.Resource {
    const resource = loadResource(context, href, base) orelse return null;
    return .{ .uri = resource.uri, .data = resource.data };
}

fn loadPath(loader: *Loader, path: []const u8) ?xmlz.xinclude.Resource {
    const owned_path = loader.allocator.dupe(u8, path) catch return null;
    const data = std.Io.Dir.cwd().readFileAlloc(
        loader.io,
        owned_path,
        loader.allocator,
        .limited(64 * 1024 * 1024),
    ) catch {
        loader.allocator.free(owned_path);
        return null;
    };
    loader.paths.append(loader.allocator, owned_path) catch {
        loader.allocator.free(owned_path);
        loader.allocator.free(data);
        return null;
    };
    loader.buffers.append(loader.allocator, data) catch {
        loader.allocator.free(data);
        return null;
    };
    return .{ .uri = owned_path, .data = data };
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
    var catalog_path: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--catalog=")) {
            catalog_path = arg["--catalog=".len..];
        } else if (path == null) {
            path = arg;
        } else {
            return error.InvalidArgument;
        }
    }
    const input_path = path orelse return error.MissingInput;

    const source = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        input_path,
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
    var document = try xmlz.dom.Document.parse(init.gpa, decoded, .{
        .keep_comments = true,
        .keep_pis = true,
    });
    defer document.deinit();

    var loader: Loader = .{ .allocator = init.gpa, .io = init.io };
    defer loader.deinit();
    var catalog: ?xmlz.catalog.Catalog = null;
    defer if (catalog) |*value| value.deinit();
    if (catalog_path) |catalog_file| {
        const catalog_source = std.Io.Dir.cwd().readFileAlloc(
            init.io,
            catalog_file,
            init.gpa,
            .limited(64 * 1024 * 1024),
        ) catch |err| {
            std.debug.print("catalog load failed: {s}\n", .{@errorName(err)});
            std.process.exit(2);
        };
        defer init.gpa.free(catalog_source);
        const catalog_decoded = xmlz.encoding.decodeAlloc(
            init.gpa,
            catalog_source,
            64 * 1024 * 1024,
        ) catch |err| {
            std.debug.print("catalog load failed: {s}\n", .{@errorName(err)});
            std.process.exit(2);
        };
        defer init.gpa.free(catalog_decoded);
        var catalog_document = xmlz.dom.Document.parse(
            init.gpa,
            catalog_decoded,
            .{},
        ) catch |err| {
            std.debug.print("catalog load failed: {s}\n", .{@errorName(err)});
            std.process.exit(2);
        };
        defer catalog_document.deinit();
        const catalog_base = std.fs.path.resolve(
            init.gpa,
            &.{catalog_file},
        ) catch |err| {
            std.debug.print("catalog load failed: {s}\n", .{@errorName(err)});
            std.process.exit(2);
        };
        defer init.gpa.free(catalog_base);
        catalog = xmlz.catalog.parseWithOptions(
            init.gpa,
            &catalog_document,
            .{
                .resolver = .{
                    .context = &loader,
                    .load = loadCatalogResource,
                },
                .base = catalog_base,
            },
        ) catch |err| {
            std.debug.print("catalog error: {s}\n", .{@errorName(err)});
            std.process.exit(2);
        };
        loader.catalog = &catalog.?;
    }
    var expanded = xmlz.xinclude.process(init.gpa, &document, .{
        .resolver = .{ .context = &loader, .load = loadResource },
        .base = input_path,
    }) catch |err| {
        std.debug.print("xinclude failed: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };
    defer expanded.deinit();

    var allocating: std.Io.Writer.Allocating = .init(init.gpa);
    defer allocating.deinit();
    try xmlz.writer.writeDocument(&allocating.writer, &expanded, .{
        .xml_declaration = false,
    });
    try std.Io.File.stdout().writeStreamingAll(init.io, allocating.written());
}
