//! XPath 1.0 abstract syntax tree.

const std = @import("std");

pub const Axis = enum {
    ancestor,
    ancestor_or_self,
    attribute,
    child,
    descendant,
    descendant_or_self,
    following,
    following_sibling,
    namespace_axis,
    parent,
    preceding,
    preceding_sibling,
    self_axis,
};

pub const NameTest = struct {
    /// Namespace prefix, or null for an unprefixed name.
    prefix: ?[]const u8 = null,
    /// Local name, or null for `*`.
    local: ?[]const u8 = null,
};

pub const NodeTest = union(enum) {
    name: NameTest,
    node,
    text,
    comment,
    processing_instruction: ?[]const u8,
};

pub const Step = struct {
    axis: Axis,
    node_test: NodeTest,
    predicates: []const *Expr,
};

pub const Op = enum {
    or_,
    and_,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    add,
    sub,
    mul,
    div,
    mod,
    union_,
};

pub const Binary = struct {
    op: Op,
    lhs: *Expr,
    rhs: *Expr,
};

pub const Path = struct {
    absolute: bool,
    /// Non-null for `FilterExpr / RelativeLocationPath`.
    start: ?*Expr = null,
    steps: []const Step,
};

pub const Filter = struct {
    primary: *Expr,
    predicates: []const *Expr,
};

pub const FunctionCall = struct {
    name: []const u8,
    args: []const *Expr,
};

/// True when the expression calls the core `last()` function anywhere.
/// `last()` is the only core function that needs the context node-set size,
/// so callers can skip computing it when this is false.
pub fn usesLast(expr: *const Expr) bool {
    return switch (expr.*) {
        .binary => |binary| usesLast(binary.lhs) or usesLast(binary.rhs),
        .unary_minus => |operand| usesLast(operand),
        .path => |path| blk: {
            if (path.start) |start| {
                if (usesLast(start)) break :blk true;
            }
            for (path.steps) |step| {
                for (step.predicates) |predicate| {
                    if (usesLast(predicate)) break :blk true;
                }
            }
            break :blk false;
        },
        .filter => |filter| blk: {
            if (usesLast(filter.primary)) break :blk true;
            for (filter.predicates) |predicate| {
                if (usesLast(predicate)) break :blk true;
            }
            break :blk false;
        },
        .function_call => |call| blk: {
            // A prefixed extension function named `last` also keeps the
            // size pass; that is conservative, not wrong.
            if (std.mem.eql(u8, call.name, "last")) break :blk true;
            for (call.args) |argument| {
                if (usesLast(argument)) break :blk true;
            }
            break :blk false;
        },
        .literal, .number, .variable => false,
    };
}

pub const Expr = union(enum) {
    binary: Binary,
    unary_minus: *Expr,
    path: Path,
    filter: Filter,
    literal: []const u8,
    number: f64,
    variable: []const u8,
    function_call: FunctionCall,
};
