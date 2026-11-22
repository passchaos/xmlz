//! Expand XInclude elements in an XML document.
//!
//! Usage: xinclude FILE
const std = @import("std");
const xmlz = @import("xmlz");

const Loader = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    buffers: std.ArrayList([]u8) = .empty,
    paths: std.ArrayList([]u8) = .empty,

    fn deinit(self: *Loader) void {
        for (self.buffers.items) |buffer| self.allocator.free(buffer);
        for (self.paths.items) |path| self.allocator.free(path);
        self.buffers.deinit(self.allocator);
        self.paths.deinit(self.allocator);
    }
};

fn loadResource(
    context: ?*anyopaque,
    href: []const u8,
    base: []const u8,
) ?xmlz.xinclude.Resource {
    const loader: *Loader = @ptrCast(@alignCast(context.?));
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
    const path = args.next() orelse return error.MissingInput;

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

    var loader: Loader = .{ .allocator = init.gpa, .io = init.io };
    defer loader.deinit();
    var expanded = xmlz.xinclude.process(init.gpa, &document, .{
        .resolver = .{ .context = &loader, .load = loadResource },
        .base = path,
    }) catch |err| {
        std.debug.print("xinclude failed: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };
    defer expanded.deinit();

    var allocating: std.Io.Writer.Allocating = .init(init.gpa);
    defer allocating.deinit();
    try xmlz.writer.writeDocument(&allocating.writer, &expanded, .{
        .xml_declaration = false,
    });
    try std.Io.File.stdout().writeStreamingAll(init.io, allocating.written());
}
