//! XML 1.0 character, name, and whitespace classification.
//!
//! These predicates follow the XML 1.0 (Fifth Edition) productions:
//!
//! ```text
//! Char          ::= #x9 | #xA | #xD | [#x20-#xD7FF] | [#xE000-#xFFFD]
//!                 | [#x10000-#x10FFFF]
//! NameStartChar ::= ":" | [A-Z] | "_" | [a-z] | [#xC0-#xD6] | [#xD8-#xF6]
//!                 | [#xF8-#x2FF] | [#x370-#x37D] | [#x37F-#x1FFF]
//!                 | [#x200C-#x200D] | [#x2070-#x218F] | [#x2C00-#x2FEF]
//!                 | [#x3001-#xD7FF] | [#xF900-#xFDCF] | [#xFDF0-#xFFFD]
//!                 | [#x10000-#xEFFFF]
//! NameChar      ::= NameStartChar | "-" | "." | [0-9] | #xB7
//!                 | [#x0300-#x036F] | [#x203F-#x2040]
//! ```
//!
//! Every hot path starts with an ASCII fast scan and only decodes UTF-8 when a
//! high byte is present, so ordinary markup costs one comparison per byte.

const std = @import("std");

/// XML `S` production: space, tab, carriage return, line feed.
pub inline fn isWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

/// The literal space character (#x20).
pub inline fn isSpace(byte: u8) bool {
    return byte == ' ';
}

pub const Version = enum { xml_1_0, xml_1_1 };

/// XML 1.0 `Char` production.
pub inline fn isXmlChar(cp: u21) bool {
    return cp == 0x9 or cp == 0xA or cp == 0xD or
        (cp >= 0x20 and cp <= 0xD7FF) or
        (cp >= 0xE000 and cp <= 0xFFFD) or
        (cp >= 0x10000 and cp <= 0x10FFFF);
}

/// XML 1.1 `Char` production.
pub inline fn isXmlChar11(cp: u21) bool {
    return (cp >= 0x1 and cp <= 0xD7FF) or
        (cp >= 0xE000 and cp <= 0xFFFD) or
        (cp >= 0x10000 and cp <= 0x10FFFF);
}

pub inline fn isXmlCharVersion(cp: u21, version: Version) bool {
    return switch (version) {
        .xml_1_0 => isXmlChar(cp),
        .xml_1_1 => isXmlChar11(cp),
    };
}

/// XML 1.1 restricted characters. These are allowed in documents only as
/// character references, not as literal characters.
pub inline fn isRestrictedChar11(cp: u21) bool {
    return switch (cp) {
        0x1...0x8, 0xB, 0xC, 0xE...0x1F, 0x7F...0x84, 0x86...0x9F => true,
        else => false,
    };
}

/// XML 1.0 `NameStartChar` production.
pub inline fn isNameStartChar(cp: u21) bool {
    return switch (cp) {
        ':', '_', 'A'...'Z', 'a'...'z' => true,
        0xC0...0xD6,
        0xD8...0xF6,
        0xF8...0x2FF,
        0x370...0x37D,
        0x37F...0x1FFF,
        0x200C...0x200D,
        0x2070...0x218F,
        0x2C00...0x2FEF,
        0x3001...0xD7FF,
        0xF900...0xFDCF,
        0xFDF0...0xFFFD,
        0x10000...0xEFFFF,
        => true,
        else => false,
    };
}

/// XML 1.0 `NameChar` production.
pub inline fn isNameChar(cp: u21) bool {
    return switch (cp) {
        '-', '.', '0'...'9', 0xB7, 0x300...0x36F, 0x203F...0x2040 => true,
        else => isNameStartChar(cp),
    };
}

/// `NCNameStartChar`: `NameStartChar` without the namespace separator.
pub inline fn isNCNameStartChar(cp: u21) bool {
    return cp != ':' and isNameStartChar(cp);
}

/// `NCNameChar`: `NameChar` without the namespace separator.
pub inline fn isNCNameChar(cp: u21) bool {
    return cp != ':' and isNameChar(cp);
}

const ascii_name_start_table: [256]bool = blk: {
    var table: [256]bool = @splat(false);
    table[':'] = true;
    table['_'] = true;
    for ('A'..'Z' + 1) |byte| table[byte] = true;
    for ('a'..'z' + 1) |byte| table[byte] = true;
    break :blk table;
};

const ascii_name_table: [256]bool = blk: {
    var table = ascii_name_start_table;
    table['-'] = true;
    table['.'] = true;
    for ('0'..'9' + 1) |byte| table[byte] = true;
    break :blk table;
};

/// ASCII subset of `NameStartChar`. Colon is included: namespace processing is
/// a separate layer that may reject or split it.
pub inline fn isAsciiNameStartChar(byte: u8) bool {
    return ascii_name_start_table[byte];
}

/// ASCII subset of `NameChar`.
pub inline fn isAsciiNameChar(byte: u8) bool {
    return ascii_name_table[byte];
}

pub const NameError = error{
    EmptyName,
    InvalidStart,
    InvalidChar,
    InvalidUtf8,
};

/// Validate a complete XML `Name`.
pub fn validateName(name: []const u8) NameError!void {
    if (name.len == 0) return error.EmptyName;
    const first_len = try codepointLength(name, 0);
    if (first_len == 1) {
        if (!isAsciiNameStartChar(name[0])) return error.InvalidStart;
    } else {
        const cp = std.unicode.utf8Decode(name[0..first_len]) catch
            return error.InvalidUtf8;
        if (!isNameStartChar(cp)) return error.InvalidStart;
    }

    var index = first_len;
    while (index < name.len) {
        const byte = name[index];
        if (byte < 0x80) {
            if (!isAsciiNameChar(byte)) return error.InvalidChar;
            index += 1;
            continue;
        }
        const len = try codepointLength(name, index);
        const cp = std.unicode.utf8Decode(name[index..][0..len]) catch
            return error.InvalidUtf8;
        if (!isNameChar(cp)) return error.InvalidChar;
        index += len;
    }
}

/// Validate an XML `Nmtoken` (one or more `NameChar`s).
pub fn validateNmtoken(name: []const u8) NameError!void {
    if (name.len == 0) return error.EmptyName;
    var index: usize = 0;
    while (index < name.len) {
        const byte = name[index];
        if (byte < 0x80) {
            if (!isAsciiNameChar(byte)) return error.InvalidChar;
            index += 1;
            continue;
        }
        const len = try codepointLength(name, index);
        const cp = std.unicode.utf8Decode(name[index..][0..len]) catch
            return error.InvalidUtf8;
        if (!isNameChar(cp)) return error.InvalidChar;
        index += len;
    }
}

/// Validate an XML `NCName` (a `Name` with no colon).
pub fn validateNCName(name: []const u8) NameError!void {
    if (name.len == 0) return error.EmptyName;
    const first_len = try codepointLength(name, 0);
    if (first_len == 1) {
        if (name[0] == ':' or !isAsciiNameStartChar(name[0])) {
            return error.InvalidStart;
        }
    } else {
        const cp = std.unicode.utf8Decode(name[0..first_len]) catch
            return error.InvalidUtf8;
        if (!isNCNameStartChar(cp)) return error.InvalidStart;
    }

    var index = first_len;
    while (index < name.len) {
        const byte = name[index];
        if (byte < 0x80) {
            if (byte == ':' or !isAsciiNameChar(byte)) return error.InvalidChar;
            index += 1;
            continue;
        }
        const len = try codepointLength(name, index);
        const cp = std.unicode.utf8Decode(name[index..][0..len]) catch
            return error.InvalidUtf8;
        if (!isNCNameChar(cp)) return error.InvalidChar;
        index += len;
    }
}

pub fn isName(name: []const u8) bool {
    validateName(name) catch return false;
    return true;
}

pub fn isNmtoken(name: []const u8) bool {
    validateNmtoken(name) catch return false;
    return true;
}

pub fn isNCName(name: []const u8) bool {
    validateNCName(name) catch return false;
    return true;
}

fn codepointLength(bytes: []const u8, index: usize) NameError!usize {
    const len = std.unicode.utf8ByteSequenceLength(bytes[index]) catch
        return error.InvalidUtf8;
    if (index + len > bytes.len) return error.InvalidUtf8;
    return len;
}

pub const NameInfo = struct {
    len: usize,
    /// Byte offset of the first colon, or 0xFFFF when absent.
    colon: u16 = 0xFFFF,
};

/// Scan the longest valid XML `Name` prefix and remember the first colon.
pub inline fn scanNameInfo(bytes: []const u8) NameInfo {
    var info: NameInfo = .{ .len = 0 };
    if (bytes.len == 0) return info;
    var index: usize = 0;
    const first = bytes[0];
    if (first < 0x80) {
        if (!isAsciiNameStartChar(first)) return info;
        if (first == ':') info.colon = 0;
        index = 1;
    } else {
        const first_len = codepointLength(bytes, 0) catch return info;
        const cp = std.unicode.utf8Decode(bytes[0..first_len]) catch return info;
        if (!isNameStartChar(cp)) return info;
        index = first_len;
    }

    // ASCII names dominate markup, so classify sixteen bytes at a time and
    // fall back to the scalar UTF-8 loop at the first high byte. The first
    // colon is tracked from the same masks instead of a second pass.
    const Vec = @Vector(16, u8);
    const lower_a: Vec = @splat('a');
    const lower_z: Vec = @splat('z');
    const digit_0: Vec = @splat('0');
    const digit_9: Vec = @splat('9');
    const underscore: Vec = @splat('_');
    const dash: Vec = @splat('-');
    const dot: Vec = @splat('.');
    const colon_char: Vec = @splat(':');
    while (index + 16 <= bytes.len) {
        const chunk: Vec = bytes[index..][0..16].*;
        const folded = chunk | @as(Vec, @splat(0x20));
        const alpha = (folded >= lower_a) & (folded <= lower_z);
        const digit = (chunk >= digit_0) & (chunk <= digit_9);
        const valid = alpha | digit | (chunk == underscore) |
            (chunk == dash) | (chunk == dot) | (chunk == colon_char);
        const invalid: u16 = ~@as(u16, @bitCast(valid));
        const stop: usize = @ctz(invalid);
        if (info.colon == 0xFFFF) {
            const colons: u16 = @bitCast(chunk == colon_char);
            if (colons != 0) {
                const offset = @ctz(colons);
                if (offset < stop and index + offset < 0xFFFF) {
                    info.colon = @intCast(index + offset);
                }
            }
        }
        if (invalid != 0) {
            index += stop;
            break;
        }
        index += 16;
    }

    while (index < bytes.len) {
        const byte = bytes[index];
        if (byte < 0x80) {
            if (!isAsciiNameChar(byte)) break;
            if (byte == ':' and info.colon == 0xFFFF and index < 0xFFFF) {
                info.colon = @intCast(index);
            }
            index += 1;
            continue;
        }
        const len = codepointLength(bytes, index) catch break;
        const cp = std.unicode.utf8Decode(bytes[index..][0..len]) catch break;
        if (!isNameChar(cp)) break;
        index += len;
    }
    info.len = index;
    return info;
}

/// Fast name scan for trusted, already-well-formed input. Stops at markup
/// delimiters and records the first colon. Non-ASCII bytes are treated as name
/// bytes; the caller has promised valid UTF-8 names.
pub fn scanNameInfoFast(bytes: []const u8) NameInfo {
    var info: NameInfo = .{ .len = 0 };
    var index: usize = 0;
    while (index < bytes.len) : (index += 1) {
        const byte = bytes[index];
        switch (byte) {
            ' ',
            '\t',
            '\r',
            '\n',
            '/',
            '>',
            '=',
            '\'',
            '"',
            '<',
            '&',
            '[',
            ']',
            '(',
            ')',
            '?',
            '!',
            => break,
            ':' => {
                if (info.colon == 0xFFFF and index < 0xFFFF) {
                    info.colon = @intCast(index);
                }
            },
            else => {},
        }
    }
    info.len = index;
    return info;
}

/// Scan the longest valid XML `Name` prefix. Returns 0 when the first byte
/// cannot start a name.
pub fn scanName(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    var index: usize = 0;
    const first = bytes[0];
    if (first < 0x80) {
        if (!isAsciiNameStartChar(first)) return 0;
        index = 1;
    } else {
        const first_len = codepointLength(bytes, 0) catch return 0;
        const cp = std.unicode.utf8Decode(bytes[0..first_len]) catch return 0;
        if (!isNameStartChar(cp)) return 0;
        index = first_len;
    }
    while (index < bytes.len) {
        const byte = bytes[index];
        if (byte < 0x80) {
            if (!isAsciiNameChar(byte)) break;
            index += 1;
            continue;
        }
        const len = codepointLength(bytes, index) catch break;
        const cp = std.unicode.utf8Decode(bytes[index..][0..len]) catch break;
        if (!isNameChar(cp)) break;
        index += len;
    }
    return index;
}

/// Scan the longest valid XML `Nmtoken` prefix. Returns 0 when no name
/// character is present.
pub fn scanNmtoken(bytes: []const u8) usize {
    var index: usize = 0;
    while (index < bytes.len) {
        const byte = bytes[index];
        if (byte < 0x80) {
            if (!isAsciiNameChar(byte)) break;
            index += 1;
            continue;
        }
        const len = codepointLength(bytes, index) catch break;
        const cp = std.unicode.utf8Decode(bytes[index..][0..len]) catch break;
        if (!isNameChar(cp)) break;
        index += len;
    }
    return index;
}

/// Validate a run of literal character data. For XML 1.1 this rejects
/// restricted characters, which are only permitted through character
/// references.
pub inline fn findInvalidLiteralCharVersion(
    bytes: []const u8,
    version: Version,
) ?usize {
    var index: usize = 0;
    // ASCII control bytes are the only invalid characters in an ASCII run.
    // Check sixteen at a time and fall back to UTF-8 decoding at the first
    // high byte.
    const Vec = @Vector(16, u8);
    const ctrl: Vec = @splat(0x20);
    const tab: Vec = @splat('\t');
    const lf: Vec = @splat('\n');
    const cr: Vec = @splat('\r');
    const del: Vec = @splat(0x7F);
    const high: Vec = @splat(0x80);
    while (index + 16 <= bytes.len) {
        const chunk: Vec = bytes[index..][0..16].*;
        var mask: u16 = @bitCast(chunk < ctrl);
        mask &= ~@as(u16, @bitCast(
            (chunk == tab) | (chunk == lf) | (chunk == cr),
        ));
        if (version == .xml_1_1) {
            mask |= @bitCast(chunk == del);
        }
        const high_mask: u16 = @bitCast(chunk >= high);
        if (mask != 0 and (high_mask == 0 or @ctz(mask) < @ctz(high_mask))) {
            return index + @ctz(mask);
        }
        if (high_mask != 0) {
            index += @ctz(high_mask);
            break;
        }
        index += 16;
    }
    while (index < bytes.len) {
        const byte = bytes[index];
        if (byte < 0x80) {
            if (byte == '\t' or byte == '\n' or byte == '\r') {
                index += 1;
                continue;
            }
            if (byte >= 0x20 and !(version == .xml_1_1 and byte == 0x7F)) {
                index += 1;
                continue;
            }
            return index;
        }
        const len = codepointLength(bytes, index) catch return index;
        const cp = std.unicode.utf8Decode(bytes[index..][0..len]) catch
            return index;
        if (!isXmlCharVersion(cp, version)) return index;
        if (version == .xml_1_1 and isRestrictedChar11(cp)) return index;
        index += len;
    }
    return null;
}

/// Validate XML 1.0 literal character data.
pub fn findInvalidXmlChar(bytes: []const u8) ?usize {
    return findInvalidLiteralCharVersion(bytes, .xml_1_0);
}

/// Decode a decimal character reference body (`#123`). Returns null for an
/// empty, malformed, or out-of-range value.
pub fn parseDecimalCharRefVersion(
    body: []const u8,
    version: Version,
) ?u21 {
    if (body.len == 0) return null;
    var value: u32 = 0;
    for (body) |byte| {
        if (byte < '0' or byte > '9') return null;
        value = value * 10 + (byte - '0');
        if (value > 0x10FFFF) return null;
    }
    if (!isXmlCharVersion(@intCast(value), version)) return null;
    return @intCast(value);
}

pub fn parseDecimalCharRef(body: []const u8) ?u21 {
    return parseDecimalCharRefVersion(body, .xml_1_0);
}

/// Decode a hexadecimal character reference body (`#x1F600`). The `x` may be
/// upper or lower case. Returns null for malformed or out-of-range values.
pub fn parseHexCharRefVersion(
    body: []const u8,
    version: Version,
) ?u21 {
    if (body.len < 2) return null;
    if (body[0] != 'x') return null;
    const digits = body[1..];
    var value: u32 = 0;
    for (digits) |byte| {
        const digit: u32 = switch (byte) {
            '0'...'9' => byte - '0',
            'a'...'f' => byte - 'a' + 10,
            'A'...'F' => byte - 'A' + 10,
            else => return null,
        };
        value = value * 16 + digit;
        if (value > 0x10FFFF) return null;
    }
    if (!isXmlCharVersion(@intCast(value), version)) return null;
    return @intCast(value);
}

pub fn parseHexCharRef(body: []const u8) ?u21 {
    return parseHexCharRefVersion(body, .xml_1_0);
}

/// Encode one code point into `buffer`, returning the used slice.
pub fn encodeUtf8(buffer: *[4]u8, cp: u21) []const u8 {
    const len = std.unicode.utf8Encode(cp, buffer) catch unreachable;
    return buffer[0..len];
}

test "XML character production boundaries" {
    try std.testing.expect(isXmlChar(0x9));
    try std.testing.expect(isXmlChar(0xA));
    try std.testing.expect(isXmlChar(0xD));
    try std.testing.expect(!isXmlChar(0x0));
    try std.testing.expect(!isXmlChar(0xB));
    try std.testing.expect(!isXmlChar(0x1F));
    try std.testing.expect(isXmlChar(0x20));
    try std.testing.expect(isXmlChar(0xD7FF));
    try std.testing.expect(!isXmlChar(0xD800));
    try std.testing.expect(!isXmlChar(0xDFFF));
    try std.testing.expect(isXmlChar(0xE000));
    try std.testing.expect(isXmlChar(0xFFFD));
    try std.testing.expect(!isXmlChar(0xFFFE));
    try std.testing.expect(!isXmlChar(0xFFFF));
    try std.testing.expect(isXmlChar(0x10000));
    try std.testing.expect(isXmlChar(0x10FFFF));
}

test "XML name productions cover ASCII and Unicode ranges" {
    try std.testing.expect(isName("svg"));
    try std.testing.expect(isName("_x"));
    try std.testing.expect(isName(":x"));
    try std.testing.expect(isName("x:y"));
    try std.testing.expect(isName("x-y.z"));
    try std.testing.expect(isName("é"));
    try std.testing.expect(isName("日本語"));
    try std.testing.expect(isName("a\u{0301}"));
    try std.testing.expect(!isName(""));
    try std.testing.expect(!isName("1x"));
    try std.testing.expect(!isName("-x"));
    try std.testing.expect(!isName(".x"));
    try std.testing.expect(!isName("x y"));
    try std.testing.expect(isName("x\u{00B7}"));
    try std.testing.expect(!isName("\u{00B7}x"));
    try std.testing.expect(isName("x\u{00B7}y"));
    try std.testing.expect(!isName("\u{037E}"));
    try std.testing.expect(!isName("x\u{FFFE}"));
    try std.testing.expect(!isName("\xFF"));
}

test "NCName validation rejects colons" {
    try std.testing.expect(isName("a:b"));
    try validateNCName("abc");
    try validateNCName("_x-y.1");
    try validateNCName("é");
    try std.testing.expectError(error.InvalidChar, validateNCName("a:b"));
    try std.testing.expectError(error.InvalidStart, validateNCName(":a"));
    try std.testing.expectError(error.InvalidChar, validateNCName("a:"));
    try std.testing.expectError(error.EmptyName, validateNCName(""));
}

test "name scanner stops at the first invalid byte" {
    try std.testing.expectEqual(@as(usize, 3), scanName("abc def"));
    try std.testing.expectEqual(@as(usize, 0), scanName("1abc"));
    try std.testing.expectEqual(@as(usize, 0), scanName(""));
    try std.testing.expectEqual(@as(usize, 6), scanName("a:b-c."));
    try std.testing.expectEqual(@as(usize, 3), scanName("é1"));
    try std.testing.expectEqual(@as(usize, 6), scanName("日本"));
}

test "XML 1.1 literal and reference character rules differ" {
    try std.testing.expect(findInvalidLiteralCharVersion("a\x01b", .xml_1_0) != null);
    try std.testing.expect(findInvalidLiteralCharVersion("a\x01b", .xml_1_1) != null);
    try std.testing.expect(findInvalidLiteralCharVersion("a\x7Fb", .xml_1_0) == null);
    try std.testing.expect(findInvalidLiteralCharVersion("a\x7Fb", .xml_1_1) != null);
    // U+0085 is a line end in XML 1.1 and is not restricted.
    try std.testing.expect(findInvalidLiteralCharVersion("\xC2\x85", .xml_1_1) == null);
    // U+0086 is restricted.
    try std.testing.expect(findInvalidLiteralCharVersion("\xC2\x86", .xml_1_1) != null);
    try std.testing.expectEqual(@as(?u21, 1), parseDecimalCharRefVersion("1", .xml_1_1));
    try std.testing.expect(parseDecimalCharRefVersion("1", .xml_1_0) == null);
    try std.testing.expectEqual(@as(?u21, 0x85), parseHexCharRefVersion("x85", .xml_1_1));
}

test "character data validation rejects control and surrogate bytes" {
    try std.testing.expect(findInvalidXmlChar("plain text\t\n\r") == null);
    try std.testing.expectEqual(@as(?usize, 1), findInvalidXmlChar("a\x00b"));
    try std.testing.expect(findInvalidXmlChar("\x7F") == null);
    try std.testing.expectEqual(@as(?usize, 2), findInvalidXmlChar("ok\xFF"));
    // U+FFFE encoded as EF BF BE.
    try std.testing.expectEqual(@as(?usize, 0), findInvalidXmlChar("\xEF\xBF\xBE"));
    // Valid astral code point.
    try std.testing.expect(findInvalidXmlChar("😀") == null);
}

test "character reference parsing" {
    try std.testing.expectEqual(@as(?u21, 'A'), parseDecimalCharRef("65"));
    try std.testing.expectEqual(@as(?u21, 'A'), parseHexCharRef("x41"));
    try std.testing.expect(parseHexCharRef("X1F600") == null);
    try std.testing.expect(parseDecimalCharRef("") == null);
    try std.testing.expect(parseDecimalCharRef("0") == null);
    try std.testing.expect(parseDecimalCharRef("1x") == null);
    try std.testing.expect(parseHexCharRef("x") == null);
    try std.testing.expect(parseHexCharRef("x110000") == null);
    try std.testing.expect(parseHexCharRef("xD800") == null);
}
