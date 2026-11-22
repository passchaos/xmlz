//! Callback (SAX-style) facade over the pull parser.
//!
//! The pull parser remains the primary API; this module is a thin adapter for
//! consumers that prefer event callbacks. All slices borrow the input buffer
//! and are only valid for the duration of the callback.

const std = @import("std");
const parser_mod = @import("parser.zig");

pub const Handler = struct {
    context: ?*anyopaque = null,
    xml_declaration: ?*const fn (
        context: ?*anyopaque,
        declaration: parser_mod.Declaration,
    ) anyerror!void = null,
    doctype: ?*const fn (
        context: ?*anyopaque,
        doctype: parser_mod.Doctype,
    ) anyerror!void = null,
    start_element: ?*const fn (
        context: ?*anyopaque,
        element: parser_mod.StartElement,
    ) anyerror!void = null,
    end_element: ?*const fn (
        context: ?*anyopaque,
        element: parser_mod.EndElement,
    ) anyerror!void = null,
    characters: ?*const fn (
        context: ?*anyopaque,
        text: []const u8,
    ) anyerror!void = null,
    cdata: ?*const fn (
        context: ?*anyopaque,
        data: []const u8,
    ) anyerror!void = null,
    comment: ?*const fn (
        context: ?*anyopaque,
        data: []const u8,
    ) anyerror!void = null,
    processing_instruction: ?*const fn (
        context: ?*anyopaque,
        instruction: parser_mod.Instruction,
    ) anyerror!void = null,
};

/// Parse an entire document, invoking the configured callbacks.
pub fn parse(
    input: []const u8,
    options: parser_mod.Options,
    handler: Handler,
) !void {
    var parser = parser_mod.Parser.init(input, options);
    defer parser.deinit();
    while (try parser.next()) |event| {
        switch (event) {
            .xml_declaration => |declaration| {
                if (handler.xml_declaration) |callback| {
                    try callback(handler.context, declaration);
                }
            },
            .doctype => |doctype| {
                if (handler.doctype) |callback| {
                    try callback(handler.context, doctype);
                }
            },
            .start_element => |element| {
                if (handler.start_element) |callback| {
                    try callback(handler.context, element);
                }
                if (element.self_closing) {
                    if (handler.end_element) |callback| {
                        try callback(handler.context, .{
                            .name = element.name,
                            .name_range = element.name_range,
                            .depth = element.depth,
                            .namespace_uri = element.namespace_uri,
                        });
                    }
                }
            },
            .end_element => |element| {
                if (handler.end_element) |callback| {
                    try callback(handler.context, element);
                }
            },
            .text => |text| {
                if (handler.characters) |callback| {
                    try callback(handler.context, text);
                }
            },
            .cdata => |data| {
                if (handler.cdata) |callback| {
                    try callback(handler.context, data);
                }
            },
            .comment => |data| {
                if (handler.comment) |callback| {
                    try callback(handler.context, data);
                }
            },
            .processing_instruction => |instruction| {
                if (handler.processing_instruction) |callback| {
                    try callback(handler.context, instruction);
                }
            },
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const Collector = struct {
    allocator: std.mem.Allocator,
    starts: std.ArrayList([]const u8),
    ends: std.ArrayList([]const u8),
    text: std.ArrayList(u8),
    comments: usize = 0,
    cdata_count: usize = 0,
    pi_count: usize = 0,
    doctype_seen: bool = false,

    fn init(allocator: std.mem.Allocator) Collector {
        return .{
            .allocator = allocator,
            .starts = .empty,
            .ends = .empty,
            .text = .empty,
        };
    }

    fn deinit(self: *Collector) void {
        self.starts.deinit(self.allocator);
        self.ends.deinit(self.allocator);
        self.text.deinit(self.allocator);
    }

    fn start(context: ?*anyopaque, element: parser_mod.StartElement) !void {
        const self: *Collector = @ptrCast(@alignCast(context.?));
        try self.starts.append(self.allocator, element.name);
    }

    fn end(context: ?*anyopaque, element: parser_mod.EndElement) !void {
        const self: *Collector = @ptrCast(@alignCast(context.?));
        try self.ends.append(self.allocator, element.name);
    }

    fn characters(context: ?*anyopaque, text: []const u8) !void {
        const self: *Collector = @ptrCast(@alignCast(context.?));
        try self.text.appendSlice(self.allocator, text);
    }

    fn comment(context: ?*anyopaque, data: []const u8) !void {
        _ = data;
        const self: *Collector = @ptrCast(@alignCast(context.?));
        self.comments += 1;
    }

    fn cdata(context: ?*anyopaque, data: []const u8) !void {
        _ = data;
        const self: *Collector = @ptrCast(@alignCast(context.?));
        self.cdata_count += 1;
    }

    fn pi(context: ?*anyopaque, instruction: parser_mod.Instruction) !void {
        _ = instruction;
        const self: *Collector = @ptrCast(@alignCast(context.?));
        self.pi_count += 1;
    }

    fn doctype(context: ?*anyopaque, value: parser_mod.Doctype) !void {
        _ = value;
        const self: *Collector = @ptrCast(@alignCast(context.?));
        self.doctype_seen = true;
    }
};

test "SAX adapter dispatches all event kinds" {
    const input =
        "<?xml version=\"1.0\"?>" ++
        "<!DOCTYPE doc [<!ELEMENT doc ANY>]>" ++
        "<doc>text<![CDATA[raw]]><!-- c --><?pi d?><child/></doc>";
    var collector = Collector.init(testing.allocator);
    defer collector.deinit();

    try parse(input, .{}, .{
        .context = &collector,
        .xml_declaration = null,
        .doctype = Collector.doctype,
        .start_element = Collector.start,
        .end_element = Collector.end,
        .characters = Collector.characters,
        .cdata = Collector.cdata,
        .comment = Collector.comment,
        .processing_instruction = Collector.pi,
    });

    try testing.expect(collector.doctype_seen);
    try testing.expectEqual(@as(usize, 2), collector.starts.items.len);
    try testing.expectEqualStrings("doc", collector.starts.items[0]);
    try testing.expectEqualStrings("child", collector.starts.items[1]);
    try testing.expectEqualStrings("child", collector.ends.items[0]);
    try testing.expectEqualStrings("doc", collector.ends.items[1]);
    try testing.expectEqualStrings("text", collector.text.items);
    try testing.expectEqual(@as(usize, 1), collector.cdata_count);
    try testing.expectEqual(@as(usize, 1), collector.comments);
    try testing.expectEqual(@as(usize, 1), collector.pi_count);
}

test "SAX adapter propagates handler errors" {
    const Failing = struct {
        fn start(_: ?*anyopaque, _: parser_mod.StartElement) !void {
            return error.HandlerRejected;
        }
    };
    try testing.expectError(
        error.HandlerRejected,
        parse("<a/>", .{}, .{ .start_element = Failing.start }),
    );
}
