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

/// Byte classes for the hot name scanners.
const NameClass = struct {
    /// Not a name character: the name ends here.
    const stop: u8 = 0;
    /// Ordinary name character.
    const name: u8 = 1;
    /// The namespace separator.
    const colon: u8 = 2;
    /// A byte at or above 0x80: a UTF-8 lead or continuation byte.
    const high: u8 = 3;
};

/// Validating `NameChar` classes, including high bytes so the scanner needs
/// no separate range test.
const name_class_table: [256]u8 = blk: {
    var table: [256]u8 = @splat(NameClass.stop);
    for ('A'..'Z' + 1) |byte| table[byte] = NameClass.name;
    for ('a'..'z' + 1) |byte| table[byte] = NameClass.name;
    for ('0'..'9' + 1) |byte| table[byte] = NameClass.name;
    table['_'] = NameClass.name;
    table['-'] = NameClass.name;
    table['.'] = NameClass.name;
    table[':'] = NameClass.colon;
    for (0x80..0x100) |byte| table[byte] = NameClass.high;
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
    /// Byte that ended the scan (the first non-name byte), or zero at end of
    /// input. Callers use it to avoid reloading the delimiter.
    stop: u8 = 0,
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

    // Markup names are short: a table lookup per byte beats the sixteen-byte
    // vector classifier, whose constant setup and mask chain cost more than
    // the handful of scalar iterations they replace. Only names longer than
    // the scalar prefix, which are rare, reach the vector loop.
    const prefix_end = @min(bytes.len, index + 16);
    while (index < prefix_end) : (index += 1) {
        const class = name_class_table[bytes[index]];
        if (class == NameClass.name) continue;
        if (class == NameClass.colon) {
            if (info.colon == 0xFFFF and index < 0xFFFF) {
                info.colon = @intCast(index);
            }
            continue;
        }
        if (class == NameClass.stop) {
            info.len = index;
            info.stop = bytes[index];
            return info;
        }
        break;
    }

    // Classify sixteen bytes at a time for long ASCII names, falling back to
    // the scalar UTF-8 loop at the first high byte. The first colon is
    // tracked from the same masks instead of a second pass.
    if (index == prefix_end and prefix_end < bytes.len) {
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
    }

    while (index < bytes.len) {
        const byte = bytes[index];
        if (byte < 0x80) {
            if (!isAsciiNameChar(byte)) {
                info.stop = byte;
                break;
            }
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
pub inline fn scanNameInfoFast(bytes: []const u8) NameInfo {
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
            => {
                info.stop = byte;
                break;
            },
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

/// Decode one UTF-8 sequence starting at `index` (whose first byte is at or
/// above 0x80) and check it against the XML character rules. Returns the
/// sequence length, or null when it is malformed or not an XML character.
pub inline fn xmlCodepointLength(
    bytes: []const u8,
    index: usize,
    version: Version,
) ?usize {
    const byte = bytes[index];
    if (byte < 0xC2) return null; // continuation byte or overlong lead
    if (byte < 0xE0) {
        if (index + 2 > bytes.len) return null;
        const b1 = bytes[index + 1];
        if (b1 & 0xC0 != 0x80) return null;
        // Two-byte sequences are always XML characters; only XML 1.1
        // restricts some of them.
        if (version == .xml_1_1) {
            const cp: u21 = (@as(u21, byte & 0x1F) << 6) | (b1 & 0x3F);
            if (isRestrictedChar11(cp)) return null;
        }
        return 2;
    }
    if (byte < 0xF0) {
        if (index + 3 > bytes.len) return null;
        const b1 = bytes[index + 1];
        const b2 = bytes[index + 2];
        if ((b1 | b2) & 0xC0 != 0x80) return null;
        // Leads E4..E9 cover U+4000..U+9FFF, which is always valid.
        if (byte >= 0xE4 and byte <= 0xE9) return 3;
        const cp: u21 = (@as(u21, byte & 0x0F) << 12) |
            (@as(u21, b1 & 0x3F) << 6) | (b2 & 0x3F);
        if (cp < 0x800) return null; // overlong
        if (cp >= 0xD800 and cp <= 0xDFFF) return null; // surrogate
        if (cp > 0xFFFD) return null; // U+FFFE and U+FFFF
        return 3;
    }
    if (byte < 0xF5) {
        if (index + 4 > bytes.len) return null;
        const b1 = bytes[index + 1];
        const b2 = bytes[index + 2];
        const b3 = bytes[index + 3];
        if ((b1 | b2 | b3) & 0xC0 != 0x80) return null;
        // F0 needs a high continuation byte to stay above the overlong
        // range; F1..F3 are always valid; F4 caps the code point.
        if (byte == 0xF0) return if (b1 >= 0x90) 4 else null;
        if (byte < 0xF4) return 4;
        const cp: u21 = (@as(u21, byte & 0x07) << 18) |
            (@as(u21, b1 & 0x3F) << 12) | (@as(u21, b2 & 0x3F) << 6) |
            (b3 & 0x3F);
        if (cp < 0x10000 or cp > 0x10FFFF) return null;
        return 4;
    }
    return null;
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
    // high byte. The vector check also runs after a decoded code point, so
    // ASCII runs embedded in mixed text (digits and markup words between CJK
    // characters) skip a block at a time instead of byte by byte.
    const Vec = @Vector(16, u8);
    const ctrl: Vec = @splat(0x20);
    const tab: Vec = @splat('\t');
    const lf: Vec = @splat('\n');
    const cr: Vec = @splat('\r');
    const del: Vec = @splat(0x7F);
    const high: Vec = @splat(0x80);
    while (index < bytes.len) {
        if (index + 16 <= bytes.len and bytes[index] < 0x80) {
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
            if (high_mask == 0) {
                index += 16;
                continue;
            }
            index += @ctz(high_mask);
            continue;
        }
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
        // Fast path: four 3-byte sequences with leads E1..EC, whose code
        // points are always valid XML characters once the continuation bytes
        // check out. (ED covers the surrogate range and EF covers U+FFFE and
        // U+FFFF, so both stay on the scalar path.) Any deviation falls back
        // to the scalar decoder, which also reports the exact bad index.
        if (index + 16 <= bytes.len and byte >= 0xE1 and byte <= 0xEC) {
            const Wide = @Vector(16, u8);
            const chunk: Wide = bytes[index..][0..16].*;
            const cont: u16 = @bitCast(
                (chunk & @as(Wide, @splat(0xC0))) ==
                    @as(Wide, @splat(0x80)),
            );
            const leads: u16 = @bitCast(
                (chunk >= @as(Wide, @splat(0xE1))) &
                    (chunk <= @as(Wide, @splat(0xEC))),
            );
            if ((cont & 0x0DB6) == 0x0DB6 and
                (leads & 0x0249) == 0x0249)
            {
                index += 12;
                continue;
            }
        }
        const len = xmlCodepointLength(bytes, index, version) orelse
            return index;
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

test "name info scanner handles short, long, and non-ASCII names" {
    const short = scanNameInfo("id=value");
    try std.testing.expectEqual(@as(usize, 2), short.len);
    try std.testing.expectEqual(@as(u16, 0xFFFF), short.colon);

    const prefixed = scanNameInfo("xlink:href>");
    try std.testing.expectEqual(@as(usize, 10), prefixed.len);
    try std.testing.expectEqual(@as(u16, 5), prefixed.colon);

    // Longer than the scalar prefix, so the vector classifier finishes it.
    const long = scanNameInfo("very-long-element-name/");
    try std.testing.expectEqual(@as(usize, 22), long.len);
    try std.testing.expectEqual(@as(u16, 0xFFFF), long.colon);

    const long_prefixed = scanNameInfo("a-very-long-prefix:local-name ");
    try std.testing.expectEqual(@as(usize, 29), long_prefixed.len);
    try std.testing.expectEqual(@as(u16, 18), long_prefixed.colon);

    // A colon after the vector classifier has started.
    const late_colon = scanNameInfo("sixteen-bytes-ab:cd ");
    try std.testing.expectEqual(@as(usize, 19), late_colon.len);
    try std.testing.expectEqual(@as(u16, 16), late_colon.colon);

    const utf8 = scanNameInfo("日本:語");
    try std.testing.expectEqual(@as(usize, 10), utf8.len);
    try std.testing.expectEqual(@as(u16, 6), utf8.colon);

    try std.testing.expectEqual(@as(usize, 0), scanNameInfo("").len);
    try std.testing.expectEqual(@as(usize, 0), scanNameInfo("9abc").len);
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

test "literal validation covers UTF-8 boundaries" {
    // Mixed ASCII and multi-byte runs, longer than one vector window.
    try std.testing.expect(findInvalidXmlChar(
        "段落文本内容示例数据0，包含中文与 ASCII 混合 text",
    ) == null);
    try std.testing.expect(findInvalidXmlChar("é") == null);
    try std.testing.expect(findInvalidXmlChar("\u{10FFFF}") == null);
    try std.testing.expect(findInvalidXmlChar("\u{10000}") == null);

    // Overlong two-byte lead.
    try std.testing.expectEqual(@as(?usize, 0), findInvalidXmlChar("\xC0\xAF"));
    // Overlong three-byte sequence (E0 80 80).
    try std.testing.expectEqual(@as(?usize, 0), findInvalidXmlChar("\xE0\x80\x80"));
    // Surrogate half (ED A0 80).
    try std.testing.expectEqual(@as(?usize, 0), findInvalidXmlChar("\xED\xA0\x80"));
    // U+FFFF (EF BF BF).
    try std.testing.expectEqual(@as(?usize, 0), findInvalidXmlChar("\xEF\xBF\xBF"));
    // Overlong four-byte sequence (F0 80 80 80).
    try std.testing.expectEqual(@as(?usize, 0), findInvalidXmlChar("\xF0\x80\x80\x80"));
    // Code point above U+10FFFF (F4 90 80 80).
    try std.testing.expectEqual(@as(?usize, 0), findInvalidXmlChar("\xF4\x90\x80\x80"));
    // Lead bytes above F4 are invalid.
    try std.testing.expectEqual(@as(?usize, 0), findInvalidXmlChar("\xF5\x80\x80\x80"));
    // A bare continuation byte.
    try std.testing.expectEqual(@as(?usize, 3), findInvalidXmlChar("abc\x80"));
    // Missing continuation.
    try std.testing.expectEqual(@as(?usize, 0), findInvalidXmlChar("\xE4\xB8" ++ "A"));
    // Truncated sequence at end of input.
    try std.testing.expectEqual(@as(?usize, 0), findInvalidXmlChar("\xE4\xB8"));
    // Errors after a valid multi-byte prefix report the sequence start.
    try std.testing.expectEqual(@as(?usize, 6), findInvalidXmlChar("中文\xED\xA0\x80"));
    // A control byte inside a mixed run.
    try std.testing.expectEqual(@as(?usize, 6), findInvalidXmlChar("中文\x01abc"));
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

/// Find `needle` in `bytes` starting at `start`. Entity reference names are
/// short, so scan the first eight bytes inline before falling back to the
/// vectorized search; longer scalar prefixes lose to the vector path when the
/// needle sits deep in a text span.
pub inline fn findByteSoon(bytes: []const u8, start: usize, needle: u8) ?usize {
    var index = start;
    const limit = @min(bytes.len, start + 8);
    while (index < limit) : (index += 1) {
        if (bytes[index] == needle) return index;
    }
    if (index < bytes.len) {
        return std.mem.indexOfScalarPos(u8, bytes, index, needle);
    }
    return null;
}

test "xmlCodepointLength enforces the UTF-8 and XML boundaries" {
    const cases = [_]struct { bytes: []const u8, ok: bool }{
        .{ .bytes = "\xE1\x80\x80", .ok = true }, // U+1000
        .{ .bytes = "\xE4\xB8\xAD", .ok = true }, // U+4E2D
        .{ .bytes = "\xE9\xBF\xBF", .ok = true }, // U+9FFF
        .{ .bytes = "\xEC\xBF\xBF", .ok = true }, // U+CFFF
        .{ .bytes = "\xED\x9F\xBF", .ok = true }, // U+D7FF
        .{ .bytes = "\xEE\x80\x80", .ok = true }, // U+E000
        .{ .bytes = "\xEF\xBF\xBD", .ok = true }, // U+FFFD
        .{ .bytes = "\xF0\x90\x80\x80", .ok = true }, // U+10000
        .{ .bytes = "\xF4\x8F\xBF\xBF", .ok = true }, // U+10FFFF
        .{ .bytes = "\xED\xA0\x80", .ok = false }, // U+D800 surrogate
        .{ .bytes = "\xED\xBF\xBF", .ok = false }, // U+DFFF surrogate
        .{ .bytes = "\xEF\xBF\xBE", .ok = false }, // U+FFFE
        .{ .bytes = "\xEF\xBF\xBF", .ok = false }, // U+FFFF
        .{ .bytes = "\xE0\x9F\xBF", .ok = false }, // overlong three-byte
        .{ .bytes = "\xF0\x8F\xBF\xBF", .ok = false }, // overlong four-byte
        .{ .bytes = "\xF4\x90\x80\x80", .ok = false }, // above U+10FFFF
        .{ .bytes = "\xC0\x80", .ok = false }, // overlong two-byte
        .{ .bytes = "\xE4\xB8", .ok = false }, // truncated
    };
    for (cases) |case| {
        const length = xmlCodepointLength(case.bytes, 0, .xml_1_0);
        try std.testing.expectEqual(case.ok, length != null);
        if (length) |len| try std.testing.expectEqual(case.bytes.len, len);
    }
}
