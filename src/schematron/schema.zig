//! ISO Schematron schema parsing.

const std = @import("std");
const dom = @import("../dom.zig");
const namespace = @import("../namespace.zig");
const ast = @import("../xpath/ast.zig");
const xpath_parser = @import("../xpath/parser.zig");

pub const namespace_uri = "http://purl.oclc.org/dsdl/schematron";

pub const Error = error{
    OutOfMemory,
    InvalidSchema,
};

pub const CompiledExpr = struct {
    root: *ast.Expr,
    namespaces: []const namespace.Binding,
};

pub const MessagePart = union(enum) {
    text: []const u8,
    value_of: CompiledExpr,
    /// `null` means the context node itself.
    name: ?CompiledExpr,
};

pub const AssertionKind = enum { assert, report };

pub const Assertion = struct {
    kind: AssertionKind,
    test_expr: CompiledExpr,
    message: []const MessagePart = &.{},
    node: dom.NodeId = dom.null_node,
};

pub const Variable = struct {
    name: []const u8,
    value: CompiledExpr,
};

pub const Rule = struct {
    context: CompiledExpr,
    assertions: []const Assertion = &.{},
    variables: []const Variable = &.{},
};

pub const Pattern = struct {
    id: []const u8 = "",
    rules: []const Rule = &.{},
    variables: []const Variable = &.{},
};

pub const Phase = struct {
    id: []const u8,
    active: []const []const u8,
};

pub const Schema = struct {
    arena: std.heap.ArenaAllocator,
    patterns: []const Pattern,
    phases: []const Phase,
    default_phase: ?[]const u8 = null,
    variables: []const Variable = &.{},

    pub fn deinit(self: *Schema) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn parse(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
) Error!Schema {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var compiler: Compiler = .{
        .arena = arena.allocator(),
        .document = document,
    };
    try compiler.compile();
    return .{
        .arena = arena,
        .patterns = try compiler.patterns.toOwnedSlice(compiler.arena),
        .phases = try compiler.phases.toOwnedSlice(compiler.arena),
        .default_phase = compiler.default_phase,
        .variables = try compiler.variables.toOwnedSlice(compiler.arena),
    };
}

const Compiler = struct {
    arena: std.mem.Allocator,
    document: *const dom.Document,
    patterns: std.ArrayList(Pattern) = .empty,
    phases: std.ArrayList(Phase) = .empty,
    schema_namespaces: std.ArrayList(namespace.Binding) = .empty,
    variables: std.ArrayList(Variable) = .empty,
    default_phase: ?[]const u8 = null,

    fn compile(self: *Compiler) Error!void {
        const root = self.document.root();
        if (root == dom.null_node) return error.InvalidSchema;
        const node = self.document.node(root);
        if (node.kind != .element or
            !std.mem.eql(u8, node.ns, namespace_uri) or
            !std.mem.eql(u8, node.local, "schema"))
        {
            return error.InvalidSchema;
        }
        if (self.document.attribute(root, "defaultPhase")) |value| {
            self.default_phase = try self.arena.dupe(u8, value);
        }

        // Namespace declarations must be known before compiling any XPath.
        var child = node.first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const child_node = self.document.node(child);
            if (child_node.kind != .element or
                !std.mem.eql(u8, child_node.ns, namespace_uri))
            {
                continue;
            }
            if (std.mem.eql(u8, child_node.local, "ns")) {
                try self.collectNamespace(child);
            }
        }

        child = node.first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const child_node = self.document.node(child);
            if (child_node.kind != .element or
                !std.mem.eql(u8, child_node.ns, namespace_uri))
            {
                continue;
            }
            if (std.mem.eql(u8, child_node.local, "let")) {
                try self.variables.append(
                    self.arena,
                    try self.parseVariable(child),
                );
            } else if (std.mem.eql(u8, child_node.local, "phase")) {
                try self.phases.append(self.arena, try self.parsePhase(child));
            } else if (std.mem.eql(u8, child_node.local, "pattern")) {
                try self.patterns.append(
                    self.arena,
                    try self.parsePattern(child),
                );
            }
        }
    }

    fn collectNamespace(self: *Compiler, id: dom.NodeId) Error!void {
        const prefix = self.document.attribute(id, "prefix") orelse
            return error.InvalidSchema;
        const uri = self.document.attribute(id, "uri") orelse
            return error.InvalidSchema;
        try self.schema_namespaces.append(self.arena, .{
            .prefix = try self.arena.dupe(u8, prefix),
            .uri = try self.arena.dupe(u8, uri),
        });
    }

    fn parsePhase(self: *Compiler, id: dom.NodeId) Error!Phase {
        const phase_id = self.document.attribute(id, "id") orelse
            return error.InvalidSchema;
        var active: std.ArrayList([]const u8) = .empty;
        var child = self.document.node(id).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const node = self.document.node(child);
            if (node.kind != .element or
                !std.mem.eql(u8, node.ns, namespace_uri) or
                !std.mem.eql(u8, node.local, "active"))
            {
                continue;
            }
            const value = self.document.attribute(child, "pattern") orelse
                return error.InvalidSchema;
            var tokens = std.mem.tokenizeAny(u8, value, " \t\r\n");
            while (tokens.next()) |token| {
                try active.append(self.arena, try self.arena.dupe(u8, token));
            }
        }
        return .{
            .id = try self.arena.dupe(u8, phase_id),
            .active = try active.toOwnedSlice(self.arena),
        };
    }

    fn parsePattern(self: *Compiler, id: dom.NodeId) Error!Pattern {
        if (self.document.attribute(id, "abstract") != null and
            isYes(self.document.attribute(id, "abstract").?))
        {
            return error.InvalidSchema;
        }
        if (self.document.attribute(id, "is-a") != null) {
            return error.InvalidSchema;
        }
        var pattern: Pattern = .{};
        if (self.document.attribute(id, "id")) |value| {
            pattern.id = try self.arena.dupe(u8, value);
        }
        var variables: std.ArrayList(Variable) = .empty;
        var rules: std.ArrayList(Rule) = .empty;
        var child = self.document.node(id).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const node = self.document.node(child);
            if (node.kind != .element or
                !std.mem.eql(u8, node.ns, namespace_uri))
            {
                continue;
            }
            if (std.mem.eql(u8, node.local, "let")) {
                try variables.append(self.arena, try self.parseVariable(child));
            } else if (std.mem.eql(u8, node.local, "rule")) {
                try rules.append(self.arena, try self.parseRule(child));
            }
        }
        pattern.variables = try variables.toOwnedSlice(self.arena);
        pattern.rules = try rules.toOwnedSlice(self.arena);
        return pattern;
    }

    fn parseRule(self: *Compiler, id: dom.NodeId) Error!Rule {
        if (self.document.attribute(id, "abstract") != null and
            isYes(self.document.attribute(id, "abstract").?))
        {
            return error.InvalidSchema;
        }
        const context_source = self.document.attribute(id, "context") orelse
            return error.InvalidSchema;
        var rule: Rule = .{
            .context = try self.compilePattern(id, context_source),
        };
        var variables: std.ArrayList(Variable) = .empty;
        var assertions: std.ArrayList(Assertion) = .empty;
        var child = self.document.node(id).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const node = self.document.node(child);
            if (node.kind != .element or
                !std.mem.eql(u8, node.ns, namespace_uri))
            {
                continue;
            }
            if (std.mem.eql(u8, node.local, "let")) {
                try variables.append(self.arena, try self.parseVariable(child));
            } else if (std.mem.eql(u8, node.local, "assert") or
                std.mem.eql(u8, node.local, "report"))
            {
                try assertions.append(
                    self.arena,
                    try self.parseAssertion(child),
                );
            } else if (std.mem.eql(u8, node.local, "extends")) {
                return error.InvalidSchema;
            }
        }
        rule.variables = try variables.toOwnedSlice(self.arena);
        rule.assertions = try assertions.toOwnedSlice(self.arena);
        return rule;
    }

    fn parseAssertion(self: *Compiler, id: dom.NodeId) Error!Assertion {
        const node = self.document.node(id);
        const test_source = self.document.attribute(id, "test") orelse
            return error.InvalidSchema;
        return .{
            .kind = if (std.mem.eql(u8, node.local, "assert"))
                .assert
            else
                .report,
            .test_expr = try self.compileExpression(id, test_source),
            .message = try self.parseMessage(id),
            .node = id,
        };
    }

    fn parseMessage(self: *Compiler, id: dom.NodeId) Error![]const MessagePart {
        var parts: std.ArrayList(MessagePart) = .empty;
        var child = self.document.node(id).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const node = self.document.node(child);
            switch (node.kind) {
                .text => try parts.append(self.arena, .{
                    .text = try self.arena.dupe(u8, node.value),
                }),
                .element => {
                    if (std.mem.eql(u8, node.ns, namespace_uri) and
                        std.mem.eql(u8, node.local, "value-of"))
                    {
                        const select = self.document.attribute(
                            child,
                            "select",
                        ) orelse return error.InvalidSchema;
                        try parts.append(self.arena, .{
                            .value_of = try self.compileExpression(
                                child,
                                select,
                            ),
                        });
                    } else if (std.mem.eql(u8, node.ns, namespace_uri) and
                        std.mem.eql(u8, node.local, "name"))
                    {
                        const path = self.document.attribute(child, "path");
                        try parts.append(self.arena, .{
                            .name = if (path) |source|
                                try self.compileExpression(child, source)
                            else
                                null,
                        });
                    } else {
                        const text = try self.textContent(child);
                        try parts.append(self.arena, .{ .text = text });
                    }
                },
                else => {},
            }
        }
        return parts.toOwnedSlice(self.arena);
    }

    fn parseVariable(self: *Compiler, id: dom.NodeId) Error!Variable {
        const name = self.document.attribute(id, "name") orelse
            return error.InvalidSchema;
        const value = self.document.attribute(id, "value") orelse
            return error.InvalidSchema;
        return .{
            .name = try self.arena.dupe(u8, name),
            .value = try self.compileExpression(id, value),
        };
    }

    fn textContent(self: *Compiler, id: dom.NodeId) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try self.appendTextContent(id, &out);
        return out.toOwnedSlice(self.arena);
    }

    fn appendTextContent(
        self: *Compiler,
        id: dom.NodeId,
        out: *std.ArrayList(u8),
    ) Error!void {
        const node = self.document.node(id);
        if (node.kind == .text) {
            try out.appendSlice(self.arena, node.value);
            return;
        }
        var child = node.first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            try self.appendTextContent(child, out);
        }
    }

    fn compilePattern(
        self: *Compiler,
        id: dom.NodeId,
        source: []const u8,
    ) Error!CompiledExpr {
        var parser = xpath_parser.Parser.init(self.arena, source) catch |err|
            switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidSchema,
            };
        const root = parser.parse() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidSchema,
        };
        return .{
            .root = try patternSelector(self.arena, root),
            .namespaces = try self.expressionBindings(id),
        };
    }

    fn compileExpression(
        self: *Compiler,
        id: dom.NodeId,
        source: []const u8,
    ) Error!CompiledExpr {
        var parser = xpath_parser.Parser.init(self.arena, source) catch |err|
            switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidSchema,
            };
        const root = parser.parse() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidSchema,
        };
        return .{
            .root = root,
            .namespaces = try self.expressionBindings(id),
        };
    }

    fn expressionBindings(
        self: *Compiler,
        id: dom.NodeId,
    ) Error![]const namespace.Binding {
        const in_scope = self.document.inScopeNamespaces(
            self.arena,
            id,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        var out: std.ArrayList(namespace.Binding) = .empty;
        for (in_scope) |binding| {
            if (std.mem.eql(u8, binding.uri, namespace_uri)) continue;
            var shadowed = false;
            for (self.schema_namespaces.items) |declared| {
                if (std.mem.eql(u8, declared.prefix, binding.prefix)) {
                    shadowed = true;
                    break;
                }
            }
            if (!shadowed) try out.append(self.arena, binding);
        }
        try out.appendSlice(self.arena, self.schema_namespaces.items);
        return out.toOwnedSlice(self.arena);
    }
};

/// Translate a Schematron rule context pattern into an absolute selector.
fn patternSelector(
    arena: std.mem.Allocator,
    expression: *ast.Expr,
) Error!*ast.Expr {
    switch (expression.*) {
        .binary => |binary| {
            if (binary.op != .union_) return error.InvalidSchema;
            const out = try arena.create(ast.Expr);
            out.* = .{ .binary = .{
                .op = .union_,
                .lhs = try patternSelector(arena, binary.lhs),
                .rhs = try patternSelector(arena, binary.rhs),
            } };
            return out;
        },
        .path => |path| {
            if (path.start != null) return error.InvalidSchema;
            if (path.absolute) return expression;
            var steps: std.ArrayList(ast.Step) = .empty;
            try steps.append(arena, .{
                .axis = .descendant_or_self,
                .node_test = .node,
                .predicates = &.{},
            });
            try steps.appendSlice(arena, path.steps);
            const out = try arena.create(ast.Expr);
            out.* = .{ .path = .{
                .absolute = true,
                .start = null,
                .steps = try steps.toOwnedSlice(arena),
            } };
            return out;
        },
        .function_call => |call| {
            if (std.mem.eql(u8, call.name, "id") or
                std.mem.eql(u8, call.name, "key"))
            {
                return expression;
            }
            return error.InvalidSchema;
        },
        else => return error.InvalidSchema,
    }
}

fn isYes(value: []const u8) bool {
    return std.mem.eql(u8, value, "true") or
        std.mem.eql(u8, value, "1") or
        std.mem.eql(u8, value, "yes");
}
