//! Bounded expansion of internal general entities for explicitly trusted XML.
const std = @import("std");

pub const Limits = struct {
    max_entities: usize,
    max_output_bytes: usize,
    max_reference_expansions: usize,
};

pub const ExpandError = error{
    OutOfMemory,
    InvalidEntityDeclaration,
    UnsupportedEntityDeclaration,
    EntityLimitExceeded,
    EntityExpansionLimitExceeded,
};

const Entity = struct { name: []const u8, value: []const u8 };

pub fn expandAlloc(
    allocator: std.mem.Allocator,
    input: []const u8,
    doctype_start: usize,
    doctype_end: usize,
    limits: Limits,
) ExpandError!?[]u8 {
    if (doctype_start > doctype_end or doctype_end > input.len) {
        return error.InvalidEntityDeclaration;
    }
    const declaration = input[doctype_start..doctype_end];
    const subset_start = std.mem.indexOfScalar(u8, declaration, '[') orelse return null;
    const subset_end = std.mem.lastIndexOfScalar(u8, declaration, ']') orelse return error.InvalidEntityDeclaration;
    if (subset_end <= subset_start) return error.InvalidEntityDeclaration;

    var entities: std.ArrayList(Entity) = .empty;
    defer entities.deinit(allocator);
    var pos = subset_start + 1;
    while (std.mem.indexOfPos(u8, declaration, pos, "<!ENTITY")) |start| {
        var cursor = start + "<!ENTITY".len;
        while (cursor < subset_end and std.ascii.isWhitespace(declaration[cursor])) cursor += 1;
        if (cursor >= subset_end or declaration[cursor] == '%') return error.UnsupportedEntityDeclaration;
        const name_start = cursor;
        while (cursor < subset_end and isNameChar(declaration[cursor])) cursor += 1;
        if (cursor == name_start) return error.InvalidEntityDeclaration;
        const name = declaration[name_start..cursor];
        while (cursor < subset_end and std.ascii.isWhitespace(declaration[cursor])) cursor += 1;
        if (cursor >= subset_end or (declaration[cursor] != '\'' and declaration[cursor] != '"')) {
            // SYSTEM/PUBLIC external entities are never resolved.
            return error.UnsupportedEntityDeclaration;
        }
        const quote = declaration[cursor];
        cursor += 1;
        const value_start = cursor;
        while (cursor < subset_end and declaration[cursor] != quote) cursor += 1;
        if (cursor >= subset_end) return error.InvalidEntityDeclaration;
        const value = declaration[value_start..cursor];
        cursor += 1;
        while (cursor < subset_end and std.ascii.isWhitespace(declaration[cursor])) cursor += 1;
        if (cursor >= subset_end or declaration[cursor] != '>') return error.InvalidEntityDeclaration;
        if (std.mem.indexOfScalar(u8, value, '&') != null) return error.UnsupportedEntityDeclaration;
        for (entities.items) |entity| if (std.mem.eql(u8, entity.name, name)) return error.InvalidEntityDeclaration;
        if (entities.items.len >= limits.max_entities) return error.EntityLimitExceeded;
        try entities.append(allocator, .{ .name = name, .value = value });
        pos = cursor + 1;
    }
    if (entities.items.len == 0) return null;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try appendBounded(allocator, &out, input[0..doctype_start], limits.max_output_bytes);
    try appendBounded(allocator, &out, input[doctype_end..], limits.max_output_bytes);

    var expanded: std.ArrayList(u8) = .empty;
    errdefer expanded.deinit(allocator);
    var refs: usize = 0;
    var cursor: usize = 0;
    while (cursor < out.items.len) {
        const amp = std.mem.indexOfScalarPos(u8, out.items, cursor, '&') orelse {
            try appendBounded(allocator, &expanded, out.items[cursor..], limits.max_output_bytes);
            break;
        };
        try appendBounded(allocator, &expanded, out.items[cursor..amp], limits.max_output_bytes);
        const semicolon = std.mem.indexOfScalarPos(u8, out.items, amp + 1, ';') orelse {
            try appendBounded(allocator, &expanded, out.items[amp..], limits.max_output_bytes);
            break;
        };
        const name = out.items[amp + 1 .. semicolon];
        const value = find(entities.items, name) orelse {
            try appendBounded(allocator, &expanded, out.items[amp .. semicolon + 1], limits.max_output_bytes);
            cursor = semicolon + 1;
            continue;
        };
        refs += 1;
        if (refs > limits.max_reference_expansions) return error.EntityExpansionLimitExceeded;
        try appendBounded(allocator, &expanded, value, limits.max_output_bytes);
        cursor = semicolon + 1;
    }
    return try expanded.toOwnedSlice(allocator);
}

fn find(entities: []const Entity, name: []const u8) ?[]const u8 {
    for (entities) |entity| if (std.mem.eql(u8, entity.name, name)) return entity.value;
    return null;
}

fn appendBounded(allocator: std.mem.Allocator, out: *std.ArrayList(u8), bytes: []const u8, limit: usize) !void {
    if (bytes.len > limit or out.items.len > limit - bytes.len) return error.EntityExpansionLimitExceeded;
    try out.appendSlice(allocator, bytes);
}

fn isNameChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '.' or byte == ':';
}

test "trusted internal entities expand markup and attributes" {
    const input = "<!DOCTYPE svg [<!ENTITY R \"<rect fill='green'/>\"><!ENTITY C 'blue'>]><svg>&R;<rect fill='&C;'/></svg>";
    const end = (std.mem.indexOf(u8, input, "]>") orelse unreachable) + 2;
    const expanded = (try expandAlloc(std.testing.allocator, input, 0, end, .{ .max_entities = 4, .max_output_bytes = 1024, .max_reference_expansions = 4 })).?;
    defer std.testing.allocator.free(expanded);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "<rect fill='green'/>") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded, "fill='blue'") != null);
}

test "trusted entity expansion rejects external recursive and oversized declarations" {
    const limits = Limits{ .max_entities = 4, .max_output_bytes = 64, .max_reference_expansions = 4 };
    const external = "<!DOCTYPE svg [<!ENTITY e SYSTEM 'file:///tmp/x'>]><svg>&e;</svg>";
    try std.testing.expectError(error.UnsupportedEntityDeclaration, expandAlloc(std.testing.allocator, external, 0, (std.mem.indexOf(u8, external, "]>") orelse unreachable) + 2, limits));
    const recursive = "<!DOCTYPE svg [<!ENTITY a '&b;'><!ENTITY b '&a;'>]><svg>&a;</svg>";
    try std.testing.expectError(error.UnsupportedEntityDeclaration, expandAlloc(std.testing.allocator, recursive, 0, (std.mem.indexOf(u8, recursive, "]>") orelse unreachable) + 2, limits));
    const oversized = "<!DOCTYPE svg [<!ENTITY e '0123456789'>]><svg>&e;&e;&e;&e;&e;&e;&e;</svg>";
    try std.testing.expectError(error.EntityExpansionLimitExceeded, expandAlloc(std.testing.allocator, oversized, 0, (std.mem.indexOf(u8, oversized, "]>") orelse unreachable) + 2, limits));
}
