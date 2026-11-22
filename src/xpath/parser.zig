//! XPath 1.0 recursive-descent parser.

const std = @import("std");
const ast = @import("ast.zig");
const lexer_mod = @import("lexer.zig");

pub const Error = error{
    OutOfMemory,
    InvalidExpression,
    UnexpectedEndOfInput,
};

pub const Token = lexer_mod.Token;
pub const Tag = lexer_mod.Tag;

pub const Parser = struct {
    lexer: lexer_mod.Lexer,
    current: Token = .{ .tag = .eof },
    peeked: ?Token = null,
    arena: std.mem.Allocator,

    pub fn init(arena: std.mem.Allocator, source: []const u8) Error!Parser {
        var parser: Parser = .{
            .lexer = lexer_mod.Lexer.init(source),
            .arena = arena,
        };
        parser.current = try parser.lex();
        return parser;
    }

    fn lex(self: *Parser) Error!Token {
        return self.lexer.next() catch |err| switch (err) {
            error.InvalidExpression => error.InvalidExpression,
            error.UnexpectedEndOfInput => error.UnexpectedEndOfInput,
        };
    }

    fn advance(self: *Parser) Error!void {
        if (self.peeked) |token| {
            self.current = token;
            self.peeked = null;
            return;
        }
        self.current = try self.lex();
    }

    fn peek(self: *Parser) Error!Token {
        if (self.peeked == null) self.peeked = try self.lex();
        return self.peeked.?;
    }

    fn consume(self: *Parser) Error!Token {
        if (self.peeked) |token| {
            self.peeked = null;
            return token;
        }
        return self.lex();
    }

    fn accept(self: *Parser, tag: Tag) Error!bool {
        if (self.current.tag != tag) return false;
        try self.advance();
        return true;
    }

    fn expect(self: *Parser, tag: Tag) Error!void {
        if (self.current.tag != tag) return error.InvalidExpression;
        try self.advance();
    }

    fn isName(self: *const Parser, text: []const u8) bool {
        return self.current.tag == .name and
            std.mem.eql(u8, self.current.text, text);
    }

    fn expectName(self: *Parser, text: []const u8) Error!void {
        if (!self.isName(text)) return error.InvalidExpression;
        try self.advance();
    }

    pub fn parse(self: *Parser) Error!*ast.Expr {
        const expression = try self.parseOr();
        if (self.current.tag != .eof) return error.InvalidExpression;
        return expression;
    }

    fn newNode(self: *Parser, value: ast.Expr) Error!*ast.Expr {
        const node = try self.arena.create(ast.Expr);
        node.* = value;
        return node;
    }

    fn parseOr(self: *Parser) Error!*ast.Expr {
        var lhs = try self.parseAnd();
        while (self.isName("or")) {
            try self.advance();
            const rhs = try self.parseAnd();
            lhs = try self.newNode(.{ .binary = .{
                .op = .or_,
                .lhs = lhs,
                .rhs = rhs,
            } });
        }
        return lhs;
    }

    fn parseAnd(self: *Parser) Error!*ast.Expr {
        var lhs = try self.parseEquality();
        while (self.isName("and")) {
            try self.advance();
            const rhs = try self.parseEquality();
            lhs = try self.newNode(.{ .binary = .{
                .op = .and_,
                .lhs = lhs,
                .rhs = rhs,
            } });
        }
        return lhs;
    }

    fn parseEquality(self: *Parser) Error!*ast.Expr {
        var lhs = try self.parseRelational();
        while (true) {
            const op: ast.Op = switch (self.current.tag) {
                .eq => .eq,
                .ne => .ne,
                else => break,
            };
            try self.advance();
            const rhs = try self.parseRelational();
            lhs = try self.newNode(.{ .binary = .{
                .op = op,
                .lhs = lhs,
                .rhs = rhs,
            } });
        }
        return lhs;
    }

    fn parseRelational(self: *Parser) Error!*ast.Expr {
        var lhs = try self.parseAdditive();
        while (true) {
            const op: ast.Op = switch (self.current.tag) {
                .lt => .lt,
                .le => .le,
                .gt => .gt,
                .ge => .ge,
                else => break,
            };
            try self.advance();
            const rhs = try self.parseAdditive();
            lhs = try self.newNode(.{ .binary = .{
                .op = op,
                .lhs = lhs,
                .rhs = rhs,
            } });
        }
        return lhs;
    }

    fn parseAdditive(self: *Parser) Error!*ast.Expr {
        var lhs = try self.parseMultiplicative();
        while (true) {
            const op: ast.Op = switch (self.current.tag) {
                .plus => .add,
                .minus => .sub,
                else => break,
            };
            try self.advance();
            const rhs = try self.parseMultiplicative();
            lhs = try self.newNode(.{ .binary = .{
                .op = op,
                .lhs = lhs,
                .rhs = rhs,
            } });
        }
        return lhs;
    }

    fn parseMultiplicative(self: *Parser) Error!*ast.Expr {
        var lhs = try self.parseUnary();
        while (true) {
            const op: ast.Op = if (self.current.tag == .star)
                .mul
            else if (self.isName("div"))
                .div
            else if (self.isName("mod"))
                .mod
            else
                break;
            try self.advance();
            const rhs = try self.parseUnary();
            lhs = try self.newNode(.{ .binary = .{
                .op = op,
                .lhs = lhs,
                .rhs = rhs,
            } });
        }
        return lhs;
    }

    fn parseUnary(self: *Parser) Error!*ast.Expr {
        if (self.current.tag == .minus) {
            try self.advance();
            const operand = try self.parseUnary();
            return self.newNode(.{ .unary_minus = operand });
        }
        return self.parseUnion();
    }

    fn parseUnion(self: *Parser) Error!*ast.Expr {
        var lhs = try self.parsePath();
        while (self.current.tag == .pipe) {
            try self.advance();
            const rhs = try self.parsePath();
            lhs = try self.newNode(.{ .binary = .{
                .op = .union_,
                .lhs = lhs,
                .rhs = rhs,
            } });
        }
        return lhs;
    }

    fn startsLocationPath(self: *Parser) bool {
        return switch (self.current.tag) {
            .slash, .double_slash, .dot, .dot_dot, .at, .star => true,
            .name => blk: {
                const peeked = self.peek() catch break :blk true;
                if (peeked.tag == .lparen) {
                    // Node-type tests are steps; other names are functions.
                    break :blk isNodeTypeName(self.current.text);
                }
                if (peeked.tag == .double_colon) break :blk true;
                break :blk true;
            },
            else => false,
        };
    }

    fn parsePath(self: *Parser) Error!*ast.Expr {
        if (self.current.tag == .slash or self.current.tag == .double_slash) {
            const absolute = true;
            var steps: std.ArrayList(ast.Step) = .empty;
            if (self.current.tag == .double_slash) {
                try steps.append(self.arena, .{
                    .axis = .descendant_or_self,
                    .node_test = .node,
                    .predicates = &.{},
                });
            }
            const was_double_slash = self.current.tag == .double_slash;
            try self.advance();
            if (was_double_slash and
                (self.current.tag == .eof or self.isStepTerminator()))
            {
                return error.InvalidExpression;
            }
            if (self.current.tag != .eof and !self.isStepTerminator()) {
                try self.parseRelativeSteps(&steps);
            }
            return self.newNode(.{ .path = .{
                .absolute = absolute,
                .start = null,
                .steps = try steps.toOwnedSlice(self.arena),
            } });
        }

        if (self.startsLocationPath()) {
            var steps: std.ArrayList(ast.Step) = .empty;
            try self.parseRelativeSteps(&steps);
            return self.newNode(.{ .path = .{
                .absolute = false,
                .start = null,
                .steps = try steps.toOwnedSlice(self.arena),
            } });
        }

        const primary = try self.parsePrimaryWithPredicates();
        if (self.current.tag == .slash or self.current.tag == .double_slash) {
            var steps: std.ArrayList(ast.Step) = .empty;
            if (self.current.tag == .double_slash) {
                try steps.append(self.arena, .{
                    .axis = .descendant_or_self,
                    .node_test = .node,
                    .predicates = &.{},
                });
            }
            const was_double_slash = self.current.tag == .double_slash;
            try self.advance();
            if (was_double_slash and
                (self.current.tag == .eof or self.isStepTerminator()))
            {
                return error.InvalidExpression;
            }
            try self.parseRelativeSteps(&steps);
            return self.newNode(.{ .path = .{
                .absolute = false,
                .start = primary,
                .steps = try steps.toOwnedSlice(self.arena),
            } });
        }
        return primary;
    }

    fn isStepTerminator(self: *Parser) bool {
        return switch (self.current.tag) {
            .rparen, .rbracket, .comma, .pipe, .eof => true,
            else => false,
        };
    }

    fn parseRelativeSteps(self: *Parser, steps: *std.ArrayList(ast.Step)) Error!void {
        try steps.append(self.arena, try self.parseStep());
        while (self.current.tag == .slash or self.current.tag == .double_slash) {
            if (self.current.tag == .double_slash) {
                try steps.append(self.arena, .{
                    .axis = .descendant_or_self,
                    .node_test = .node,
                    .predicates = &.{},
                });
            }
            try self.advance();
            try steps.append(self.arena, try self.parseStep());
        }
    }

    fn parseStep(self: *Parser) Error!ast.Step {
        if (self.current.tag == .dot) {
            try self.advance();
            return .{ .axis = .self_axis, .node_test = .node, .predicates = &.{} };
        }
        if (self.current.tag == .dot_dot) {
            try self.advance();
            return .{ .axis = .parent, .node_test = .node, .predicates = &.{} };
        }

        var axis: ast.Axis = .child;
        if (self.current.tag == .at) {
            axis = .attribute;
            try self.advance();
        } else if (self.current.tag == .name) {
            const name = self.current.text;
            if (try self.peekIsDoubleColon()) {
                axis = parseAxis(name) orelse return error.InvalidExpression;
                try self.advance(); // name
                try self.expect(.double_colon);
            }
        }

        const node_test = try self.parseNodeTest();
        var predicates: std.ArrayList(*ast.Expr) = .empty;
        while (self.current.tag == .lbracket) {
            try self.advance();
            try predicates.append(self.arena, try self.parseOr());
            try self.expect(.rbracket);
        }
        return .{
            .axis = axis,
            .node_test = node_test,
            .predicates = try predicates.toOwnedSlice(self.arena),
        };
    }

    fn peekIsDoubleColon(self: *Parser) Error!bool {
        const token = try self.peek();
        return token.tag == .double_colon;
    }

    fn parseNodeTest(self: *Parser) Error!ast.NodeTest {
        if (self.current.tag == .star) {
            try self.advance();
            return .{ .name = .{} };
        }
        if (self.current.tag != .name) return error.InvalidExpression;
        const name = self.current.text;
        if (try self.peekIsLparen()) {
            if (isNodeTypeName(name)) {
                try self.advance();
                try self.expect(.lparen);
                if (std.mem.eql(u8, name, "processing-instruction")) {
                    if (self.current.tag == .literal) {
                        const target = self.current.text;
                        try self.advance();
                        try self.expect(.rparen);
                        return .{ .processing_instruction = target };
                    }
                }
                try self.expect(.rparen);
                if (std.mem.eql(u8, name, "node")) return .node;
                if (std.mem.eql(u8, name, "text")) return .text;
                if (std.mem.eql(u8, name, "comment")) return .comment;
                if (std.mem.eql(u8, name, "processing-instruction")) {
                    return .{ .processing_instruction = null };
                }
                return error.InvalidExpression;
            }
        }
        try self.advance();
        return .{ .name = try self.parseNameTest(name) };
    }

    fn parseNameTest(self: *Parser, name: []const u8) Error!ast.NameTest {
        _ = self;
        if (std.mem.eql(u8, name, "*")) return .{};
        if (std.mem.indexOfScalar(u8, name, ':')) |colon| {
            if (colon == 0 or colon + 1 == name.len) return error.InvalidExpression;
            const prefix = name[0..colon];
            const local = name[colon + 1 ..];
            if (std.mem.indexOfScalar(u8, local, ':') != null) {
                return error.InvalidExpression;
            }
            if (std.mem.eql(u8, local, "*")) {
                return .{ .prefix = prefix };
            }
            return .{ .prefix = prefix, .local = local };
        }
        return .{ .local = name };
    }

    fn peekIsLparen(self: *Parser) Error!bool {
        const token = try self.peek();
        return token.tag == .lparen;
    }

    fn parsePrimaryWithPredicates(self: *Parser) Error!*ast.Expr {
        const primary = try self.parsePrimary();
        var predicates: std.ArrayList(*ast.Expr) = .empty;
        while (self.current.tag == .lbracket) {
            try self.advance();
            try predicates.append(self.arena, try self.parseOr());
            try self.expect(.rbracket);
        }
        if (predicates.items.len == 0) return primary;
        return self.newNode(.{ .filter = .{
            .primary = primary,
            .predicates = try predicates.toOwnedSlice(self.arena),
        } });
    }

    fn parsePrimary(self: *Parser) Error!*ast.Expr {
        switch (self.current.tag) {
            .literal => {
                const value = self.current.text;
                try self.advance();
                return self.newNode(.{ .literal = value });
            },
            .number => {
                const value = self.current.number;
                try self.advance();
                return self.newNode(.{ .number = value });
            },
            .variable => {
                const name = self.current.text;
                try self.advance();
                return self.newNode(.{ .variable = name });
            },
            .lparen => {
                try self.advance();
                const expression = try self.parseOr();
                try self.expect(.rparen);
                return expression;
            },
            .name => {
                const name = self.current.text;
                try self.advance();
                try self.expect(.lparen);
                var args: std.ArrayList(*ast.Expr) = .empty;
                if (self.current.tag != .rparen) {
                    while (true) {
                        try args.append(self.arena, try self.parseOr());
                        if (self.current.tag != .comma) break;
                        try self.advance();
                    }
                }
                try self.expect(.rparen);
                return self.newNode(.{ .function_call = .{
                    .name = name,
                    .args = try args.toOwnedSlice(self.arena),
                } });
            },
            else => return error.InvalidExpression,
        }
    }
};

fn isNodeTypeName(name: []const u8) bool {
    return std.mem.eql(u8, name, "node") or
        std.mem.eql(u8, name, "text") or
        std.mem.eql(u8, name, "comment") or
        std.mem.eql(u8, name, "processing-instruction");
}

fn parseAxis(name: []const u8) ?ast.Axis {
    const axes = [_]struct { []const u8, ast.Axis }{
        .{ "ancestor", .ancestor },
        .{ "ancestor-or-self", .ancestor_or_self },
        .{ "attribute", .attribute },
        .{ "child", .child },
        .{ "descendant", .descendant },
        .{ "descendant-or-self", .descendant_or_self },
        .{ "following", .following },
        .{ "following-sibling", .following_sibling },
        .{ "namespace", .namespace_axis },
        .{ "parent", .parent },
        .{ "preceding", .preceding },
        .{ "preceding-sibling", .preceding_sibling },
        .{ "self", .self_axis },
    };
    for (axes) |entry| {
        if (std.mem.eql(u8, entry[0], name)) return entry[1];
    }
    return null;
}

test "XPath parser accepts location paths and predicates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "//a/b[@x='v' and position() >= 2] | $v");
    const expression = try parser.parse();
    try std.testing.expect(expression.* == .binary);
    try std.testing.expectEqual(ast.Op.union_, expression.binary.op);
}

test "XPath parser handles filters arithmetic and functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(
        arena.allocator(),
        "count(//item[price * 2 > 10]) + 1",
    );
    const expression = try parser.parse();
    try std.testing.expect(expression.* == .binary);
    try std.testing.expectEqual(ast.Op.add, expression.binary.op);
    try std.testing.expect(expression.binary.lhs.* == .function_call);
}
