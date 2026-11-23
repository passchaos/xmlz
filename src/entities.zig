//! Entity decoding and XML character-data normalization.
//!
//! The parser validates references and declarations; this module turns raw
//! borrowed spans into consumer-facing character data. Decoding is
//! allocation-free when a span contains no references or normalization work:
//! in that case the returned slice aliases the input.

const std = @import("std");
const chars = @import("chars.zig");

/// Upper bound on entity declarations held by one parser. libxml2's
/// default limit is 10000; DocBook's DTD declares over 3000 entities.
pub const max_entities = 4096;

pub const Entity = struct {
    name: []const u8,
    /// Replacement text for internal entities. Empty for external entities.
    value: []const u8,
    external: bool = false,
    /// System identifier for external entities.
    system_id: []const u8 = "",
    /// Public identifier for external entities, when present.
    public_id: []const u8 = "",
    /// Unparsed (NDATA) external entity; references are not allowed in content.
    unparsed: bool = false,
    /// Notation name for an unparsed entity.
    notation: []const u8 = "",
    /// True when the declaration came from the external subset or an external
    /// parameter entity. Standalone documents may not use such declarations.
    from_external: bool = false,
    /// Byte offset of the declaration in the source document, for diagnostics.
    offset: usize = 0,
};

/// Entity storage is allocated on first declaration. Keeping only a pointer
/// in `Table` makes `parser.Parser` small, so creating a parser for every
/// included stylesheet or entity file does not zero a megabyte of tables.
/// Lookups use open-addressing buckets over a fixed-capacity entry array.
const hash_buckets = 8192;

pub const Table = struct {
    data: ?*Data = null,
    count: usize = 0,

    const Data = struct {
        entries: [max_entities]Entity = undefined,
        /// Entry index + 1 of the first entity in each bucket; 0 means empty.
        buckets: [hash_buckets]u16 = @splat(0),
        /// Entry index + 1 of the next entity in the same bucket; 0 means end.
        next: [max_entities]u16 = undefined,
    };

    pub const AddError = error{ OutOfMemory, EntityLimitExceeded };

    fn bucketIndex(name: []const u8) usize {
        return @as(usize, @truncate(std.hash.Wyhash.hash(0, name))) &
            (hash_buckets - 1);
    }

    pub fn find(self: *const Table, name: []const u8) ?*const Entity {
        const data = self.data orelse return null;
        var link = data.buckets[bucketIndex(name)];
        while (link != 0) {
            const index: usize = link - 1;
            const entry = &data.entries[index];
            if (std.mem.eql(u8, entry.name, name)) return entry;
            link = data.next[index];
        }
        return null;
    }

    pub fn isDeclared(self: *const Table, name: []const u8) bool {
        return self.find(name) != null or isPredefined(name);
    }

    /// Whether the table declares an external parsed entity, which means
    /// document content may pull in a large replacement tree.
    pub fn hasExternalParsed(self: *const Table) bool {
        for (self.entries()) |entity| {
            if (entity.external and !entity.unparsed) return true;
        }
        return false;
    }

    /// Declared entities in declaration order.
    pub fn entries(self: *const Table) []const Entity {
        const data = self.data orelse return &.{};
        return data.entries[0..self.count];
    }

    pub fn at(self: *const Table, index: usize) *const Entity {
        return &self.data.?.entries[index];
    }

    /// First declaration wins, matching XML's entity binding rule.
    pub fn add(
        self: *Table,
        allocator: std.mem.Allocator,
        entity: Entity,
    ) AddError!void {
        if (self.find(entity.name) != null) return;
        const data = self.data orelse blk: {
            const created = try allocator.create(Data);
            created.* = .{};
            self.data = created;
            break :blk created;
        };
        if (self.count == data.entries.len) return error.EntityLimitExceeded;
        const index = self.count;
        data.entries[index] = entity;
        const bucket = bucketIndex(entity.name);
        data.next[index] = data.buckets[bucket];
        data.buckets[bucket] = @intCast(index + 1);
        self.count += 1;
    }

    pub fn deinit(self: *Table, allocator: std.mem.Allocator) void {
        if (self.data) |data| allocator.destroy(data);
        self.data = null;
        self.count = 0;
    }
};

pub const predefined = [_]struct { name: []const u8, replacement: u8 }{
    .{ .name = "lt", .replacement = '<' },
    .{ .name = "gt", .replacement = '>' },
    .{ .name = "amp", .replacement = '&' },
    .{ .name = "apos", .replacement = '\'' },
    .{ .name = "quot", .replacement = '"' },
};

pub fn predefinedReplacement(name: []const u8) ?u8 {
    for (predefined) |entity| {
        if (std.mem.eql(u8, entity.name, name)) return entity.replacement;
    }
    return null;
}

pub fn isPredefined(name: []const u8) bool {
    return predefinedReplacement(name) != null;
}

/// Hard cap on nested entity replacement depth.
pub const max_expansion_depth = 32;

pub const Limits = struct {
    /// Maximum decoded bytes produced for one call.
    max_output_bytes: usize = 8 * 1024 * 1024,
    /// Maximum entity references expanded for one call.
    max_expansions: usize = 100_000,
    /// Maximum nested entity replacement depth.
    max_depth: usize = max_expansion_depth,
};

pub const Options = struct {
    /// Document character rules and line-ending set.
    version: chars.Version = .xml_1_0,
    /// Preserve `&name;` literally when no declaration exists. Used by
    /// permissive parsing of real-world SVG exports.
    preserve_undeclared: bool = false,
    /// Preserve `&name;` literally for declared external entities whose
    /// replacement text is not available to this process.
    preserve_external: bool = true,
    /// Normalize CR (and, for XML 1.1, NEL/LS) while appending literal runs.
    /// Callers that already know the source has none can skip the scan.
    normalize_line_endings: bool = true,
};

pub const DecodeError = error{
    OutOfMemory,
    UndeclaredEntity,
    ExternalEntity,
    EntityExpansionLimitExceeded,
    EntityRecursion,
    InvalidEntityReference,
};

const Context = enum {
    text,
    attribute,
};

const Expansion = struct {
    allocator: std.mem.Allocator,
    table: *const Table,
    limits: Limits,
    options: Options,
    context: Context,
    out: std.ArrayList(u8) = .empty,
    expansions: usize = 0,

    fn append(self: *Expansion, bytes: []const u8) DecodeError!void {
        if (bytes.len > self.limits.max_output_bytes or
            self.out.items.len > self.limits.max_output_bytes - bytes.len)
        {
            return error.EntityExpansionLimitExceeded;
        }
        try self.out.appendSlice(self.allocator, bytes);
    }

    fn appendByte(self: *Expansion, byte: u8) DecodeError!void {
        if (self.out.items.len == self.limits.max_output_bytes) {
            return error.EntityExpansionLimitExceeded;
        }
        try self.out.append(self.allocator, byte);
    }

    /// Append literal replacement text, normalizing XML line endings and, in
    /// attribute context, literal whitespace.
    fn appendLiteral(self: *Expansion, bytes: []const u8) DecodeError!void {
        const attribute = self.context == .attribute;
        if (!attribute and !self.options.normalize_line_endings) {
            try self.append(bytes);
            return;
        }
        var index: usize = 0;
        var chunk_start: usize = 0;
        while (index < bytes.len) {
            const byte = bytes[index];
            var replacement: ?u8 = null;
            var advance: usize = 1;

            if (byte == '\r') {
                replacement = if (attribute) ' ' else '\n';
                if (index + 1 < bytes.len and bytes[index + 1] == '\n') {
                    advance = 2;
                }
            } else if (byte == '\n' or byte == '\t') {
                if (attribute) replacement = ' ';
            } else if (self.options.version == .xml_1_1) {
                if (byte == 0xC2 and index + 1 < bytes.len and
                    bytes[index + 1] == 0x85)
                {
                    // U+0085 NEL is a line end in XML 1.1.
                    replacement = if (attribute) ' ' else '\n';
                    advance = 2;
                } else if (byte == 0xE2 and index + 2 < bytes.len and
                    bytes[index + 1] == 0x80 and bytes[index + 2] == 0xA8)
                {
                    // U+2028 LINE SEPARATOR is a line end in XML 1.1.
                    replacement = if (attribute) ' ' else '\n';
                    advance = 3;
                }
            }

            if (replacement) |value| {
                if (index > chunk_start) try self.append(bytes[chunk_start..index]);
                try self.appendByte(value);
                index += advance;
                chunk_start = index;
                continue;
            }
            index += 1;
        }
        if (chunk_start < bytes.len) try self.append(bytes[chunk_start..]);
    }

    fn decodeInto(self: *Expansion, raw: []const u8, depth: usize) DecodeError!void {
        if (depth > self.limits.max_depth) return error.EntityRecursion;
        var cursor: usize = 0;
        while (cursor < raw.len) {
            const amp = chars.findByteSoon(raw, cursor, '&') orelse {
                try self.appendLiteral(raw[cursor..]);
                return;
            };
            if (amp > cursor) try self.appendLiteral(raw[cursor..amp]);
            const semicolon = chars.findByteSoon(raw, amp + 1, ';') orelse
                return error.InvalidEntityReference;
            const body = raw[amp + 1 .. semicolon];
            try self.decodeReference(body, depth);
            cursor = semicolon + 1;
        }
    }

    fn decodeReference(self: *Expansion, body: []const u8, depth: usize) DecodeError!void {
        if (body.len == 0) return error.InvalidEntityReference;
        if (body[0] == '#') {
            const codepoint = if (body.len > 1 and body[1] == 'x')
                chars.parseHexCharRefVersion(body[1..], self.options.version)
            else
                chars.parseDecimalCharRefVersion(body[1..], self.options.version);
            const cp = codepoint orelse return error.InvalidEntityReference;
            var buffer: [4]u8 = undefined;
            try self.append(chars.encodeUtf8(&buffer, cp));
            return;
        }

        if (predefinedReplacement(body)) |byte| {
            self.expansions += 1;
            if (self.expansions > self.limits.max_expansions) {
                return error.EntityExpansionLimitExceeded;
            }
            try self.appendByte(byte);
            return;
        }

        const entity = self.table.find(body) orelse {
            if (self.options.preserve_undeclared) {
                try self.appendByte('&');
                try self.append(body);
                try self.appendByte(';');
                return;
            }
            return error.UndeclaredEntity;
        };
        if (entity.external) {
            if (self.options.preserve_external) {
                try self.appendByte('&');
                try self.append(body);
                try self.appendByte(';');
                return;
            }
            return error.ExternalEntity;
        }
        self.expansions += 1;
        if (self.expansions > self.limits.max_expansions) {
            return error.EntityExpansionLimitExceeded;
        }
        try self.decodeInto(entity.value, depth + 1);
    }

    fn finish(self: *Expansion, raw: []const u8) DecodeError![]const u8 {
        if (self.out.items.len == 0) return raw[0..0];
        return self.out.toOwnedSlice(self.allocator);
    }
};

/// Stack buffer size for the short-value decode fast path.
const simple_decode_capacity = 256;

/// Decode a short XML 1.0 span that contains only predefined entity
/// references, character references, and line ends. Returns the decoded
/// length, or null when a general entity or a limit requires the general
/// path.
fn decodeSimple(
    raw: []const u8,
    attribute: bool,
    normalize: bool,
    max_output: usize,
    buffer: []u8,
) ?usize {
    // Long text without line ends takes the bulk-copy path; short values and
    // attribute values are cheaper to walk byte by byte.
    if (attribute or normalize or raw.len <= 32) {
        return decodeSimpleBytes(raw, attribute, normalize, max_output, buffer);
    }
    var out: usize = 0;
    var index: usize = 0;
    while (index < raw.len) {
        const stop = chars.findByteSoon(raw, index, '&') orelse raw.len;
        const run = stop - index;
        if (run != 0) {
            if (out + run > buffer.len or out + run > max_output) return null;
            @memcpy(buffer[out..][0..run], raw[index..][0..run]);
            out += run;
            index = stop;
        }
        if (index >= raw.len) break;
        const reference = decodeSimpleReference(raw, &index, max_output, buffer, out) orelse
            return null;
        out = reference;
    }
    return out;
}

/// Single-pass byte loop used for short spans and attribute values.
fn decodeSimpleBytes(
    raw: []const u8,
    attribute: bool,
    normalize: bool,
    max_output: usize,
    buffer: []u8,
) ?usize {
    var out: usize = 0;
    var index: usize = 0;
    while (index < raw.len) {
        const byte = raw[index];
        var advance: usize = 1;
        var replacement: ?u8 = null;
        if (byte == '&') {
            out = decodeSimpleReference(raw, &index, max_output, buffer, out) orelse
                return null;
            continue;
        } else if (byte == '\r') {
            if (attribute or normalize) {
                replacement = if (attribute) ' ' else '\n';
                if (index + 1 < raw.len and raw[index + 1] == '\n') advance = 2;
            }
        } else if (attribute and (byte == '\t' or byte == '\n')) {
            replacement = ' ';
        }
        const value = replacement orelse byte;
        if (out + 1 > buffer.len or out + 1 > max_output) return null;
        buffer[out] = value;
        out += 1;
        index += advance;
    }
    return out;
}

/// Decode the reference at `index` and advance it. Returns the new output
/// length, or null when the general decoder is needed.
inline fn decodeSimpleReference(
    raw: []const u8,
    index: *usize,
    max_output: usize,
    buffer: []u8,
    out: usize,
) ?usize {
    const amp = index.*;
    const semicolon = chars.findByteSoon(raw, amp + 1, ';') orelse return null;
    const body = raw[amp + 1 .. semicolon];
    if (body.len != 0 and body[0] == '#') {
        const codepoint = if (body.len > 1 and body[1] == 'x')
            chars.parseHexCharRefVersion(body[1..], .xml_1_0)
        else
            chars.parseDecimalCharRefVersion(body[1..], .xml_1_0);
        const cp = codepoint orelse return null;
        var encoded: [4]u8 = undefined;
        const bytes = chars.encodeUtf8(&encoded, cp);
        if (out + bytes.len > buffer.len or out + bytes.len > max_output) {
            return null;
        }
        @memcpy(buffer[out..][0..bytes.len], bytes);
        index.* = semicolon + 1;
        return out + bytes.len;
    }
    const replacement = predefinedReplacement(body) orelse return null;
    if (out + 1 > buffer.len or out + 1 > max_output) return null;
    buffer[out] = replacement;
    index.* = semicolon + 1;
    return out + 1;
}

fn needsTextDecode(raw: []const u8, version: chars.Version) bool {
    var index: usize = 0;
    while (index < raw.len) : (index += 1) {
        const byte = raw[index];
        if (byte == '&' or byte == '\r') return true;
        if (version == .xml_1_1) {
            if (byte == 0xC2 and index + 1 < raw.len and raw[index + 1] == 0x85) {
                return true;
            }
            if (byte == 0xE2 and index + 2 < raw.len and
                raw[index + 1] == 0x80 and raw[index + 2] == 0xA8)
            {
                return true;
            }
        }
    }
    return false;
}

fn needsAttributeDecode(raw: []const u8, version: chars.Version) bool {
    var index: usize = 0;
    while (index < raw.len) : (index += 1) {
        const byte = raw[index];
        switch (byte) {
            '&', '\r', '\n', '\t' => return true,
            0xC2 => {
                if (version == .xml_1_1 and index + 1 < raw.len and
                    raw[index + 1] == 0x85)
                {
                    return true;
                }
            },
            0xE2 => {
                if (version == .xml_1_1 and index + 2 < raw.len and
                    raw[index + 1] == 0x80 and raw[index + 2] == 0xA8)
                {
                    return true;
                }
            },
            else => {},
        }
    }
    return false;
}

/// Decode character data: entity references are expanded and XML line endings
/// are normalized to `\n`. Returns `raw` unchanged when no work is needed.
pub fn decodeTextAlloc(
    allocator: std.mem.Allocator,
    raw: []const u8,
    table: *const Table,
    limits: Limits,
    options: Options,
) DecodeError![]const u8 {
    if (!needsTextDecode(raw, options.version)) return raw;
    return decodeTextAllocChecked(allocator, raw, table, limits, options);
}

/// Decode text that the caller already knows contains a reference or a line
/// end, skipping the detection scan.
pub fn decodeTextAllocChecked(
    allocator: std.mem.Allocator,
    raw: []const u8,
    table: *const Table,
    limits: Limits,
    options: Options,
) DecodeError![]const u8 {
    if (raw.len <= simple_decode_capacity and options.version == .xml_1_0) {
        var buffer: [simple_decode_capacity]u8 = undefined;
        if (decodeSimple(
            raw,
            false,
            options.normalize_line_endings,
            limits.max_output_bytes,
            &buffer,
        )) |len| {
            if (len == 0) return raw[0..0];
            return allocator.dupe(u8, buffer[0..len]);
        }
    }
    var expansion: Expansion = .{
        .allocator = allocator,
        .table = table,
        .limits = limits,
        .options = options,
        .context = .text,
    };
    errdefer expansion.out.deinit(allocator);
    // Decoded text is usually no longer than its source, so size the output
    // once instead of growing it chunk by chunk.
    try expansion.out.ensureTotalCapacity(
        allocator,
        @min(raw.len, limits.max_output_bytes),
    );
    try expansion.decodeInto(raw, 0);
    return expansion.finish(raw);
}

/// Decode an attribute value: entity references are expanded, literal
/// whitespace (#x9, #xA, #xD) becomes a space, and character references keep
/// their referenced code point. Returns `raw` unchanged when no work is needed.
pub fn decodeAttributeAlloc(
    allocator: std.mem.Allocator,
    raw: []const u8,
    table: *const Table,
    limits: Limits,
    options: Options,
) DecodeError![]const u8 {
    if (!needsAttributeDecode(raw, options.version)) return raw;
    if (raw.len <= simple_decode_capacity and options.version == .xml_1_0) {
        var buffer: [simple_decode_capacity]u8 = undefined;
        if (decodeSimple(
            raw,
            true,
            true,
            limits.max_output_bytes,
            &buffer,
        )) |len| {
            if (len == 0) return raw[0..0];
            return allocator.dupe(u8, buffer[0..len]);
        }
    }
    var expansion: Expansion = .{
        .allocator = allocator,
        .table = table,
        .limits = limits,
        .options = options,
        .context = .attribute,
    };
    errdefer expansion.out.deinit(allocator);
    try expansion.decodeInto(raw, 0);
    return expansion.finish(raw);
}

/// Release a decoded slice when it was allocated.
pub fn freeDecoded(allocator: std.mem.Allocator, raw: []const u8, decoded: []const u8) void {
    if (decoded.ptr != raw.ptr) allocator.free(decoded);
}

test "text decoding expands references and normalizes line endings" {
    const allocator = std.testing.allocator;
    const table = Table{};
    const raw = "a&amp;b&#65;&#x1F600;\r\nc\rd";
    const decoded = try decodeTextAlloc(allocator, raw, &table, .{}, .{});
    defer freeDecoded(allocator, raw, decoded);
    try std.testing.expectEqualStrings("a&bA😀\nc\nd", decoded);
}

test "text decoding returns the raw slice when nothing changes" {
    const table = Table{};
    const raw = "plain text";
    const decoded = try decodeTextAlloc(std.testing.allocator, raw, &table, .{}, .{});
    try std.testing.expect(decoded.ptr == raw.ptr);
}

test "attribute decoding normalizes literal whitespace but preserves char refs" {
    const allocator = std.testing.allocator;
    const table = Table{};
    const raw = "a\tb\nc&#10;d";
    const decoded = try decodeAttributeAlloc(allocator, raw, &table, .{}, .{});
    defer freeDecoded(allocator, raw, decoded);
    try std.testing.expectEqualStrings("a b c\nd", decoded);
}

test "internal entities expand recursively with limits" {
    const allocator = std.testing.allocator;
    var table = Table{};
    defer table.deinit(allocator);
    try table.add(allocator, .{ .name = "a", .value = "x&b;y" });
    try table.add(allocator, .{ .name = "b", .value = "B" });
    const raw = "[&a;]";
    const decoded = try decodeTextAlloc(allocator, raw, &table, .{}, .{});
    defer freeDecoded(allocator, raw, decoded);
    try std.testing.expectEqualStrings("[xBy]", decoded);

    try std.testing.expectError(
        error.EntityExpansionLimitExceeded,
        decodeTextAlloc(allocator, raw, &table, .{ .max_output_bytes = 4 }, .{}),
    );
}

test "undeclared and external entities follow policy" {
    const allocator = std.testing.allocator;
    var table = Table{};
    defer table.deinit(std.testing.allocator);
    try table.add(
        std.testing.allocator,
        .{ .name = "ext", .value = "", .external = true },
    );
    try std.testing.expectError(
        error.UndeclaredEntity,
        decodeTextAlloc(allocator, "&missing;", &table, .{}, .{}),
    );
    const preserved = try decodeTextAlloc(
        allocator,
        "&missing;",
        &table,
        .{},
        .{ .preserve_undeclared = true },
    );
    defer freeDecoded(allocator, "&missing;", preserved);
    try std.testing.expectEqualStrings("&missing;", preserved);

    const external = try decodeTextAlloc(allocator, "&ext;", &table, .{}, .{});
    defer freeDecoded(allocator, "&ext;", external);
    try std.testing.expectEqualStrings("&ext;", external);
    try std.testing.expectError(
        error.ExternalEntity,
        decodeTextAlloc(allocator, "&ext;", &table, .{}, .{ .preserve_external = false }),
    );
}

test "entity table keeps the first declaration" {
    var table = Table{};
    defer table.deinit(std.testing.allocator);
    try table.add(std.testing.allocator, .{ .name = "a", .value = "first" });
    try table.add(std.testing.allocator, .{ .name = "a", .value = "second" });
    try std.testing.expectEqual(@as(usize, 1), table.count);
    try std.testing.expectEqualStrings("first", table.find("a").?.value);
}
