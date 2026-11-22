//! Pure helpers for the EXSLT functions evaluated by the XPath engine.

const std = @import("std");

/// Replace every non-overlapping occurrence of `search` with `replacement`.
/// An empty search leaves the input unchanged.
pub fn replaceAll(
    allocator: std.mem.Allocator,
    text: []const u8,
    search: []const u8,
    replacement: []const u8,
) ![]const u8 {
    if (search.len == 0) return allocator.dupe(u8, text);
    var out: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < text.len) {
        if (std.mem.startsWith(u8, text[index..], search)) {
            try out.appendSlice(allocator, replacement);
            index += search.len;
        } else {
            try out.append(allocator, text[index]);
            index += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

const Date = struct {
    year: i64,
    month: u32,
    day: u32,
    year_month_only: bool,
};

const Duration = struct {
    years: i64 = 0,
    months: i64 = 0,
    days: i64 = 0,
};

fn parseUnsigned(comptime T: type, text: []const u8) ?T {
    if (text.len == 0) return null;
    return std.fmt.parseUnsigned(T, text, 10) catch null;
}

fn isLeapYear(year: i64) bool {
    return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or
        @mod(year, 400) == 0;
}

fn daysInMonth(year: i64, month: u32) u32 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

fn parseDate(text: []const u8) ?Date {
    if (text.len != 7 and text.len != 10) return null;
    if (text[4] != '-') return null;
    const year = parseUnsigned(i64, text[0..4]) orelse return null;
    const month = parseUnsigned(u32, text[5..7]) orelse return null;
    if (month < 1 or month > 12) return null;
    var day: u32 = 1;
    if (text.len == 10) {
        if (text[7] != '-') return null;
        day = parseUnsigned(u32, text[8..10]) orelse return null;
        if (day < 1 or day > daysInMonth(year, month)) return null;
    }
    return .{
        .year = year,
        .month = month,
        .day = day,
        .year_month_only = text.len == 7,
    };
}

fn parseDuration(text: []const u8) ?Duration {
    var index: usize = 0;
    var sign: i64 = 1;
    if (index < text.len and (text[index] == '-' or text[index] == '+')) {
        if (text[index] == '-') sign = -1;
        index += 1;
    }
    if (index >= text.len or text[index] != 'P') return null;
    index += 1;
    var duration: Duration = .{};
    var saw_field = false;
    while (index < text.len) {
        if (text[index] == 'T') return null; // time components unsupported
        const start = index;
        while (index < text.len and std.ascii.isDigit(text[index])) {
            index += 1;
        }
        if (index == start or index >= text.len) return null;
        const value = parseUnsigned(i64, text[start..index]) orelse return null;
        switch (text[index]) {
            'Y' => duration.years = value,
            'M' => duration.months = value,
            'D' => duration.days = value,
            else => return null,
        }
        saw_field = true;
        index += 1;
    }
    if (!saw_field) return null;
    return .{
        .years = duration.years * sign,
        .months = duration.months * sign,
        .days = duration.days * sign,
    };
}

fn daysFromCivil(year: i64, month: u32, day: u32) i64 {
    var adjusted_year = year;
    if (month <= 2) adjusted_year -= 1;
    const era = @divFloor(adjusted_year, 400);
    const year_of_era = adjusted_year - era * 400;
    const shifted_month: i64 = if (month > 2) month - 3 else month + 9;
    const day_of_year = @divFloor(153 * shifted_month + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

const Civil = struct { year: i64, month: u32, day: u32 };

fn civilFromDays(days: i64) Civil {
    const shifted = days + 719468;
    const era = @divFloor(shifted, 146097);
    const day_of_era = shifted - era * 146097;
    const year_of_era = @divFloor(
        day_of_era - @divFloor(day_of_era, 1460) +
            @divFloor(day_of_era, 36524) -
            @divFloor(day_of_era, 146096),
        365,
    );
    const year = year_of_era + era * 400;
    const day_of_year = day_of_era - (365 * year_of_era +
        @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100));
    const shifted_month = @divFloor(5 * day_of_year + 2, 153);
    const day = day_of_year - @divFloor(153 * shifted_month + 2, 5) + 1;
    const month: u32 = if (shifted_month < 10)
        @intCast(shifted_month + 3)
    else
        @intCast(shifted_month - 9);
    return .{
        .year = if (month <= 2) year + 1 else year,
        .month = month,
        .day = @intCast(day),
    };
}

/// EXSLT `date:add(date, duration)` for date and year-month values with
/// year/month/day durations. Returns an empty string for unsupported forms.
pub fn dateAdd(
    allocator: std.mem.Allocator,
    date_text: []const u8,
    duration_text: []const u8,
) ![]const u8 {
    const date = parseDate(date_text) orelse return "";
    const duration = parseDuration(duration_text) orelse return "";
    const total_months = date.year * 12 + @as(i64, date.month) - 1 +
        duration.years * 12 + duration.months;
    const year = @divFloor(total_months, 12);
    const month: u32 = @intCast(@mod(total_months, 12) + 1);
    var day = date.day;
    const month_days = daysInMonth(year, month);
    if (day > month_days) day = month_days;
    const result_days = daysFromCivil(year, month, day) + duration.days;
    const civil = civilFromDays(result_days);
    var buffer: [32]u8 = undefined;
    var year_buffer: [16]u8 = undefined;
    const year_text = if (civil.year >= 0)
        std.fmt.bufPrint(&year_buffer, "{d:0>4}", .{
            @as(u64, @intCast(civil.year)),
        }) catch return error.OutOfMemory
    else
        std.fmt.bufPrint(&year_buffer, "{d}", .{civil.year}) catch
            return error.OutOfMemory;
    const formatted = if (date.year_month_only and civil.day == 1)
        std.fmt.bufPrint(&buffer, "{s}-{d:0>2}", .{
            year_text,
            civil.month,
        }) catch return error.OutOfMemory
    else
        std.fmt.bufPrint(&buffer, "{s}-{d:0>2}-{d:0>2}", .{
            year_text,
            civil.month,
            civil.day,
        }) catch return error.OutOfMemory;
    return allocator.dupe(u8, formatted);
}

const testing = std.testing;

test "EXSLT date:add handles year-month and full dates" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try testing.expectEqualStrings(
        "2001-01-04",
        try dateAdd(allocator, "2001-01", "P3D"),
    );
    try testing.expectEqualStrings(
        "2001-12-31",
        try dateAdd(allocator, "2001-12", "P30D"),
    );
    try testing.expectEqualStrings(
        "2002-01",
        try dateAdd(allocator, "2001-12", "P31D"),
    );
    try testing.expectEqualStrings(
        "2002-01-02",
        try dateAdd(allocator, "2001-12", "P32D"),
    );
    try testing.expectEqualStrings(
        "2000-03-01",
        try dateAdd(allocator, "2000-02-29", "P1D"),
    );
    try testing.expectEqualStrings(
        "",
        try dateAdd(allocator, "not-a-date", "P1D"),
    );
}

test "EXSLT str:replace replaces every occurrence" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try testing.expectEqualStrings(
        "_",
        try replaceAll(allocator, "__", "__", "_"),
    );
    try testing.expectEqualStrings(
        "a-b-c",
        try replaceAll(allocator, "a b c", " ", "-"),
    );
    try testing.expectEqualStrings(
        "abc",
        try replaceAll(allocator, "abc", "", "x"),
    );
}

fn isDelimiter(codepoint: u21, delimiters: []const u8) bool {
    var index: usize = 0;
    while (index < delimiters.len) {
        const length = std.unicode.utf8ByteSequenceLength(
            delimiters[index],
        ) catch 1;
        if (index + length > delimiters.len) return false;
        const candidate = std.unicode.utf8Decode(
            delimiters[index..][0..length],
        ) catch 0;
        if (candidate == codepoint) return true;
        index += length;
    }
    return false;
}

fn asciiCaseEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

/// EXSLT `str:tokenize`: split on any delimiter character.
pub fn tokenize(
    allocator: std.mem.Allocator,
    text: []const u8,
    delimiters: []const u8,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (delimiters.len == 0) {
        var index: usize = 0;
        while (index < text.len) {
            const length = std.unicode.utf8ByteSequenceLength(
                text[index],
            ) catch 1;
            const end = @min(index + length, text.len);
            try out.append(
                allocator,
                try allocator.dupe(u8, text[index..end]),
            );
            index = end;
        }
        return out.toOwnedSlice(allocator);
    }
    var token_start: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(
            text[index],
        ) catch 1;
        const end = @min(index + length, text.len);
        const codepoint = std.unicode.utf8Decode(text[index..end]) catch 0;
        if (isDelimiter(codepoint, delimiters)) {
            if (index > token_start) {
                try out.append(
                    allocator,
                    try allocator.dupe(u8, text[token_start..index]),
                );
            }
            token_start = end;
        }
        index = end;
    }
    if (token_start < text.len) {
        try out.append(
            allocator,
            try allocator.dupe(u8, text[token_start..]),
        );
    }
    return out.toOwnedSlice(allocator);
}

/// EXSLT `str:split`: split on an exact (case-insensitive) delimiter string.
pub fn split(
    allocator: std.mem.Allocator,
    text: []const u8,
    delimiter: []const u8,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (delimiter.len == 0) {
        var index: usize = 0;
        while (index < text.len) {
            const length = std.unicode.utf8ByteSequenceLength(
                text[index],
            ) catch 1;
            const end = @min(index + length, text.len);
            try out.append(
                allocator,
                try allocator.dupe(u8, text[index..end]),
            );
            index = end;
        }
        return out.toOwnedSlice(allocator);
    }
    var token_start: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        if (index + delimiter.len <= text.len and
            asciiCaseEqual(text[index..][0..delimiter.len], delimiter))
        {
            if (index > token_start) {
                try out.append(
                    allocator,
                    try allocator.dupe(u8, text[token_start..index]),
                );
            }
            index += delimiter.len;
            token_start = index;
            continue;
        }
        const length = std.unicode.utf8ByteSequenceLength(
            text[index],
        ) catch 1;
        index = @min(index + length, text.len);
    }
    if (token_start < text.len) {
        try out.append(
            allocator,
            try allocator.dupe(u8, text[token_start..]),
        );
    }
    return out.toOwnedSlice(allocator);
}

fn codepointLength(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

/// Byte offset of the `count`-th codepoint.
fn codepointOffset(text: []const u8, count: usize) usize {
    var index: usize = 0;
    var seen: usize = 0;
    while (index < text.len and seen < count) {
        const length = std.unicode.utf8ByteSequenceLength(
            text[index],
        ) catch 1;
        index = @min(index + length, text.len);
        seen += 1;
    }
    return index;
}

/// EXSLT `str:padding`: repeat `pattern` to exactly `length` codepoints.
pub fn padding(
    allocator: std.mem.Allocator,
    length: f64,
    pattern: []const u8,
) ![]const u8 {
    var wanted: usize = 0;
    if (!std.math.isNan(length) and length > 0) {
        wanted = @intFromFloat(@min(length, 100000.0));
    }
    if (wanted == 0) return "";
    var effective = pattern;
    if (effective.len == 0) effective = " ";
    var out: std.ArrayList(u8) = .empty;
    var produced: usize = 0;
    while (produced < wanted) {
        const remaining = wanted - produced;
        const available = codepointLength(effective);
        if (available <= remaining) {
            try out.appendSlice(allocator, effective);
            produced += available;
        } else {
            const end = codepointOffset(effective, remaining);
            try out.appendSlice(allocator, effective[0..end]);
            produced = wanted;
        }
    }
    return out.toOwnedSlice(allocator);
}

/// EXSLT `str:align`: align `text` within `padding`.
pub fn alignString(
    allocator: std.mem.Allocator,
    text: []const u8,
    pad: []const u8,
    alignment: []const u8,
) ![]const u8 {
    const text_length = codepointLength(text);
    const pad_length = codepointLength(pad);
    if (text_length == pad_length) return allocator.dupe(u8, text);
    if (text_length > pad_length) {
        return allocator.dupe(
            u8,
            text[0..codepointOffset(text, pad_length)],
        );
    }
    var out: std.ArrayList(u8) = .empty;
    if (std.mem.eql(u8, alignment, "right")) {
        try out.appendSlice(
            allocator,
            pad[0..codepointOffset(pad, pad_length - text_length)],
        );
        try out.appendSlice(allocator, text);
    } else if (std.mem.eql(u8, alignment, "center")) {
        const left = (pad_length - text_length) / 2;
        try out.appendSlice(allocator, pad[0..codepointOffset(pad, left)]);
        try out.appendSlice(allocator, text);
        try out.appendSlice(
            allocator,
            pad[codepointOffset(pad, left + text_length)..],
        );
    } else {
        try out.appendSlice(allocator, text);
        try out.appendSlice(
            allocator,
            pad[codepointOffset(pad, text_length)..],
        );
    }
    return out.toOwnedSlice(allocator);
}

/// EXSLT `str:encode-uri`.
pub fn encodeUri(
    allocator: std.mem.Allocator,
    text: []const u8,
    escape_reserved: bool,
) ![]const u8 {
    if (text.len == 0) return "";
    const hex = "0123456789ABCDEF";
    var out: std.ArrayList(u8) = .empty;
    for (text) |byte| {
        const unreserved = std.ascii.isAlphanumeric(byte) or
            std.mem.indexOfScalar(u8, "-_.!~*'()", byte) != null;
        const reserved = std.mem.indexOfScalar(
            u8,
            ";/?:@&=+$,[]",
            byte,
        ) != null;
        // libxml2's xmlURIEscapeStr always leaves '@' alone, even when
        // every reserved character is escaped.
        if (unreserved or byte == '@' or
            (!escape_reserved and reserved))
        {
            try out.append(allocator, byte);
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hex[byte >> 4]);
            try out.append(allocator, hex[byte & 0x0F]);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn hexValue(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

/// EXSLT `str:decode-uri`; invalid UTF-8 yields an empty string.
pub fn decodeUri(
    allocator: std.mem.Allocator,
    text: []const u8,
) ![]const u8 {
    if (text.len == 0) return "";
    var out: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == '%' and index + 2 < text.len) {
            const high = hexValue(text[index + 1]);
            const low = hexValue(text[index + 2]);
            if (high != null and low != null) {
                try out.append(allocator, high.? << 4 | low.?);
                index += 3;
                continue;
            }
        }
        try out.append(allocator, text[index]);
        index += 1;
    }
    const decoded = try out.toOwnedSlice(allocator);
    if (!std.unicode.utf8ValidateSlice(decoded)) return "";
    return decoded;
}

/// EXSLT `str:replace` over parallel search/replacement lists.
pub fn replaceNodes(
    allocator: std.mem.Allocator,
    text: []const u8,
    search: []const []const u8,
    replacement: []const ?[]const u8,
) ![]const u8 {
    if (search.len == 0) return allocator.dupe(u8, text);
    var empty_index: ?usize = null;
    for (search, 0..) |needle, index| {
        if (needle.len != 0) continue;
        if (index < replacement.len) {
            if (replacement[index]) |value| {
                if (value.len != 0) {
                    empty_index = index;
                    break;
                }
            }
        }
    }
    var out: std.ArrayList(u8) = .empty;
    var start: usize = 0;
    var src: usize = 0;
    while (src < text.len) {
        var match_index: ?usize = null;
        var match_length: usize = 0;
        for (search, 0..) |needle, index| {
            if (needle.len == 0 or needle.len <= match_length) continue;
            if (src + needle.len > text.len) continue;
            if (!std.mem.eql(u8, text[src..][0..needle.len], needle)) {
                continue;
            }
            match_index = index;
            match_length = needle.len;
        }
        if (match_index) |index| {
            try out.appendSlice(allocator, text[start..src]);
            if (index < replacement.len) {
                if (replacement[index]) |value| {
                    try out.appendSlice(allocator, value);
                }
            }
            src += match_length;
            start = src;
            continue;
        }
        if (empty_index) |index| {
            if (start < src) {
                try out.appendSlice(allocator, text[start..src]);
                if (replacement[index]) |value| {
                    try out.appendSlice(allocator, value);
                }
                start = src;
            }
        }
        const length = std.unicode.utf8ByteSequenceLength(text[src]) catch 1;
        src = @min(src + length, text.len);
    }
    try out.appendSlice(allocator, text[start..]);
    return out.toOwnedSlice(allocator);
}

test "EXSLT tokenize split padding and align" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tokens = try tokenize(allocator, "2001-06-03T11", "-T:");
    try testing.expectEqual(4, tokens.len);
    try testing.expectEqualStrings("2001", tokens[0]);
    try testing.expectEqualStrings("11", tokens[3]);
    const split_tokens = try split(allocator, "a, simple, list", ", ");
    try testing.expectEqual(3, split_tokens.len);
    try testing.expectEqualStrings("simple", split_tokens[1]);
    try testing.expectEqualStrings(
        "abcabcabca",
        try padding(allocator, 10, "abc"),
    );
    try testing.expectEqualStrings(
        "  hi  ",
        try alignString(allocator, "hi", "      ", "center"),
    );
    try testing.expectEqualStrings(
        "    hi",
        try alignString(allocator, "hi", "      ", "right"),
    );
    try testing.expectEqualStrings(
        "hi    ",
        try alignString(allocator, "hi", "      ", ""),
    );
}

test "EXSLT URI escaping and replacement" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try testing.expectEqualStrings(
        "%3B%2F%3F",
        try encodeUri(allocator, ";/?", true),
    );
    try testing.expectEqualStrings(
        "@",
        try encodeUri(allocator, "@", true),
    );
    try testing.expectEqualStrings(
        ";/?",
        try encodeUri(allocator, ";/?", false),
    );
    try testing.expectEqualStrings(
        "%F0%9F%91%8C",
        try encodeUri(allocator, "\u{1F44C}", true),
    );
    try testing.expectEqualStrings(
        "\u{1F44C}",
        try decodeUri(allocator, "%F0%9F%91%8C"),
    );
    const search = [_][]const u8{ "fee", "fi", "fo", "fum" };
    const replacement = [_]?[]const u8{ "tee", "eye", "billow", "a longer string" };
    try testing.expectEqualStrings(
        "tee, eye, billow, a longer string",
        try replaceNodes(allocator, "fee, fi, fo, fum", &search, &replacement),
    );
    const empty_search = [_][]const u8{""};
    const empty_replace = [_]?[]const u8{"baz"};
    try testing.expectEqualStrings(
        "fbazobazo",
        try replaceNodes(allocator, "foo", &empty_search, &empty_replace),
    );
}
