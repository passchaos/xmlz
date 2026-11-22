//! Validate an XML document against a RELAX NG schema.
//!
//! Usage: rng [--catalog=FILE] [--compact] SCHEMA INSTANCE
//! Exit code: 0 valid, 1 invalid, 2 schema error.
const std = @import("std");
const xmlz = @import("xmlz");
const embedded_schematron = @import("embedded_schematron.zig");
const file_loader = @import("file_loader.zig");

const Loaded = struct {
    document: xmlz.dom.Document,
    decoded: []u8,

    fn deinit(self: *Loaded, allocator: std.mem.Allocator) void {
        self.document.deinit();
        allocator.free(self.decoded);
    }
};

fn loadSchema(
    context: ?*anyopaque,
    href: []const u8,
    base: []const u8,
) ?xmlz.rng.Resource {
    const loader: *file_loader.Loader = @ptrCast(@alignCast(context.?));
    const loaded = loader.load(href, base) orelse return null;
    return .{ .uri = loaded.uri, .data = loaded.data };
}

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    var compact = false;
    var schema_path: ?[]const u8 = null;
    var instance_path: ?[]const u8 = null;
    var catalog_path: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--compact")) {
            compact = true;
        } else if (std.mem.startsWith(u8, arg, "--catalog=")) {
            catalog_path = arg["--catalog=".len..];
        } else if (schema_path == null) {
            schema_path = arg;
        } else if (instance_path == null) {
            instance_path = arg;
        } else {
            return error.InvalidArgument;
        }
    }
    const schema_file_path = schema_path orelse return error.MissingSchema;
    const instance_file_path = instance_path orelse return error.MissingInstance;

    var schema_file: ?Loaded = null;
    if (!compact) {
        schema_file = loadFile(init, schema_file_path) catch |err| {
            std.debug.print("schema load failed: {s}\n", .{@errorName(err)});
            std.process.exit(2);
        };
    }
    defer if (schema_file) |*loaded| loaded.deinit(init.gpa);
    var instance_file = loadFile(init, instance_file_path) catch |err| {
        std.debug.print("instance load failed: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };
    defer instance_file.deinit(init.gpa);

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
    var compiled = if (compact) blk: {
        const source = std.Io.Dir.cwd().readFileAlloc(
            init.io,
            schema_file_path,
            init.gpa,
            .limited(64 * 1024 * 1024),
        ) catch |err| {
            std.debug.print("schema load failed: {s}\n", .{@errorName(err)});
            std.process.exit(2);
        };
        defer init.gpa.free(source);
        const decoded = xmlz.encoding.decodeAlloc(
            init.gpa,
            source,
            64 * 1024 * 1024,
        ) catch |err| {
            std.debug.print("schema load failed: {s}\n", .{@errorName(err)});
            std.process.exit(2);
        };
        defer init.gpa.free(decoded);
        break :blk xmlz.rng.parseCompactWithOptions(
            init.gpa,
            decoded,
            .{
                .resolver = .{
                    .context = &loader,
                    .load = loadSchema,
                },
                .base = schema_file_path,
            },
        ) catch |err| {
            std.debug.print("schema error: {s}\n", .{@errorName(err)});
            std.process.exit(2);
        };
    } else xmlz.rng.parseWithOptions(
        init.gpa,
        &schema_file.?.document,
        .{
            .resolver = .{ .context = &loader, .load = loadSchema },
            .base = schema_file_path,
        },
    ) catch |err| {
        std.debug.print("schema error: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };
    defer compiled.deinit();

    var result = xmlz.rng.validate(
        &compiled,
        init.gpa,
        &instance_file.document,
    ) catch |err| {
        std.debug.print("validation failed: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };
    defer result.deinit();

    const stdout = std.Io.File.stdout();
    if (result.isValid()) {
        if (!compact) {
            const embedded_valid = embedded_schematron.validate(
                init.gpa,
                &schema_file.?.document,
                &instance_file.document,
                null,
            ) catch |err| {
                std.debug.print("schematron error: {s}\n", .{@errorName(err)});
                std.process.exit(2);
            };
            if (!embedded_valid) {
                try stdout.writeStreamingAll(init.io, "invalid\n");
                std.process.exit(1);
            }
        }
        try stdout.writeStreamingAll(init.io, "valid\n");
        return;
    }
    for (result.errors) |validation_error| {
        std.debug.print("{d}: {s}\n", .{
            validation_error.node,
            validation_error.message,
        });
    }
    try stdout.writeStreamingAll(init.io, "invalid\n");
    std.process.exit(1);
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
