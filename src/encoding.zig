//! XML byte-encoding detection and normalization to owned UTF-8.
//!
//! SVG parsing operates on UTF-8 slices. This boundary implements XML's
//! required UTF encodings plus Windows-1251, which is common in legacy SVG
//! exports, before any XML/CSS/resource scanner borrows source ranges.

const std = @import("std");

const Encoding = enum {
    utf8,
    utf16_le,
    utf16_be,
    utf32_le,
    utf32_be,
    windows_1251,
    iso_8859_1,
    windows_1252,
};

const Detection = struct {
    encoding: Encoding,
    start: usize = 0,
};

pub fn decodeAlloc(
    allocator: std.mem.Allocator,
    source: []const u8,
    max_output_bytes: usize,
) ![]u8 {
    const decoded = try decodeUnrewrittenAlloc(
        allocator,
        source,
        max_output_bytes,
    );
    errdefer allocator.free(decoded);
    if (try declarationEncoding(decoded)) |declared| {
        if (!std.mem.eql(u8, declared, "UTF-8")) {
            const rewritten = try rewriteDeclarationEncodingAlloc(
                allocator,
                decoded,
                declared,
                max_output_bytes,
            );
            allocator.free(decoded);
            return rewritten;
        }
    }
    return decoded;
}

/// Decode to UTF-8 without rewriting the XML declaration. Callers that strip
/// the text declaration (the DTD and external-entity parser paths) use this
/// to avoid copying the whole buffer a second time.
pub fn decodeUnrewrittenAlloc(
    allocator: std.mem.Allocator,
    source: []const u8,
    max_output_bytes: usize,
) ![]u8 {
    const detection = try detect(source);
    const payload = source[detection.start..];
    const decoded = switch (detection.encoding) {
        .utf8 => try decodeUtf8Alloc(allocator, payload, max_output_bytes),
        .utf16_le => try decodeUtf16Alloc(allocator, payload, .little, max_output_bytes),
        .utf16_be => try decodeUtf16Alloc(allocator, payload, .big, max_output_bytes),
        .utf32_le => try decodeUtf32Alloc(allocator, payload, .little, max_output_bytes),
        .utf32_be => try decodeUtf32Alloc(allocator, payload, .big, max_output_bytes),
        .windows_1251 => try decodeWindows1251Alloc(allocator, payload, max_output_bytes),
        .iso_8859_1 => try decodeLatin1Alloc(allocator, payload, max_output_bytes),
        .windows_1252 => try decodeWindows1252Alloc(allocator, payload, max_output_bytes),
    };
    errdefer allocator.free(decoded);
    try validateDeclaredEncoding(decoded, detection.encoding);
    return decoded;
}

fn rewriteDeclarationEncodingAlloc(
    allocator: std.mem.Allocator,
    source: []const u8,
    declared: []const u8,
    max_output_bytes: usize,
) ![]u8 {
    const canonical = "UTF-8";
    const prefix_len = @intFromPtr(declared.ptr) - @intFromPtr(source.ptr);
    if (prefix_len > source.len or declared.len > source.len - prefix_len) {
        return error.InvalidXmlEncoding;
    }
    const base_len = source.len - declared.len;
    if (canonical.len > max_output_bytes or
        base_len > max_output_bytes - canonical.len)
    {
        return error.SvgResourceInputTooLarge;
    }
    const output = try allocator.alloc(u8, base_len + canonical.len);
    @memcpy(output[0..prefix_len], source[0..prefix_len]);
    @memcpy(output[prefix_len..][0..canonical.len], canonical);
    const source_suffix = source[prefix_len + declared.len ..];
    @memcpy(output[prefix_len + canonical.len ..], source_suffix);
    return output;
}

fn detect(source: []const u8) !Detection {
    if (std.mem.startsWith(u8, source, "\x00\x00\xFE\xFF")) {
        return .{ .encoding = .utf32_be, .start = 4 };
    }
    if (std.mem.startsWith(u8, source, "\xFF\xFE\x00\x00")) {
        return .{ .encoding = .utf32_le, .start = 4 };
    }
    if (std.mem.startsWith(u8, source, "\xEF\xBB\xBF")) {
        return .{ .encoding = .utf8, .start = 3 };
    }
    if (std.mem.startsWith(u8, source, "\xFE\xFF")) {
        return .{ .encoding = .utf16_be, .start = 2 };
    }
    if (std.mem.startsWith(u8, source, "\xFF\xFE")) {
        return .{ .encoding = .utf16_le, .start = 2 };
    }
    if (std.mem.startsWith(u8, source, "\x00\x00\x00<")) {
        return .{ .encoding = .utf32_be };
    }
    if (std.mem.startsWith(u8, source, "<\x00\x00\x00")) {
        return .{ .encoding = .utf32_le };
    }
    if (std.mem.startsWith(u8, source, "\x00<\x00?")) {
        return .{ .encoding = .utf16_be };
    }
    if (std.mem.startsWith(u8, source, "<\x00?\x00")) {
        return .{ .encoding = .utf16_le };
    }

    const declared = try declarationEncoding(source) orelse
        return .{ .encoding = .utf8 };
    if (encodingNameEql(declared, "utf-8") or
        encodingNameEql(declared, "utf8") or
        encodingNameEql(declared, "us-ascii") or
        encodingNameEql(declared, "ascii"))
    {
        return .{ .encoding = .utf8 };
    }
    if (encodingNameEql(declared, "windows-1251") or
        encodingNameEql(declared, "cp1251") or
        encodingNameEql(declared, "x-cp1251"))
    {
        return .{ .encoding = .windows_1251 };
    }
    if (encodingNameEql(declared, "iso-8859-1") or
        encodingNameEql(declared, "iso_8859-1") or
        encodingNameEql(declared, "latin1") or
        encodingNameEql(declared, "latin-1") or
        encodingNameEql(declared, "l1") or
        encodingNameEql(declared, "cp819") or
        encodingNameEql(declared, "ibm819"))
    {
        return .{ .encoding = .iso_8859_1 };
    }
    if (encodingNameEql(declared, "windows-1252") or
        encodingNameEql(declared, "cp1252") or
        encodingNameEql(declared, "x-cp1252"))
    {
        return .{ .encoding = .windows_1252 };
    }
    if (encodingNameEql(declared, "utf-16") or
        encodingNameEql(declared, "utf-16le") or
        encodingNameEql(declared, "utf-16be") or
        encodingNameEql(declared, "utf-32") or
        encodingNameEql(declared, "utf-32le") or
        encodingNameEql(declared, "utf-32be"))
    {
        // A UTF-16/32 declaration encoded as ordinary ASCII bytes conflicts
        // with XML's byte-pattern autodetection and is not a valid document.
        return error.InvalidXmlEncoding;
    }
    return error.UnsupportedXmlEncoding;
}

fn declarationEncoding(source: []const u8) !?[]const u8 {
    if (!std.mem.startsWith(u8, source, "<?xml")) return null;
    const end = std.mem.indexOf(u8, source[5..], "?>") orelse
        return error.InvalidXmlEncoding;
    const declaration = source[5 .. 5 + end];
    var index: usize = 0;
    while (index < declaration.len) {
        while (index < declaration.len and
            std.ascii.isWhitespace(declaration[index])) index += 1;
        const name_start = index;
        while (index < declaration.len and isDeclarationNameByte(
            declaration[index],
        )) index += 1;
        const name = declaration[name_start..index];
        if (name.len == 0) {
            if (index < declaration.len) index += 1;
            continue;
        }
        while (index < declaration.len and
            std.ascii.isWhitespace(declaration[index])) index += 1;
        if (index >= declaration.len or declaration[index] != '=') {
            if (std.mem.eql(u8, name, "encoding")) {
                return error.InvalidXmlEncoding;
            }
            continue;
        }
        index += 1;
        while (index < declaration.len and
            std.ascii.isWhitespace(declaration[index])) index += 1;
        if (index >= declaration.len or
            (declaration[index] != '"' and declaration[index] != '\''))
        {
            return error.InvalidXmlEncoding;
        }
        const quote = declaration[index];
        index += 1;
        const value_start = index;
        while (index < declaration.len and declaration[index] != quote) {
            index += 1;
        }
        if (index >= declaration.len) return error.InvalidXmlEncoding;
        const value = declaration[value_start..index];
        index += 1;
        if (std.mem.eql(u8, name, "encoding")) {
            if (!validEncodingName(value)) return error.InvalidXmlEncoding;
            return value;
        }
    }
    return null;
}

fn validEncodingName(value: []const u8) bool {
    if (value.len == 0) return false;
    if (!std.ascii.isAlphabetic(value[0])) return false;
    for (value[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and
            byte != '.' and byte != '_' and byte != '-')
        {
            return false;
        }
    }
    return true;
}

fn isDeclarationNameByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or
        byte == ':' or byte == '.';
}

fn encodingNameEql(actual: []const u8, expected: []const u8) bool {
    return std.ascii.eqlIgnoreCase(
        std.mem.trim(u8, actual, " \t\r\n"),
        expected,
    );
}

fn validateDeclaredEncoding(source: []const u8, actual: Encoding) !void {
    const declared = try declarationEncoding(source) orelse return;
    const compatible = switch (actual) {
        .utf8 => encodingNameEql(declared, "utf-8") or
            encodingNameEql(declared, "utf8") or
            encodingNameEql(declared, "us-ascii") or
            encodingNameEql(declared, "ascii"),
        .utf16_le => encodingNameEql(declared, "utf-16") or
            encodingNameEql(declared, "utf-16le"),
        .utf16_be => encodingNameEql(declared, "utf-16") or
            encodingNameEql(declared, "utf-16be"),
        .utf32_le => encodingNameEql(declared, "utf-32") or
            encodingNameEql(declared, "utf-32le"),
        .utf32_be => encodingNameEql(declared, "utf-32") or
            encodingNameEql(declared, "utf-32be"),
        .windows_1251 => encodingNameEql(declared, "windows-1251") or
            encodingNameEql(declared, "cp1251") or
            encodingNameEql(declared, "x-cp1251"),
        .iso_8859_1 => encodingNameEql(declared, "iso-8859-1") or
            encodingNameEql(declared, "iso_8859-1") or
            encodingNameEql(declared, "latin1") or
            encodingNameEql(declared, "latin-1") or
            encodingNameEql(declared, "l1") or
            encodingNameEql(declared, "cp819") or
            encodingNameEql(declared, "ibm819"),
        .windows_1252 => encodingNameEql(declared, "windows-1252") or
            encodingNameEql(declared, "cp1252") or
            encodingNameEql(declared, "x-cp1252"),
    };
    if (!compatible) return error.InvalidXmlEncoding;
}

fn decodeUtf8Alloc(
    allocator: std.mem.Allocator,
    source: []const u8,
    max_output_bytes: usize,
) ![]u8 {
    if (source.len > max_output_bytes) return error.SvgResourceInputTooLarge;
    if (!std.unicode.utf8ValidateSlice(source)) return error.InvalidUtf8;
    return allocator.dupe(u8, source);
}

fn decodeUtf16Alloc(
    allocator: std.mem.Allocator,
    source: []const u8,
    endian: std.builtin.Endian,
    max_output_bytes: usize,
) ![]u8 {
    if (source.len % 2 != 0) return error.InvalidXmlEncoding;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    while (index < source.len) {
        const first = readU16(source[index..][0..2], endian);
        index += 2;
        const codepoint: u21 = if (first >= 0xD800 and first <= 0xDBFF) blk: {
            if (index >= source.len) return error.InvalidXmlEncoding;
            const second = readU16(source[index..][0..2], endian);
            index += 2;
            if (second < 0xDC00 or second > 0xDFFF) {
                return error.InvalidXmlEncoding;
            }
            break :blk @intCast(
                0x10000 +
                    ((@as(u32, first) - 0xD800) << 10) +
                    (@as(u32, second) - 0xDC00),
            );
        } else if (first >= 0xDC00 and first <= 0xDFFF)
            return error.InvalidXmlEncoding
        else
            @intCast(first);
        try appendCodepoint(
            &output,
            allocator,
            codepoint,
            max_output_bytes,
        );
    }
    return output.toOwnedSlice(allocator);
}

fn decodeUtf32Alloc(
    allocator: std.mem.Allocator,
    source: []const u8,
    endian: std.builtin.Endian,
    max_output_bytes: usize,
) ![]u8 {
    if (source.len % 4 != 0) return error.InvalidXmlEncoding;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    while (index < source.len) : (index += 4) {
        const value = readU32(source[index..][0..4], endian);
        if (value > 0x10FFFF or (value >= 0xD800 and value <= 0xDFFF)) {
            return error.InvalidXmlEncoding;
        }
        try appendCodepoint(
            &output,
            allocator,
            @intCast(value),
            max_output_bytes,
        );
    }
    return output.toOwnedSlice(allocator);
}

fn decodeWindows1251Alloc(
    allocator: std.mem.Allocator,
    source: []const u8,
    max_output_bytes: usize,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    for (source) |byte| {
        const codepoint: u21 = if (byte < 0x80)
            byte
        else blk: {
            const mapped = windows_1251[byte - 0x80];
            if (mapped == 0) return error.InvalidXmlEncoding;
            break :blk mapped;
        };
        try appendCodepoint(
            &output,
            allocator,
            codepoint,
            max_output_bytes,
        );
    }
    return output.toOwnedSlice(allocator);
}

fn decodeLatin1Alloc(
    allocator: std.mem.Allocator,
    source: []const u8,
    max_output_bytes: usize,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var pos: usize = 0;
    while (pos < source.len) {
        const high = findHighByte(source, pos);
        if (high > pos) {
            const run = high - pos;
            if (run > max_output_bytes or
                output.items.len > max_output_bytes - run)
            {
                return error.SvgResourceInputTooLarge;
            }
            try output.appendSlice(allocator, source[pos..high]);
            pos = high;
            if (pos >= source.len) break;
        }
        const byte = source[pos];
        var encoded: [4]u8 = undefined;
        const count = std.unicode.utf8Encode(@as(u21, byte), &encoded) catch
            return error.InvalidXmlEncoding;
        if (count > max_output_bytes or
            output.items.len > max_output_bytes - count)
        {
            return error.SvgResourceInputTooLarge;
        }
        try output.appendSlice(allocator, encoded[0..count]);
        pos += 1;
    }
    return output.toOwnedSlice(allocator);
}

/// First byte at or after `start` that is not ASCII.
fn findHighByte(input: []const u8, start: usize) usize {
    const Vec = @Vector(32, u8);
    const threshold: Vec = @splat(0x80);
    var index = start;
    while (index + 32 <= input.len) : (index += 32) {
        const chunk: Vec = input[index..][0..32].*;
        const mask: u32 = @bitCast(chunk >= threshold);
        if (mask != 0) return index + @ctz(mask);
    }
    while (index < input.len) : (index += 1) {
        if (input[index] >= 0x80) return index;
    }
    return input.len;
}

/// First byte at or after `start` in the Windows-1252 extension range.
fn findWindows1252Special(input: []const u8, start: usize) usize {
    const Vec = @Vector(32, u8);
    const low: Vec = @splat(0x80);
    const high: Vec = @splat(0xA0);
    var index = start;
    while (index + 32 <= input.len) : (index += 32) {
        const chunk: Vec = input[index..][0..32].*;
        const mask: u32 = @as(u32, @bitCast(chunk >= low)) &
            @as(u32, @bitCast(chunk < high));
        if (mask != 0) return index + @ctz(mask);
    }
    while (index < input.len) : (index += 1) {
        if (input[index] >= 0x80 and input[index] < 0xA0) return index;
    }
    return input.len;
}

fn decodeWindows1252Alloc(
    allocator: std.mem.Allocator,
    source: []const u8,
    max_output_bytes: usize,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var pos: usize = 0;
    while (pos < source.len) {
        const special = findWindows1252Special(source, pos);
        if (special > pos) {
            const run = special - pos;
            if (run > max_output_bytes or
                output.items.len > max_output_bytes - run)
            {
                return error.SvgResourceInputTooLarge;
            }
            try output.appendSlice(allocator, source[pos..special]);
            pos = special;
            if (pos >= source.len) break;
        }
        const byte = source[pos];
        const mapped = windows_1252[byte - 0x80];
        if (mapped == 0) return error.InvalidXmlEncoding;
        try appendCodepoint(
            &output,
            allocator,
            mapped,
            max_output_bytes,
        );
        pos += 1;
    }
    return output.toOwnedSlice(allocator);
}

fn appendCodepoint(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    codepoint: u21,
    max_output_bytes: usize,
) !void {
    var encoded: [4]u8 = undefined;
    const count = std.unicode.utf8Encode(codepoint, &encoded) catch
        return error.InvalidXmlEncoding;
    if (count > max_output_bytes or
        output.items.len > max_output_bytes - count)
    {
        return error.SvgResourceInputTooLarge;
    }
    try output.appendSlice(allocator, encoded[0..count]);
}

fn readU16(bytes: *const [2]u8, endian: std.builtin.Endian) u16 {
    return switch (endian) {
        .little => @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8),
        .big => (@as(u16, bytes[0]) << 8) | @as(u16, bytes[1]),
    };
}

fn readU32(bytes: *const [4]u8, endian: std.builtin.Endian) u32 {
    return switch (endian) {
        .little => @as(u32, bytes[0]) |
            (@as(u32, bytes[1]) << 8) |
            (@as(u32, bytes[2]) << 16) |
            (@as(u32, bytes[3]) << 24),
        .big => (@as(u32, bytes[0]) << 24) |
            (@as(u32, bytes[1]) << 16) |
            (@as(u32, bytes[2]) << 8) |
            @as(u32, bytes[3]),
    };
}

const windows_1252 = [32]u21{
    0x20AC, 0x0000, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x0000, 0x017D, 0x0000,
    0x0000, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x0000, 0x017E, 0x0178,
};

const windows_1251 = [128]u21{
    0x0402, 0x0403, 0x201A, 0x0453, 0x201E, 0x2026, 0x2020, 0x2021,
    0x20AC, 0x2030, 0x0409, 0x2039, 0x040A, 0x040C, 0x040B, 0x040F,
    0x0452, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x0000, 0x2122, 0x0459, 0x203A, 0x045A, 0x045C, 0x045B, 0x045F,
    0x00A0, 0x040E, 0x045E, 0x0408, 0x00A4, 0x0490, 0x00A6, 0x00A7,
    0x0401, 0x00A9, 0x0404, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x0407,
    0x00B0, 0x00B1, 0x0406, 0x0456, 0x0491, 0x00B5, 0x00B6, 0x00B7,
    0x0451, 0x2116, 0x0454, 0x00BB, 0x0458, 0x0405, 0x0455, 0x0457,
    0x0410, 0x0411, 0x0412, 0x0413, 0x0414, 0x0415, 0x0416, 0x0417,
    0x0418, 0x0419, 0x041A, 0x041B, 0x041C, 0x041D, 0x041E, 0x041F,
    0x0420, 0x0421, 0x0422, 0x0423, 0x0424, 0x0425, 0x0426, 0x0427,
    0x0428, 0x0429, 0x042A, 0x042B, 0x042C, 0x042D, 0x042E, 0x042F,
    0x0430, 0x0431, 0x0432, 0x0433, 0x0434, 0x0435, 0x0436, 0x0437,
    0x0438, 0x0439, 0x043A, 0x043B, 0x043C, 0x043D, 0x043E, 0x043F,
    0x0440, 0x0441, 0x0442, 0x0443, 0x0444, 0x0445, 0x0446, 0x0447,
    0x0448, 0x0449, 0x044A, 0x044B, 0x044C, 0x044D, 0x044E, 0x044F,
};

test "XML encoding normalizes UTF-8 BOM and validates input" {
    const allocator = std.testing.allocator;
    const decoded = try decodeAlloc(allocator, "\xEF\xBB\xBF<svg/>", 64);
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("<svg/>", decoded);
    try std.testing.expectError(
        error.InvalidUtf8,
        decodeAlloc(allocator, "<svg>\xFF</svg>", 64),
    );
}

test "XML encoding decodes UTF-16 and UTF-32 byte orders" {
    const allocator = std.testing.allocator;
    const utf16_le = try decodeAlloc(
        allocator,
        "\xFF\xFE<\x00s\x00v\x00g\x00/\x00>\x00",
        64,
    );
    defer allocator.free(utf16_le);
    try std.testing.expectEqualStrings("<svg/>", utf16_le);

    const utf16_be = try decodeAlloc(
        allocator,
        "\xFE\xFF\x00<\x00s\x00v\x00g\x00/\x00>",
        64,
    );
    defer allocator.free(utf16_be);
    try std.testing.expectEqualStrings("<svg/>", utf16_be);

    const utf32_le = try decodeAlloc(
        allocator,
        "\xFF\xFE\x00\x00<\x00\x00\x00s\x00\x00\x00v\x00\x00\x00g\x00\x00\x00/\x00\x00\x00>\x00\x00\x00",
        64,
    );
    defer allocator.free(utf32_le);
    try std.testing.expectEqualStrings("<svg/>", utf32_le);
}

test "XML encoding decodes Latin-1 and Windows-1252 declarations" {
    const allocator = std.testing.allocator;
    const latin1 = try decodeAlloc(
        allocator,
        "<?xml version=\"1.1\" encoding=\"ISO-8859-1\"?><r>caf\xE9</r>",
        1024,
    );
    defer allocator.free(latin1);
    try std.testing.expect(std.mem.indexOf(u8, latin1, "café") != null);
    try std.testing.expect(std.mem.indexOf(u8, latin1, "encoding=\"UTF-8\"") != null);

    const cp1252 = try decodeAlloc(
        allocator,
        "<?xml version=\"1.0\" encoding=\"windows-1252\"?><r>\x80</r>",
        1024,
    );
    defer allocator.free(cp1252);
    try std.testing.expect(std.mem.indexOf(u8, cp1252, "€") != null);
}

test "XML encoding decodes Windows-1251 declarations" {
    const allocator = std.testing.allocator;
    const source = "<?xml version=\"1.0\" encoding=\"Windows-1251\"?>" ++
        "<svg><text>\xCF\xF0\xE8\xE2\xE5\xF2 \xEC\xE8\xF0</text></svg>";
    const decoded = try decodeAlloc(allocator, source, 1024);
    defer allocator.free(decoded);
    try std.testing.expect(std.mem.indexOf(
        u8,
        decoded,
        "encoding=\"UTF-8\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, decoded, "Привет мир") != null);
}

test "XML encoding rejects unsupported declarations and expanded limits" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.UnsupportedXmlEncoding,
        decodeAlloc(
            allocator,
            "<?xml version=\"1.0\" encoding=\"Shift_JIS\"?><svg/>",
            1024,
        ),
    );
    try std.testing.expectError(
        error.SvgResourceInputTooLarge,
        decodeAlloc(
            allocator,
            "<?xml version=\"1.0\" encoding=\"Windows-1251\"?><svg>\xCF</svg>",
            16,
        ),
    );
}

test "XML encoding rejects declaration conflicts and malformed UTF units" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidXmlEncoding,
        decodeAlloc(
            allocator,
            "\xEF\xBB\xBF<?xml version=\"1.0\" encoding=\"Windows-1251\"?><svg/>",
            1024,
        ),
    );
    try std.testing.expectError(
        error.InvalidXmlEncoding,
        decodeAlloc(allocator, "\xFF\xFE\x00\xD8", 1024),
    );
    try std.testing.expectError(
        error.InvalidXmlEncoding,
        decodeAlloc(allocator, "\xFF\xFE\x00\x00\x00\x00\x11\x00", 1024),
    );
}

fn decodeWindows1251AllocationFailure(allocator: std.mem.Allocator) !void {
    const source = "<?xml version=\"1.0\" encoding=\"Windows-1251\"?>" ++
        "<svg><text>\xCF\xF0\xE8\xE2\xE5\xF2</text></svg>";
    const decoded = try decodeAlloc(allocator, source, 1024);
    defer allocator.free(decoded);
    try std.testing.expect(std.mem.indexOf(u8, decoded, "Привет") != null);
}

test "XML encoding releases every partial allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        decodeWindows1251AllocationFailure,
        .{},
    );
}

/// Output encodings supported by the XML serializer.
pub const OutputEncoding = enum {
    utf8,
    utf16,
    utf16_le,
    utf16_be,
    iso_8859_1,
    us_ascii,
    windows_1252,
};

pub fn outputEncoding(name: []const u8) ?OutputEncoding {
    var buffer: [32]u8 = undefined;
    if (name.len > buffer.len) return null;
    const upper = std.ascii.upperString(buffer[0..name.len], name);
    if (std.mem.eql(u8, upper, "UTF-8") or std.mem.eql(u8, upper, "UTF8")) {
        return .utf8;
    }
    if (std.mem.eql(u8, upper, "UTF-16")) return .utf16;
    if (std.mem.eql(u8, upper, "UTF-16LE")) return .utf16_le;
    if (std.mem.eql(u8, upper, "UTF-16BE")) return .utf16_be;
    if (std.mem.eql(u8, upper, "ISO-8859-1") or
        std.mem.eql(u8, upper, "ISO8859-1") or
        std.mem.eql(u8, upper, "LATIN1") or
        std.mem.eql(u8, upper, "LATIN-1"))
    {
        return .iso_8859_1;
    }
    if (std.mem.eql(u8, upper, "US-ASCII") or
        std.mem.eql(u8, upper, "ASCII") or
        std.mem.eql(u8, upper, "ANSI_X3.4-1968"))
    {
        return .us_ascii;
    }
    if (std.mem.eql(u8, upper, "WINDOWS-1252") or
        std.mem.eql(u8, upper, "CP1252"))
    {
        return .windows_1252;
    }
    return null;
}

/// Transcode UTF-8 to an output encoding. Characters that cannot be
/// represented are emitted as decimal character references.
pub fn encodeAlloc(
    allocator: std.mem.Allocator,
    source: []const u8,
    encoding: OutputEncoding,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    switch (encoding) {
        .utf8 => return allocator.dupe(u8, source),
        .utf16 => try out.appendSlice(allocator, &.{ 0xFF, 0xFE }),
        else => {},
    }
    var index: usize = 0;
    while (index < source.len) {
        const length = std.unicode.utf8ByteSequenceLength(source[index]) catch
            return error.InvalidXmlEncoding;
        if (index + length > source.len) return error.InvalidXmlEncoding;
        const codepoint = std.unicode.utf8Decode(source[index..][0..length]) catch
            return error.InvalidXmlEncoding;
        index += length;
        switch (encoding) {
            .utf8 => unreachable,
            .utf16, .utf16_le, .utf16_be => try appendUtf16(
                &out,
                allocator,
                codepoint,
                encoding == .utf16_be,
            ),
            .iso_8859_1 => try appendSingleByte(
                &out,
                allocator,
                codepoint,
                if (codepoint <= 0xFF) @intCast(codepoint) else null,
            ),
            .us_ascii => try appendSingleByte(
                &out,
                allocator,
                codepoint,
                if (codepoint <= 0x7F) @intCast(codepoint) else null,
            ),
            .windows_1252 => try appendSingleByte(
                &out,
                allocator,
                codepoint,
                windows1252Byte(codepoint),
            ),
        }
    }
    return out.toOwnedSlice(allocator);
}

fn appendSingleByte(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    codepoint: u21,
    byte: ?u8,
) !void {
    if (byte) |value| {
        try out.append(allocator, value);
        return;
    }
    var buffer: [16]u8 = undefined;
    const reference = try std.fmt.bufPrint(
        &buffer,
        "&#{d};",
        .{codepoint},
    );
    try out.appendSlice(allocator, reference);
}

fn appendUtf16(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    codepoint: u21,
    big_endian: bool,
) !void {
    var buffer: [4]u8 = undefined;
    var length: usize = 2;
    if (codepoint <= 0xFFFF) {
        buffer[0] = @truncate(codepoint >> 8);
        buffer[1] = @truncate(codepoint);
    } else {
        const value = codepoint - 0x10000;
        const high: u16 = @intCast(0xD800 + (value >> 10));
        const low: u16 = @intCast(0xDC00 + (value & 0x3FF));
        buffer[0] = @truncate(high >> 8);
        buffer[1] = @truncate(high);
        buffer[2] = @truncate(low >> 8);
        buffer[3] = @truncate(low);
        length = 4;
    }
    if (!big_endian) {
        var index: usize = 0;
        while (index < length) : (index += 2) {
            const first = buffer[index];
            buffer[index] = buffer[index + 1];
            buffer[index + 1] = first;
        }
    }
    try out.appendSlice(allocator, buffer[0..length]);
}

fn windows1252Byte(codepoint: u21) ?u8 {
    if (codepoint <= 0x7F or (codepoint >= 0xA0 and codepoint <= 0xFF)) {
        return @intCast(codepoint);
    }
    const mapping = [_]struct { cp: u21, byte: u8 }{
        .{ .cp = 0x20AC, .byte = 0x80 },
        .{ .cp = 0x201A, .byte = 0x82 },
        .{ .cp = 0x0192, .byte = 0x83 },
        .{ .cp = 0x201E, .byte = 0x84 },
        .{ .cp = 0x2026, .byte = 0x85 },
        .{ .cp = 0x2020, .byte = 0x86 },
        .{ .cp = 0x2021, .byte = 0x87 },
        .{ .cp = 0x02C6, .byte = 0x88 },
        .{ .cp = 0x2030, .byte = 0x89 },
        .{ .cp = 0x0160, .byte = 0x8A },
        .{ .cp = 0x2039, .byte = 0x8B },
        .{ .cp = 0x0152, .byte = 0x8C },
        .{ .cp = 0x017D, .byte = 0x8E },
        .{ .cp = 0x2018, .byte = 0x91 },
        .{ .cp = 0x2019, .byte = 0x92 },
        .{ .cp = 0x201C, .byte = 0x93 },
        .{ .cp = 0x201D, .byte = 0x94 },
        .{ .cp = 0x2022, .byte = 0x95 },
        .{ .cp = 0x2013, .byte = 0x96 },
        .{ .cp = 0x2014, .byte = 0x97 },
        .{ .cp = 0x02DC, .byte = 0x98 },
        .{ .cp = 0x2122, .byte = 0x99 },
        .{ .cp = 0x0161, .byte = 0x9A },
        .{ .cp = 0x203A, .byte = 0x9B },
        .{ .cp = 0x0153, .byte = 0x9C },
        .{ .cp = 0x017E, .byte = 0x9E },
        .{ .cp = 0x0178, .byte = 0x9F },
    };
    for (mapping) |entry| {
        if (entry.cp == codepoint) return entry.byte;
    }
    return null;
}

/// Decoding targets selectable by name, used by XInclude `encoding`.
pub const DecodeEncoding = enum {
    utf8,
    utf16,
    utf16_le,
    utf16_be,
    utf32,
    utf32_le,
    utf32_be,
    iso_8859_1,
    us_ascii,
    windows_1251,
    windows_1252,
};

pub fn decodeEncodingName(name: []const u8) ?DecodeEncoding {
    var buffer: [32]u8 = undefined;
    if (name.len > buffer.len) return null;
    const upper = std.ascii.upperString(buffer[0..name.len], name);
    if (std.mem.eql(u8, upper, "UTF-8") or std.mem.eql(u8, upper, "UTF8")) {
        return .utf8;
    }
    if (std.mem.eql(u8, upper, "UTF-16")) return .utf16;
    if (std.mem.eql(u8, upper, "UTF-16LE")) return .utf16_le;
    if (std.mem.eql(u8, upper, "UTF-16BE")) return .utf16_be;
    if (std.mem.eql(u8, upper, "UTF-32")) return .utf32;
    if (std.mem.eql(u8, upper, "UTF-32LE")) return .utf32_le;
    if (std.mem.eql(u8, upper, "UTF-32BE")) return .utf32_be;
    if (std.mem.eql(u8, upper, "ISO-8859-1") or
        std.mem.eql(u8, upper, "ISO8859-1") or
        std.mem.eql(u8, upper, "LATIN1") or
        std.mem.eql(u8, upper, "LATIN-1"))
    {
        return .iso_8859_1;
    }
    if (std.mem.eql(u8, upper, "US-ASCII") or
        std.mem.eql(u8, upper, "ASCII"))
    {
        return .us_ascii;
    }
    if (std.mem.eql(u8, upper, "WINDOWS-1251") or
        std.mem.eql(u8, upper, "CP1251"))
    {
        return .windows_1251;
    }
    if (std.mem.eql(u8, upper, "WINDOWS-1252") or
        std.mem.eql(u8, upper, "CP1252"))
    {
        return .windows_1252;
    }
    return null;
}

/// Decode `source` using an explicitly named encoding. A matching byte order
/// mark is removed.
pub fn decodeWithEncodingAlloc(
    allocator: std.mem.Allocator,
    source: []const u8,
    encoding: DecodeEncoding,
    max_output_bytes: usize,
) ![]u8 {
    switch (encoding) {
        .utf8 => {
            const payload = stripBom(source, &.{ 0xEF, 0xBB, 0xBF });
            return decodeUtf8Alloc(allocator, payload, max_output_bytes);
        },
        .utf16 => {
            if (stripBomStrict(source, &.{ 0xFF, 0xFE })) |payload| {
                return decodeUtf16Alloc(
                    allocator,
                    payload,
                    .little,
                    max_output_bytes,
                );
            }
            const payload = stripBomStrict(source, &.{ 0xFE, 0xFF }) orelse
                return error.InvalidXmlEncoding;
            return decodeUtf16Alloc(
                allocator,
                payload,
                .big,
                max_output_bytes,
            );
        },
        .utf16_le => return decodeUtf16Alloc(
            allocator,
            stripBom(source, &.{ 0xFF, 0xFE }),
            .little,
            max_output_bytes,
        ),
        .utf16_be => return decodeUtf16Alloc(
            allocator,
            stripBom(source, &.{ 0xFE, 0xFF }),
            .big,
            max_output_bytes,
        ),
        .utf32 => {
            if (stripBomStrict(source, &.{ 0xFF, 0xFE, 0x00, 0x00 })) |payload| {
                return decodeUtf32Alloc(
                    allocator,
                    payload,
                    .little,
                    max_output_bytes,
                );
            }
            const payload = stripBomStrict(source, &.{ 0x00, 0x00, 0xFE, 0xFF }) orelse
                return error.InvalidXmlEncoding;
            return decodeUtf32Alloc(
                allocator,
                payload,
                .big,
                max_output_bytes,
            );
        },
        .utf32_le => return decodeUtf32Alloc(
            allocator,
            stripBom(source, &.{ 0xFF, 0xFE, 0x00, 0x00 }),
            .little,
            max_output_bytes,
        ),
        .utf32_be => return decodeUtf32Alloc(
            allocator,
            stripBom(source, &.{ 0x00, 0x00, 0xFE, 0xFF }),
            .big,
            max_output_bytes,
        ),
        .iso_8859_1 => return decodeLatin1Alloc(
            allocator,
            source,
            max_output_bytes,
        ),
        .us_ascii => {
            if (source.len > max_output_bytes) {
                return error.SvgResourceInputTooLarge;
            }
            for (source) |byte| {
                if (byte > 0x7F) return error.InvalidXmlEncoding;
            }
            return allocator.dupe(u8, source);
        },
        .windows_1251 => return decodeWindows1251Alloc(
            allocator,
            source,
            max_output_bytes,
        ),
        .windows_1252 => return decodeWindows1252Alloc(
            allocator,
            source,
            max_output_bytes,
        ),
    }
}

fn stripBom(source: []const u8, bom: []const u8) []const u8 {
    if (std.mem.startsWith(u8, source, bom)) return source[bom.len..];
    return source;
}

fn stripBomStrict(source: []const u8, bom: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, source, bom)) return source[bom.len..];
    return null;
}
