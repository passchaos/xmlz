//! Expand XInclude elements in an XML document.
//!
//! Usage: xinclude [--catalog=FILE] FILE
const std = @import("std");
const xmlz = @import("xmlz");
const file_loader = @import("file_loader.zig");

fn loadResource(
    context: ?*anyopaque,
    href: []const u8,
    base: []const u8,
) ?xmlz.xinclude.Resource {
    const loader: *file_loader.Loader = @ptrCast(@alignCast(context.?));
    const loaded = loader.load(href, base) orelse return null;
    return .{ .uri = loaded.uri, .data = loaded.data };
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

    var loader: file_loader.Loader = .{ .allocator = init.gpa, .io = init.io };
    defer loader.deinit();
    var catalog: ?xmlz.catalog.Catalog = null;
    defer if (catalog) |*value| value.deinit();
    if (catalog_path) |catalog_file| {
        catalog = loader.loadCatalog(catalog_file) catch |err| {
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
