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
