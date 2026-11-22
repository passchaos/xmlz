//! XPath 1.0 abstract syntax tree.

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
