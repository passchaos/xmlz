//! Apply an XSLT 1.0 stylesheet to an XML document.
//!
//! Usage: xslt STYLESHEET SOURCE [--param=name=value]...
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
    const stylesheet_path = args.next() orelse return error.MissingStylesheet;
    const source_path = args.next() orelse return error.MissingSource;

    var parameters: std.ArrayList(xmlz.xpath.Variable) = .empty;
    defer parameters.deinit(init.gpa);
    while (args.next()) |arg| {
        if (!std.mem.startsWith(u8, arg, "--param=")) {
            return error.InvalidArgument;
        }
        const assignment = arg["--param=".len..];
        const equals = std.mem.indexOfScalar(u8, assignment, '=') orelse
            return error.InvalidArgument;
        try parameters.append(init.gpa, .{
            .name = assignment[0..equals],
            .value = .{ .string = assignment[equals + 1 ..] },
        });
    }

    var stylesheet = try loadFile(init, stylesheet_path);
    defer stylesheet.deinit(init.gpa);
    var source = try loadFile(init, source_path);
    defer source.deinit(init.gpa);

    var result = try xmlz.xslt.transform(
        init.gpa,
        &stylesheet.document,
        &source.document,
        .{ .parameters = parameters.items },
    );
    defer result.deinit();

    const output = try result.toOwnedSlice(init.gpa);
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
