//! XML Schema Part 2 built-in datatypes and constraining facets.

const std = @import("std");
const chars = @import("../chars.zig");
const regex = @import("regex.zig");

pub const Whitespace = enum { preserve, replace, collapse };

pub const Kind = enum {
    string,
    normalized_string,
    token,
    language,
    name,
    ncname,
    nmtoken,
    nmtokens,
    id,
    idref,
    idrefs,
    entity,
    entities,
    any_uri,
    qname,
    notation,
    boolean,
    decimal,
    integer,
    non_positive_integer,
    negative_integer,
    long,
    int,
    short,
    byte,
    non_negative_integer,
    unsigned_long,
    unsigned_int,
    unsigned_short,
    unsigned_byte,
    positive_integer,
    float,
    double,
    duration,
    date_time,
    time,
    date,
    g_year_month,
    g_year,
    g_month_day,
    g_day,
    g_month,
    hex_binary,
    base64_binary,
};

pub const Builtin = struct {
    kind: Kind,
    whitespace: Whitespace,
};

/// Built-in type from which `kind` is derived by restriction. Returns null
/// for `anySimpleType`-level types.
pub fn baseKind(kind: Kind) ?Kind {
    return switch (kind) {
        .string,
        .any_uri,
        .qname,
        .notation,
        .boolean,
        .decimal,
        .float,
        .double,
        .duration,
        .date_time,
        .time,
        .date,
        .g_year_month,
        .g_year,
        .g_month_day,
        .g_day,
        .g_month,
        .hex_binary,
        .base64_binary,
        => null,
        .normalized_string => .string,
        .token => .normalized_string,
        .language, .name, .nmtoken => .token,
        .ncname => .name,
        .nmtokens => .nmtoken,
        .id, .idref, .entity => .ncname,
        .idrefs => .idref,
        .entities => .entity,
        .integer => .decimal,
        .non_positive_integer => .integer,
        .negative_integer => .non_positive_integer,
        .long => .integer,
        .int => .long,
        .short => .int,
        .byte => .short,
        .non_negative_integer => .integer,
        .unsigned_long => .non_negative_integer,
        .unsigned_int => .unsigned_long,
        .unsigned_short => .unsigned_int,
        .unsigned_byte => .unsigned_short,
        .positive_integer => .non_negative_integer,
    };
}

pub const Facets = struct {
    enumeration: []const []const u8 = &.{},
    patterns: []const *const regex.Regex = &.{},
    length: ?usize = null,
    min_length: ?usize = null,
    max_length: ?usize = null,
    min_inclusive: ?[]const u8 = null,
    max_inclusive: ?[]const u8 = null,
    min_exclusive: ?[]const u8 = null,
    max_exclusive: ?[]const u8 = null,
    total_digits: ?usize = null,
    fraction_digits: ?usize = null,
    white_space: ?Whitespace = null,
};

/// Look up a built-in type by its local name (without the `xs:` prefix).
pub fn builtin(local_name: []const u8) ?Builtin {
    const collapsed = Whitespace.collapse;
    const preserved = Whitespace.preserve;
    const replaced = Whitespace.replace;
    const table = [_]struct { []const u8, Kind, Whitespace }{
        .{ "string", .string, preserved },
        .{ "normalizedString", .normalized_string, replaced },
        .{ "token", .token, collapsed },
        .{ "language", .language, collapsed },
        .{ "Name", .name, collapsed },
        .{ "NCName", .ncname, collapsed },
        .{ "NMTOKEN", .nmtoken, collapsed },
        .{ "NMTOKENS", .nmtokens, collapsed },
        .{ "ID", .id, collapsed },
        .{ "IDREF", .idref, collapsed },
        .{ "IDREFS", .idrefs, collapsed },
        .{ "ENTITY", .entity, collapsed },
        .{ "ENTITIES", .entities, collapsed },
        .{ "anyURI", .any_uri, collapsed },
        .{ "QName", .qname, collapsed },
        .{ "NOTATION", .notation, collapsed },
        .{ "boolean", .boolean, collapsed },
        .{ "decimal", .decimal, collapsed },
        .{ "integer", .integer, collapsed },
        .{ "nonPositiveInteger", .non_positive_integer, collapsed },
        .{ "negativeInteger", .negative_integer, collapsed },
        .{ "long", .long, collapsed },
        .{ "int", .int, collapsed },
        .{ "short", .short, collapsed },
        .{ "byte", .byte, collapsed },
        .{ "nonNegativeInteger", .non_negative_integer, collapsed },
        .{ "unsignedLong", .unsigned_long, collapsed },
        .{ "unsignedInt", .unsigned_int, collapsed },
        .{ "unsignedShort", .unsigned_short, collapsed },
        .{ "unsignedByte", .unsigned_byte, collapsed },
        .{ "positiveInteger", .positive_integer, collapsed },
        .{ "float", .float, collapsed },
        .{ "double", .double, collapsed },
        .{ "duration", .duration, collapsed },
        .{ "dateTime", .date_time, collapsed },
        .{ "time", .time, collapsed },
        .{ "date", .date, collapsed },
        .{ "gYearMonth", .g_year_month, collapsed },
        .{ "gYear", .g_year, collapsed },
        .{ "gMonthDay", .g_month_day, collapsed },
        .{ "gDay", .g_day, collapsed },
        .{ "gMonth", .g_month, collapsed },
        .{ "hexBinary", .hex_binary, collapsed },
        .{ "base64Binary", .base64_binary, collapsed },
    };
    for (table) |entry| {
        if (std.mem.eql(u8, entry[0], local_name)) {
            return .{ .kind = entry[1], .whitespace = entry[2] };
        }
    }
    return null;
}

pub fn builtinWhitespace(kind: Kind) Whitespace {
    return switch (kind) {
        .string => .preserve,
        .normalized_string => .replace,
        else => .collapse,
    };
}

/// Apply the XML Schema whitespace rule. The result may borrow `value`.
pub fn normalize(
    allocator: std.mem.Allocator,
    whitespace: Whitespace,
    value: []const u8,
) ![]const u8 {
    return switch (whitespace) {
        .preserve => value,
        .replace => replaceWhitespace(allocator, value),
        .collapse => collapseWhitespace(allocator, value),
    };
}

fn replaceWhitespace(
    allocator: std.mem.Allocator,
    value: []const u8,
) ![]const u8 {
    var changed = false;
    for (value) |byte| {
        if (byte == '\t' or byte == '\r' or byte == '\n') {
            changed = true;
            break;
        }
    }
    if (!changed) return value;
    const out = try allocator.dupe(u8, value);
    for (out) |*byte| {
        if (byte.* == '\t' or byte.* == '\r' or byte.* == '\n') byte.* = ' ';
    }
    return out;
}

fn collapseWhitespace(
    allocator: std.mem.Allocator,
    value: []const u8,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var pending_space = false;
    var started = false;
    for (value) |byte| {
        if (byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n') {
            if (started) pending_space = true;
            continue;
        }
        if (pending_space) {
            try out.append(allocator, ' ');
            pending_space = false;
        }
        try out.append(allocator, byte);
        started = true;
    }
    return out.toOwnedSlice(allocator);
}

/// Validate a lexical value against a built-in type and its facets.
/// Temporary allocations are released before returning.
pub fn validate(
    allocator: std.mem.Allocator,
    kind: Kind,
    facets: Facets,
    value: []const u8,
) !bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const whitespace = facets.white_space orelse builtinWhitespace(kind);
    const normalized = try normalize(arena.allocator(), whitespace, value);
    return validateNormalizedArena(arena.allocator(), kind, facets, normalized);
}

/// Validate an already-normalized value. Temporary allocations are released
/// before returning.
pub fn validateNormalized(
    allocator: std.mem.Allocator,
    kind: Kind,
    facets: Facets,
    value: []const u8,
) !bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    return validateNormalizedArena(arena.allocator(), kind, facets, value);
}

fn validateNormalizedArena(
    allocator: std.mem.Allocator,
    kind: Kind,
    facets: Facets,
    value: []const u8,
) !bool {
    if (!validateLexical(kind, value)) return false;

    if (facets.enumeration.len != 0) {
        var found = false;
        for (facets.enumeration) |candidate| {
            const normalized = try normalize(
                allocator,
                facets.white_space orelse builtinWhitespace(kind),
                candidate,
            );
            if (valuesEqual(kind, value, normalized)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }

    if (facets.patterns.len != 0) {
        var matched = false;
        for (facets.patterns) |pattern| {
            if (try pattern.matches(allocator, value)) {
                matched = true;
                break;
            }
        }
        if (!matched) return false;
    }

    if (facets.length != null or facets.min_length != null or
        facets.max_length != null)
    {
        const units = lengthUnits(kind, value) orelse return false;
        if (facets.length) |expected| {
            if (units != expected) return false;
        }
        if (facets.min_length) |minimum| {
            if (units < minimum) return false;
        }
        if (facets.max_length) |maximum| {
            if (units > maximum) return false;
        }
    }

    if (facets.min_inclusive) |bound| {
        const order = compareValues(kind, value, bound) orelse return false;
        if (order == .lt) return false;
    }
    if (facets.max_inclusive) |bound| {
        const order = compareValues(kind, value, bound) orelse return false;
        if (order == .gt) return false;
    }
    if (facets.min_exclusive) |bound| {
        const order = compareValues(kind, value, bound) orelse return false;
        if (order != .gt) return false;
    }
    if (facets.max_exclusive) |bound| {
        const order = compareValues(kind, value, bound) orelse return false;
        if (order != .lt) return false;
    }

    if (facets.total_digits) |limit| {
        const digits = decimalDigits(value) orelse return false;
        if (digits.total > limit) return false;
    }
    if (facets.fraction_digits) |limit| {
        const digits = decimalDigits(value) orelse return false;
        if (digits.fraction > limit) return false;
    }
    return true;
}

pub fn validateLexical(kind: Kind, value: []const u8) bool {
    return switch (kind) {
        .string, .normalized_string, .token, .any_uri => true,
        .language => isLanguage(value),
        .name => chars.isName(value),
        .ncname => chars.isNCName(value),
        .nmtoken => chars.isNmtoken(value),
        .nmtokens => allTokens(value, .nmtoken),
        .id, .idref => chars.isNCName(value),
        .idrefs => allTokens(value, .ncname),
        .entity => chars.isName(value),
        .entities => allTokens(value, .name),
        .qname, .notation => isQName(value),
        .boolean => isBoolean(value),
        .decimal => parseDecimal(value) != null,
        .integer,
        .non_positive_integer,
        .negative_integer,
        .long,
        .int,
        .short,
        .byte,
        .non_negative_integer,
        .unsigned_long,
        .unsigned_int,
        .unsigned_short,
        .unsigned_byte,
        .positive_integer,
        => integerInRange(kind, value),
        .float, .double => parseFloatValue(value) != null,
        .duration => parseDuration(value) != null,
        .date_time => parseDateTimeValue(.date_time, value) != null,
        .time => parseDateTimeValue(.time, value) != null,
        .date => parseDateTimeValue(.date, value) != null,
        .g_year_month => parseDateTimeValue(.g_year_month, value) != null,
        .g_year => parseDateTimeValue(.g_year, value) != null,
        .g_month_day => parseDateTimeValue(.g_month_day, value) != null,
        .g_day => parseDateTimeValue(.g_day, value) != null,
        .g_month => parseDateTimeValue(.g_month, value) != null,
        .hex_binary => isHexBinary(value),
        .base64_binary => base64DecodedLength(value) != null,
    };
}

fn isLanguage(value: []const u8) bool {
    var tokens = std.mem.splitScalar(u8, value, '-');
    const first = tokens.next() orelse return false;
    if (first.len == 0 or first.len > 8) return false;
    for (first) |byte| {
        if (!std.ascii.isAlphabetic(byte)) return false;
    }
    while (tokens.next()) |token| {
        if (token.len == 0 or token.len > 8) return false;
        for (token) |byte| {
            if (!std.ascii.isAlphanumeric(byte)) return false;
        }
    }
    return true;
}

fn allTokens(value: []const u8, kind: Kind) bool {
    var tokens = std.mem.tokenizeAny(u8, value, " \t\r\n");
    var count: usize = 0;
    while (tokens.next()) |token| {
        if (!validateLexical(kind, token)) return false;
        count += 1;
    }
    return count != 0;
}

fn isQName(value: []const u8) bool {
    if (std.mem.indexOfScalar(u8, value, ':')) |colon| {
        if (colon == 0 or colon + 1 == value.len) return false;
        if (std.mem.indexOfScalarPos(u8, value, colon + 1, ':') != null) {
            return false;
        }
        return chars.isNCName(value[0..colon]) and
            chars.isNCName(value[colon + 1 ..]);
    }
    return chars.isNCName(value);
}

fn isBoolean(value: []const u8) bool {
    return std.mem.eql(u8, value, "true") or
        std.mem.eql(u8, value, "false") or
        std.mem.eql(u8, value, "1") or
        std.mem.eql(u8, value, "0");
}

fn booleanValue(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1")) {
        return true;
    }
    if (std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "0")) {
        return false;
    }
    return null;
}

const Decimal = struct {
    negative: bool,
    integer: []const u8,
    fraction: []const u8,
};

fn parseDecimal(value: []const u8) ?Decimal {
    if (value.len == 0) return null;
    var index: usize = 0;
    var negative = false;
    if (value[index] == '+' or value[index] == '-') {
        negative = value[index] == '-';
        index += 1;
    }
    const integer_start = index;
    while (index < value.len and std.ascii.isDigit(value[index])) index += 1;
    const integer = value[integer_start..index];
    var fraction: []const u8 = "";
    if (index < value.len and value[index] == '.') {
        index += 1;
        const fraction_start = index;
        while (index < value.len and std.ascii.isDigit(value[index])) index += 1;
        fraction = value[fraction_start..index];
    }
    if (index != value.len) return null;
    if (integer.len == 0 and fraction.len == 0) return null;
    return .{ .negative = negative, .integer = integer, .fraction = fraction };
}

fn trimLeadingZeros(value: []const u8) []const u8 {
    var index: usize = 0;
    while (index < value.len and value[index] == '0') index += 1;
    return value[index..];
}

fn trimTrailingZeros(value: []const u8) []const u8 {
    var end = value.len;
    while (end > 0 and value[end - 1] == '0') end -= 1;
    return value[0..end];
}

fn decimalIsZero(value: Decimal) bool {
    for (value.integer) |byte| if (byte != '0') return false;
    for (value.fraction) |byte| if (byte != '0') return false;
    return true;
}

fn compareDecimal(a: Decimal, b: Decimal) std.math.Order {
    const a_zero = decimalIsZero(a);
    const b_zero = decimalIsZero(b);
    if (a_zero and b_zero) return .eq;
    if (a_zero) return if (b.negative) .gt else .lt;
    if (b_zero) return if (a.negative) .lt else .gt;
    if (a.negative != b.negative) return if (a.negative) .lt else .gt;
    const a_integer = trimLeadingZeros(a.integer);
    const b_integer = trimLeadingZeros(b.integer);
    var order: std.math.Order = .eq;
    if (a_integer.len != b_integer.len) {
        order = if (a_integer.len < b_integer.len) .lt else .gt;
    } else {
        order = std.mem.order(u8, a_integer, b_integer);
    }
    if (order != .eq) return if (a.negative) reverseOrder(order) else order;
    const a_fraction = trimTrailingZeros(a.fraction);
    const b_fraction = trimTrailingZeros(b.fraction);
    const length = @max(a_fraction.len, b_fraction.len);
    var index: usize = 0;
    while (index < length) : (index += 1) {
        const a_digit: u8 = if (index < a_fraction.len) a_fraction[index] else '0';
        const b_digit: u8 = if (index < b_fraction.len) b_fraction[index] else '0';
        if (a_digit != b_digit) {
            const fraction_order: std.math.Order = if (a_digit < b_digit) .lt else .gt;
            return if (a.negative) reverseOrder(fraction_order) else fraction_order;
        }
    }
    return .eq;
}

fn reverseOrder(order: std.math.Order) std.math.Order {
    return switch (order) {
        .lt => .gt,
        .gt => .lt,
        .eq => .eq,
    };
}

fn integerInRange(kind: Kind, value: []const u8) bool {
    const decimal = parseDecimal(value) orelse return false;
    if (decimal.fraction.len != 0) return false;
    var index: usize = 0;
    var negative = false;
    if (value.len != 0 and (value[0] == '+' or value[0] == '-')) {
        negative = value[0] == '-';
        index = 1;
    }
    if (index >= value.len) return false;
    for (value[index..]) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    const digits = value[index..];
    const zero = trimLeadingZeros(digits).len == 0;
    switch (kind) {
        .integer => return true,
        .non_positive_integer => return negative or zero,
        .negative_integer => return negative and !zero,
        .non_negative_integer => return !negative or zero,
        .positive_integer => return !negative and !zero,
        else => {},
    }
    const signed_text = if (value.len != 0 and value[0] == '+')
        value[1..]
    else
        value;
    const parsed = std.fmt.parseInt(i128, signed_text, 10) catch return false;
    return switch (kind) {
        .long => parsed >= std.math.minInt(i64) and parsed <= std.math.maxInt(i64),
        .int => parsed >= std.math.minInt(i32) and parsed <= std.math.maxInt(i32),
        .short => parsed >= std.math.minInt(i16) and parsed <= std.math.maxInt(i16),
        .byte => parsed >= std.math.minInt(i8) and parsed <= std.math.maxInt(i8),
        .unsigned_long => parsed >= 0 and @as(u128, @intCast(parsed)) <= std.math.maxInt(u64),
        .unsigned_int => parsed >= 0 and parsed <= std.math.maxInt(u32),
        .unsigned_short => parsed >= 0 and parsed <= std.math.maxInt(u16),
        .unsigned_byte => parsed >= 0 and parsed <= std.math.maxInt(u8),
        else => false,
    };
}

fn parseFloatValue(value: []const u8) ?f64 {
    if (std.mem.eql(u8, value, "INF") or std.mem.eql(u8, value, "+INF")) {
        return std.math.inf(f64);
    }
    if (std.mem.eql(u8, value, "-INF")) return -std.math.inf(f64);
    if (std.mem.eql(u8, value, "NaN")) return std.math.nan(f64);

    var index: usize = 0;
    if (value.len == 0) return null;
    if (value[index] == '+' or value[index] == '-') index += 1;
    var digits: usize = 0;
    while (index < value.len and std.ascii.isDigit(value[index])) : (index += 1) {
        digits += 1;
    }
    if (index < value.len and value[index] == '.') {
        index += 1;
        while (index < value.len and std.ascii.isDigit(value[index])) : (index += 1) {
            digits += 1;
        }
    }
    if (digits == 0) return null;
    if (index < value.len and (value[index] == 'e' or value[index] == 'E')) {
        index += 1;
        if (index < value.len and (value[index] == '+' or value[index] == '-')) {
            index += 1;
        }
        const exponent_start = index;
        while (index < value.len and std.ascii.isDigit(value[index])) : (index += 1) {}
        if (index == exponent_start) return null;
    }
    if (index != value.len) return null;
    return std.fmt.parseFloat(f64, value) catch null;
}

const DateTimeKind = enum {
    date_time,
    date,
    time,
    g_year_month,
    g_year,
    g_month_day,
    g_day,
    g_month,
};

const DateTimeValue = struct {
    kind: DateTimeKind,
    seconds: i64,
    nanos: u32,
    year: i64,
    month: u8,
    day: u8,
};

const Cursor = struct {
    text: []const u8,
    index: usize = 0,

    fn eof(self: *const Cursor) bool {
        return self.index >= self.text.len;
    }

    fn peek(self: *const Cursor) ?u8 {
        if (self.eof()) return null;
        return self.text[self.index];
    }

    fn expect(self: *Cursor, byte: u8) bool {
        if (self.peek() != byte) return false;
        self.index += 1;
        return true;
    }

    fn digits(self: *Cursor, count: usize) ?[]const u8 {
        const start = self.index;
        var read: usize = 0;
        while (read < count and !self.eof() and
            std.ascii.isDigit(self.text[self.index]))
        {
            self.index += 1;
            read += 1;
        }
        if (read != count) return null;
        return self.text[start..self.index];
    }

    fn number(self: *Cursor, count: usize) ?u32 {
        const text = self.digits(count) orelse return null;
        return std.fmt.parseUnsigned(u32, text, 10) catch null;
    }
};

fn parseYear(cursor: *Cursor) ?i64 {
    var negative = false;
    if (cursor.peek() == '-') {
        negative = true;
        cursor.index += 1;
    }
    const start = cursor.index;
    while (!cursor.eof() and std.ascii.isDigit(cursor.text[cursor.index])) {
        cursor.index += 1;
    }
    const digits = cursor.text[start..cursor.index];
    if (digits.len < 4) return null;
    if (digits.len > 4 and digits[0] == '0') return null;
    const value = std.fmt.parseInt(i64, digits, 10) catch return null;
    if (value == 0) return null;
    return if (negative) -value else value;
}

fn parseTimezone(cursor: *Cursor) ?i32 {
    if (cursor.eof()) return 0;
    if (cursor.peek() == 'Z') {
        cursor.index += 1;
        return 0;
    }
    const sign: i32 = if (cursor.peek() == '+')
        1
    else if (cursor.peek() == '-')
        -1
    else
        return 0;
    cursor.index += 1;
    const hours = cursor.number(2) orelse return null;
    if (!cursor.expect(':')) return null;
    const minutes = cursor.number(2) orelse return null;
    if (hours > 14 or minutes > 59) return null;
    if (hours == 14 and minutes != 0) return null;
    return sign * (@as(i32, @intCast(hours)) * 60 + @as(i32, @intCast(minutes)));
}

fn parseSeconds(cursor: *Cursor, second: *u32, nanos: *u32) bool {
    const value = cursor.number(2) orelse return false;
    if (value > 59) return false;
    second.* = value;
    if (cursor.peek() == '.') {
        cursor.index += 1;
        const start = cursor.index;
        while (!cursor.eof() and std.ascii.isDigit(cursor.text[cursor.index])) {
            cursor.index += 1;
        }
        if (cursor.index == start) return false;
        var fraction: u64 = 0;
        var count: usize = 0;
        for (cursor.text[start..cursor.index]) |byte| {
            if (count == 9) break;
            fraction = fraction * 10 + (byte - '0');
            count += 1;
        }
        while (count < 9) : (count += 1) fraction *= 10;
        nanos.* = @intCast(fraction);
    }
    return true;
}

fn parseDateTimeValue(
    kind: DateTimeKind,
    value: []const u8,
) ?DateTimeValue {
    var cursor: Cursor = .{ .text = value };
    var year: i64 = 0;
    var month: u8 = 0;
    var day: u8 = 0;
    var hour: u32 = 0;
    var minute: u32 = 0;
    var second: u32 = 0;
    var nanos: u32 = 0;
    var has_time = false;

    switch (kind) {
        .date_time => {
            year = parseYear(&cursor) orelse return null;
            if (!cursor.expect('-')) return null;
            month = @intCast(cursor.number(2) orelse return null);
            if (!cursor.expect('-')) return null;
            day = @intCast(cursor.number(2) orelse return null);
            if (!cursor.expect('T')) return null;
            hour = cursor.number(2) orelse return null;
            if (!cursor.expect(':')) return null;
            minute = cursor.number(2) orelse return null;
            if (!cursor.expect(':')) return null;
            if (!parseSeconds(&cursor, &second, &nanos)) return null;
            has_time = true;
        },
        .date => {
            year = parseYear(&cursor) orelse return null;
            if (!cursor.expect('-')) return null;
            month = @intCast(cursor.number(2) orelse return null);
            if (!cursor.expect('-')) return null;
            day = @intCast(cursor.number(2) orelse return null);
        },
        .time => {
            hour = cursor.number(2) orelse return null;
            if (!cursor.expect(':')) return null;
            minute = cursor.number(2) orelse return null;
            if (!cursor.expect(':')) return null;
            if (!parseSeconds(&cursor, &second, &nanos)) return null;
            has_time = true;
        },
        .g_year_month => {
            year = parseYear(&cursor) orelse return null;
            if (!cursor.expect('-')) return null;
            month = @intCast(cursor.number(2) orelse return null);
        },
        .g_year => {
            year = parseYear(&cursor) orelse return null;
        },
        .g_month_day => {
            if (!cursor.expect('-') or !cursor.expect('-')) return null;
            month = @intCast(cursor.number(2) orelse return null);
            if (!cursor.expect('-')) return null;
            day = @intCast(cursor.number(2) orelse return null);
        },
        .g_day => {
            if (!cursor.expect('-') or !cursor.expect('-') or
                !cursor.expect('-'))
            {
                return null;
            }
            day = @intCast(cursor.number(2) orelse return null);
        },
        .g_month => {
            if (!cursor.expect('-') or !cursor.expect('-')) return null;
            month = @intCast(cursor.number(2) orelse return null);
        },
    }

    if (month != 0 and (month < 1 or month > 12)) return null;
    if (kind == .g_day) {
        if (day < 1 or day > 31) return null;
    } else if (month != 0 and day != 0 and
        (day < 1 or day > daysInMonth(year, month)))
    {
        return null;
    }
    if (has_time) {
        if (hour == 24) {
            if (minute != 0 or second != 0 or nanos != 0) return null;
        } else if (hour > 23) {
            return null;
        }
        if (minute > 59 or second > 59) return null;
    }

    const offset = parseTimezone(&cursor) orelse return null;
    if (!cursor.eof()) return null;

    var seconds: i64 = 0;
    switch (kind) {
        .date_time, .date => {
            const days = daysFromCivil(year, month, day);
            seconds = days * 86400;
            if (has_time) {
                seconds += @as(i64, hour) * 3600 + @as(i64, minute) * 60 +
                    @as(i64, second);
            }
            seconds -= @as(i64, offset) * 60;
        },
        .time => {
            seconds = @as(i64, hour) * 3600 + @as(i64, minute) * 60 +
                @as(i64, second) - @as(i64, offset) * 60;
        },
        else => {},
    }
    return .{
        .kind = kind,
        .seconds = seconds,
        .nanos = nanos,
        .year = year,
        .month = month,
        .day = day,
    };
}

fn isLeapYear(year: i64) bool {
    return @mod(year, 4) == 0 and
        (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

fn daysInMonth(year: i64, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

fn daysFromCivil(year: i64, month: u8, day: u8) i64 {
    // Astronomical year numbering: XSD -0001 is 1 BC (astronomical year 0).
    const astronomical = if (year < 0) year + 1 else year;
    var y = astronomical;
    y -= if (month <= 2) 1 else 0;
    const era = @divFloor(y, 400);
    const year_of_era = y - era * 400;
    const month_prime: i64 = @mod(@as(i64, month) + 9, 12);
    const day_of_year = @divFloor(153 * month_prime + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

const DurationValue = struct {
    negative: bool,
    months: i64,
    seconds: i64,
    nanos: u32,
};

fn parseDuration(value: []const u8) ?DurationValue {
    var index: usize = 0;
    var negative = false;
    if (value.len == 0) return null;
    if (value[index] == '-') {
        negative = true;
        index += 1;
    }
    if (index >= value.len or value[index] != 'P') return null;
    index += 1;

    var months: i64 = 0;
    var seconds: i64 = 0;
    var nanos: u32 = 0;
    var components: usize = 0;
    var in_time = false;
    while (index < value.len) {
        if (value[index] == 'T') {
            if (in_time) return null;
            in_time = true;
            index += 1;
            const time_start = index;
            var last_time: u8 = 0;
            while (index < value.len) {
                const number_start = index;
                while (index < value.len and std.ascii.isDigit(value[index])) {
                    index += 1;
                }
                if (index == number_start) return null;
                const number = std.fmt.parseInt(i64, value[number_start..index], 10) catch
                    return null;
                var fraction_nanos: u32 = 0;
                var has_fraction = false;
                if (index < value.len and value[index] == '.') {
                    index += 1;
                    const fraction_start = index;
                    while (index < value.len and std.ascii.isDigit(value[index])) {
                        index += 1;
                    }
                    if (index == fraction_start) return null;
                    var fraction: u64 = 0;
                    var count: usize = 0;
                    for (value[fraction_start..index]) |byte| {
                        if (count == 9) break;
                        fraction = fraction * 10 + (byte - '0');
                        count += 1;
                    }
                    while (count < 9) : (count += 1) fraction *= 10;
                    fraction_nanos = @intCast(fraction);
                    has_fraction = true;
                }
                if (index >= value.len) return null;
                const designator = value[index];
                index += 1;
                switch (designator) {
                    'H' => {
                        if (has_fraction or last_time >= 1) return null;
                        last_time = 1;
                        seconds += number * 3600;
                    },
                    'M' => {
                        if (has_fraction or last_time >= 2) return null;
                        last_time = 2;
                        seconds += number * 60;
                    },
                    'S' => {
                        if (last_time >= 3) return null;
                        last_time = 3;
                        seconds += number;
                        nanos = fraction_nanos;
                    },
                    else => return null,
                }
                components += 1;
            }
            if (index == time_start) return null;
            break;
        }
        const number_start = index;
        while (index < value.len and std.ascii.isDigit(value[index])) {
            index += 1;
        }
        if (index == number_start) return null;
        const number = std.fmt.parseInt(i64, value[number_start..index], 10) catch
            return null;
        if (index >= value.len) return null;
        const designator = value[index];
        index += 1;
        switch (designator) {
            'Y' => months += number * 12,
            'M' => months += number,
            'D' => seconds += number * 86400,
            else => return null,
        }
        components += 1;
    }
    if (components == 0) return null;
    return .{
        .negative = negative,
        .months = months,
        .seconds = seconds,
        .nanos = nanos,
    };
}

fn isHexBinary(value: []const u8) bool {
    if (value.len % 2 != 0) return false;
    for (value) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

fn base64DecodedLength(value: []const u8) ?usize {
    var count: usize = 0;
    var padding: usize = 0;
    var seen_padding = false;
    for (value) |byte| {
        if (byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n') {
            continue;
        }
        if (seen_padding and byte != '=') return null;
        if (byte == '=') {
            seen_padding = true;
            padding += 1;
            if (padding > 2) return null;
            count += 1;
            continue;
        }
        if (!isBase64Char(byte)) return null;
        count += 1;
    }
    if (count == 0 or count % 4 != 0) return null;
    return count / 4 * 3 - padding;
}

fn isBase64Char(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '+' or byte == '/';
}

fn lengthUnits(kind: Kind, value: []const u8) ?usize {
    return switch (kind) {
        .hex_binary => value.len / 2,
        .base64_binary => base64DecodedLength(value) orelse return null,
        .nmtokens, .idrefs, .entities => blk: {
            var tokens = std.mem.tokenizeAny(u8, value, " \t\r\n");
            var count: usize = 0;
            while (tokens.next()) |_| count += 1;
            break :blk count;
        },
        .string,
        .normalized_string,
        .token,
        .language,
        .name,
        .ncname,
        .nmtoken,
        .id,
        .idref,
        .entity,
        .any_uri,
        .qname,
        .notation,
        => std.unicode.utf8CountCodepoints(value) catch return null,
        else => return null,
    };
}

fn decimalDigits(value: []const u8) ?struct { total: usize, fraction: usize } {
    const decimal = parseDecimal(value) orelse return null;
    const integer = trimLeadingZeros(decimal.integer);
    const fraction = trimTrailingZeros(decimal.fraction);
    const total = @max(integer.len + fraction.len, 1);
    return .{ .total = total, .fraction = fraction.len };
}

fn valuesEqual(kind: Kind, a: []const u8, b: []const u8) bool {
    if (compareValues(kind, a, b)) |order| return order == .eq;
    return std.mem.eql(u8, a, b);
}

pub fn compareValues(kind: Kind, a: []const u8, b: []const u8) ?std.math.Order {
    return switch (kind) {
        .boolean => blk: {
            const a_value = booleanValue(a) orelse break :blk null;
            const b_value = booleanValue(b) orelse break :blk null;
            if (a_value == b_value) break :blk .eq;
            break :blk if (!a_value) .lt else .gt;
        },
        .decimal,
        .integer,
        .non_positive_integer,
        .negative_integer,
        .long,
        .int,
        .short,
        .byte,
        .non_negative_integer,
        .unsigned_long,
        .unsigned_int,
        .unsigned_short,
        .unsigned_byte,
        .positive_integer,
        => blk: {
            const a_value = parseDecimal(a) orelse break :blk null;
            const b_value = parseDecimal(b) orelse break :blk null;
            break :blk compareDecimal(a_value, b_value);
        },
        .float, .double => blk: {
            const a_value = parseFloatValue(a) orelse break :blk null;
            const b_value = parseFloatValue(b) orelse break :blk null;
            if (std.math.isNan(a_value) or std.math.isNan(b_value)) {
                break :blk if (std.math.isNan(a_value) and
                    std.math.isNan(b_value)) .eq else null;
            }
            break :blk std.math.order(a_value, b_value);
        },
        .date_time,
        .date,
        .time,
        .g_year_month,
        .g_year,
        .g_month_day,
        .g_day,
        .g_month,
        => blk: {
            const date_kind: DateTimeKind = switch (kind) {
                .date_time => .date_time,
                .date => .date,
                .time => .time,
                .g_year_month => .g_year_month,
                .g_year => .g_year,
                .g_month_day => .g_month_day,
                .g_day => .g_day,
                .g_month => .g_month,
                else => unreachable,
            };
            const a_value = parseDateTimeValue(date_kind, a) orelse break :blk null;
            const b_value = parseDateTimeValue(date_kind, b) orelse break :blk null;
            break :blk compareDateTimes(a_value, b_value);
        },
        .duration => blk: {
            const a_value = parseDuration(a) orelse break :blk null;
            const b_value = parseDuration(b) orelse break :blk null;
            break :blk compareDurations(a_value, b_value);
        },
        .hex_binary => blk: {
            if (a.len != b.len) break :blk if (a.len < b.len) .lt else .gt;
            var index: usize = 0;
            while (index < a.len) : (index += 1) {
                const a_byte = std.ascii.toLower(a[index]);
                const b_byte = std.ascii.toLower(b[index]);
                if (a_byte != b_byte) break :blk if (a_byte < b_byte) .lt else .gt;
            }
            break :blk .eq;
        },
        else => std.mem.order(u8, a, b),
    };
}

fn compareDateTimes(a: DateTimeValue, b: DateTimeValue) std.math.Order {
    switch (a.kind) {
        .date_time, .date, .time => {
            if (a.seconds != b.seconds) {
                return if (a.seconds < b.seconds) .lt else .gt;
            }
            if (a.nanos != b.nanos) {
                return if (a.nanos < b.nanos) .lt else .gt;
            }
            return .eq;
        },
        .g_year => {
            if (a.year == b.year) return .eq;
            return if (a.year < b.year) .lt else .gt;
        },
        .g_year_month => {
            const a_months = a.year * 12 + a.month;
            const b_months = b.year * 12 + b.month;
            if (a_months == b_months) return .eq;
            return if (a_months < b_months) .lt else .gt;
        },
        .g_month_day => {
            const a_value = @as(i64, a.month) * 32 + a.day;
            const b_value = @as(i64, b.month) * 32 + b.day;
            if (a_value == b_value) return .eq;
            return if (a_value < b_value) .lt else .gt;
        },
        .g_day => {
            if (a.day == b.day) return .eq;
            return if (a.day < b.day) .lt else .gt;
        },
        .g_month => {
            if (a.month == b.month) return .eq;
            return if (a.month < b.month) .lt else .gt;
        },
    }
}

fn compareDurations(a: DurationValue, b: DurationValue) std.math.Order {
    const a_months = if (a.negative) -a.months else a.months;
    const b_months = if (b.negative) -b.months else b.months;
    if (a_months != b_months) return if (a_months < b_months) .lt else .gt;
    const a_seconds = if (a.negative) -a.seconds else a.seconds;
    const b_seconds = if (b.negative) -b.seconds else b.seconds;
    if (a_seconds != b_seconds) return if (a_seconds < b_seconds) .lt else .gt;
    if (a.nanos == b.nanos) return .eq;
    return if (a.nanos < b.nanos) .lt else .gt;
}

const testing = std.testing;

test "XSD built-in whitespace rules" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try testing.expectEqualStrings("a b", try normalize(
        allocator,
        .collapse,
        "  a \t b  ",
    ));
    try testing.expectEqualStrings("a b", try normalize(
        allocator,
        .replace,
        "a\tb",
    ));
    try testing.expectEqualStrings("a\tb", try normalize(
        allocator,
        .preserve,
        "a\tb",
    ));
}

test "XSD lexical validation for common types" {
    try testing.expect(validateLexical(.boolean, "true"));
    try testing.expect(validateLexical(.boolean, "0"));
    try testing.expect(!validateLexical(.boolean, "yes"));
    try testing.expect(validateLexical(.decimal, "-12.50"));
    try testing.expect(validateLexical(.decimal, ".5"));
    try testing.expect(!validateLexical(.decimal, "1e3"));
    try testing.expect(validateLexical(.integer, "-42"));
    try testing.expect(!validateLexical(.integer, "4.2"));
    try testing.expect(validateLexical(.byte, "127"));
    try testing.expect(!validateLexical(.byte, "128"));
    try testing.expect(validateLexical(.unsigned_byte, "255"));
    try testing.expect(!validateLexical(.unsigned_byte, "-1"));
    try testing.expect(validateLexical(.positive_integer, "1"));
    try testing.expect(!validateLexical(.positive_integer, "0"));
    try testing.expect(validateLexical(.float, "1.5e3"));
    try testing.expect(validateLexical(.float, "INF"));
    try testing.expect(!validateLexical(.float, "1e"));
    try testing.expect(validateLexical(.language, "en-US"));
    try testing.expect(!validateLexical(.language, "en--US"));
    try testing.expect(validateLexical(.qname, "p:item"));
    try testing.expect(!validateLexical(.qname, "a:b:c"));
    try testing.expect(validateLexical(.hex_binary, "0aFF"));
    try testing.expect(!validateLexical(.hex_binary, "0aF"));
    try testing.expect(validateLexical(.base64_binary, "aGVsbG8="));
    try testing.expect(!validateLexical(.base64_binary, "aGVsbG8"));
}

test "XSD date and duration lexical validation" {
    try testing.expect(validateLexical(.date_time, "2024-02-29T12:30:00Z"));
    try testing.expect(!validateLexical(.date_time, "2023-02-29T12:30:00Z"));
    try testing.expect(validateLexical(.date, "2024-12-31"));
    try testing.expect(!validateLexical(.date, "2024-13-01"));
    try testing.expect(validateLexical(.time, "23:59:59.999"));
    try testing.expect(!validateLexical(.time, "24:00:01"));
    try testing.expect(validateLexical(.g_year, "2024"));
    try testing.expect(!validateLexical(.g_year, "0000"));
    try testing.expect(validateLexical(.g_month_day, "--02-29"));
    try testing.expect(validateLexical(.g_day, "---15"));
    try testing.expect(validateLexical(.g_month, "--07"));
    try testing.expect(validateLexical(.duration, "P1Y2M3DT4H5M6.5S"));
    try testing.expect(validateLexical(.duration, "-P1D"));
    try testing.expect(!validateLexical(.duration, "P"));
    try testing.expect(!validateLexical(.duration, "PT"));
}

test "XSD facets constrain values" {
    const enum_values = [_][]const u8{ "red", "green", "blue" };
    var facets: Facets = .{ .enumeration = &enum_values };
    try testing.expect(try validate(testing.allocator, .token, facets, "green"));
    try testing.expect(!try validate(testing.allocator, .token, facets, "black"));

    facets = .{ .min_inclusive = "1", .max_inclusive = "10" };
    try testing.expect(try validate(testing.allocator, .integer, facets, "5"));
    try testing.expect(!try validate(testing.allocator, .integer, facets, "11"));
    try testing.expect(!try validate(testing.allocator, .integer, facets, "0"));

    facets = .{ .length = 3 };
    try testing.expect(try validate(testing.allocator, .string, facets, "abc"));
    try testing.expect(!try validate(testing.allocator, .string, facets, "abcd"));

    facets = .{ .total_digits = 3, .fraction_digits = 1 };
    try testing.expect(try validate(testing.allocator, .decimal, facets, "12.3"));
    try testing.expect(!try validate(testing.allocator, .decimal, facets, "123.4"));
    try testing.expect(!try validate(testing.allocator, .decimal, facets, "1.23"));
}

test "XSD pattern facets" {
    var pattern = try regex.compile(testing.allocator, "[A-Z]{2}[0-9]{3}");
    defer pattern.deinit();
    const patterns = [_]*const regex.Regex{&pattern};
    const facets: Facets = .{ .patterns = &patterns };
    try testing.expect(try validate(testing.allocator, .token, facets, "AB123"));
    try testing.expect(!try validate(testing.allocator, .token, facets, "ab123"));
    try testing.expect(!try validate(testing.allocator, .token, facets, "AB12"));
}
