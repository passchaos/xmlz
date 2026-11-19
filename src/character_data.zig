//! Borrowed XML character spans with entity-decoding provenance.
//! Element tags never enter the output; only ordinary character data decodes
//! entity references. CDATA is literal, even when it resembles tags/entities.
const std = @import("std");
const markup = @import("markup.zig");

pub const Span = union(enum) {
    escaped: []const u8,
    literal: []const u8,
};

pub const Iterator = struct {
    input: []const u8,
    pos: usize = 0,

    pub fn next(self: *Iterator) ?Span {
        while (self.pos < self.input.len) {
            const start = self.pos;
            const lt = std.mem.indexOfScalarPos(u8, self.input, start, '<') orelse self.input.len;
            if (lt != start) {
                self.pos = lt;
                return .{ .escaped = self.input[start..lt] };
            }
            const tail = self.input[start..];
            if (std.mem.startsWith(u8, tail, "<!--")) {
                self.pos = if (std.mem.indexOfPos(u8, self.input, start + 4, "-->")) |end| end + 3 else self.input.len;
            } else if (std.mem.startsWith(u8, tail, "<![CDATA[")) {
                const data_start = start + 9;
                const data_end = std.mem.indexOfPos(u8, self.input, data_start, "]]>") orelse self.input.len;
                self.pos = if (data_end < self.input.len) data_end + 3 else self.input.len;
                return .{ .literal = self.input[data_start..data_end] };
            } else if (std.mem.startsWith(u8, tail, "<?")) {
                self.pos = if (std.mem.indexOfPos(u8, self.input, start + 2, "?>")) |end| end + 2 else self.input.len;
            } else if (std.mem.startsWith(u8, tail, "<!")) {
                self.pos = if (markup.findDeclarationEnd(self.input, start + 2)) |end| end + 1 else self.input.len;
            } else {
                self.pos = if (markup.findTagEnd(self.input, start + 1)) |end| end + 1 else self.input.len;
            }
        }
        return null;
    }
};

test "XML character data keeps escaped and CDATA provenance" {
    var it = Iterator{ .input = "A&amp;<tspan data=\">\">B<![CDATA[&#32;<x>]]>C</tspan>D" };
    try std.testing.expectEqualStrings("A&amp;", it.next().?.escaped);
    try std.testing.expectEqualStrings("B", it.next().?.escaped);
    try std.testing.expectEqualStrings("&#32;<x>", it.next().?.literal);
    try std.testing.expectEqualStrings("C", it.next().?.escaped);
    try std.testing.expectEqualStrings("D", it.next().?.escaped);
    try std.testing.expect(it.next() == null);
}

test "XML character data excludes opaque markup and pseudo elements" {
    var it = Iterator{ .input = "a<!-- <![CDATA[wrong]]> --><?pi '<x>'?><!DOCTYPE x [<!ENTITY y '>'>]>b<g><q/>c</g>" };
    try std.testing.expectEqualStrings("a", it.next().?.escaped);
    try std.testing.expectEqualStrings("b", it.next().?.escaped);
    try std.testing.expectEqualStrings("c", it.next().?.escaped);
    try std.testing.expect(it.next() == null);
}

test "XML character data preserves permissive incomplete CDATA recovery" {
    var it = Iterator{ .input = "before<![CDATA[&#32;<x>" };
    try std.testing.expectEqualStrings("before", it.next().?.escaped);
    try std.testing.expectEqualStrings("&#32;<x>", it.next().?.literal);
    try std.testing.expect(it.next() == null);
    var empty = Iterator{ .input = "<![CDATA[]]>" };
    try std.testing.expectEqualStrings("", empty.next().?.literal);
    try std.testing.expect(empty.next() == null);
}
