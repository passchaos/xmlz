//! XPath 1.0 lexer.

const std = @import("std");
const chars = @import("../chars.zig");

pub const Error = error{
    InvalidExpression,
    UnexpectedEndOfInput,
};

pub const Tag = enum {
    eof,
    name,
    number,
    literal,
    variable,
    slash,
    double_slash,
    dot,
    dot_dot,
    at,
    double_colon,
    lparen,
    rparen,
    lbracket,
    rbracket,
    comma,
    pipe,
    plus,
    minus,
    star,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
};

pub const Token = struct {
    tag: Tag,
    text: []const u8 = "",
    number: f64 = 0,
    offset: usize = 0,
};

pub const Lexer = struct {
    source: []const u8,
    pos: usize = 0,

    pub fn init(source: []const u8) Lexer {
        return .{ .source = source };
    }

    pub fn next(self: *Lexer) Error!Token {
        while (self.pos < self.source.len and
            chars.isWhitespace(self.source[self.pos]))
        {
            self.pos += 1;
        }
        const start = self.pos;
        if (start >= self.source.len) return .{ .tag = .eof, .offset = start };

        const byte = self.source[self.pos];
        switch (byte) {
            '/' => {
                if (self.peekByte(1) == '/') {
                    self.pos += 2;
                    return .{ .tag = .double_slash, .offset = start };
                }
                self.pos += 1;
                return .{ .tag = .slash, .offset = start };
            },
            '.' => {
                if (self.peekByte(1) == '.') {
                    self.pos += 2;
                    return .{ .tag = .dot_dot, .offset = start };
                }
                if (std.ascii.isDigit(self.peekByte(1))) {
                    return self.scanNumber();
                }
                self.pos += 1;
                return .{ .tag = .dot, .offset = start };
            },
            '@' => {
                self.pos += 1;
                return .{ .tag = .at, .offset = start };
            },
            '(' => {
                self.pos += 1;
                return .{ .tag = .lparen, .offset = start };
            },
            ')' => {
                self.pos += 1;
                return .{ .tag = .rparen, .offset = start };
            },
            '[' => {
                self.pos += 1;
                return .{ .tag = .lbracket, .offset = start };
            },
            ']' => {
                self.pos += 1;
                return .{ .tag = .rbracket, .offset = start };
            },
            ',' => {
                self.pos += 1;
                return .{ .tag = .comma, .offset = start };
            },
            '|' => {
                self.pos += 1;
                return .{ .tag = .pipe, .offset = start };
            },
            '+' => {
                self.pos += 1;
                return .{ .tag = .plus, .offset = start };
            },
            '-' => {
                self.pos += 1;
                return .{ .tag = .minus, .offset = start };
            },
            '*' => {
                self.pos += 1;
                return .{ .tag = .star, .offset = start };
            },
            '=' => {
                self.pos += 1;
                return .{ .tag = .eq, .offset = start };
            },
            '!' => {
                if (self.peekByte(1) == '=') {
                    self.pos += 2;
                    return .{ .tag = .ne, .offset = start };
                }
                return error.InvalidExpression;
            },
            '<' => {
                if (self.peekByte(1) == '=') {
                    self.pos += 2;
                    return .{ .tag = .le, .offset = start };
                }
                self.pos += 1;
                return .{ .tag = .lt, .offset = start };
            },
            '>' => {
                if (self.peekByte(1) == '=') {
                    self.pos += 2;
                    return .{ .tag = .ge, .offset = start };
                }
                self.pos += 1;
                return .{ .tag = .gt, .offset = start };
            },
            ':' => {
                if (self.peekByte(1) == ':') {
                    self.pos += 2;
                    return .{ .tag = .double_colon, .offset = start };
                }
                return error.InvalidExpression;
            },
            '\'', '"' => return self.scanLiteral(byte),
            '$' => {
                self.pos += 1;
                const name_len = chars.scanName(self.source[self.pos..]);
                if (name_len == 0) return error.InvalidExpression;
                const name = self.source[self.pos .. self.pos + name_len];
                self.pos += name_len;
                return .{ .tag = .variable, .text = name, .offset = start };
            },
            '0'...'9' => return self.scanNumber(),
            else => {},
        }

        if (std.ascii.isDigit(byte) or byte == '.') return self.scanNumber();
        const full_len = chars.scanName(self.source[self.pos..]);
        if (full_len == 0) return error.InvalidExpression;
        var name_len = full_len;
        if (std.mem.indexOfScalar(u8, self.source[self.pos .. self.pos + full_len], ':')) |colon| {
            if (colon == 0) return error.InvalidExpression;
            // `axis::` is an axis name followed by the `::` operator, not a
            // QName whose local part begins with a colon.
            if (colon + 1 < full_len and self.source[self.pos + colon + 1] == ':') {
                name_len = colon;
            }
        }
        if (name_len == full_len and name_len > 0 and
            self.source[self.pos + name_len - 1] == ':' and
            self.pos + name_len < self.source.len and
            self.source[self.pos + name_len] == '*')
        {
            name_len += 1;
        }
        const name = self.source[self.pos .. self.pos + name_len];
        self.pos += name_len;
        return .{ .tag = .name, .text = name, .offset = start };
    }

    fn peekByte(self: *const Lexer, offset: usize) u8 {
        const index = self.pos + offset;
        return if (index < self.source.len) self.source[index] else 0;
    }

    fn scanNumber(self: *Lexer) Error!Token {
        const start = self.pos;
        var digits: usize = 0;
        while (self.pos < self.source.len and
            std.ascii.isDigit(self.source[self.pos]))
        {
            self.pos += 1;
            digits += 1;
        }
        if (self.pos < self.source.len and self.source[self.pos] == '.') {
            self.pos += 1;
            while (self.pos < self.source.len and
                std.ascii.isDigit(self.source[self.pos]))
            {
                self.pos += 1;
                digits += 1;
            }
        }
        if (digits == 0) return error.InvalidExpression;
        const text = self.source[start..self.pos];
        const value = std.fmt.parseFloat(f64, text) catch
            return error.InvalidExpression;
        return .{ .tag = .number, .text = text, .number = value, .offset = start };
    }

    fn scanLiteral(self: *Lexer, quote: u8) Error!Token {
        const start = self.pos;
        self.pos += 1;
        const value_start = self.pos;
        while (self.pos < self.source.len and self.source[self.pos] != quote) {
            self.pos += 1;
        }
        if (self.pos >= self.source.len) return error.UnexpectedEndOfInput;
        const value = self.source[value_start..self.pos];
        self.pos += 1;
        return .{ .tag = .literal, .text = value, .offset = start };
    }
};

test "XPath lexer tokenizes paths operators and literals" {
    var lexer = Lexer.init("//a/b[@x='v' and position() >= 2] | $v");
    const expected = [_]Tag{
        .double_slash, .name,     .slash, .name,     .lbracket, .at,     .name,
        .eq,           .literal,  .name,  .name,     .lparen,   .rparen, .ge,
        .number,       .rbracket, .pipe,  .variable,
    };
    for (expected) |tag| {
        const token = try lexer.next();
        try std.testing.expectEqual(tag, token.tag);
    }
    try std.testing.expectEqual(Tag.eof, (try lexer.next()).tag);
}

test "XPath lexer distinguishes names from subtraction" {
    var lexer = Lexer.init("foo-bar foo - bar .5 .. .");
    try std.testing.expectEqualStrings("foo-bar", (try lexer.next()).text);
    try std.testing.expectEqualStrings("foo", (try lexer.next()).text);
    try std.testing.expectEqual(Tag.minus, (try lexer.next()).tag);
    try std.testing.expectEqualStrings("bar", (try lexer.next()).text);
    try std.testing.expectEqual(@as(f64, 0.5), (try lexer.next()).number);
    try std.testing.expectEqual(Tag.dot_dot, (try lexer.next()).tag);
    try std.testing.expectEqual(Tag.dot, (try lexer.next()).tag);
}
