//! Validate an XML document against an ISO Schematron schema.
//!
//! Usage: schematron SCHEMA INSTANCE [--phase=ID]
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

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const schema_path = args.next() orelse return error.MissingSchema;
    const instance_path = args.next() orelse return error.MissingInstance;
    var options: xmlz.schematron.Options = .{};
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--phase=")) {
            options.phase = arg["--phase=".len..];
        } else {
            return error.InvalidArgument;
        }
    }

    var schema_file = loadFile(init, schema_path) catch |err| {
        std.debug.print("schema load failed: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };
    defer schema_file.deinit(init.gpa);
    var instance_file = loadFile(init, instance_path) catch |err| {
        std.debug.print("instance load failed: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };
    defer instance_file.deinit(init.gpa);

    var compiled = xmlz.schematron.parse(
        init.gpa,
        &schema_file.document,
    ) catch |err| {
        std.debug.print("schema error: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };
    defer compiled.deinit();

    var result = xmlz.schematron.validate(
        &compiled,
        init.gpa,
        &instance_file.document,
        options,
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
    for (result.failures) |failure| {
        std.debug.print("{s}: {s}\n", .{
            failure.pattern_id,
            failure.message,
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
    const document = try xmlz.dom.Document.parse(init.gpa, decoded, .{});
    return .{ .document = document, .decoded = decoded };
}
