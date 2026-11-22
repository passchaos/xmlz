//! Apply an XSLT 1.0 stylesheet to an XML document.
//!
//! Usage: xslt [--catalog=FILE] STYLESHEET SOURCE [--param=name=value]...
const std = @import("std");
const xmlz = @import("xmlz");
const file_loader = @import("file_loader.zig");

const Loaded = struct {
    document: xmlz.dom.Document,
    decoded: []u8,

    fn deinit(self: *Loaded, allocator: std.mem.Allocator) void {
        self.document.deinit();
        allocator.free(self.decoded);
    }
};

fn loadStylesheet(
    context: ?*anyopaque,
    href: []const u8,
    base: []const u8,
) ?xmlz.xslt.Resource {
    const loader: *file_loader.Loader = @ptrCast(@alignCast(context.?));
    const loaded = loader.load(href, base) orelse return null;
    return .{ .uri = loaded.uri, .data = loaded.data };
}

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    var stylesheet_path: ?[]const u8 = null;
    var source_path: ?[]const u8 = null;
    var catalog_path: ?[]const u8 = null;
    var repeat: usize = 1;
    var parameters: std.ArrayList(xmlz.xpath.Variable) = .empty;
    defer parameters.deinit(init.gpa);
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--param=")) {
            const assignment = arg["--param=".len..];
            const equals = std.mem.indexOfScalar(u8, assignment, '=') orelse
                return error.InvalidArgument;
            try parameters.append(init.gpa, .{
                .name = assignment[0..equals],
                .value = .{ .string = assignment[equals + 1 ..] },
            });
        } else if (std.mem.startsWith(u8, arg, "--repeat=")) {
            repeat = std.fmt.parseUnsigned(
                usize,
                arg["--repeat=".len..],
                10,
            ) catch return error.InvalidArgument;
            if (repeat == 0) return error.InvalidArgument;
        } else if (std.mem.startsWith(u8, arg, "--catalog=")) {
            catalog_path = arg["--catalog=".len..];
        } else if (stylesheet_path == null) {
            stylesheet_path = arg;
        } else if (source_path == null) {
            source_path = arg;
        } else {
            return error.InvalidArgument;
        }
    }
    const stylesheet_file_path = stylesheet_path orelse
        return error.MissingStylesheet;
    const source_file_path = source_path orelse return error.MissingSource;

    var stylesheet = try loadFile(init, stylesheet_file_path);
    defer stylesheet.deinit(init.gpa);
    var source = try loadFile(init, source_file_path);
    defer source.deinit(init.gpa);

    var loader: file_loader.Loader = .{ .allocator = init.gpa, .io = init.io };
    defer loader.deinit();
    var catalog: ?xmlz.catalog.Catalog = null;
    defer if (catalog) |*value| value.deinit();
    if (catalog_path) |path| {
        catalog = loader.loadCatalog(path) catch |err| {
            std.debug.print("catalog error: {s}\n", .{@errorName(err)});
            std.process.exit(2);
        };
        loader.catalog = &catalog.?;
    }
    const timestamp = std.Io.Clock.real.now(init.io);
    const now = xmlz.xpath.exslt_date.formatUnixSeconds(
        init.gpa,
        @intCast(@divFloor(timestamp.nanoseconds, 1_000_000_000)),
    ) catch null;
    defer if (now) |value| init.gpa.free(value);
    var compiled = try xmlz.xslt.parseWithOptions(
        init.gpa,
        &stylesheet.document,
        .{
            .parameters = parameters.items,
            .resolver = .{
                .context = &loader,
                .load = loadStylesheet,
            },
            .base = stylesheet_file_path,
            .now = now,
        },
    );
    defer compiled.deinit();
    var result = try xmlz.xslt.apply(
        &compiled,
        &source.document,
        .{
            .parameters = parameters.items,
            .resolver = .{
                .context = &loader,
                .load = loadStylesheet,
            },
            .base = stylesheet_file_path,
            .now = now,
        },
    );
    var iteration: usize = 1;
    while (iteration < repeat) : (iteration += 1) {
        result.deinit();
        result = try xmlz.xslt.apply(
            &compiled,
            &source.document,
            .{
                .parameters = parameters.items,
                .resolver = .{
                    .context = &loader,
                    .load = loadStylesheet,
                },
                .base = stylesheet_file_path,
                .now = now,
            },
        );
    }
    defer result.deinit();

    for (result.messages) |message| {
        std.debug.print("{s}\n", .{message});
    }
    const output = try result.toOwnedSliceWithOptions(
        init.gpa,
        .{ .libxslt_compat = true },
    );
    defer init.gpa.free(output);
    try std.Io.File.stdout().writeStreamingAll(init.io, output);
}

fn loadFile(init: std.process.Init, path: []const u8) !Loaded {
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
    errdefer init.gpa.free(decoded);
    const document = try xmlz.dom.Document.parse(init.gpa, decoded, .{
        .keep_comments = true,
        .keep_pis = true,
    });
    return .{ .document = document, .decoded = decoded };
}
