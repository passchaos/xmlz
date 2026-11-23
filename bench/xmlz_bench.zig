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
        try runPull(io, source, mb, false, false);
        try runPull(io, source, mb, true, false);
    }
    if (std.mem.eql(u8, mode, "all") or std.mem.eql(u8, mode, "fast") or
        std.mem.eql(u8, mode, "pull-fast"))
    {
        try runPull(io, source, mb, true, true);
    }
    if (std.mem.eql(u8, mode, "all") or std.mem.eql(u8, mode, "dom")) {
        try runDom(init.gpa, io, source, mb, true, false);
    }
    if (std.mem.eql(u8, mode, "all") or std.mem.eql(u8, mode, "fast") or
        std.mem.eql(u8, mode, "dom-fast"))
    {
        try runDom(init.gpa, io, source, mb, true, true);
    }
    if (std.mem.eql(u8, mode, "dom-raw")) {
        try runDom(init.gpa, io, source, mb, false, false);
    }
    if (std.mem.eql(u8, mode, "all") or std.mem.eql(u8, mode, "dom-pool")) {
        try runDomPool(init.gpa, io, source, mb, true, false);
    }
    if (std.mem.eql(u8, mode, "dom-pool-fast") or std.mem.eql(u8, mode, "all")) {
        try runDomPool(init.gpa, io, source, mb, true, true);
    }
    if (std.mem.eql(u8, mode, "all") or std.mem.eql(u8, mode, "write")) {
        try runWrite(init.gpa, io, source, mb);
    }
}

fn runWrite(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    mb: f64,
) !void {
    var doc = try xmlz.dom.Document.parse(allocator, source, .{});
    defer doc.deinit();
    // Serialize into a preallocated memory buffer so every engine pays the
    // same copying cost.
    const capacity = source.len * 2;
    const buffer = try allocator.alloc(u8, capacity);
    defer allocator.free(buffer);
    var best: f64 = std.math.inf(f64);
    for (0..iterations) |iteration| {
        const start = std.Io.Clock.Timestamp.now(io, .awake);
        var fixed = std.Io.Writer.fixed(buffer);
        try xmlz.writer.writeDocument(&fixed, &doc, .{});
        const elapsed = start.raw.durationTo(
            std.Io.Clock.Timestamp.now(io, .awake).raw,
        );
        const seconds = @as(f64, @floatFromInt(elapsed.nanoseconds)) / std.time.ns_per_s;
        if (iteration != 0 and seconds < best) best = seconds;
    }
    std.debug.print("xmlz,write,{d:.2},{d}\n", .{ mb / best, rssKilobytes() });
}

fn runPull(
    io: std.Io,
    source: []const u8,
    mb: f64,
    namespaces: bool,
    trusted: bool,
) !void {
    var best: f64 = std.math.inf(f64);
    for (0..iterations) |iteration| {
        const start = std.Io.Clock.Timestamp.now(io, .awake);
        var parser = xmlz.parser.Parser.init(source, .{
            .namespaces = namespaces,
            .trusted = trusted,
        });
        var event: xmlz.parser.Event = undefined;
        while (try parser.nextInto(&event)) {}
        parser.deinit();
        const elapsed = start.raw.durationTo(
            std.Io.Clock.Timestamp.now(io, .awake).raw,
        );
        const seconds = @as(f64, @floatFromInt(elapsed.nanoseconds)) / std.time.ns_per_s;
        if (iteration != 0 and seconds < best) best = seconds;
    }
    std.debug.print(
        "xmlz,pull-{s},{d:.2},{d}\n",
        .{
            if (trusted) "fast" else if (namespaces) "ns" else "raw",
            mb / best,
            rssKilobytes(),
        },
    );
}

fn runDom(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    mb: f64,
    namespaces: bool,
    trusted: bool,
) !void {
    var best: f64 = std.math.inf(f64);
    for (0..iterations) |iteration| {
        const start = std.Io.Clock.Timestamp.now(io, .awake);
        var doc = try xmlz.dom.Document.parse(allocator, source, .{
            .parser = .{
                .namespaces = namespaces,
                .trusted = trusted,
            },
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
        .{
            if (trusted) "fast" else if (namespaces) "ns" else "raw",
            mb / best,
            rssKilobytes(),
        },
    );
}

fn rssKilobytes() c_long {
    return @intCast(std.posix.getrusage(0).maxrss);
}

fn runDomPool(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    mb: f64,
    namespaces: bool,
    trusted: bool,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var best: f64 = std.math.inf(f64);
    for (0..iterations) |iteration| {
        const start = std.Io.Clock.Timestamp.now(io, .awake);
        var doc = try xmlz.dom.Document.parseIn(&arena, source, .{
            .parser = .{
                .namespaces = namespaces,
                .trusted = trusted,
            },
        });
        doc.deinit();
        const elapsed = start.raw.durationTo(
            std.Io.Clock.Timestamp.now(io, .awake).raw,
        );
        const seconds = @as(f64, @floatFromInt(elapsed.nanoseconds)) / std.time.ns_per_s;
        if (iteration != 0 and seconds < best) best = seconds;
    }
    std.debug.print(
        "xmlz,dom-pool-{s},{d:.2},{d}\n",
        .{
            if (trusted) "fast" else "ns",
            mb / best,
            rssKilobytes(),
        },
    );
}
