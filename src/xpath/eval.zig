//! XPath 1.0 evaluator over `dom.Document`.

const std = @import("std");
const ast = @import("ast.zig");
const value = @import("value.zig");
const dom = @import("../dom.zig");
const namespace = @import("../namespace.zig");

pub const Error = error{
    OutOfMemory,
    InvalidExpression,
    UndefinedVariable,
    UndefinedPrefix,
    UnknownFunction,
    InvalidArgument,
};

pub fn evaluate(
    allocator: std.mem.Allocator,
    expression: *const ast.Expr,
    context: *const value.Context,
) Error!value.Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var evaluator: Evaluator = .{ .allocator = arena.allocator() };
    const result = try evaluator.eval(expression, context);
    return .{ .arena = arena, .value = result };
}

const Kind = enum {
    document,
    element,
    text,
    comment,
    processing_instruction,
    attribute,
    namespace,
};

const Evaluator = struct {
    allocator: std.mem.Allocator,

    fn eval(
        self: *Evaluator,
        expression: *const ast.Expr,
        context: *const value.Context,
    ) Error!value.Value {
        return switch (expression.*) {
            .binary => |binary| self.evalBinary(binary, context),
            .unary_minus => |operand| blk: {
                const number = try self.toNumber(
                    try self.eval(operand, context),
                    context,
                );
                break :blk .{ .number = -number };
            },
            .path => |path| self.evalPath(path, context),
            .filter => |filter| self.evalFilter(filter, context),
            .literal => |literal| .{ .string = literal },
            .number => |number| .{ .number = number },
            .variable => |name| context.variable(name) orelse
                error.UndefinedVariable,
            .function_call => |call| self.evalFunction(call, context),
        };
    }

    fn evalBinary(
        self: *Evaluator,
        binary: ast.Binary,
        context: *const value.Context,
    ) Error!value.Value {
        switch (binary.op) {
            .or_ => {
                const lhs = try self.eval(binary.lhs, context);
                if (lhs.toBoolean()) return .{ .boolean = true };
                return .{ .boolean = (try self.eval(binary.rhs, context)).toBoolean() };
            },
            .and_ => {
                const lhs = try self.eval(binary.lhs, context);
                if (!lhs.toBoolean()) return .{ .boolean = false };
                return .{ .boolean = (try self.eval(binary.rhs, context)).toBoolean() };
            },
            .union_ => {
                const lhs = try self.requireNodeSet(
                    try self.eval(binary.lhs, context),
                );
                const rhs = try self.requireNodeSet(
                    try self.eval(binary.rhs, context),
                );
                var combined: std.ArrayList(value.NodeRef) = .empty;
                try combined.appendSlice(self.allocator, lhs);
                try combined.appendSlice(self.allocator, rhs);
                return .{ .node_set = try self.sortDedup(combined.items) };
            },
            .eq, .ne, .lt, .le, .gt, .ge => {
                const lhs = try self.eval(binary.lhs, context);
                const rhs = try self.eval(binary.rhs, context);
                return .{ .boolean = try self.compare(binary.op, lhs, rhs, context) };
            },
            .add, .sub, .mul, .div, .mod => {
                const lhs = try self.toNumber(
                    try self.eval(binary.lhs, context),
                    context,
                );
                const rhs = try self.toNumber(
                    try self.eval(binary.rhs, context),
                    context,
                );
                return .{ .number = switch (binary.op) {
                    .add => lhs + rhs,
                    .sub => lhs - rhs,
                    .mul => lhs * rhs,
                    .div => lhs / rhs,
                    .mod => @rem(lhs, rhs),
                    else => unreachable,
                } };
            },
        }
    }

    fn evalPath(
        self: *Evaluator,
        path: ast.Path,
        context: *const value.Context,
    ) Error!value.Value {
        var current: []const value.NodeRef = undefined;
        if (path.start) |start_expression| {
            current = try self.requireNodeSet(
                try self.eval(start_expression, context),
            );
        } else if (path.absolute) {
            const nodes = try self.allocator.alloc(value.NodeRef, 1);
            nodes[0] = .{ .node = 0 };
            current = nodes;
        } else {
            const nodes = try self.allocator.alloc(value.NodeRef, 1);
            nodes[0] = context.node;
            current = nodes;
        }

        for (path.steps) |step| {
            current = try self.applyStep(context, current, step);
        }
        return .{ .node_set = current };
    }

    fn evalFilter(
        self: *Evaluator,
        filter: ast.Filter,
        context: *const value.Context,
    ) Error!value.Value {
        const primary = try self.requireNodeSet(
            try self.eval(filter.primary, context),
        );
        const sorted = try self.sortDedup(primary);
        return .{ .node_set = try self.applyPredicates(
            context,
            sorted,
            filter.predicates,
        ) };
    }

    fn applyStep(
        self: *Evaluator,
        context: *const value.Context,
        input: []const value.NodeRef,
        step: ast.Step,
    ) Error![]const value.NodeRef {
        var result: std.ArrayList(value.NodeRef) = .empty;
        for (input) |node| {
            const axis_nodes = try self.axisNodes(context, node, step.axis);
            var matched: std.ArrayList(value.NodeRef) = .empty;
            for (axis_nodes) |candidate| {
                if (try self.matchesTest(
                    context,
                    candidate,
                    step.node_test,
                    step.axis,
                )) {
                    try matched.append(self.allocator, candidate);
                }
            }
            const filtered = try self.applyPredicates(
                context,
                matched.items,
                step.predicates,
            );
            try result.appendSlice(self.allocator, filtered);
        }
        return self.sortDedup(result.items);
    }

    fn applyPredicates(
        self: *Evaluator,
        context: *const value.Context,
        nodes: []const value.NodeRef,
        predicates: []const *ast.Expr,
    ) Error![]const value.NodeRef {
        var current = nodes;
        for (predicates) |predicate| {
            var filtered: std.ArrayList(value.NodeRef) = .empty;
            const size = current.len;
            for (current, 0..) |node, index| {
                const predicate_context = context.withNode(
                    node,
                    index + 1,
                    size,
                );
                const result = try self.eval(predicate, &predicate_context);
                const keep = switch (result) {
                    .number => |number| @as(f64, @floatFromInt(index + 1)) == number,
                    else => result.toBoolean(),
                };
                if (keep) try filtered.append(self.allocator, node);
            }
            current = try filtered.toOwnedSlice(self.allocator);
        }
        return current;
    }

    fn axisNodes(
        self: *Evaluator,
        context: *const value.Context,
        node: value.NodeRef,
        axis: ast.Axis,
    ) Error![]const value.NodeRef {
        var out: std.ArrayList(value.NodeRef) = .empty;
        switch (axis) {
            .self_axis => try out.append(self.allocator, node),
            .child => try self.appendChildren(context, node, &out),
            .attribute => try self.appendAttributes(context, node, &out),
            .parent => {
                if (self.parentOf(context, node)) |parent| {
                    try out.append(self.allocator, parent);
                }
            },
            .ancestor => {
                var current = self.parentOf(context, node);
                while (current) |parent| {
                    try out.append(self.allocator, parent);
                    current = self.parentOf(context, parent);
                }
            },
            .ancestor_or_self => {
                try out.append(self.allocator, node);
                var current = self.parentOf(context, node);
                while (current) |parent| {
                    try out.append(self.allocator, parent);
                    current = self.parentOf(context, parent);
                }
            },
            .descendant => try self.appendDescendants(context, node, &out),
            .descendant_or_self => {
                try out.append(self.allocator, node);
                try self.appendDescendants(context, node, &out);
            },
            .following_sibling => try self.appendFollowingSiblings(
                context,
                node,
                &out,
            ),
            .preceding_sibling => try self.appendPrecedingSiblings(
                context,
                node,
                &out,
            ),
            .following => try self.appendFollowing(context, node, &out),
            .preceding => try self.appendPreceding(context, node, &out),
            .namespace_axis => try self.appendNamespaces(context, node, &out),
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn appendChildren(
        self: *Evaluator,
        context: *const value.Context,
        node: value.NodeRef,
        out: *std.ArrayList(value.NodeRef),
    ) Error!void {
        const id = switch (node) {
            .node => |id| id,
            .attribute, .namespace_node => return,
        };
        const node_value = context.document.node(id);
        if (node_value.kind != .document and node_value.kind != .element) return;
        var child = node_value.first_child;
        while (child != dom.null_node) : (child = context.document.node(child).next_sibling) {
            try out.append(self.allocator, .{ .node = child });
        }
    }

    fn appendAttributes(
        self: *Evaluator,
        context: *const value.Context,
        node: value.NodeRef,
        out: *std.ArrayList(value.NodeRef),
    ) Error!void {
        const id = switch (node) {
            .node => |id| id,
            .attribute, .namespace_node => return,
        };
        if (context.document.node(id).kind != .element) return;
        const attributes = context.document.attributesOf(id);
        for (attributes, 0..) |attribute, index| {
            if (namespace.Resolver.isNamespaceDeclaration(attribute.name)) continue;
            try out.append(self.allocator, .{ .attribute = .{
                .element = id,
                .index = @intCast(index),
            } });
        }
    }

    /// Collect the in-scope namespaces of an element as namespace nodes,
    /// ordered lexicographically by prefix as XPath 1.0 requires.
    fn appendNamespaces(
        self: *Evaluator,
        context: *const value.Context,
        node: value.NodeRef,
        out: *std.ArrayList(value.NodeRef),
    ) Error!void {
        const id = switch (node) {
            .node => |node_id| node_id,
            .attribute, .namespace_node => return,
        };
        if (context.document.node(id).kind != .element) return;

        const bindings = try context.document.inScopeNamespaces(
            self.allocator,
            id,
        );
        std.mem.sort(
            namespace.Binding,
            bindings,
            {},
            namespace.bindingLessThan,
        );
        for (bindings, 0..) |binding, index| {
            try out.append(self.allocator, .{ .namespace_node = .{
                .element = id,
                .prefix = binding.prefix,
                .uri = binding.uri,
                .order = @intCast(index),
            } });
        }
    }

    fn appendDescendants(
        self: *Evaluator,
        context: *const value.Context,
        node: value.NodeRef,
        out: *std.ArrayList(value.NodeRef),
    ) Error!void {
        const id = switch (node) {
            .node => |id| id,
            .attribute, .namespace_node => return,
        };
        const node_value = context.document.node(id);
        if (node_value.kind != .document and node_value.kind != .element) return;
        var child = node_value.first_child;
        while (child != dom.null_node) : (child = context.document.node(child).next_sibling) {
            try out.append(self.allocator, .{ .node = child });
            try self.appendDescendants(context, .{ .node = child }, out);
        }
    }

    fn appendFollowingSiblings(
        self: *Evaluator,
        context: *const value.Context,
        node: value.NodeRef,
        out: *std.ArrayList(value.NodeRef),
    ) Error!void {
        const id = switch (node) {
            .node => |id| id,
            .attribute, .namespace_node => return,
        };
        const parent = context.document.node(id).parent;
        if (parent == dom.null_node) return;
        var sibling = context.document.node(id).next_sibling;
        while (sibling != dom.null_node) : (sibling = context.document.node(sibling).next_sibling) {
            try out.append(self.allocator, .{ .node = sibling });
        }
    }

    fn appendPrecedingSiblings(
        self: *Evaluator,
        context: *const value.Context,
        node: value.NodeRef,
        out: *std.ArrayList(value.NodeRef),
    ) Error!void {
        const id = switch (node) {
            .node => |id| id,
            .attribute, .namespace_node => return,
        };
        const parent = context.document.node(id).parent;
        if (parent == dom.null_node) return;
        var previous: ?dom.NodeId = null;
        var sibling = context.document.node(parent).first_child;
        while (sibling != dom.null_node and sibling != id) : (sibling = context.document.node(sibling).next_sibling) {
            previous = sibling;
        }
        while (previous) |sibling_id| {
            try out.append(self.allocator, .{ .node = sibling_id });
            previous = null;
            var scan = context.document.node(parent).first_child;
            while (scan != dom.null_node and scan != sibling_id) : (scan = context.document.node(scan).next_sibling) {
                previous = scan;
            }
        }
    }

    fn appendFollowing(
        self: *Evaluator,
        context: *const value.Context,
        node: value.NodeRef,
        out: *std.ArrayList(value.NodeRef),
    ) Error!void {
        const all = try self.allNodes(context);
        const key = node.orderKey();
        for (all) |candidate| {
            if (!value.orderKeyLessThan(key, candidate.orderKey())) continue;
            if (self.isDescendantOf(context, candidate, node)) continue;
            try out.append(self.allocator, candidate);
        }
    }

    fn appendPreceding(
        self: *Evaluator,
        context: *const value.Context,
        node: value.NodeRef,
        out: *std.ArrayList(value.NodeRef),
    ) Error!void {
        const all = try self.allNodes(context);
        const key = node.orderKey();
        var reversed: std.ArrayList(value.NodeRef) = .empty;
        for (all) |candidate| {
            if (!value.orderKeyLessThan(candidate.orderKey(), key)) continue;
            if (self.isAncestorOf(context, candidate, node)) continue;
            try reversed.append(self.allocator, candidate);
        }
        var index = reversed.items.len;
        while (index > 0) {
            index -= 1;
            try out.append(self.allocator, reversed.items[index]);
        }
    }

    fn allNodes(self: *Evaluator, context: *const value.Context) Error![]const value.NodeRef {
        var out: std.ArrayList(value.NodeRef) = .empty;
        try out.append(self.allocator, .{ .node = 0 });
        try self.appendDescendants(context, .{ .node = 0 }, &out);
        return out.toOwnedSlice(self.allocator);
    }

    fn parentOf(
        self: *Evaluator,
        context: *const value.Context,
        node: value.NodeRef,
    ) ?value.NodeRef {
        _ = self;
        return switch (node) {
            .attribute => |attribute| .{ .node = attribute.element },
            .namespace_node => |namespace_node| .{ .node = namespace_node.element },
            .node => |id| blk: {
                const parent = context.document.node(id).parent;
                if (parent == dom.null_node) break :blk null;
                break :blk .{ .node = parent };
            },
        };
    }

    fn isDescendantOf(
        self: *Evaluator,
        context: *const value.Context,
        candidate: value.NodeRef,
        ancestor: value.NodeRef,
    ) bool {
        var current = self.parentOf(context, candidate);
        while (current) |parent| {
            if (parent.eql(ancestor)) return true;
            current = self.parentOf(context, parent);
        }
        return false;
    }

    fn isAncestorOf(
        self: *Evaluator,
        context: *const value.Context,
        candidate: value.NodeRef,
        descendant: value.NodeRef,
    ) bool {
        return self.isDescendantOf(context, descendant, candidate);
    }

    fn matchesTest(
        self: *Evaluator,
        context: *const value.Context,
        node: value.NodeRef,
        node_test: ast.NodeTest,
        axis: ast.Axis,
    ) Error!bool {
        const node_kind = self.kind(context, node);
        switch (node_test) {
            .node => return true,
            .text => return node_kind == .text,
            .comment => return node_kind == .comment,
            .processing_instruction => |target| {
                if (node_kind != .processing_instruction) return false;
                if (target) |expected| {
                    const id = node.node;
                    return std.mem.eql(
                        u8,
                        context.document.node(id).name,
                        expected,
                    );
                }
                return true;
            },
            .name => |name_test| {
                if (axis == .namespace_axis) {
                    if (node_kind != .namespace) return false;
                    if (name_test.prefix) |prefix| {
                        // Namespace nodes have a null namespace URI, so a
                        // prefixed name test can never match one.
                        _ = context.resolvePrefix(prefix) orelse
                            return error.UndefinedPrefix;
                        return false;
                    }
                    if (name_test.local) |expected| {
                        return std.mem.eql(
                            u8,
                            self.localName(context, node),
                            expected,
                        );
                    }
                    return true;
                }
                if (axis == .attribute) {
                    if (node_kind != .attribute) return false;
                } else {
                    if (node_kind != .element) return false;
                }
                if (name_test.prefix == null and name_test.local == null) {
                    return true;
                }
                if (name_test.local) |expected| {
                    if (!std.mem.eql(u8, self.localName(context, node), expected)) {
                        return false;
                    }
                }
                if (name_test.prefix) |prefix| {
                    const uri = context.resolvePrefix(prefix) orelse
                        return error.UndefinedPrefix;
                    return std.mem.eql(
                        u8,
                        self.namespaceUri(context, node),
                        uri,
                    );
                }
                return self.namespaceUri(context, node).len == 0;
            },
        }
    }

    fn kind(
        self: *Evaluator,
        context: *const value.Context,
        node: value.NodeRef,
    ) Kind {
        _ = self;
        return switch (node) {
            .attribute => .attribute,
            .namespace_node => .namespace,
            .node => |id| switch (context.document.node(id).kind) {
                .document => .document,
                .element => .element,
                .text => .text,
                .comment => .comment,
                .processing_instruction => .processing_instruction,
            },
        };
    }

    fn localName(
        self: *Evaluator,
        context: *const value.Context,
        node: value.NodeRef,
    ) []const u8 {
        _ = self;
        return switch (node) {
            .attribute => |attribute| context.document
                .attributesOf(attribute.element)[attribute.index].localName(),
            .namespace_node => |namespace_node| namespace_node.prefix,
            .node => |id| blk: {
                const node_value = context.document.node(id);
                break :blk switch (node_value.kind) {
                    .element => node_value.local,
                    .processing_instruction => node_value.name,
                    else => "",
                };
            },
        };
    }

    fn namespaceUri(
        self: *Evaluator,
        context: *const value.Context,
        node: value.NodeRef,
    ) []const u8 {
        _ = self;
        return switch (node) {
            .attribute => |attribute| context.document
                .attributesOf(attribute.element)[attribute.index].ns,
            .namespace_node => "",
            .node => |id| blk: {
                const node_value = context.document.node(id);
                break :blk if (node_value.kind == .element) node_value.ns else "";
            },
        };
    }

    fn nodeName(
        self: *Evaluator,
        context: *const value.Context,
        node: value.NodeRef,
    ) []const u8 {
        _ = self;
        return switch (node) {
            .attribute => |attribute| context.document
                .attributesOf(attribute.element)[attribute.index].name,
            .namespace_node => |namespace_node| namespace_node.prefix,
            .node => |id| blk: {
                const node_value = context.document.node(id);
                break :blk switch (node_value.kind) {
                    .element, .processing_instruction => node_value.name,
                    else => "",
                };
            },
        };
    }

    fn stringValue(
        self: *Evaluator,
        context: *const value.Context,
        node: value.NodeRef,
    ) Error![]const u8 {
        switch (node) {
            .attribute => |attribute| {
                return context.document
                    .attributesOf(attribute.element)[attribute.index].value;
            },
            .namespace_node => |namespace_node| {
                return namespace_node.uri;
            },
            .node => |id| {
                const node_value = context.document.node(id);
                switch (node_value.kind) {
                    .text, .comment, .processing_instruction => {
                        return node_value.value;
                    },
                    .element, .document => {
                        var out: std.ArrayList(u8) = .empty;
                        try self.appendTextValue(context, id, &out);
                        return out.toOwnedSlice(self.allocator);
                    },
                }
            },
        }
    }

    fn appendTextValue(
        self: *Evaluator,
        context: *const value.Context,
        id: dom.NodeId,
        out: *std.ArrayList(u8),
    ) Error!void {
        const node = context.document.node(id);
        if (node.kind == .text) {
            try out.appendSlice(self.allocator, node.value);
            return;
        }
        var child = node.first_child;
        while (child != dom.null_node) : (child = context.document.node(child).next_sibling) {
            try self.appendTextValue(context, child, out);
        }
    }

    fn firstInDocumentOrder(
        self: *Evaluator,
        nodes: []const value.NodeRef,
    ) ?value.NodeRef {
        _ = self;
        if (nodes.len == 0) return null;
        var best = nodes[0];
        for (nodes[1..]) |node| {
            if (value.orderLessThan({}, node, best)) best = node;
        }
        return best;
    }

    fn requireNodeSet(self: *Evaluator, result: value.Value) Error![]const value.NodeRef {
        _ = self;
        return switch (result) {
            .node_set => |nodes| nodes,
            else => error.InvalidArgument,
        };
    }

    fn sortDedup(self: *Evaluator, nodes: []const value.NodeRef) Error![]const value.NodeRef {
        if (nodes.len <= 1) return nodes;
        var copy: std.ArrayList(value.NodeRef) = .empty;
        try copy.appendSlice(self.allocator, nodes);
        std.mem.sort(value.NodeRef, copy.items, {}, value.orderLessThan);
        var out: std.ArrayList(value.NodeRef) = .empty;
        for (copy.items) |node| {
            if (out.items.len == 0 or !out.items[out.items.len - 1].eql(node)) {
                try out.append(self.allocator, node);
            }
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn toNumber(
        self: *Evaluator,
        result: value.Value,
        context: *const value.Context,
    ) Error!f64 {
        return switch (result) {
            .number => |number| number,
            .boolean => |boolean| if (boolean) 1 else 0,
            .string => |string| value.parseNumber(string),
            .node_set => |nodes| blk: {
                const node = self.firstInDocumentOrder(nodes) orelse
                    break :blk std.math.nan(f64);
                break :blk value.parseNumber(try self.stringValue(context, node));
            },
        };
    }

    fn toString(
        self: *Evaluator,
        result: value.Value,
        context: *const value.Context,
    ) Error![]const u8 {
        return switch (result) {
            .string => |string| string,
            .boolean => |boolean| if (boolean) "true" else "false",
            .number => |number| try value.formatNumber(self.allocator, number),
            .node_set => |nodes| blk: {
                const node = self.firstInDocumentOrder(nodes) orelse
                    break :blk "";
                break :blk try self.stringValue(context, node);
            },
        };
    }

    fn compare(
        self: *Evaluator,
        op: ast.Op,
        lhs: value.Value,
        rhs: value.Value,
        context: *const value.Context,
    ) Error!bool {
        const lhs_nodes = lhs == .node_set;
        const rhs_nodes = rhs == .node_set;
        if (lhs_nodes and rhs_nodes) {
            for (lhs.node_set) |a| {
                const a_value = value.Value{
                    .string = try self.stringValue(context, a),
                };
                for (rhs.node_set) |b| {
                    const b_value = value.Value{
                        .string = try self.stringValue(context, b),
                    };
                    if (try self.compareAtomic(op, a_value, b_value, context)) return true;
                }
            }
            return false;
        }
        if (lhs_nodes or rhs_nodes) {
            const nodes = if (lhs_nodes) lhs.node_set else rhs.node_set;
            const other = if (lhs_nodes) rhs else lhs;
            if (other == .boolean and (op == .eq or op == .ne)) {
                const lhs_boolean = if (lhs_nodes) lhs.toBoolean() else other.boolean;
                const rhs_boolean = if (rhs_nodes) rhs.toBoolean() else other.boolean;
                return if (op == .eq)
                    lhs_boolean == rhs_boolean
                else
                    lhs_boolean != rhs_boolean;
            }
            for (nodes) |node| {
                const node_value = value.Value{
                    .string = try self.stringValue(context, node),
                };
                const a = if (lhs_nodes) node_value else other;
                const b = if (lhs_nodes) other else node_value;
                if (try self.compareAtomic(op, a, b, context)) return true;
            }
            return false;
        }
        return self.compareAtomic(op, lhs, rhs, context);
    }

    fn compareAtomic(
        self: *Evaluator,
        op: ast.Op,
        lhs: value.Value,
        rhs: value.Value,
        context: *const value.Context,
    ) Error!bool {
        switch (op) {
            .eq, .ne => {
                if (lhs == .boolean or rhs == .boolean) {
                    const equal = lhs.toBoolean() == rhs.toBoolean();
                    return if (op == .eq) equal else !equal;
                }
                if (lhs == .number or rhs == .number) {
                    const a = try self.toNumber(lhs, context);
                    const b = try self.toNumber(rhs, context);
                    return if (op == .eq) a == b else a != b;
                }
                const a = try self.toString(lhs, context);
                const b = try self.toString(rhs, context);
                const equal = std.mem.eql(u8, a, b);
                return if (op == .eq) equal else !equal;
            },
            .lt, .le, .gt, .ge => {
                const a = try self.toNumber(lhs, context);
                const b = try self.toNumber(rhs, context);
                return switch (op) {
                    .lt => a < b,
                    .le => a <= b,
                    .gt => a > b,
                    .ge => a >= b,
                    else => unreachable,
                };
            },
            else => unreachable,
        }
    }

    fn evalFunction(
        self: *Evaluator,
        call: ast.FunctionCall,
        context: *const value.Context,
    ) Error!value.Value {
        var args: std.ArrayList(value.Value) = .empty;
        for (call.args) |arg| {
            try args.append(self.allocator, try self.eval(arg, context));
        }
        const name = call.name;
        const items = args.items;

        if (std.mem.eql(u8, name, "last")) {
            if (items.len != 0) return error.InvalidArgument;
            return .{ .number = @floatFromInt(context.size) };
        }
        if (std.mem.eql(u8, name, "position")) {
            if (items.len != 0) return error.InvalidArgument;
            return .{ .number = @floatFromInt(context.position) };
        }
        if (std.mem.eql(u8, name, "count")) {
            if (items.len != 1) return error.InvalidArgument;
            return .{ .number = @floatFromInt(
                (try self.requireNodeSet(items[0])).len,
            ) };
        }
        if (std.mem.eql(u8, name, "local-name")) {
            const node = try self.functionNode(items, context);
            return .{ .string = if (node) |n| self.localName(context, n) else "" };
        }
        if (std.mem.eql(u8, name, "namespace-uri")) {
            const node = try self.functionNode(items, context);
            return .{ .string = if (node) |n| self.namespaceUri(context, n) else "" };
        }
        if (std.mem.eql(u8, name, "name")) {
            const node = try self.functionNode(items, context);
            return .{ .string = if (node) |n| self.nodeName(context, n) else "" };
        }
        if (std.mem.eql(u8, name, "string")) {
            if (items.len == 0) return .{ .string = try self.toString(.{
                .node_set = &.{context.node},
            }, context) };
            if (items.len != 1) return error.InvalidArgument;
            return .{ .string = try self.toString(items[0], context) };
        }
        if (std.mem.eql(u8, name, "concat")) {
            if (items.len < 2) return error.InvalidArgument;
            var out: std.ArrayList(u8) = .empty;
            for (items) |item| {
                try out.appendSlice(
                    self.allocator,
                    try self.toString(item, context),
                );
            }
            return .{ .string = try out.toOwnedSlice(self.allocator) };
        }
        if (std.mem.eql(u8, name, "starts-with")) {
            if (items.len != 2) return error.InvalidArgument;
            const a = try self.toString(items[0], context);
            const b = try self.toString(items[1], context);
            return .{ .boolean = std.mem.startsWith(u8, a, b) };
        }
        if (std.mem.eql(u8, name, "contains")) {
            if (items.len != 2) return error.InvalidArgument;
            const a = try self.toString(items[0], context);
            const b = try self.toString(items[1], context);
            return .{ .boolean = std.mem.indexOf(u8, a, b) != null };
        }
        if (std.mem.eql(u8, name, "substring-before")) {
            if (items.len != 2) return error.InvalidArgument;
            const a = try self.toString(items[0], context);
            const b = try self.toString(items[1], context);
            if (std.mem.indexOf(u8, a, b)) |index| {
                return .{ .string = a[0..index] };
            }
            return .{ .string = "" };
        }
        if (std.mem.eql(u8, name, "substring-after")) {
            if (items.len != 2) return error.InvalidArgument;
            const a = try self.toString(items[0], context);
            const b = try self.toString(items[1], context);
            if (std.mem.indexOf(u8, a, b)) |index| {
                return .{ .string = a[index + b.len ..] };
            }
            return .{ .string = "" };
        }
        if (std.mem.eql(u8, name, "substring")) {
            if (items.len != 2 and items.len != 3) return error.InvalidArgument;
            const text = try self.toString(items[0], context);
            const start = try self.toNumber(items[1], context);
            const length: f64 = if (items.len == 3)
                try self.toNumber(items[2], context)
            else
                std.math.inf(f64);
            return .{ .string = try self.substring(text, start, length) };
        }
        if (std.mem.eql(u8, name, "string-length")) {
            const text = if (items.len == 0)
                try self.toString(.{ .node_set = &.{context.node} }, context)
            else if (items.len == 1)
                try self.toString(items[0], context)
            else
                return error.InvalidArgument;
            return .{ .number = @floatFromInt(codepointCount(text)) };
        }
        if (std.mem.eql(u8, name, "normalize-space")) {
            const text = if (items.len == 0)
                try self.toString(.{ .node_set = &.{context.node} }, context)
            else if (items.len == 1)
                try self.toString(items[0], context)
            else
                return error.InvalidArgument;
            return .{ .string = try self.normalizeSpace(text) };
        }
        if (std.mem.eql(u8, name, "translate")) {
            if (items.len != 3) return error.InvalidArgument;
            const text = try self.toString(items[0], context);
            const from = try self.toString(items[1], context);
            const to = try self.toString(items[2], context);
            return .{ .string = try self.translate(text, from, to) };
        }
        if (std.mem.eql(u8, name, "boolean")) {
            if (items.len != 1) return error.InvalidArgument;
            return .{ .boolean = items[0].toBoolean() };
        }
        if (std.mem.eql(u8, name, "not")) {
            if (items.len != 1) return error.InvalidArgument;
            return .{ .boolean = !items[0].toBoolean() };
        }
        if (std.mem.eql(u8, name, "true")) {
            if (items.len != 0) return error.InvalidArgument;
            return .{ .boolean = true };
        }
        if (std.mem.eql(u8, name, "false")) {
            if (items.len != 0) return error.InvalidArgument;
            return .{ .boolean = false };
        }
        if (std.mem.eql(u8, name, "lang")) {
            if (items.len != 1) return error.InvalidArgument;
            const requested = try self.toString(items[0], context);
            return .{ .boolean = self.lang(context, context.node, requested) };
        }
        if (std.mem.eql(u8, name, "number")) {
            if (items.len == 0) {
                return .{ .number = try self.toNumber(.{
                    .node_set = &.{context.node},
                }, context) };
            }
            if (items.len != 1) return error.InvalidArgument;
            return .{ .number = try self.toNumber(items[0], context) };
        }
        if (std.mem.eql(u8, name, "sum")) {
            if (items.len != 1) return error.InvalidArgument;
            const nodes = try self.requireNodeSet(items[0]);
            var total: f64 = 0;
            for (nodes) |node| {
                total += value.parseNumber(try self.stringValue(context, node));
            }
            return .{ .number = total };
        }
        if (std.mem.eql(u8, name, "floor")) {
            if (items.len != 1) return error.InvalidArgument;
            return .{ .number = std.math.floor(try self.toNumber(items[0], context)) };
        }
        if (std.mem.eql(u8, name, "ceiling")) {
            if (items.len != 1) return error.InvalidArgument;
            return .{ .number = std.math.ceil(try self.toNumber(items[0], context)) };
        }
        if (std.mem.eql(u8, name, "round")) {
            if (items.len != 1) return error.InvalidArgument;
            const number = try self.toNumber(items[0], context);
            return .{ .number = std.math.floor(number + 0.5) };
        }
        if (std.mem.eql(u8, name, "id")) {
            if (items.len != 1) return error.InvalidArgument;
            const text = try self.toString(items[0], context);
            return .{ .node_set = try self.idLookup(context, text) };
        }
        return error.UnknownFunction;
    }

    fn functionNode(
        self: *Evaluator,
        args: []const value.Value,
        context: *const value.Context,
    ) Error!?value.NodeRef {
        if (args.len == 0) return context.node;
        if (args.len != 1) return error.InvalidArgument;
        const nodes = try self.requireNodeSet(args[0]);
        return self.firstInDocumentOrder(nodes);
    }

    fn substring(
        self: *Evaluator,
        text: []const u8,
        start: f64,
        length: f64,
    ) Error![]const u8 {
        if (std.math.isNan(start) or std.math.isNan(length)) return "";
        const start_round = std.math.floor(start + 0.5);
        const end_round = if (std.math.isInf(length))
            std.math.inf(f64)
        else
            start_round + std.math.floor(length + 0.5);
        var out: std.ArrayList(u8) = .empty;
        var position: f64 = 1;
        var index: usize = 0;
        while (index < text.len) {
            const sequence_length = std.unicode.utf8ByteSequenceLength(text[index]) catch
                return error.InvalidArgument;
            const next = index + sequence_length;
            if (position >= start_round and position < end_round) {
                try out.appendSlice(self.allocator, text[index..next]);
            }
            position += 1;
            index = next;
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn normalizeSpace(self: *Evaluator, text: []const u8) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var pending_space = false;
        var started = false;
        for (text) |byte| {
            if (byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n') {
                if (started) pending_space = true;
                continue;
            }
            if (pending_space) {
                try out.append(self.allocator, ' ');
                pending_space = false;
            }
            try out.append(self.allocator, byte);
            started = true;
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn translate(
        self: *Evaluator,
        text: []const u8,
        from: []const u8,
        to: []const u8,
    ) Error![]const u8 {
        const from_points = try self.codepoints(from);
        const to_points = try self.codepoints(to);
        var out: std.ArrayList(u8) = .empty;
        var index: usize = 0;
        while (index < text.len) {
            const length = std.unicode.utf8ByteSequenceLength(text[index]) catch
                return error.InvalidArgument;
            const codepoint = std.unicode.utf8Decode(text[index..][0..length]) catch
                return error.InvalidArgument;
            var replaced = false;
            for (from_points, 0..) |candidate, candidate_index| {
                if (candidate == codepoint) {
                    if (candidate_index < to_points.len) {
                        var buffer: [4]u8 = undefined;
                        const encoded = std.unicode.utf8Encode(
                            to_points[candidate_index],
                            &buffer,
                        ) catch return error.InvalidArgument;
                        try out.appendSlice(self.allocator, buffer[0..encoded]);
                    }
                    replaced = true;
                    break;
                }
            }
            if (!replaced) try out.appendSlice(self.allocator, text[index..][0..length]);
            index += length;
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn codepoints(self: *Evaluator, text: []const u8) Error![]const u21 {
        var out: std.ArrayList(u21) = .empty;
        var index: usize = 0;
        while (index < text.len) {
            const length = std.unicode.utf8ByteSequenceLength(text[index]) catch
                return error.InvalidArgument;
            const codepoint = std.unicode.utf8Decode(text[index..][0..length]) catch
                return error.InvalidArgument;
            try out.append(self.allocator, codepoint);
            index += length;
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn lang(
        self: *Evaluator,
        context: *const value.Context,
        node: value.NodeRef,
        requested: []const u8,
    ) bool {
        var current: ?value.NodeRef = node;
        while (current) |ref| {
            if (self.kind(context, ref) == .element) {
                const id = ref.node;
                if (context.document.attributeNs(
                    id,
                    namespace.xml_uri,
                    "lang",
                )) |language| {
                    if (language.len == requested.len) {
                        return std.ascii.eqlIgnoreCase(language, requested);
                    }
                    if (language.len > requested.len and
                        language[requested.len] == '-')
                    {
                        return std.ascii.eqlIgnoreCase(
                            language[0..requested.len],
                            requested,
                        );
                    }
                    return false;
                }
            }
            current = self.parentOf(context, ref);
        }
        return false;
    }

    fn idLookup(
        self: *Evaluator,
        context: *const value.Context,
        text: []const u8,
    ) Error![]const value.NodeRef {
        var out: std.ArrayList(value.NodeRef) = .empty;
        var tokens = std.mem.tokenizeAny(u8, text, " \t\r\n");
        while (tokens.next()) |token| {
            for (context.document.nodes, 0..) |node, index| {
                if (node.kind != .element) continue;
                const id = @as(dom.NodeId, @intCast(index));
                if (context.document.attribute(id, "id")) |id_value| {
                    if (std.mem.eql(u8, id_value, token)) {
                        try out.append(self.allocator, .{ .node = id });
                        continue;
                    }
                }
                if (context.document.attributeNs(id, namespace.xml_uri, "id")) |xml_id| {
                    if (std.mem.eql(u8, xml_id, token)) {
                        try out.append(self.allocator, .{ .node = id });
                    }
                }
            }
        }
        return self.sortDedup(out.items);
    }
};

fn codepointCount(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}
