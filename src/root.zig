const std = @import("std");

pub const encoding = @import("encoding.zig");
pub const internal_entities = @import("internal_entities.zig");
pub const markup = @import("markup.zig");
pub const character_data = @import("character_data.zig");
pub const chars = @import("chars.zig");
pub const entities = @import("entities.zig");
pub const parser = @import("parser.zig");
pub const sax = @import("sax.zig");
pub const namespace = @import("namespace.zig");
pub const dom = @import("dom.zig");
pub const dom_builder = @import("dom_builder.zig");
pub const writer = @import("writer.zig");
pub const xpath = @import("xpath/root.zig");
pub const validation = @import("validation.zig");

const findTagEnd = markup.findTagEnd;
const findDeclarationEnd = markup.findDeclarationEnd;
pub const CharacterDataIterator = character_data.Iterator;

test {
    std.testing.refAllDecls(@This());
    _ = encoding;
    _ = internal_entities;
    _ = markup;
    _ = character_data;
    _ = chars;
    _ = entities;
    _ = parser;
    _ = sax;
    _ = namespace;
    _ = dom;
    _ = dom_builder;
    _ = writer;
    _ = xpath;
    _ = validation;
    _ = @import("fuzz_tests.zig");
}

pub const XmlTag = struct {
    raw_name: []const u8,
    name: []const u8,
    attrs: []const u8,
    start: usize,
    inner_start: usize,
    end: usize,
    self_closing: bool,
};

pub const SourceRange = struct {
    start: usize,
    end: usize,
};

pub const AttributeValue = struct {
    value: []const u8,
    /// Byte range of `value` relative to the attribute-list slice passed to
    /// attrValueRange(). Keeping this relative avoids baking in assumptions
    /// about whether the caller is scanning a root tag, a nested tag, or a
    /// borrowed subtree slice.
    range: SourceRange,
};

pub const Attribute = struct {
    name: []const u8,
    value: []const u8,
    /// Byte range of `value` relative to the iterator's attribute-list slice.
    range: SourceRange,
};

/// Allocation-free iteration over the quoted attributes accepted by the
/// permissive SVG scanner. Malformed tokens are skipped with the same recovery
/// rules as `attrValueRange`, so callers that need several attributes can scan
/// an element once without introducing a second XML interpretation.
pub const AttributeIterator = struct {
    attrs: []const u8,
    index: usize = 0,

    pub fn init(attrs: []const u8) AttributeIterator {
        return .{ .attrs = attrs };
    }

    pub fn next(self: *AttributeIterator) ?Attribute {
        while (self.index < self.attrs.len) {
            while (self.index < self.attrs.len and std.ascii.isWhitespace(self.attrs[self.index])) {
                self.index += 1;
            }
            const name_start = self.index;
            while (self.index < self.attrs.len and attributeNameByte(self.attrs[self.index])) {
                self.index += 1;
            }
            const name = self.attrs[name_start..self.index];
            if (name.len == 0) {
                // Malformed exported SVG occasionally contains stray
                // punctuation. Always make progress before trying to recover.
                self.index += 1;
                continue;
            }
            while (self.index < self.attrs.len and std.ascii.isWhitespace(self.attrs[self.index])) {
                self.index += 1;
            }
            if (self.index >= self.attrs.len or self.attrs[self.index] != '=') continue;
            self.index += 1;
            while (self.index < self.attrs.len and std.ascii.isWhitespace(self.attrs[self.index])) {
                self.index += 1;
            }
            if (self.index >= self.attrs.len) return null;
            const quote = self.attrs[self.index];
            if (quote != '"' and quote != '\'') {
                while (self.index < self.attrs.len and !std.ascii.isWhitespace(self.attrs[self.index])) {
                    self.index += 1;
                }
                continue;
            }
            self.index += 1;
            const value_start = self.index;
            while (self.index < self.attrs.len and self.attrs[self.index] != quote) {
                self.index += 1;
            }
            const value_end = self.index;
            if (self.index < self.attrs.len) self.index += 1;
            return .{
                .name = name,
                .value = self.attrs[value_start..value_end],
                .range = .{ .start = value_start, .end = value_end },
            };
        }
        return null;
    }
};

/// A zero-allocation single-scan attribute list for callers that probe many
/// names on one element. Duplicate attributes keep the first value, matching
/// `attrValueRange`. Lists beyond the inline capacity fall back to the raw
/// attribute bytes so no probe can silently miss an entry.
pub const AttributeList = struct {
    pub const Entry = struct {
        name: []const u8,
        value: []const u8,
        name_hash: u32,
    };
    pub const max_entries = 64;

    entries: [max_entries]Entry = undefined,
    count: usize = 0,
    complete: bool = true,

    pub fn parse(attrs: []const u8) AttributeList {
        var result: AttributeList = .{};
        result.parseInto(attrs);
        return result;
    }

    /// Fill an existing list in place. Cache owners use this to avoid copying
    /// the complete bounded entry array on every miss.
    pub fn parseInto(self: *AttributeList, attrs: []const u8) void {
        self.count = 0;
        self.complete = true;
        var iterator = AttributeIterator.init(attrs);
        while (iterator.next()) |attribute| {
            // Duplicates stay in the list: `get` returns the first entry, which
            // matches the first-wins rule, and avoiding the O(n^2) duplicate
            // probe keeps the one scan per element cheap. An overflow falls
            // back to the raw attribute scan, which also keeps the first value.
            if (self.count == self.entries.len) {
                self.complete = false;
                break;
            }
            self.entries[self.count] = .{
                .name = attribute.name,
                .value = attribute.value,
                .name_hash = attributeNameHash(attribute.name),
            };
            self.count += 1;
        }
    }

    pub fn get(self: *const AttributeList, name: []const u8) ?[]const u8 {
        const key_hash = attributeNameHash(name);
        for (self.entries[0..self.count]) |entry| {
            if (entry.name_hash == key_hash and
                std.mem.eql(u8, entry.name, name))
            {
                return entry.value;
            }
        }
        return null;
    }

    /// Resolve one name, falling back to the raw attribute scan when the list
    /// overflowed. The fallback stays on the raw iterator so cache owners that
    /// call this from `cachedAttributeList` cannot recurse.
    pub fn value(self: *const AttributeList, attrs: []const u8, name: []const u8) ?[]const u8 {
        if (!self.complete) {
            const found = scanAttrValueRange(attrs, name) orelse return null;
            return found.value;
        }
        return self.get(name);
    }
};

fn attributeNameHash(name: []const u8) u32 {
    var hash: u32 = 2166136261;
    for (name) |byte| {
        hash ^= byte;
        hash *%= 16777619;
    }
    return hash;
}

/// Cheap content sample for memoized attribute lists: the first and last up
/// to eight bytes. The per-document generation bump isolates builds; the
/// sample only guards against a same-address slice being rewritten in place.
const AttributeSample = struct {
    head: u64,
    tail: u64,
};

inline fn loadAttributeSample(bytes: []const u8) u64 {
    if (bytes.len == 8) return std.mem.readInt(u64, bytes[0..8], .little);
    var value: u64 = 0;
    @memcpy(std.mem.asBytes(&value)[0..bytes.len], bytes);
    return value;
}

inline fn attributeSample(attrs: []const u8) AttributeSample {
    const edge = @min(attrs.len, 8);
    return .{
        .head = loadAttributeSample(attrs[0..edge]),
        .tail = loadAttributeSample(attrs[attrs.len - edge ..]),
    };
}

threadlocal var probe_attrs: ?[]const u8 = null;
threadlocal var probe_list: AttributeList = undefined;

/// Parse one element's attributes for a scoped validator batch. Validators
/// that would otherwise rescan the raw bytes reuse this list. Scopes must not
/// overlap on one thread; end with `endAttributeProbe`.
pub fn beginAttributeProbe(attrs: []const u8) *const AttributeList {
    probe_attrs = attrs;
    probe_list.parseInto(attrs);
    return &probe_list;
}

pub fn endAttributeProbe() void {
    probe_attrs = null;
}

/// Returns the active probe list when it was parsed from the same slice.
pub fn currentAttributeList(attrs: []const u8) ?*const AttributeList {
    const current = probe_attrs orelse return null;
    if (current.ptr != attrs.ptr or current.len != attrs.len) return null;
    return &probe_list;
}

/// A zero-allocation, single-scan index for a fixed set of attribute names.
/// `Key` must be a dense enum starting at zero; quoted enum field names allow
/// XML spellings such as `stroke-width` and `xml:lang` to be used directly.
/// Duplicate attributes keep the first value, matching `attrValueRange`.
pub fn AttributeSet(comptime Key: type) type {
    const fields = @typeInfo(Key).@"enum".fields;
    comptime {
        for (fields, 0..) |field, index| {
            if (field.value != index) {
                @compileError("AttributeSet key enums must be dense and start at zero");
            }
        }
    }

    return struct {
        values: [fields.len][]const u8 = undefined,
        present: std.StaticBitSet(fields.len) = .empty,

        const Self = @This();

        /// Attribute names are dense enum field names. A comptime string map
        /// replaces the linear `stringToEnum` comparison chain, which ran for
        /// every authored attribute on every cascade snapshot.
        const name_map = blk: {
            var entries: [fields.len]struct { []const u8, usize } = undefined;
            for (fields, 0..) |field, index| {
                entries[index] = .{ field.name, index };
            }
            break :blk std.StaticStringMap(usize).initComptime(entries);
        };

        pub fn parse(attrs: []const u8) Self {
            var result: Self = .{};
            // Reuse the active probe list or the memoized attribute list when
            // either already covers the payload: one tokenization pass serves
            // the set and every other probe on the same element.
            const list = currentAttributeList(attrs) orelse
                &cachedAttributeList(attrs).list;
            if (list.complete) {
                for (list.entries[0..list.count]) |attribute| {
                    const index = name_map.get(attribute.name) orelse continue;
                    if (!result.present.isSet(index)) {
                        result.values[index] = attribute.value;
                        result.present.set(index);
                    }
                }
                return result;
            }
            var iterator = AttributeIterator.init(attrs);
            while (iterator.next()) |attribute| {
                const index = name_map.get(attribute.name) orelse continue;
                if (!result.present.isSet(index)) {
                    result.values[index] = attribute.value;
                    result.present.set(index);
                }
            }
            return result;
        }

        pub fn get(self: *const Self, key: Key) ?[]const u8 {
            const index: usize = @intCast(@intFromEnum(key));
            return if (self.present.isSet(index)) self.values[index] else null;
        }

        pub fn value(self: *const Self, key: Key) ?[]const u8 {
            return self.get(key);
        }

        pub fn valueNamed(self: *const Self, comptime name: []const u8) ?[]const u8 {
            return self.value(@field(Key, name));
        }

        /// True when no tracked attribute was present in the source.
        pub fn isEmpty(self: *const Self) bool {
            return self.present.count() == 0;
        }
    };
}

pub fn attrValue(attrs: []const u8, name: []const u8) ?[]const u8 {
    return if (attrValueRange(attrs, name)) |attr| attr.value else null;
}

pub fn attrValueRange(attrs: []const u8, name: []const u8) ?AttributeValue {
    if (name.len == 0) return null;
    // Validators probe one element's attributes in a batch. Reuse the active
    // probe list so a probe costs one hash-list lookup instead of a cache
    // fingerprint and slot scan per name.
    if (currentAttributeList(attrs)) |probe| {
        const value = probe.value(attrs, name) orelse return null;
        const start = @intFromPtr(value.ptr) - @intFromPtr(attrs.ptr);
        return .{ .value = value, .range = .{ .start = start, .end = start + value.len } };
    }
    // Resource and style probes ask one element for dozens of names. Parse the
    // attribute list once per element and resolve names through its hash list
    // instead of rescanning the complete payload per probe.
    const entry = cachedAttributeList(attrs);
    if (!entry.list.complete) return scanAttrValueRange(attrs, name);
    const value = entry.list.get(name) orelse return null;
    const start = @intFromPtr(value.ptr) - @intFromPtr(attrs.ptr);
    return .{ .value = value, .range = .{ .start = start, .end = start + value.len } };
}

const attribute_cache_slots = 4;

/// One attribute-list parse serves every probe on the same element. Entries
/// are keyed by slice identity plus a head/tail content sample and are dropped
/// at the start of each document build.
pub const CachedAttributeList = struct {
    generation: u64,
    ptr: [*]const u8,
    len: usize,
    sample: AttributeSample,
    list: AttributeList,
    /// Inline style payload resolved once per element. Every cascaded property
    /// probe on the same element would otherwise rescan for `style`.
    style: ?[]const u8,
};

threadlocal var attribute_cache: [attribute_cache_slots]?CachedAttributeList =
    .{null} ** attribute_cache_slots;
threadlocal var attribute_cache_next: usize = 0;
threadlocal var attribute_cache_generation: u64 = 0;

/// Invalidates memoized attribute lists. Call once per document build so a
/// later document cannot observe an entry whose source bytes were reallocated
/// at the same address.
pub fn resetAttributeCache() void {
    attribute_cache_generation +%= 1;
    attribute_cache_next = 0;
}

pub fn cachedAttributeList(attrs: []const u8) *const CachedAttributeList {
    const sample = attributeSample(attrs);
    for (&attribute_cache) |*slot| {
        if (slot.*) |*entry| {
            if (entry.generation == attribute_cache_generation and
                entry.ptr == attrs.ptr and entry.len == attrs.len and
                entry.sample.head == sample.head and
                entry.sample.tail == sample.tail)
            {
                return entry;
            }
        }
    }
    const slot = &attribute_cache[attribute_cache_next % attribute_cache_slots];
    attribute_cache_next +%= 1;
    slot.* = .{
        .generation = attribute_cache_generation,
        .ptr = attrs.ptr,
        .len = attrs.len,
        .sample = sample,
        .list = .{},
        .style = null,
    };
    const entry = &slot.*.?;
    entry.list.parseInto(attrs);
    entry.style = entry.list.value(attrs, "style");
    return entry;
}

fn attributeNameByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or
        byte == ':';
}

fn attrValueRangeFullScan(attrs: []const u8, name: []const u8) ?AttributeValue {
    if (name.len == 0) return null;
    return scanAttrValueRange(attrs, name);
}

fn scanAttrValueRange(attrs: []const u8, name: []const u8) ?AttributeValue {
    var iterator = AttributeIterator.init(attrs);
    while (iterator.next()) |attribute| {
        if (std.mem.eql(u8, attribute.name, name)) return .{
            .value = attribute.value,
            .range = attribute.range,
        };
    }
    return null;
}

pub fn localName(name: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, name, ':')) |colon| name[colon + 1 ..] else name;
}

/// Memoized tag boundary. The resource index and the color snapshot scan the
/// same fragment in the same order, so the second pass reuses every tag extent
/// instead of rescanning subtrees. Entries are keyed by slice identity and
/// start offset and are dropped at the start of each document build.
const TagCacheEntry = struct {
    generation: u64,
    input_ptr: [*]const u8,
    input_len: usize,
    pos: usize,
    next_pos: usize,
    tag: ?XmlTag,
};

const tag_cache_sets = 64;
const tag_cache_ways = 4;

threadlocal var tag_cache: [tag_cache_sets * tag_cache_ways]?TagCacheEntry =
    .{null} ** (tag_cache_sets * tag_cache_ways);
threadlocal var tag_cache_next: [tag_cache_sets]u8 = @splat(0);
threadlocal var tag_cache_generation: u64 = 0;

/// Invalidates memoized tag boundaries. Call once per document build.
pub fn resetTagCache() void {
    tag_cache_generation +%= 1;
    tag_cache_next = @splat(0);
}

inline fn tagCacheSet(input: []const u8, pos: usize) usize {
    var hash: u64 = @as(u64, @intFromPtr(input.ptr)) >> 3;
    hash ^= @as(u64, input.len) << 32;
    hash ^= @as(u64, pos) *% 0x9e37_79b9_7f4a_7c15;
    hash ^= hash >> 31;
    return @intCast(hash & (tag_cache_sets - 1));
}

pub fn nextTag(input: []const u8, pos: *usize) ?XmlTag {
    if (comptime @import("builtin").is_test) return scanNextTag(input, pos);
    const key_pos = pos.*;
    const set = tagCacheSet(input, key_pos);
    const slots = tag_cache[set * tag_cache_ways ..][0..tag_cache_ways];
    for (slots) |*slot| {
        if (slot.*) |*entry| {
            if (entry.generation == tag_cache_generation and
                entry.input_ptr == input.ptr and
                entry.input_len == input.len and
                entry.pos == key_pos)
            {
                pos.* = entry.next_pos;
                return entry.tag;
            }
        }
    }
    const tag = scanNextTag(input, pos);
    const slot = &slots[tag_cache_next[set] % tag_cache_ways];
    tag_cache_next[set] +%= 1;
    slot.* = .{
        .generation = tag_cache_generation,
        .input_ptr = input.ptr,
        .input_len = input.len,
        .pos = key_pos,
        .next_pos = pos.*,
        .tag = tag,
    };
    return tag;
}

fn scanNextTag(input: []const u8, pos: *usize) ?XmlTag {
    const lt_rel = nextMarkupStart(input, pos) orelse return null;
    const gt = findTagEnd(input, lt_rel + 1) orelse return null;
    pos.* = gt + 1;
    var body = std.mem.trim(u8, input[lt_rel + 1 .. gt], " \t\r\n");
    const self_closing = body.len > 0 and body[body.len - 1] == '/';
    if (self_closing) body = std.mem.trimEnd(u8, body[0 .. body.len - 1], " \t\r\n");
    const name_end = std.mem.indexOfAny(u8, body, " \t\r\n/") orelse body.len;
    const raw_name = body[0..name_end];
    const name = if (raw_name.len != 0 and (raw_name[0] == '/' or raw_name[0] == '!' or raw_name[0] == '?')) raw_name else localName(raw_name);
    const attrs = if (name_end < body.len) body[name_end..] else "";
    const inner_start = gt + 1;
    if (self_closing or name.len == 0 or name[0] == '/' or name[0] == '!' or name[0] == '?') {
        return .{ .raw_name = raw_name, .name = name, .attrs = attrs, .start = lt_rel, .inner_start = inner_start, .end = inner_start, .self_closing = true };
    }
    const close_start = findClosingTag(input, name, inner_start) orelse input.len;
    if (close_start < input.len) {
        pos.* = (findTagEnd(input, close_start + 1) orelse close_start) + 1;
    } else {
        pos.* = input.len;
    }
    return .{ .raw_name = raw_name, .name = name, .attrs = attrs, .start = lt_rel, .inner_start = inner_start, .end = close_start, .self_closing = false };
}

pub fn hasDoctypeDeclaration(input: []const u8) bool {
    return doctypeDeclarationRange(input) != null;
}

pub fn doctypeDeclarationRange(input: []const u8) ?SourceRange {
    var pos: usize = 0;
    while (std.mem.indexOfScalarPos(u8, input, pos, '<')) |lt| {
        if (std.mem.startsWith(u8, input[lt..], "<!--")) {
            pos = if (std.mem.indexOfPos(u8, input, lt + "<!--".len, "-->")) |end|
                end + "-->".len
            else
                input.len;
            continue;
        }
        if (std.mem.startsWith(u8, input[lt..], "<![CDATA[")) {
            pos = if (std.mem.indexOfPos(u8, input, lt + "<![CDATA[".len, "]]>")) |end|
                end + "]]>".len
            else
                input.len;
            continue;
        }
        if (std.mem.startsWith(u8, input[lt..], "<?")) {
            pos = if (std.mem.indexOfPos(u8, input, lt + "<?".len, "?>")) |end|
                end + "?>".len
            else
                input.len;
            continue;
        }
        if (std.mem.startsWith(u8, input[lt..], "<!")) {
            var name_start = lt + "<!".len;
            while (name_start < input.len and std.ascii.isWhitespace(input[name_start])) name_start += 1;
            var name_end = name_start;
            while (name_end < input.len and std.ascii.isAlphabetic(input[name_end])) name_end += 1;
            const declaration_end = if (findDeclarationEnd(input, name_end)) |end|
                end + 1
            else
                input.len;
            if (std.ascii.eqlIgnoreCase(input[name_start..name_end], "DOCTYPE")) {
                return .{ .start = lt, .end = declaration_end };
            }
            pos = declaration_end;
            continue;
        }
        pos = lt + 1;
    }
    return null;
}

pub fn stripTags(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, input, '<') == null) return input;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var pos: usize = 0;
    while (pos < input.len) {
        const lt = std.mem.indexOfScalarPos(u8, input, pos, '<') orelse {
            try out.appendSlice(allocator, input[pos..]);
            break;
        };
        try out.appendSlice(allocator, input[pos..lt]);

        if (std.mem.startsWith(u8, input[lt..], "<!--")) {
            pos = if (std.mem.indexOfPos(u8, input, lt + "<!--".len, "-->")) |end|
                end + "-->".len
            else
                input.len;
            continue;
        }

        if (std.mem.startsWith(u8, input[lt..], "<![CDATA[")) {
            const data_start = lt + "<![CDATA[".len;
            if (std.mem.indexOfPos(u8, input, data_start, "]]>")) |data_end| {
                // CDATA is markup syntax whose payload is literal character
                // data.  Preserve only the payload so text renderers can keep
                // using this helper before applying SVG whitespace handling.
                try out.appendSlice(allocator, input[data_start..data_end]);
                pos = data_end + "]]>".len;
                continue;
            }

            // Malformed/incomplete CDATA should not cause subsequent literal
            // text to disappear. Treat the opener as markup and keep the rest
            // as character data rather than truncating at '<'.
            try out.appendSlice(allocator, input[data_start..]);
            break;
        }

        if (std.mem.startsWith(u8, input[lt..], "<?")) {
            pos = if (std.mem.indexOfPos(u8, input, lt + "<?".len, "?>")) |end|
                end + "?>".len
            else
                input.len;
            continue;
        }

        if (std.mem.startsWith(u8, input[lt..], "<!")) {
            pos = if (findDeclarationEnd(input, lt + "<!".len)) |end|
                end + 1
            else
                input.len;
            continue;
        }

        const gt = findTagEnd(input, lt + 1) orelse break;
        pos = gt + 1;
    }

    return try out.toOwnedSlice(allocator);
}

pub fn freeStrippedTags(allocator: std.mem.Allocator, original: []const u8, stripped: []const u8) void {
    if (stripped.ptr != original.ptr) allocator.free(stripped);
}

test "attrValue skips malformed attributes and continues scanning" {
    const attrs = " @bad=\"x\" disabled width=\"10\" broken=unquoted height='20'";
    try std.testing.expectEqualStrings("10", attrValue(attrs, "width") orelse "");
    try std.testing.expectEqualStrings("20", attrValue(attrs, "height") orelse "");
    const height = attrValueRange(attrs, "height") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("20", height.value);
    try std.testing.expectEqual(std.mem.indexOf(u8, attrs, "20").?, height.range.start);
    try std.testing.expectEqual(height.range.start + "20".len, height.range.end);
    try std.testing.expect(attrValue(attrs, "broken") == null);
    try std.testing.expect(attrValue("/ width=\"10\"", "width") != null);
    try std.testing.expectEqualStrings(
        "inside",
        attrValue("= ' x=\"inside\"'", "x") orelse "",
    );
}

test "attribute fast paths match the full scanner" {
    const Key = enum {
        a,
        ab,
        x,
        id,
        @"xlink:href",
        @"stroke-width",
        missing,
    };
    const Set = AttributeSet(Key);
    const alphabet = "abxy09-_:/.=?'\" \t\r\n";
    const names = [_][]const u8{
        "",
        "a",
        "ab",
        "x",
        "id",
        "xlink:href",
        "stroke-width",
        "missing",
    };
    var prng = std.Random.DefaultPrng.init(0x7a73_7667_5f78_6d6c);
    const random = prng.random();

    var attrs_buffer: [256]u8 = undefined;
    for (0..20_000) |_| {
        const len = random.uintLessThan(usize, attrs_buffer.len + 1);
        for (attrs_buffer[0..len]) |*byte| {
            byte.* = alphabet[random.uintLessThan(usize, alphabet.len)];
        }
        const attrs = attrs_buffer[0..len];
        const set = Set.parse(attrs);

        for (names) |name| {
            const expected = attrValueRangeFullScan(attrs, name);
            const actual = attrValueRange(attrs, name);
            if ((expected != null) != (actual != null)) {
                std.debug.print(
                    "attribute parser mismatch: attrs=\"{f}\" name=\"{f}\" expected={any} actual={any}\n",
                    .{ std.zig.fmtString(attrs), std.zig.fmtString(name), expected, actual },
                );
                return error.TestUnexpectedResult;
            }
            if (expected) |expected_attr| {
                const actual_attr = actual.?;
                try std.testing.expectEqualStrings(expected_attr.value, actual_attr.value);
                try std.testing.expectEqual(expected_attr.range.start, actual_attr.range.start);
                try std.testing.expectEqual(expected_attr.range.end, actual_attr.range.end);
            }
        }
        inline for (@typeInfo(Key).@"enum".fields) |field| {
            const expected = attrValueRangeFullScan(attrs, field.name);
            const actual = set.valueNamed(field.name);
            try std.testing.expectEqual(expected != null, actual != null);
            if (expected) |attribute| {
                try std.testing.expectEqualStrings(attribute.value, actual.?);
            }
        }
    }
}

test "AttributeIterator shares lookup recovery and source ranges" {
    const attrs = " @bad=\"x\" disabled width=\"10\" broken=unquoted height='20'";
    const expected_names = [_][]const u8{ "bad", "width", "height" };
    const expected_values = [_][]const u8{ "x", "10", "20" };

    var iterator = AttributeIterator.init(attrs);
    for (expected_names, expected_values) |expected_name, expected_value| {
        const attribute = iterator.next() orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(expected_name, attribute.name);
        try std.testing.expectEqualStrings(expected_value, attribute.value);
        try std.testing.expectEqualStrings(
            expected_value,
            attrs[attribute.range.start..attribute.range.end],
        );
    }
    try std.testing.expect(iterator.next() == null);
}

test "AttributeSet indexes selected names once and keeps first duplicates" {
    const Key = enum {
        id,
        @"stroke-width",
        @"xml:lang",
        missing,
    };
    const attrs = " ignored=\"yes\" id='first' stroke-width=\"2\" id=\"second\" xml:lang='zh-CN'";
    const set = AttributeSet(Key).parse(attrs);

    try std.testing.expectEqualStrings("first", set.value(.id) orelse "");
    try std.testing.expectEqualStrings("2", set.value(.@"stroke-width") orelse "");
    try std.testing.expectEqualStrings("zh-CN", set.value(.@"xml:lang") orelse "");
    try std.testing.expect(set.value(.missing) == null);
}

test "stripTags preserves ordinary text without allocation" {
    const raw = "plain text";
    const stripped = try stripTags(std.testing.allocator, raw);
    defer freeStrippedTags(std.testing.allocator, raw, stripped);

    try std.testing.expect(stripped.ptr == raw.ptr);
    try std.testing.expectEqualStrings("plain text", stripped);
}

test "stripTags preserves CDATA text payload" {
    const raw = "<![CDATA[not <a> tag & not decoded]]>";
    const stripped = try stripTags(std.testing.allocator, raw);
    defer freeStrippedTags(std.testing.allocator, raw, stripped);

    try std.testing.expectEqualStrings("not <a> tag & not decoded", stripped);
}

test "stripTags preserves text around CDATA payload" {
    const raw = "before <![CDATA[middle <literal>]]> after";
    const stripped = try stripTags(std.testing.allocator, raw);
    defer freeStrippedTags(std.testing.allocator, raw, stripped);

    try std.testing.expectEqualStrings("before middle <literal> after", stripped);
}

test "stripTags removes XML comments processing instructions and declarations" {
    const raw =
        \\before <!-- <tspan>ignored</tspan> --> middle <?pi <fake/> ?> <!DECL "<fake/>" [ <!ENTITY e "<x/>"> ]> after
    ;
    const stripped = try stripTags(std.testing.allocator, raw);
    defer freeStrippedTags(std.testing.allocator, raw, stripped);

    try std.testing.expectEqualStrings("before  middle   after", stripped);
}

test "nextTag skips markup-like text inside XML ignored sections" {
    const raw =
        \\<!-- > <rect id="comment"/> -->
        \\<![CDATA[> <circle id="cdata"/>]]>
        \\<?zsvg > <path id="pi"/> ?>
        \\<g id="real"/>
    ;

    var pos: usize = 0;
    const tag = nextTag(raw, &pos) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("g", tag.name);
    try std.testing.expectEqualStrings("real", attrValue(tag.attrs, "id") orelse "");
    try std.testing.expect(nextTag(raw, &pos) == null);
}

test "nextTag closing scan ignores comments and CDATA payload" {
    const raw =
        \\<g id="outer"><!-- > </g> --><![CDATA[> </g>]]><rect id="inside"/></g>
        \\<rect id="after"/>
    ;

    var pos: usize = 0;
    const group = nextTag(raw, &pos) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("g", group.name);
    try std.testing.expectEqualStrings("outer", attrValue(group.attrs, "id") orelse "");
    try std.testing.expect(hasChildTag(raw[group.inner_start..group.end], "rect"));

    const after = nextTag(raw, &pos) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("rect", after.name);
    try std.testing.expectEqualStrings("after", attrValue(after.attrs, "id") orelse "");
    try std.testing.expect(nextTag(raw, &pos) == null);
}

test "nextTag skips XML declarations containing pseudo elements" {
    const raw =
        \\<!DOCTYPE svg [
        \\  <!ENTITY phantom "<rect id='phantom'/>">
        \\  <!ENTITY premature "</svg>">
        \\]>
        \\<!GENERIC "<circle id='decl'/>" "</g>">
        \\<svg id="root"><g id="outer"><!DECL "</g>" [ <!ENTITY nested "<path id='nested'/>" > ]><rect id="inside"/></g></svg>
        \\<rect id="after"/>
    ;

    var pos: usize = 0;
    const root = nextTag(raw, &pos) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("svg", root.name);
    try std.testing.expectEqualStrings("root", attrValue(root.attrs, "id") orelse "");

    const root_content = raw[root.inner_start..root.end];
    try std.testing.expect(!hasChildTag(root_content, "path"));

    var child_pos: usize = 0;
    const group = nextTag(root_content, &child_pos) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("g", group.name);
    try std.testing.expectEqualStrings("outer", attrValue(group.attrs, "id") orelse "");
    try std.testing.expect(hasChildTag(root_content[group.inner_start..group.end], "rect"));

    const after = nextTag(raw, &pos) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("rect", after.name);
    try std.testing.expectEqualStrings("after", attrValue(after.attrs, "id") orelse "");
    try std.testing.expect(nextTag(raw, &pos) == null);
}

test "doctype source range ignores comments cdata and processing instructions" {
    const raw =
        \\<!-- <!DOCTYPE ignored> -->
        \\<![CDATA[<!DOCTYPE ignored>]]>
        \\<?pi <!DOCTYPE ignored> ?>
        \\<!DOCTYPE svg [ <!ENTITY e "<rect/>"> ]>
        \\<svg/>
    ;
    const range = doctypeDeclarationRange(raw) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(std.mem.indexOf(u8, raw, "<!DOCTYPE svg").?, range.start);
    try std.testing.expect(std.mem.indexOf(u8, raw[range.start..range.end], "<!ENTITY") != null);
}

pub fn hasTextChildTag(input: []const u8) bool {
    var pos: usize = 0;
    while (nextTag(input, &pos)) |tag| {
        if (std.mem.eql(u8, tag.name, "tspan") or std.mem.eql(u8, tag.name, "textPath") or std.mem.eql(u8, tag.name, "a")) return true;
    }
    return false;
}

pub fn hasAnyChildTag(input: []const u8) bool {
    var pos: usize = 0;
    while (nextTag(input, &pos)) |tag| {
        if (tag.name.len != 0 and tag.name[0] != '/' and tag.name[0] != '!' and tag.name[0] != '?') return true;
    }
    return false;
}

pub fn hasChildTag(input: []const u8, name: []const u8) bool {
    var pos: usize = 0;
    while (nextTag(input, &pos)) |tag| {
        if (std.mem.eql(u8, tag.name, name)) return true;
    }
    return false;
}

fn nextMarkupStart(input: []const u8, pos: *usize) ?usize {
    while (std.mem.indexOfScalarPos(u8, input, pos.*, '<')) |lt| {
        if (std.mem.startsWith(u8, input[lt..], "<!--")) {
            // XML comments are markup, but their payload is not parsed for
            // child elements. Skip the whole comment so text such as
            // "<!-- <rect/> -->" cannot create phantom SVG nodes.
            pos.* = if (std.mem.indexOfPos(u8, input, lt + "<!--".len, "-->")) |end|
                end + "-->".len
            else
                input.len;
            continue;
        }
        if (std.mem.startsWith(u8, input[lt..], "<![CDATA[")) {
            // CDATA contains literal character data; '<' bytes inside it must
            // not be considered markup. This matters for mixed text content
            // and for resource/style scans over arbitrary element payloads.
            pos.* = if (std.mem.indexOfPos(u8, input, lt + "<![CDATA[".len, "]]>")) |end|
                end + "]]>".len
            else
                input.len;
            continue;
        }
        if (std.mem.startsWith(u8, input[lt..], "<?")) {
            // Processing instructions are standalone markup and their content
            // is not element syntax. XML terminates them with '?>', not just
            // the first '>' that may appear inside pseudo-attributes.
            pos.* = if (std.mem.indexOfPos(u8, input, lt + "<?".len, "?>")) |end|
                end + "?>".len
            else
                input.len;
            continue;
        }
        if (std.mem.startsWith(u8, input[lt..], "<!")) {
            // DTD declarations (notably <!DOCTYPE ... [ ... ]>) are markup
            // declarations, not elements. Their internal subset may contain
            // declaration markup and quoted pseudo-elements such as
            // "<rect/>" or "</svg>"; treat the entire declaration as opaque
            // so those bytes cannot create phantom SVG nodes or close an
            // ancestor while findClosingTag is scanning.
            pos.* = if (findDeclarationEnd(input, lt + "<!".len)) |end|
                end + 1
            else
                input.len;
            continue;
        }
        pos.* = lt;
        return lt;
    }
    pos.* = input.len;
    return null;
}

fn findClosingTag(input: []const u8, name: []const u8, start: usize) ?usize {
    var depth: usize = 1;
    var pos = start;
    while (nextMarkupStart(input, &pos)) |lt| {
        const gt = findTagEnd(input, lt + 1) orelse return null;
        var body = std.mem.trim(u8, input[lt + 1 .. gt], " \t\r\n");
        if (body.len == 0 or body[0] == '!' or body[0] == '?') {
            pos = gt + 1;
            continue;
        }
        if (body[0] == '/') {
            body = std.mem.trim(u8, body[1..], " \t\r\n");
            const end = std.mem.indexOfAny(u8, body, " \t\r\n>") orelse body.len;
            if (std.mem.eql(u8, localName(body[0..end]), name)) {
                depth -= 1;
                if (depth == 0) return lt;
            }
        } else {
            const self_closing = body[body.len - 1] == '/';
            const end = std.mem.indexOfAny(u8, body, " \t\r\n/") orelse body.len;
            if (!self_closing and std.mem.eql(u8, localName(body[0..end]), name)) depth += 1;
        }
        pos = gt + 1;
    }
    return null;
}
