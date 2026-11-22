//! Validate an XML document against an XML Schema.
//!
//! Usage: xsd SCHEMA INSTANCE
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

    var compiled = xmlz.xsd.parse(init.gpa, &schema_file.document) catch |err| {
        std.debug.print("schema error: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };
    defer compiled.deinit();

    var result = xmlz.xsd.validate(
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
        std.debug.print("{s}: {s}\n", .{
            validation_error.path,
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
