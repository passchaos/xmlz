//! Validate an XML document against an ISO Schematron schema.
//!
//! Usage: schematron [--report|--svrl] [--phase=ID] SCHEMA INSTANCE
//! Exit code: 0 valid, 1 invalid, 2 schema error.
//! `--report` prints tab-separated findings after the validity line;
//! `--svrl` writes an SVRL report instead.
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
    var schema_path: ?[]const u8 = null;
    var instance_path: ?[]const u8 = null;
    var options: xmlz.schematron.Options = .{};
    var report = false;
    var svrl = false;
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--phase=")) {
            options.phase = arg["--phase=".len..];
        } else if (std.mem.eql(u8, arg, "--report")) {
            report = true;
        } else if (std.mem.eql(u8, arg, "--svrl")) {
            svrl = true;
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

    var schema_file = loadFile(init, schema_file_path) catch |err| {
        std.debug.print("schema load failed: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };
    defer schema_file.deinit(init.gpa);
    var instance_file = loadFile(init, instance_file_path) catch |err| {
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
    if (svrl) {
        var allocating: std.Io.Writer.Allocating = .init(init.gpa);
        defer allocating.deinit();
        try xmlz.schematron.writeSvrl(
            &allocating.writer,
            &result,
            &instance_file.document,
            .{},
        );
        try stdout.writeStreamingAll(init.io, allocating.written());
        if (!result.isValid()) std.process.exit(1);
        return;
    }
    if (report) {
        var allocating: std.Io.Writer.Allocating = .init(init.gpa);
        defer allocating.deinit();
        const writer = &allocating.writer;
        try writer.print("{s}\n", .{
            if (result.isValid()) "valid" else "invalid",
        });
        for (result.failures) |failure| {
            try writer.print("{s}\t{s}\t", .{
                if (failure.kind == .assert)
                    "failed-assert"
                else
                    "successful-report",
                failure.pattern_id,
            });
            try writeNormalized(writer, failure.message);
            try writer.writeByte('\n');
            for (failure.diagnostics) |diagnostic| {
                try writer.print("diagnostic\t{s}\t", .{diagnostic.id});
                try writeNormalized(writer, diagnostic.message);
                try writer.writeByte('\n');
            }
            for (failure.properties) |property| {
                try writer.print("property\t{s}\t{s}\t{s}\t", .{
                    property.id,
                    property.scheme,
                    property.role,
                });
                try writeNormalized(writer, property.message);
                try writer.writeByte('\n');
            }
        }
        try stdout.writeStreamingAll(init.io, allocating.written());
    } else {
        for (result.failures) |failure| {
            std.debug.print("{s}: {s}\n", .{
                failure.pattern_id,
                failure.message,
            });
            for (failure.diagnostics) |diagnostic| {
                std.debug.print("  diagnostic {s}: {s}\n", .{
                    diagnostic.id,
                    diagnostic.message,
                });
            }
            for (failure.properties) |property| {
                std.debug.print("  property {s}: {s}\n", .{
                    property.id,
                    property.message,
                });
            }
        }
        try stdout.writeStreamingAll(
            init.io,
            if (result.isValid()) "valid\n" else "invalid\n",
        );
    }
    if (!result.isValid()) std.process.exit(1);
}

/// Collapse whitespace so report findings stay on one line.
fn writeNormalized(writer: *std.Io.Writer, text: []const u8) !void {
    var pending_space = false;
    var wrote = false;
    for (text) |byte| {
        if (byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r') {
            if (wrote) pending_space = true;
            continue;
        }
        if (pending_space) {
            try writer.writeByte(' ');
            pending_space = false;
        }
        try writer.writeByte(byte);
        wrote = true;
    }
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
