//! xmlz benchmark: pull parser and DOM on a shared input file.
const std = @import("std");
const xmlz = @import("xmlz");

const iterations = 6;

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const path = args.next() orelse return error.MissingInput;
    const mode = args.next() orelse "all";
    const io = init.io;

    const source = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        init.gpa,
        .limited(512 * 1024 * 1024),
    );
    defer init.gpa.free(source);

    const mb = @as(f64, @floatFromInt(source.len)) / (1024.0 * 1024.0);

    if (std.mem.eql(u8, mode, "all") or std.mem.eql(u8, mode, "pull")) {
        try runPull(io, source, mb, false);
        try runPull(io, source, mb, true);
    }
    if (std.mem.eql(u8, mode, "all") or std.mem.eql(u8, mode, "dom")) {
        try runDom(init.gpa, io, source, mb, true);
    }
    if (std.mem.eql(u8, mode, "dom-raw")) {
        try runDom(init.gpa, io, source, mb, false);
    }
}

fn runPull(
    io: std.Io,
    source: []const u8,
    mb: f64,
    namespaces: bool,
) !void {
    var best: f64 = std.math.inf(f64);
    for (0..iterations) |iteration| {
        const start = std.Io.Clock.Timestamp.now(io, .awake);
        var parser = xmlz.parser.Parser.init(source, .{ .namespaces = namespaces });
        while (try parser.next()) |_| {}
        parser.deinit();
        const elapsed = start.raw.durationTo(
            std.Io.Clock.Timestamp.now(io, .awake).raw,
        );
        const seconds = @as(f64, @floatFromInt(elapsed.nanoseconds)) / std.time.ns_per_s;
        if (iteration != 0 and seconds < best) best = seconds;
    }
    std.debug.print(
        "xmlz,pull-{s},{d:.2},{d}\n",
        .{ if (namespaces) "ns" else "raw", mb / best, rssKilobytes() },
    );
}

fn runDom(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    mb: f64,
    namespaces: bool,
) !void {
    var best: f64 = std.math.inf(f64);
    for (0..iterations) |iteration| {
        const start = std.Io.Clock.Timestamp.now(io, .awake);
        var doc = try xmlz.dom.Document.parse(allocator, source, .{
            .parser = .{ .namespaces = namespaces },
        });
        doc.deinit();
        const elapsed = start.raw.durationTo(
            std.Io.Clock.Timestamp.now(io, .awake).raw,
        );
        const seconds = @as(f64, @floatFromInt(elapsed.nanoseconds)) / std.time.ns_per_s;
        if (iteration != 0 and seconds < best) best = seconds;
    }
    std.debug.print(
        "xmlz,dom-{s},{d:.2},{d}\n",
        .{ if (namespaces) "ns" else "raw", mb / best, rssKilobytes() },
    );
}

fn rssKilobytes() c_long {
    return @intCast(std.posix.getrusage(0).maxrss);
}
