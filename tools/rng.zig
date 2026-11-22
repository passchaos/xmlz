//! Validate an XML document against a RELAX NG schema.
//!
//! Usage: rng SCHEMA INSTANCE
//! Exit code: 0 valid, 1 invalid, 2 schema error.
const std = @import("std");
const xmlz = @import("xmlz");

const Loaded = struct {
    document: xmlz.dom.Document,
    decoded: []u8,

    fn deinit(self: *Loaded, allocator: std.mem.Allocator) void {
        self.document.deinit();
        allocator.free(self.decoded);
    }
};

const SchemaLoader = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    buffers: std.ArrayList([]u8) = .empty,
    paths: std.ArrayList([]u8) = .empty,

    fn deinit(self: *SchemaLoader) void {
        for (self.buffers.items) |buffer| self.allocator.free(buffer);
        for (self.paths.items) |path| self.allocator.free(path);
        self.buffers.deinit(self.allocator);
        self.paths.deinit(self.allocator);
    }
};

fn loadSchema(
    context: ?*anyopaque,
    href: []const u8,
    base: []const u8,
) ?xmlz.rng.Resource {
    const loader: *SchemaLoader = @ptrCast(@alignCast(context.?));
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
    var compact = false;
    var schema_path = args.next() orelse return error.MissingSchema;
    if (std.mem.eql(u8, schema_path, "--compact")) {
        compact = true;
        schema_path = args.next() orelse return error.MissingSchema;
    }
    const instance_path = args.next() orelse return error.MissingInstance;

    var schema_file: ?Loaded = null;
    if (!compact) {
        schema_file = loadFile(init, schema_path) catch |err| {
            std.debug.print("schema load failed: {s}\n", .{@errorName(err)});
            std.process.exit(2);
        };
    }
    defer if (schema_file) |*loaded| loaded.deinit(init.gpa);
    var instance_file = loadFile(init, instance_path) catch |err| {
        std.debug.print("instance load failed: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };
    defer instance_file.deinit(init.gpa);

    var loader: SchemaLoader = .{ .allocator = init.gpa, .io = init.io };
    defer loader.deinit();
    var compiled = if (compact) blk: {
        const source = std.Io.Dir.cwd().readFileAlloc(
            init.io,
            schema_path,
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
                .resolver = .{ .context = &loader, .load = loadSchema },
                .base = schema_path,
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
            .base = schema_path,
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
