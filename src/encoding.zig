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
    const detection = try detect(source);
    const payload = source[detection.start..];
    const decoded = switch (detection.encoding) {
        .utf8 => try decodeUtf8Alloc(allocator, payload, max_output_bytes),
        .utf16_le => try decodeUtf16Alloc(allocator, payload, .little, max_output_bytes),
        .utf16_be => try decodeUtf16Alloc(allocator, payload, .big, max_output_bytes),
        .utf32_le => try decodeUtf32Alloc(allocator, payload, .little, max_output_bytes),
        .utf32_be => try decodeUtf32Alloc(allocator, payload, .big, max_output_bytes),
        .windows_1251 => try decodeWindows1251Alloc(allocator, payload, max_output_bytes),
    };
    errdefer allocator.free(decoded);
    try validateDeclaredEncoding(decoded, detection.encoding);
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
