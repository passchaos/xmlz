//! XPath 1.0 parser and evaluator.

const std = @import("std");
const ast = @import("ast.zig");
const parser_mod = @import("parser.zig");
const eval_mod = @import("eval.zig");

pub const lexer = @import("lexer.zig");
pub const value = @import("value.zig");
pub const exslt_date = @import("exslt_date.zig");

pub const Context = value.Context;
pub const Value = value.Value;
pub const Variable = value.Variable;
pub const NodeRef = value.NodeRef;
pub const AttributeRef = value.AttributeRef;
pub const NamespaceRef = value.NamespaceRef;
pub const Result = value.Result;
pub const DescendantCache = value.DescendantCache;
pub const parseNumber = value.parseNumber;
pub const formatNumber = value.formatNumber;

pub const Error = parser_mod.Error || eval_mod.Error;

pub const Expression = struct {
    arena: std.heap.ArenaAllocator,
    root: *ast.Expr,

    pub fn parse(allocator: std.mem.Allocator, source: []const u8) Error!Expression {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        var parser = try parser_mod.Parser.init(arena.allocator(), source);
        const root = try parser.parse();
        return .{ .arena = arena, .root = root };
    }

    pub fn deinit(self: *Expression) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn evaluate(
        self: *const Expression,
        allocator: std.mem.Allocator,
        context: *const Context,
    ) Error!Result {
        return eval_mod.evaluate(allocator, self.root, context);
    }
};

test {
    _ = @import("tests.zig");
}
