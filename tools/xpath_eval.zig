//! Evaluate one XPath expression against an XML file.
//!
//! Usage: xpath-eval FILE EXPRESSION [count|string|number|boolean]
const std = @import("std");
const xmlz = @import("xmlz");

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const path = args.next() orelse return error.MissingInput;
    const source_expression = args.next() orelse return error.MissingExpression;
    const mode = args.next() orelse "string";

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

    var expression = try xmlz.xpath.Expression.parse(
        init.gpa,
        source_expression,
    );
    defer expression.deinit();
    var context: xmlz.xpath.Context = .{
        .document = &document,
        .node = .{ .node = 0 },
    };
    var result = try expression.evaluate(init.gpa, &context);
    defer result.deinit();

    const output = if (std.mem.eql(u8, mode, "count")) blk: {
        const count: usize = switch (result.value) {
            .node_set => |nodes| nodes.len,
            else => 0,
        };
        break :blk try std.fmt.allocPrint(init.gpa, "{d}", .{count});
    } else if (std.mem.eql(u8, mode, "string")) blk: {
        const text: []const u8 = switch (result.value) {
            .string => |value| value,
            else => "",
        };
        break :blk try init.gpa.dupe(u8, text);
    } else if (std.mem.eql(u8, mode, "number")) blk: {
        const number: f64 = switch (result.value) {
            .number => |value| value,
            else => 0,
        };
        break :blk try std.fmt.allocPrint(init.gpa, "{d}", .{number});
    } else if (std.mem.eql(u8, mode, "boolean")) blk: {
        const boolean: bool = switch (result.value) {
            .boolean => |value| value,
            else => false,
        };
        break :blk try init.gpa.dupe(u8, if (boolean) "true" else "false");
    } else return error.InvalidMode;
    defer init.gpa.free(output);
    const stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(init.io, output);
    try stdout.writeStreamingAll(init.io, "\n");
}
