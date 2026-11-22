//! EXSLT dates-and-times helpers, matching libexslt's `date.c` semantics.
//!
//! Dates use libexslt's continuous internal year representation: year 0 does
//! not exist, so "-0005" is stored as -4 and reported as -5.

const std = @import("std");

pub const DateType = enum(u8) {
    unknown = 0,
    time = 1,
    gday = 2,
    gmonth = 4,
    gmonthday = 6,
    gyear = 8,
    gyearmonth = 12,
    date = 14,
    datetime = 15,
};

const bit_time: u8 = 1;
const bit_gday: u8 = 2;
const bit_gmonth: u8 = 4;
const bit_gyear: u8 = 8;

pub const DateValue = struct {
    kind: DateType = .unknown,
    year: i64 = 0,
    mon: u32 = 1,
    day: u32 = 1,
    hour: u32 = 0,
    min: u32 = 0,
    sec: f64 = 0,
    tz_flag: bool = false,
    /// Timezone offset in minutes.
    tzo: i32 = 0,
};

pub const Duration = struct {
    /// Years and months combined as `years * 12 + months`.
    mon: i64 = 0,
    day: i64 = 0,
    /// Seconds within a day; negative durations store the complement with a
    /// negative day, exactly like libexslt.
    sec: f64 = 0,
};

pub const Value = union(enum) {
    string: []const u8,
    number: f64,
    boolean: bool,
};

const secs_per_min = 60;
const secs_per_hour = 3600;
const secs_per_day = 86400;

fn isLeap(year: i64) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

fn daysInMonth(year: i64, mon: u32) u32 {
    return switch (mon) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeap(year)) 29 else 28,
        else => 0,
    };
}

fn dayInYear(day: u32, mon: u32, year: i64) i64 {
    const offsets = [_]i64{ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 };
    const leap_offsets = [_]i64{ 0, 31, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335 };
    const table = if (isLeap(year)) leap_offsets else offsets;
    if (mon < 1 or mon > 12) return 0;
    return table[mon - 1] + @as(i64, day);
}

/// Day of week with Sunday = 0, matching libexslt.
fn dayOfWeek(yday: i64, year: i64) i64 {
    if (year <= 0) {
        var result = @mod(
            @mod(year, 7) - 2 +
                (@divTrunc(year, 4) - @divTrunc(year, 100) +
                    @divTrunc(year, 400)) + yday,
            7,
        );
        if (result < 0) result += 7;
        return result;
    }
    return @mod(
        @mod(year, 7) - 1 +
            (@divTrunc(year - 1, 4) - @divTrunc(year - 1, 100) +
                @divTrunc(year - 1, 400)) + yday,
        7,
    );
}

/// Days from the continuous internal year/month to a comparable day count.
fn castYmToDays(dt: DateValue) i64 {
    if (dt.year <= 0) {
        return (dt.year - 1) * 365 +
            (@divTrunc(dt.year, 4) - @divTrunc(dt.year, 100) +
                @divTrunc(dt.year, 400)) +
            dayInYear(0, dt.mon, dt.year) - 1;
    }
    return (dt.year - 1) * 365 +
        (@divTrunc(dt.year - 1, 4) - @divTrunc(dt.year - 1, 100) +
            @divTrunc(dt.year - 1, 400)) +
        dayInYear(0, dt.mon, dt.year);
}

fn timeToNumber(dt: DateValue) f64 {
    return @as(f64, @floatFromInt(dt.hour * secs_per_hour +
        dt.min * secs_per_min)) + dt.sec;
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

const ParseYear = union(enum) {
    ok: struct { year: i64, end: usize },
    invalid,
    zero,
};

fn parseYear(text: []const u8, start: usize) ParseYear {
    var index = start;
    var negative = false;
    if (index < text.len and (text[index] == '-' or text[index] == '+')) {
        negative = text[index] == '-';
        index += 1;
    }
    const first = index;
    var value: i64 = 0;
    while (index < text.len and std.ascii.isDigit(text[index])) {
        value = value * 10 + (text[index] - '0');
        if (value > std.math.maxInt(i64) / 16) return .invalid;
        index += 1;
    }
    const digits = index - first;
    if (digits < 4) return .invalid;
    if (digits > 4 and text[first] == '0') return .invalid;
    if (value == 0) return .zero;
    return .{ .ok = .{
        .year = if (negative) -value + 1 else value,
        .end = index,
    } };
}

fn parseTwoDigits(
    text: []const u8,
    index: *usize,
    validate: fn (u32) bool,
) ?u32 {
    if (index.* + 2 > text.len) return null;
    const a = text[index.*];
    const b = text[index.* + 1];
    if (!std.ascii.isDigit(a) or !std.ascii.isDigit(b)) return null;
    const value: u32 = (a - '0') * 10 + (b - '0');
    if (!validate(value)) return null;
    index.* += 2;
    return value;
}

fn validMonth(value: u32) bool {
    return value >= 1 and value <= 12;
}

fn validDay(value: u32) bool {
    return value >= 1 and value <= 31;
}

fn validHour(value: u32) bool {
    return value <= 23;
}

fn validMinute(value: u32) bool {
    return value <= 59;
}

fn parseTime(text: []const u8, start: usize) ?struct { hour: u32, min: u32, sec: f64, end: usize } {
    var index = start;
    const hour = parseTwoDigits(text, &index, validHour) orelse return null;
    if (index >= text.len or text[index] != ':') return null;
    index += 1;
    const min = parseTwoDigits(text, &index, validMinute) orelse return null;
    if (index >= text.len or text[index] != ':') return null;
    index += 1;
    if (index + 2 > text.len) return null;
    if (!std.ascii.isDigit(text[index]) or !std.ascii.isDigit(text[index + 1])) {
        return null;
    }
    var sec: f64 = @floatFromInt((text[index] - '0') * 10 + (text[index + 1] - '0'));
    index += 2;
    if (index < text.len and text[index] == '.') {
        index += 1;
        if (index >= text.len or !std.ascii.isDigit(text[index])) return null;
        var mult: f64 = 1;
        while (index < text.len and std.ascii.isDigit(text[index])) {
            mult /= 10;
            sec += @as(f64, @floatFromInt(text[index] - '0')) * mult;
            index += 1;
        }
    }
    if (!(sec < 60)) return null;
    return .{ .hour = hour, .min = min, .sec = sec, .end = index };
}

fn parseTimeZone(dt: *DateValue, text: []const u8, start: usize) ?usize {
    if (start >= text.len) {
        dt.tz_flag = false;
        dt.tzo = 0;
        return start;
    }
    switch (text[start]) {
        'Z' => {
            dt.tz_flag = true;
            dt.tzo = 0;
            return start + 1;
        },
        '+', '-' => {
            const negative = text[start] == '-';
            var index = start + 1;
            const hours = parseTwoDigits(text, &index, validHour) orelse return null;
            if (index >= text.len or text[index] != ':') return null;
            index += 1;
            const minutes = parseTwoDigits(text, &index, validMinute) orelse return null;
            var offset: i32 = @intCast(hours * 60 + minutes);
            if (negative) offset = -offset;
            if (offset <= -1440 or offset >= 1440) return null;
            dt.tz_flag = true;
            dt.tzo = offset;
            return index;
        },
        else => return null,
    }
}

/// Attempt to read a trailing timezone. Returns null when the text at
/// `index` is not a timezone (for example the '-' before a month), so date
/// parsing can continue.
fn tryTimeZone(dt: *DateValue, text: []const u8, index: usize) ?usize {
    if (index < text.len and text[index] != 'Z' and
        text[index] != '+' and text[index] != '-')
    {
        return null;
    }
    return parseTimeZone(dt, text, index);
}

pub fn parse(text: []const u8) ?DateValue {
    var dt: DateValue = .{};
    if (text.len >= 2 and text[0] == '-' and text[1] == '-') {
        var index: usize = 2;
        if (index < text.len and text[index] == '-') {
            index += 1;
            dt.day = parseTwoDigits(text, &index, validDay) orelse return null;
            const end = parseTimeZone(&dt, text, index) orelse return null;
            if (end != text.len) return null;
            dt.kind = .gday;
            return dt;
        }
        dt.mon = parseTwoDigits(text, &index, validMonth) orelse return null;
        if (index >= text.len or text[index] != '-') return null;
        index += 1;
        if (index < text.len and text[index] == '-') {
            index += 1;
            const end = parseTimeZone(&dt, text, index) orelse return null;
            if (end != text.len) return null;
            dt.kind = .gmonth;
            return dt;
        }
        dt.day = parseTwoDigits(text, &index, validDay) orelse return null;
        const end = parseTimeZone(&dt, text, index) orelse return null;
        if (end != text.len) return null;
        dt.kind = .gmonthday;
        return dt;
    }

    if (text.len != 0 and std.ascii.isDigit(text[0])) {
        if (parseTime(text, 0)) |parsed| {
            var candidate = dt;
            candidate.hour = parsed.hour;
            candidate.min = parsed.min;
            candidate.sec = parsed.sec;
            const end = parseTimeZone(&candidate, text, parsed.end) orelse null;
            if (end) |tz_end| {
                if (tz_end == text.len) {
                    candidate.kind = .time;
                    return candidate;
                }
            }
        }
    }

    const parsed_year = parseYear(text, 0);
    const year = switch (parsed_year) {
        .ok => |value| value,
        else => return null,
    };
    dt.year = year.year;
    var index = year.end;
    if (tryTimeZone(&dt, text, index)) |end| {
        if (end != text.len) return null;
        dt.kind = .gyear;
        return dt;
    }
    if (index >= text.len or text[index] != '-') return null;
    index += 1;
    dt.mon = parseTwoDigits(text, &index, validMonth) orelse return null;
    if (tryTimeZone(&dt, text, index)) |end| {
        if (end != text.len) return null;
        dt.kind = .gyearmonth;
        return dt;
    }
    if (index >= text.len or text[index] != '-') return null;
    index += 1;
    dt.day = parseTwoDigits(text, &index, validDay) orelse return null;
    if (dt.day > daysInMonth(dt.year, dt.mon)) return null;
    if (tryTimeZone(&dt, text, index)) |end| {
        if (end != text.len) return null;
        dt.kind = .date;
        return dt;
    }
    if (index >= text.len or text[index] != 'T') return null;
    index += 1;
    const time = parseTime(text, index) orelse return null;
    dt.hour = time.hour;
    dt.min = time.min;
    dt.sec = time.sec;
    const end = parseTimeZone(&dt, text, time.end) orelse return null;
    if (end != text.len) return null;
    dt.kind = .datetime;
    return dt;
}

pub fn parseDuration(text: []const u8) ?Duration {
    var index: usize = 0;
    var negative = false;
    if (index < text.len and text[index] == '-') {
        negative = true;
        index += 1;
    }
    if (index >= text.len or text[index] != 'P') return null;
    index += 1;
    if (index >= text.len) return null;

    var duration: Duration = .{};
    var seq: usize = 0;
    var seconds: i64 = 0;
    var seconds_frac: f64 = 0;
    while (index < text.len) {
        if (seq >= 6) return null;
        if (text[index] == 'T') {
            if (seq > 3) return null;
            index += 1;
            seq = 3;
        } else if (seq == 3) {
            return null;
        }
        var number: i64 = 0;
        var has_digits = false;
        while (index < text.len and std.ascii.isDigit(text[index])) {
            number = number * 10 + (text[index] - '0');
            if (number > std.math.maxInt(i64) / 16) return null;
            has_digits = true;
            index += 1;
        }
        var has_frac = false;
        if (index < text.len and text[index] == '.') {
            index += 1;
            has_frac = true;
            var mult: f64 = 1;
            while (index < text.len and std.ascii.isDigit(text[index])) {
                mult /= 10;
                seconds_frac += @as(f64, @floatFromInt(text[index] - '0')) * mult;
                has_digits = true;
                index += 1;
            }
        }
        const designators = "YMDHMS";
        while (index >= text.len or text[index] != designators[seq]) {
            seq += 1;
            if (seq == 3 or seq >= 6) return null;
        }
        index += 1;
        if (!has_digits or (has_frac and seq != 5)) return null;
        switch (seq) {
            0 => duration.mon = number * 12,
            1 => duration.mon += number,
            2 => duration.day = number,
            3 => {
                duration.day += @divTrunc(number, 24);
                seconds = @mod(number, 24) * secs_per_hour;
            },
            4 => {
                duration.day += @divTrunc(number, 1440);
                seconds += @mod(number, 1440) * secs_per_min;
            },
            5 => {
                duration.day += @divTrunc(number, secs_per_day);
                seconds += @mod(number, secs_per_day);
            },
            else => unreachable,
        }
        seq += 1;
    }
    duration.day += @divTrunc(seconds, secs_per_day);
    duration.sec = @as(f64, @floatFromInt(@mod(seconds, secs_per_day))) +
        seconds_frac;
    if (negative) {
        duration.mon = -duration.mon;
        duration.day = -duration.day;
        if (duration.sec != 0) {
            duration.sec = secs_per_day - duration.sec;
            duration.day -= 1;
        }
    }
    return duration;
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

fn appendLong(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: i64) !void {
    var buffer: [24]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch
        return error.OutOfMemory;
    try out.appendSlice(allocator, text);
}

fn appendTwoDigits(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    try out.append(allocator, '0' + @as(u8, @intCast(value / 10 % 10)));
    try out.append(allocator, '0' + @as(u8, @intCast(value % 10)));
}

fn appendYear(out: *std.ArrayList(u8), allocator: std.mem.Allocator, year: i64) !void {
    if (year <= 0) try out.append(allocator, '-');
    var value: u64 = @intCast(if (year <= 0) -year + 1 else year);
    var buffer: [24]u8 = undefined;
    var length: usize = 0;
    while (value > 0) {
        buffer[length] = '0' + @as(u8, @intCast(value % 10));
        value /= 10;
        length += 1;
    }
    while (length < 4) : (length += 1) buffer[length] = '0';
    while (length > 0) {
        length -= 1;
        try out.append(allocator, buffer[length]);
    }
}

fn appendTimeZone(out: *std.ArrayList(u8), allocator: std.mem.Allocator, tzo: i32) !void {
    if (tzo == 0) {
        try out.append(allocator, 'Z');
        return;
    }
    const magnitude: u32 = @intCast(if (tzo < 0) -tzo else tzo);
    try out.append(allocator, if (tzo < 0) '-' else '+');
    try appendTwoDigits(out, allocator, magnitude / 60);
    try out.append(allocator, ':');
    try appendTwoDigits(out, allocator, magnitude % 60);
}

fn appendTime(out: *std.ArrayList(u8), allocator: std.mem.Allocator, dt: DateValue) !void {
    try appendTwoDigits(out, allocator, dt.hour);
    try out.append(allocator, ':');
    try appendTwoDigits(out, allocator, dt.min);
    try out.append(allocator, ':');
    const whole = std.math.floor(dt.sec);
    var seconds: i64 = @intFromFloat(whole);
    var nanoseconds: i64 = @intFromFloat(std.math.floor(
        (dt.sec - whole) * 1_000_000_000 + 0.5,
    ));
    if (nanoseconds > 999_999_999) nanoseconds = 999_999_999;
    if (seconds < 0) seconds = 0;
    try appendTwoDigits(out, allocator, @intCast(@mod(seconds, 60)));
    if (nanoseconds > 0) {
        try out.append(allocator, '.');
        var p10: i64 = 100_000_000;
        while (nanoseconds > 0) {
            const digit = @divTrunc(nanoseconds, p10);
            try out.append(allocator, '0' + @as(u8, @intCast(digit)));
            nanoseconds -= digit * p10;
            p10 = @divTrunc(p10, 10);
        }
    }
}

fn appendDate(out: *std.ArrayList(u8), allocator: std.mem.Allocator, dt: DateValue) !void {
    try appendYear(out, allocator, dt.year);
    try out.append(allocator, '-');
    try appendTwoDigits(out, allocator, dt.mon);
    try out.append(allocator, '-');
    try appendTwoDigits(out, allocator, dt.day);
}

pub fn formatDate(allocator: std.mem.Allocator, dt: DateValue) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try appendDate(&out, allocator, dt);
    if (dt.tz_flag or dt.tzo != 0) {
        try appendTimeZone(&out, allocator, dt.tzo);
    }
    return out.toOwnedSlice(allocator);
}

pub fn formatTime(allocator: std.mem.Allocator, dt: DateValue) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try appendTime(&out, allocator, dt);
    if (dt.tz_flag or dt.tzo != 0) {
        try appendTimeZone(&out, allocator, dt.tzo);
    }
    return out.toOwnedSlice(allocator);
}

pub fn formatDateTime(allocator: std.mem.Allocator, dt: DateValue) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try appendDate(&out, allocator, dt);
    try out.append(allocator, 'T');
    try appendTime(&out, allocator, dt);
    try appendTimeZone(&out, allocator, dt.tzo);
    return out.toOwnedSlice(allocator);
}

pub fn formatDuration(allocator: std.mem.Allocator, duration: Duration) ![]const u8 {
    if (duration.sec == 0 and duration.day == 0 and duration.mon == 0) {
        return allocator.dupe(u8, "P0D");
    }
    var seconds = duration.sec;
    var days = duration.day;
    var months = duration.mon;
    var negative = false;
    if (days < 0) {
        if (seconds != 0) {
            seconds = secs_per_day - seconds;
            days += 1;
        }
        days = -days;
        negative = true;
    }
    if (months < 0) {
        months = -months;
        negative = true;
    }
    var out: std.ArrayList(u8) = .empty;
    if (negative) try out.append(allocator, '-');
    try out.append(allocator, 'P');
    if (months >= 12) {
        const years = @divTrunc(months, 12);
        months -= years * 12;
        try appendLong(&out, allocator, years);
        try out.append(allocator, 'Y');
    }
    if (months != 0) {
        try appendLong(&out, allocator, months);
        try out.append(allocator, 'M');
    }
    if (days != 0) {
        try appendLong(&out, allocator, days);
        try out.append(allocator, 'D');
    }
    const whole = std.math.floor(seconds);
    var whole_seconds: i64 = @intFromFloat(whole);
    var nanoseconds: i64 = @intFromFloat(std.math.floor(
        (seconds - whole) * 1_000_000_000 + 0.5,
    ));
    if (nanoseconds >= 1_000_000_000) {
        nanoseconds -= 1_000_000_000;
        whole_seconds += 1;
    }
    if (whole_seconds > 0 or nanoseconds > 0) {
        try out.append(allocator, 'T');
        if (whole_seconds >= secs_per_hour) {
            const hours = @divTrunc(whole_seconds, secs_per_hour);
            whole_seconds -= hours * secs_per_hour;
            try appendLong(&out, allocator, hours);
            try out.append(allocator, 'H');
        }
        if (whole_seconds >= secs_per_min) {
            const minutes = @divTrunc(whole_seconds, secs_per_min);
            whole_seconds -= minutes * secs_per_min;
            try appendLong(&out, allocator, minutes);
            try out.append(allocator, 'M');
        }
        if (whole_seconds > 0 or nanoseconds > 0) {
            try appendLong(&out, allocator, whole_seconds);
            if (nanoseconds > 0) {
                try out.append(allocator, '.');
                var p10: i64 = 100_000_000;
                while (nanoseconds > 0) {
                    const digit = @divTrunc(nanoseconds, p10);
                    try out.append(allocator, '0' + @as(u8, @intCast(digit)));
                    nanoseconds -= digit * p10;
                    p10 = @divTrunc(p10, 10);
                }
            }
            try out.append(allocator, 'S');
        }
    }
    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Arithmetic
// ---------------------------------------------------------------------------

fn truncateDate(dt: *DateValue, kind: DateType) void {
    const bits: u8 = @intFromEnum(kind);
    if (bits & bit_time != bit_time) {
        dt.hour = 0;
        dt.min = 0;
        dt.sec = 0;
    }
    if (bits & bit_gday != bit_gday) dt.day = 1;
    if (bits & bit_gmonth != bit_gmonth) dt.mon = 1;
    if (bits & bit_gyear != bit_gyear) dt.year = 0;
    dt.kind = kind;
}

fn addDate(dt: DateValue, duration: Duration) ?DateValue {
    var result: DateValue = .{
        .kind = dt.kind,
        .tzo = dt.tzo,
        .tz_flag = dt.tz_flag,
    };
    var temp: i64 = @as(i64, dt.mon) + @rem(duration.mon, 12);
    var carry: i64 = @divTrunc(duration.mon, 12);
    if (temp < 1) {
        temp += 12;
        carry -= 1;
    } else if (temp > 12) {
        temp -= 12;
        carry += 1;
    }
    result.mon = @intCast(temp);
    carry += @divTrunc(duration.day, 146097) * 400;
    result.year = dt.year + carry;

    const sum = dt.sec + duration.sec;
    result.sec = @mod(sum, 60.0);
    carry = @intFromFloat(std.math.floor(sum / 60.0));
    temp = @as(i64, dt.min) + @mod(carry, 60);
    carry = @divTrunc(carry, 60);
    if (temp >= 60) {
        temp -= 60;
        carry += 1;
    }
    result.min = @intCast(temp);
    temp = @as(i64, dt.hour) + @mod(carry, 24);
    carry = @divTrunc(carry, 24);
    if (temp >= 24) {
        temp -= 24;
        carry += 1;
    }
    result.hour = @intCast(temp);

    var day: i64 = if (dt.day > daysInMonth(result.year, result.mon))
        daysInMonth(result.year, result.mon)
    else if (dt.day < 1)
        1
    else
        dt.day;
    day += @rem(duration.day, 146097) + carry;
    while (true) {
        if (day < 1) {
            if (result.mon > 1) {
                result.mon -= 1;
            } else {
                result.mon = 12;
                result.year -= 1;
            }
            day += daysInMonth(result.year, result.mon);
        } else if (day > daysInMonth(result.year, result.mon)) {
            day -= daysInMonth(result.year, result.mon);
            if (result.mon < 12) {
                result.mon += 1;
            } else {
                result.mon = 1;
                result.year += 1;
            }
        } else break;
    }
    result.day = @intCast(day);

    if (result.kind != .datetime) {
        if (result.hour != 0 or result.min != 0 or result.sec != 0) {
            result.kind = .datetime;
        } else if (result.kind != .date) {
            if (result.day != 1) {
                result.kind = .date;
            } else if (result.kind != .gyearmonth and result.mon != 1) {
                result.kind = .gyearmonth;
            }
        }
    }
    return result;
}

fn difference(x_in: DateValue, y_in: DateValue, force_days: bool) ?Duration {
    const x_bits: u8 = @intFromEnum(x_in.kind);
    if (x_bits < bit_gyear or x_bits > @intFromEnum(DateType.datetime)) {
        return null;
    }
    const y_bits: u8 = @intFromEnum(y_in.kind);
    if (y_bits < bit_gyear or y_bits > @intFromEnum(DateType.datetime)) {
        return null;
    }
    var x = x_in;
    var y = y_in;
    if (x.kind != y.kind) {
        if (x_bits < y_bits) {
            truncateDate(&y, x.kind);
        } else {
            truncateDate(&x, y.kind);
        }
    }
    var result: Duration = .{};
    if ((x.kind == .gyear or x.kind == .gyearmonth) and !force_days) {
        result.mon = (y.year - x.year) * 12 + (@as(i64, y.mon) - x.mon);
        return result;
    }
    var seconds = timeToNumber(y) - timeToNumber(x) +
        @as(f64, @floatFromInt(x.tzo - y.tzo)) * secs_per_min;
    const carry: i64 = @intFromFloat(std.math.floor(seconds / secs_per_day));
    seconds -= @as(f64, @floatFromInt(carry)) * secs_per_day;
    result.sec = seconds;
    result.day = castYmToDays(y) - castYmToDays(x) +
        @as(i64, y.day) - x.day + carry;
    return result;
}

fn addDurations(x: Duration, y: Duration) ?Duration {
    var result: Duration = .{};
    result.mon = x.mon + y.mon;
    result.day = x.day + y.day;
    result.sec = x.sec + y.sec;
    if (result.sec >= secs_per_day) {
        result.sec -= secs_per_day;
        result.day += 1;
    }
    if (result.day >= 0) {
        if ((result.day > 0 or result.sec > 0) and result.mon < 0) return null;
    } else if (result.mon > 0) {
        return null;
    }
    return result;
}

fn secondsOf(dt: DateValue) f64 {
    const epoch: DateValue = .{
        .kind = .datetime,
        .year = 1970,
        .mon = 1,
        .day = 1,
        .tz_flag = true,
    };
    const diff = difference(epoch, dt, true) orelse return std.math.nan(f64);
    return @as(f64, @floatFromInt(diff.day)) * secs_per_day + diff.sec;
}

// ---------------------------------------------------------------------------
// Field accessors
// ---------------------------------------------------------------------------

fn accepts(kind: DateType, allowed: []const DateType) bool {
    for (allowed) |candidate| {
        if (kind == candidate) return true;
    }
    return false;
}

fn dateOrNow(text: ?[]const u8, now: ?[]const u8) ?DateValue {
    if (text) |value| return parse(value);
    if (now) |value| return parse(value);
    return null;
}

pub fn yearOf(dt: DateValue) f64 {
    var year = dt.year;
    if (year <= 0) year -= 1;
    return @floatFromInt(year);
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

const string_fields = struct {
    fn monthName(mon: u32) []const u8 {
        const names = [_][]const u8{
            "",       "January", "February", "March",    "April",
            "May",    "June",    "July",     "August",   "September",
            "October", "November", "December",
        };
        if (mon < 1 or mon > 12) return "";
        return names[mon];
    }

    fn monthAbbreviation(mon: u32) []const u8 {
        const names = [_][]const u8{
            "",    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
            "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
        };
        if (mon < 1 or mon > 12) return "";
        return names[mon];
    }

    fn dayName(index: i64) []const u8 {
        const names = [_][]const u8{
            "Sunday",   "Monday", "Tuesday", "Wednesday",
            "Thursday", "Friday", "Saturday",
        };
        if (index < 0 or index > 6) return "";
        return names[@intCast(index)];
    }

    fn dayAbbreviation(index: i64) []const u8 {
        const names = [_][]const u8{
            "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat",
        };
        if (index < 0 or index > 6) return "";
        return names[@intCast(index)];
    }
};

pub fn call(
    allocator: std.mem.Allocator,
    local: []const u8,
    args: []const []const u8,
    now: ?[]const u8,
) ?Value {
    const text: ?[]const u8 = if (args.len == 0) null else args[0];
    if (std.mem.eql(u8, local, "date-time")) {
        if (args.len != 0) return null;
        const dt = dateOrNow(null, now) orelse return .{ .string = "" };
        return .{ .string = formatDateTime(allocator, dt) catch return null };
    }
    if (std.mem.eql(u8, local, "date")) {
        if (args.len > 1) return null;
        const dt = dateOrNow(text, now) orelse return .{ .string = "" };
        if (!accepts(dt.kind, &.{ .datetime, .date })) {
            return .{ .string = "" };
        }
        return .{ .string = formatDate(allocator, dt) catch return null };
    }
    if (std.mem.eql(u8, local, "time")) {
        if (args.len > 1) return null;
        const dt = dateOrNow(text, now) orelse return .{ .string = "" };
        if (!accepts(dt.kind, &.{ .datetime, .time })) {
            return .{ .string = "" };
        }
        return .{ .string = formatTime(allocator, dt) catch return null };
    }
    if (std.mem.eql(u8, local, "year")) {
        if (args.len > 1) return null;
        const dt = dateOrNow(text, now) orelse
            return .{ .number = std.math.nan(f64) };
        if (!accepts(dt.kind, &.{ .datetime, .date, .gyearmonth, .gyear })) {
            return .{ .number = std.math.nan(f64) };
        }
        return .{ .number = yearOf(dt) };
    }
    if (std.mem.eql(u8, local, "leap-year")) {
        if (args.len > 1) return null;
        const dt = dateOrNow(text, now) orelse
            return .{ .number = std.math.nan(f64) };
        if (!accepts(dt.kind, &.{ .datetime, .date, .gyearmonth, .gyear })) {
            return .{ .number = std.math.nan(f64) };
        }
        return .{ .boolean = isLeap(dt.year) };
    }
    if (std.mem.eql(u8, local, "month-in-year")) {
        if (args.len > 1) return null;
        const dt = dateOrNow(text, now) orelse
            return .{ .number = std.math.nan(f64) };
        if (!accepts(dt.kind, &.{
            .datetime, .date, .gyearmonth, .gmonth, .gmonthday,
        })) return .{ .number = std.math.nan(f64) };
        return .{ .number = @floatFromInt(dt.mon) };
    }
    if (std.mem.eql(u8, local, "month-name") or
        std.mem.eql(u8, local, "month-abbreviation"))
    {
        if (args.len > 1) return null;
        const dt = dateOrNow(text, now) orelse return .{ .string = "" };
        if (!accepts(dt.kind, &.{
            .datetime, .date, .gyearmonth, .gmonth, .gmonthday,
        })) {
            return .{ .string = "" };
        }
        return .{ .string = if (std.mem.eql(u8, local, "month-name"))
            string_fields.monthName(dt.mon)
        else
            string_fields.monthAbbreviation(dt.mon) };
    }
    if (std.mem.eql(u8, local, "week-in-year")) {
        if (args.len > 1) return null;
        const dt = dateOrNow(text, now) orelse
            return .{ .number = std.math.nan(f64) };
        if (!accepts(dt.kind, &.{ .datetime, .date })) {
            return .{ .number = std.math.nan(f64) };
        }
        var diy = dayInYear(dt.day, dt.mon, dt.year);
        const diw = @mod(dayOfWeek(diy, dt.year) + 6, 7);
        diy += 3 - diw;
        if (diy < 1) {
            var previous = dt.year - 1;
            if (previous == 0) previous -= 1;
            diy = dayInYear(31, 12, previous) + diy;
        } else if (diy > dayInYear(31, 12, dt.year)) {
            diy -= dayInYear(31, 12, dt.year);
        }
        return .{ .number = @floatFromInt(@divTrunc(diy - 1, 7) + 1) };
    }
    if (std.mem.eql(u8, local, "week-in-month")) {
        if (args.len > 1) return null;
        const dt = dateOrNow(text, now) orelse
            return .{ .number = std.math.nan(f64) };
        if (!accepts(dt.kind, &.{ .datetime, .date })) {
            return .{ .number = std.math.nan(f64) };
        }
        const first_day = dayInYear(1, dt.mon, dt.year);
        const first_diw = @mod(dayOfWeek(first_day, dt.year) + 6, 7);
        return .{ .number = @floatFromInt(
            @divTrunc(@as(i64, dt.day) + first_diw - 1, 7) + 1,
        ) };
    }
    if (std.mem.eql(u8, local, "day-in-year")) {
        if (args.len > 1) return null;
        const dt = dateOrNow(text, now) orelse
            return .{ .number = std.math.nan(f64) };
        if (!accepts(dt.kind, &.{ .datetime, .date })) {
            return .{ .number = std.math.nan(f64) };
        }
        return .{ .number = @floatFromInt(dayInYear(dt.day, dt.mon, dt.year)) };
    }
    if (std.mem.eql(u8, local, "day-in-month")) {
        if (args.len > 1) return null;
        const dt = dateOrNow(text, now) orelse
            return .{ .number = std.math.nan(f64) };
        if (!accepts(dt.kind, &.{
            .datetime, .date, .gmonthday, .gday,
        })) return .{ .number = std.math.nan(f64) };
        return .{ .number = @floatFromInt(dt.day) };
    }
    if (std.mem.eql(u8, local, "day-of-week-in-month")) {
        if (args.len > 1) return null;
        const dt = dateOrNow(text, now) orelse
            return .{ .number = std.math.nan(f64) };
        if (!accepts(dt.kind, &.{ .datetime, .date })) {
            return .{ .number = std.math.nan(f64) };
        }
        return .{ .number = @floatFromInt(@divTrunc(dt.day - 1, 7) + 1) };
    }
    if (std.mem.eql(u8, local, "day-in-week") or
        std.mem.eql(u8, local, "day-name") or
        std.mem.eql(u8, local, "day-abbreviation"))
    {
        if (args.len > 1) return null;
        const dt = dateOrNow(text, now) orelse
            return if (std.mem.eql(u8, local, "day-in-week"))
                .{ .number = std.math.nan(f64) }
            else
                .{ .string = "" };
        if (!accepts(dt.kind, &.{ .datetime, .date })) {
            return if (std.mem.eql(u8, local, "day-in-week"))
                .{ .number = std.math.nan(f64) }
            else
                .{ .string = "" };
        }
        const index = dayOfWeek(dayInYear(dt.day, dt.mon, dt.year), dt.year);
        if (std.mem.eql(u8, local, "day-in-week")) {
            return .{ .number = @floatFromInt(index + 1) };
        }
        if (std.mem.eql(u8, local, "day-name")) {
            return .{ .string = string_fields.dayName(index) };
        }
        return .{ .string = string_fields.dayAbbreviation(index) };
    }
    if (std.mem.eql(u8, local, "hour-in-day") or
        std.mem.eql(u8, local, "minute-in-hour") or
        std.mem.eql(u8, local, "second-in-minute"))
    {
        if (args.len > 1) return null;
        const dt = dateOrNow(text, now) orelse
            return .{ .number = std.math.nan(f64) };
        if (!accepts(dt.kind, &.{ .datetime, .time })) {
            return .{ .number = std.math.nan(f64) };
        }
        if (std.mem.eql(u8, local, "hour-in-day")) {
            return .{ .number = @floatFromInt(dt.hour) };
        }
        if (std.mem.eql(u8, local, "minute-in-hour")) {
            return .{ .number = @floatFromInt(dt.min) };
        }
        return .{ .number = dt.sec };
    }
    if (std.mem.eql(u8, local, "add")) {
        if (args.len != 2) return null;
        const dt = parse(args[0]) orelse return .{ .string = "" };
        if (!accepts(dt.kind, &.{
            .gyear, .gyearmonth, .date, .datetime,
        })) return .{ .string = "" };
        const duration = parseDuration(args[1]) orelse
            return .{ .string = "" };
        const result = addDate(dt, duration) orelse
            return .{ .string = "" };
        return .{ .string = formatDateOrDateTime(allocator, result) catch
            return null };
    }
    if (std.mem.eql(u8, local, "add-duration")) {
        if (args.len != 2) return null;
        const first = parseDuration(args[0]) orelse
            return .{ .string = "" };
        const second = parseDuration(args[1]) orelse
            return .{ .string = "" };
        const result = addDurations(first, second) orelse
            return .{ .string = "" };
        return .{ .string = formatDuration(allocator, result) catch return null };
    }
    if (std.mem.eql(u8, local, "difference")) {
        if (args.len != 2) return null;
        const first = parse(args[0]) orelse return .{ .string = "" };
        const second = parse(args[1]) orelse return .{ .string = "" };
        const result = difference(first, second, false) orelse
            return .{ .string = "" };
        return .{ .string = formatDuration(allocator, result) catch return null };
    }
    if (std.mem.eql(u8, local, "duration")) {
        if (args.len > 1) return null;
        const seconds = if (text) |value|
            std.fmt.parseFloat(f64, value) catch std.math.nan(f64)
        else if (now) |value|
            secondsOf(parse(value) orelse return .{ .string = "" })
        else
            std.math.nan(f64);
        if (std.math.isNan(seconds) or std.math.isInf(seconds)) {
            return .{ .string = "" };
        }
        const days = std.math.floor(seconds / secs_per_day);
        const long_min: f64 = @floatFromInt(std.math.minInt(i64));
        const long_max: f64 = @floatFromInt(std.math.maxInt(i64));
        if (days <= long_min or days >= long_max) {
            return .{ .string = "" };
        }
        const duration: Duration = .{
            .day = @intFromFloat(days),
            .sec = seconds - days * secs_per_day,
        };
        return .{ .string = formatDuration(allocator, duration) catch return null };
    }
    if (std.mem.eql(u8, local, "seconds")) {
        if (args.len > 1) return null;
        if (text) |value| {
            if (parse(value)) |dt| {
                if (@intFromEnum(dt.kind) >= bit_gyear) {
                    return .{ .number = secondsOf(dt) };
                }
                return .{ .number = std.math.nan(f64) };
            }
            if (parseDuration(value)) |duration| {
                if (duration.mon != 0) {
                    return .{ .number = std.math.nan(f64) };
                }
                return .{ .number = @as(f64, @floatFromInt(duration.day)) *
                    secs_per_day + duration.sec };
            }
            return .{ .number = std.math.nan(f64) };
        }
        if (now) |value| {
            const dt = parse(value) orelse
                return .{ .number = std.math.nan(f64) };
            return .{ .number = secondsOf(dt) };
        }
        return .{ .number = std.math.nan(f64) };
    }
    return null;
}

fn formatDateOrDateTime(allocator: std.mem.Allocator, dt: DateValue) ![]const u8 {
    return switch (dt.kind) {
        .datetime => formatDateTime(allocator, dt),
        .date => formatDate(allocator, dt),
        .gyearmonth => blk: {
            var out: std.ArrayList(u8) = .empty;
            try appendYear(&out, allocator, dt.year);
            try out.append(allocator, '-');
            try appendTwoDigits(&out, allocator, dt.mon);
            if (dt.tz_flag or dt.tzo != 0) {
                try appendTimeZone(&out, allocator, dt.tzo);
            }
            break :blk out.toOwnedSlice(allocator);
        },
        .gyear => blk: {
            var out: std.ArrayList(u8) = .empty;
            try appendYear(&out, allocator, dt.year);
            if (dt.tz_flag or dt.tzo != 0) {
                try appendTimeZone(&out, allocator, dt.tzo);
            }
            break :blk out.toOwnedSlice(allocator);
        },
        else => allocator.dupe(u8, ""),
    };
}

/// Sum a list of duration strings; returns null when any duration is invalid
/// or the components cannot be combined.
pub fn sumDurations(
    allocator: std.mem.Allocator,
    values: []const []const u8,
) !?[]const u8 {
    if (values.len == 0) return null;
    var total: Duration = .{};
    for (values) |value| {
        const duration = parseDuration(value) orelse return null;
        total = addDurations(total, duration) orelse return null;
    }
    return try formatDuration(allocator, total);
}

/// Format seconds since the Unix epoch as an xs:dateTime in UTC.
pub fn formatUnixSeconds(
    allocator: std.mem.Allocator,
    seconds: i64,
) ![]const u8 {
    const days = @divFloor(seconds, secs_per_day);
    const day_seconds = @mod(seconds, secs_per_day);
    // Howard Hinnant's civil_from_days, proleptic Gregorian.
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) -
        @divFloor(doe, 146096), 365);
    var year = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day = doy - @divFloor(153 * mp + 2, 5) + 1;
    const mon = if (mp < 10) mp + 3 else mp - 9;
    if (mon <= 2) year += 1;
    var out: std.ArrayList(u8) = .empty;
    try appendYear(&out, allocator, year);
    try out.append(allocator, '-');
    try appendTwoDigits(&out, allocator, @intCast(mon));
    try out.append(allocator, '-');
    try appendTwoDigits(&out, allocator, @intCast(day));
    try out.append(allocator, 'T');
    try appendTwoDigits(&out, allocator, @intCast(@divFloor(day_seconds, 3600)));
    try out.append(allocator, ':');
    try appendTwoDigits(&out, allocator, @intCast(
        @divFloor(@mod(day_seconds, 3600), 60),
    ));
    try out.append(allocator, ':');
    try appendTwoDigits(&out, allocator, @intCast(@mod(day_seconds, 60)));
    try out.append(allocator, 'Z');
    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "EXSLT date parses and reports fields" {
    const dt = parse("0001-12-31Z").?;
    try testing.expectEqual(DateType.date, dt.kind);
    try testing.expectEqual(@as(f64, 1), yearOf(dt));
    try testing.expect(!isLeap(dt.year));
    try testing.expectEqual(@as(i64, 365), dayInYear(dt.day, dt.mon, dt.year));
    try testing.expectEqual(@as(i64, 2), dayOfWeek(365, dt.year) + 1);

    const negative = parse("-0005-02-29").?;
    try testing.expectEqual(@as(f64, -5), yearOf(negative));
    try testing.expect(isLeap(negative.year));

    try testing.expect(parse("2001-02-29") == null);
    try testing.expect(parse("--02-29").?.kind == .gmonthday);
    try testing.expect(parse("--02--").?.kind == .gmonth);
    try testing.expect(parse("---15").?.kind == .gday);
    try testing.expect(parse("24:00:00") == null);
}

test "EXSLT date formats durations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try testing.expectEqualStrings(
        "P1DT0.5S",
        try formatDuration(allocator, .{ .day = 1, .sec = 0.5 }),
    );
    try testing.expectEqualStrings(
        "PT1H",
        try formatDuration(allocator, .{ .sec = 3599.99999999999 }),
    );
    try testing.expectEqualStrings(
        "-PT1M",
        try formatDuration(allocator, parseDuration("-PT1M").?),
    );
    try testing.expectEqualStrings(
        "P1Y2M3DT4H5M6.5S",
        try formatDuration(allocator, parseDuration("P1Y2M3DT4H5M6.5S").?),
    );
    try testing.expectEqualStrings(
        "P0D",
        try formatDuration(allocator, .{}),
    );
}

test "EXSLT date arithmetic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const add = call(
        allocator,
        "add",
        &.{ "2001-02-28", "P1D" },
        null,
    ).?.string;
    try testing.expectEqualStrings("2001-03-01", add);
    const difference_value = call(
        allocator,
        "difference",
        &.{ "2001-01-01", "2001-01-02" },
        null,
    ).?.string;
    try testing.expectEqualStrings("P1D", difference_value);
    const seconds_value = call(
        allocator,
        "seconds",
        &.{"PT10M"},
        null,
    ).?.number;
    try testing.expectEqual(@as(f64, 600), seconds_value);
    const duration_value = call(
        allocator,
        "duration",
        &.{"3661.5"},
        null,
    ).?.string;
    try testing.expectEqualStrings("PT1H1M1.5S", duration_value);
}
