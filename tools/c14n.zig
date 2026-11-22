//! Canonicalize one XML file.
//!
//! Usage: c14n FILE [--comments] [--c14n11] [--exclusive]
//!                  [--inclusive=PREFIX[,PREFIX...]]
const std = @import("std");
const xmlz = @import("xmlz");

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const path = args.next() orelse return error.MissingInput;

    var options: xmlz.c14n.Options = .{};
    var inclusive: std.ArrayList([]const u8) = .empty;
    defer inclusive.deinit(init.gpa);
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--comments")) {
            options.comments = true;
        } else if (std.mem.eql(u8, arg, "--c14n11")) {
            options.version = .c14n_1_1;
        } else if (std.mem.eql(u8, arg, "--exclusive")) {
            options.exclusive = true;
        } else if (std.mem.startsWith(u8, arg, "--inclusive=")) {
            var tokens = std.mem.tokenizeAny(
                u8,
                arg["--inclusive=".len..],
                ",",
            );
            while (tokens.next()) |token| {
                try inclusive.append(init.gpa, token);
            }
        } else {
            return error.InvalidArgument;
        }
    }
    options.inclusive_prefixes = inclusive.items;

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

    var document = try xmlz.dom.Document.parse(init.gpa, decoded, .{
        .keep_comments = true,
        .keep_pis = true,
    });
    defer document.deinit();

    const output = try xmlz.c14n.canonicalize(init.gpa, &document, options);
    defer init.gpa.free(output);
    try std.Io.File.stdout().writeStreamingAll(init.io, output);
}
