//! XPath 1.0 evaluator over `dom.Document`.

const std = @import("std");
const ast = @import("ast.zig");
const value = @import("value.zig");
const dom = @import("../dom.zig");
const namespace = @import("../namespace.zig");
const exslt = @import("exslt.zig");
const exslt_date = @import("exslt_date.zig");
const xmlbase = @import("../xmlbase.zig");

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

/// Evaluate without an intermediate arena. The returned value and all of its
/// strings/node arrays are allocated with `allocator` and live as long as it
/// does; this is intended for callers that already own a transform arena and
/// copy out or consume the value immediately.
pub fn evaluateDirect(
    allocator: std.mem.Allocator,
    expression: *const ast.Expr,
    context: *const value.Context,
) Error!value.Value {
    var evaluator: Evaluator = .{ .allocator = allocator };
    return evaluator.eval(expression, context);
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
            .variable => |name| context.variable(name) orelse blk: {
                const resolver = context.variable_resolver orelse
                    return error.UndefinedVariable;
                break :blk (resolver.resolve(
                    resolver.context,
                    name,
                ) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.UndefinedVariable,
                }) orelse return error.UndefinedVariable;
            },
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
                    context,
                );
                const rhs = try self.requireNodeSet(
                    try self.eval(binary.rhs, context),
                    context,
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
        // Single-step relative paths (`@href`, `title`, `text()`, `.`) are
        // extremely common. Evaluate them directly instead of allocating an
        // axis result, a filtered result, and a sorted copy.
        if (path.start == null and !path.absolute and path.steps.len == 1) {
            const step = path.steps[0];
            if (step.predicates.len == 0) {
                const prefix_uri = try resolveNameTestPrefix(
                    context,
                    step.node_test,
                );
                var out: std.ArrayList(value.NodeRef) = .empty;
                if (try self.appendSingleAxis(
                    context,
                    context.node,
                    step,
                    prefix_uri,
                    &out,
                )) {
                    if (out.items.len == 0) return .{ .node_set = &.{} };
                    const owned: []const value.NodeRef = try out.toOwnedSlice(
                        self.allocator,
                    );
                    return .{ .node_set = owned };
                }
            }
        }
        // `//name` collects children matching a name test from every
        // descendant. A single preorder traversal is much cheaper than
        // materializing every descendant and then testing their children.
        if (path.absolute and path.start == null and
            path.steps.len == 2 and
            path.steps[0].axis == .descendant_or_self and
            path.steps[0].predicates.len == 0 and
            path.steps[0].node_test == .node and
            path.steps[1].axis == .child and
            !predicatesNeedPositions(path.steps[1].predicates))
        {
            const step = path.steps[1];
            const prefix_uri = try resolveNameTestPrefix(
                context,
                step.node_test,
            );
            var out: std.ArrayList(value.NodeRef) = .empty;
            try self.appendDescendantMatches(
                context,
                documentRootOf(context, context.node),
                step,
                prefix_uri,
                &out,
            );
            if (step.predicates.len != 0) {
                if (try self.filterDescendantMatches(
                    context,
                    step.predicates,
                    &out,
                )) |nodes| {
                    return .{ .node_set = nodes };
                }
                // A predicate produced a numeric result (positional
                // filtering), so the general path must handle it.
            } else {
                if (out.items.len == 0) return .{ .node_set = &.{} };
                const owned: []const value.NodeRef = try out.toOwnedSlice(
                    self.allocator,
                );
                return .{ .node_set = owned };
            }
        }
        var initial: [1]value.NodeRef = undefined;
        var current: []const value.NodeRef = undefined;
        if (path.start) |start_expression| {
            current = try self.requireNodeSet(
                try self.eval(start_expression, context),
                context,
            );
        } else if (path.absolute) {
            initial[0] = documentRootOf(context, context.node);
            current = initial[0..1];
        } else {
            initial[0] = context.node;
            current = initial[0..1];
        }
        if (path.steps.len == 0) {
            // Nothing consumes the initial node, so it cannot stay on this
            // stack frame.
            const nodes = try self.allocator.alloc(
                value.NodeRef,
                current.len,
            );
            @memcpy(nodes, current);
            return .{ .node_set = nodes };
        }
        for (path.steps) |step| {
            current = try self.applyStep(context, current, step);
        }
        return .{ .node_set = current };
    }

    /// Evaluate a single child or attribute step from one context node.
    /// Returns null when the context node kind cannot have that axis, so the
    /// general path can handle it.
    /// Append the matches of one child, attribute, or self step from a single
    /// context node. Returns false when the axis or node kind needs the
    /// general path.
    fn appendSingleAxis(
        self: *Evaluator,
        context: *const value.Context,
        node: value.NodeRef,
        step: ast.Step,
        prefix_uri: ?[]const u8,
        out: *std.ArrayList(value.NodeRef),
    ) Error!bool {
        switch (step.axis) {
            .self_axis => {
                if (try self.matchesTest(
                    context,
                    node,
                    step.node_test,
                    step.axis,
                    prefix_uri,
                )) {
                    try out.append(self.allocator, node);
                }
                return true;
            },
            .child, .attribute => {
                const id = switch (node) {
                    .node => |node_id| node_id,
                    else => return false,
                };
                switch (step.axis) {
                    .child => {
                        const node_value = context.document.node(id);
                        if (node_value.kind != .document and
                            node_value.kind != .element)
                        {
                            return false;
                        }
                        var child = node_value.first_child;
                        while (child != dom.null_node) : (child =
                            context.document.node(child).next_sibling)
                        {
                            const candidate: value.NodeRef = .{ .node = child };
                            if (try self.matchesTest(
                                context,
                                candidate,
                                step.node_test,
                                step.axis,
                                prefix_uri,
                            )) {
                                try out.append(self.allocator, candidate);
                            }
                        }
                    },
                    else => {
                        if (context.document.node(id).kind != .element) {
                            return false;
                        }
                        const attributes = context.document.attributesOf(id);
                        for (attributes, 0..) |attribute, index| {
                            if (namespace.Resolver.isNamespaceDeclaration(
                                attribute.name,
                            )) continue;
                            const candidate: value.NodeRef = .{
                                .attribute = .{
                                    .element = id,
                                    .index = @intCast(index),
                                },
                            };
                            if (try self.matchesTest(
                                context,
                                candidate,
                                step.node_test,
                                step.axis,
                                prefix_uri,
                            )) {
                                try out.append(self.allocator, candidate);
                            }
                        }
                    },
                }
                return true;
            },
            else => return false,
        }
    }

    fn evalFilter(
        self: *Evaluator,
        filter: ast.Filter,
        context: *const value.Context,
    ) Error!value.Value {
        const primary = try self.requireNodeSet(
            try self.eval(filter.primary, context),
            context,
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
        const prefix_uri = try resolveNameTestPrefix(context, step.node_test);
        if (input.len == 1 and step.predicates.len == 0) {
            var single: std.ArrayList(value.NodeRef) = .empty;
            if (try self.appendSingleAxis(
                context,
                input[0],
                step,
                prefix_uri,
                &single,
            )) {
                if (single.items.len == 0) return &.{};
                const owned: []const value.NodeRef = try single.toOwnedSlice(
                    self.allocator,
                );
                return owned;
            }
        }
        // Predicates that do not depend on position can be evaluated while
        // collecting the axis matches, which avoids a filtered list per
        // input node (important for `$nodes/child[@attr = $value]`).
        if (step.predicates.len != 0 and
            !predicatesNeedPositions(step.predicates) and
            (step.axis == .child or step.axis == .attribute))
        {
            if (try self.applyStepPredicates(
                context,
                input,
                step,
                prefix_uri,
            )) |nodes| {
                return nodes;
            }
        }
        var result: std.ArrayList(value.NodeRef) = .empty;
        var axis_buffer: std.ArrayList(value.NodeRef) = .empty;
        var matched: std.ArrayList(value.NodeRef) = .empty;
        for (input) |node| {
            matched.clearRetainingCapacity();
            // Child, attribute, and self steps are tested while walking the
            // axis, so no intermediate axis list is needed.
            if (!try self.appendSingleAxis(
                context,
                node,
                step,
                prefix_uri,
                &matched,
            )) {
                axis_buffer.clearRetainingCapacity();
                try self.appendAxisNodes(
                    context,
                    node,
                    step.axis,
                    &axis_buffer,
                );
                for (axis_buffer.items) |candidate| {
                    if (try self.matchesTest(
                        context,
                        candidate,
                        step.node_test,
                        step.axis,
                        prefix_uri,
                    )) {
                        try matched.append(self.allocator, candidate);
                    }
                }
            }
            const filtered = try self.applyPredicates(
                context,
                matched.items,
                step.predicates,
            );
            try result.appendSlice(self.allocator, filtered);
        }
        // A single input node on a forward axis produces document-ordered,
        // duplicate-free results, so the sort/dedup pass is unnecessary.
        if (input.len == 1 and isForwardAxis(step.axis)) {
            if (result.items.len == 0) return &.{};
            const owned: []const value.NodeRef = try result.toOwnedSlice(
                self.allocator,
            );
            return owned;
        }
        return self.sortDedup(result.items);
    }

    /// Evaluate a child/attribute step whose predicates do not depend on
    /// position, collecting and filtering candidates in one pass. Returns
    /// null when a predicate produces a number and the general path must run.
    fn applyStepPredicates(
        self: *Evaluator,
        context: *const value.Context,
        input: []const value.NodeRef,
        step: ast.Step,
        prefix_uri: ?[]const u8,
    ) Error!?[]const value.NodeRef {
        var out: std.ArrayList(value.NodeRef) = .empty;
        var axis_buffer: std.ArrayList(value.NodeRef) = .empty;
        var predicate_context = context.*;
        predicate_context.position = 1;
        predicate_context.size = 1;
        for (input) |node| {
            axis_buffer.clearRetainingCapacity();
            try self.appendAxisNodes(
                context,
                node,
                step.axis,
                &axis_buffer,
            );
            for (axis_buffer.items) |candidate| {
                if (!try self.matchesTest(
                    context,
                    candidate,
                    step.node_test,
                    step.axis,
                    prefix_uri,
                )) continue;
                predicate_context.node = candidate;
                var keep = true;
                for (step.predicates) |predicate| {
                    const result = try self.eval(predicate, &predicate_context);
                    if (result == .number) return null;
                    if (!result.toBoolean()) {
                        keep = false;
                        break;
                    }
                }
                if (keep) try out.append(self.allocator, candidate);
            }
        }
        if (input.len == 1) {
            if (out.items.len == 0) return &.{};
            const owned: ?[]const value.NodeRef = try out.toOwnedSlice(
                self.allocator,
            );
            return owned;
        }
        const sorted: ?[]const value.NodeRef = try self.sortDedup(out.items);
        return sorted;
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

    fn appendAxisNodes(
        self: *Evaluator,
        context: *const value.Context,
        node: value.NodeRef,
        axis: ast.Axis,
        out: *std.ArrayList(value.NodeRef),
    ) Error!void {
        switch (axis) {
            .self_axis => try out.append(self.allocator, node),
            .child => try self.appendChildren(context, node, out),
            .attribute => try self.appendAttributes(context, node, out),
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
            .descendant => try self.appendDescendants(context, node, out),
            .descendant_or_self => {
                try out.append(self.allocator, node);
                try self.appendDescendants(context, node, out);
            },
            .following_sibling => try self.appendFollowingSiblings(
                context,
                node,
                out,
            ),
            .preceding_sibling => try self.appendPrecedingSiblings(
                context,
                node,
                out,
            ),
            .following => try self.appendFollowing(context, node, out),
            .preceding => try self.appendPreceding(context, node, out),
            .namespace_axis => try self.appendNamespaces(context, node, out),
        }
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
        // libxml2 places the implicit xml binding first on the axis.
        for (bindings, 0..) |binding, index| {
            if (!std.mem.eql(u8, binding.prefix, "xml")) continue;
            if (index == 0) break;
            const xml_binding = binding;
            var move = index;
            while (move > 0) : (move -= 1) {
                bindings[move] = bindings[move - 1];
            }
            bindings[0] = xml_binding;
            break;
        }
        for (bindings, 0..) |binding, index| {
            try out.append(self.allocator, .{ .namespace_node = .{
                .element = id,
                .prefix = binding.prefix,
                .uri = binding.uri,
                .order = @intCast(index),
            } });
        }
    }

    /// Apply non-positional predicates to the collected nodes. Returns null
    /// when a predicate yields a number, which the caller must treat as
    /// positional filtering.
    fn filterDescendantMatches(
        self: *Evaluator,
        context: *const value.Context,
        predicates: []const *ast.Expr,
        nodes: *std.ArrayList(value.NodeRef),
    ) Error!?[]const value.NodeRef {
        var predicate_context = context.*;
        predicate_context.position = 1;
        predicate_context.size = 1;
        var filtered: std.ArrayList(value.NodeRef) = .empty;
        outer: for (nodes.items) |candidate| {
            predicate_context.node = candidate;
            for (predicates) |predicate| {
                const result = try self.eval(predicate, &predicate_context);
                if (result == .number) return null;
                if (!result.toBoolean()) continue :outer;
            }
            try filtered.append(self.allocator, candidate);
        }
        if (filtered.items.len == 0) return &.{};
        const owned: []const value.NodeRef = try filtered.toOwnedSlice(
            self.allocator,
        );
        return owned;
    }

    fn appendDescendantMatches(
        self: *Evaluator,
        context: *const value.Context,
        node: value.NodeRef,
        step: ast.Step,
        prefix_uri: ?[]const u8,
        out: *std.ArrayList(value.NodeRef),
    ) Error!void {
        const id = switch (node) {
            .node => |node_id| node_id,
            else => return,
        };
        const node_value = context.document.node(id);
        if (node_value.kind != .document and node_value.kind != .element) {
            return;
        }
        var child = node_value.first_child;
        while (child != dom.null_node) : (child =
            context.document.node(child).next_sibling)
        {
            const candidate: value.NodeRef = .{ .node = child };
            if (try self.matchesTest(
                context,
                candidate,
                step.node_test,
                .child,
                prefix_uri,
            )) {
                try out.append(self.allocator, candidate);
            }
            try self.appendDescendantMatches(
                context,
                candidate,
                step,
                prefix_uri,
                out,
            );
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

    fn resolveNameTestPrefix(
        context: *const value.Context,
        node_test: ast.NodeTest,
    ) Error!?[]const u8 {
        switch (node_test) {
            .name => |name_test| {
                if (name_test.prefix) |prefix| {
                    return context.resolvePrefix(prefix) orelse
                        error.UndefinedPrefix;
                }
            },
            else => {},
        }
        return null;
    }

    fn matchesTest(
        self: *Evaluator,
        context: *const value.Context,
        node: value.NodeRef,
        node_test: ast.NodeTest,
        axis: ast.Axis,
        prefix_uri: ?[]const u8,
    ) Error!bool {
        switch (node_test) {
            .node => return true,
            .text => return self.kind(context, node) == .text,
            .comment => return self.kind(context, node) == .comment,
            .processing_instruction => |target| {
                if (self.kind(context, node) != .processing_instruction) {
                    return false;
                }
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
                    switch (node) {
                        .namespace_node => {},
                        else => return false,
                    }
                    if (name_test.prefix != null) {
                        // Namespace nodes have a null namespace URI, so a
                        // prefixed name test can never match one.
                        _ = prefix_uri orelse return error.UndefinedPrefix;
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
                var local: []const u8 = undefined;
                var uri: []const u8 = undefined;
                switch (node) {
                    .node => |id| {
                        if (axis == .attribute) return false;
                        const node_value = context.document.node(id);
                        if (node_value.kind != .element) return false;
                        local = node_value.local;
                        uri = node_value.ns;
                    },
                    .attribute => |attr| {
                        if (axis != .attribute) return false;
                        const node_value = context.document.attributesOf(
                            attr.element,
                        )[attr.index];
                        local = node_value.localName();
                        uri = node_value.ns;
                    },
                    .namespace_node => return false,
                }
                if (name_test.prefix == null and name_test.local == null) {
                    return true;
                }
                if (name_test.local) |expected| {
                    if (!std.mem.eql(u8, local, expected)) return false;
                }
                if (name_test.prefix != null) {
                    const expected_uri = prefix_uri orelse
                        return error.UndefinedPrefix;
                    return std.mem.eql(u8, uri, expected_uri);
                }
                return uri.len == 0;
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

    fn buildTextNodeSet(
        self: *Evaluator,
        context: *const value.Context,
        text: []const u8,
    ) Error!value.Value {
        const factory = context.fragment_factory orelse
            return error.InvalidArgument;
        const nodes = factory.build(
            factory.context,
            self.allocator,
            &.{.{ .name = null, .text = text }},
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidArgument,
        };
        return .{ .node_set = nodes };
    }

    fn buildTokenNodeSet(
        self: *Evaluator,
        context: *const value.Context,
        tokens: []const []const u8,
    ) Error!value.Value {
        const factory = context.fragment_factory orelse
            return error.InvalidArgument;
        const specs = try self.allocator.alloc(value.FragmentNode, tokens.len);
        for (tokens, 0..) |token, index| {
            specs[index] = .{ .name = "token", .text = token };
        }
        const nodes = factory.build(
            factory.context,
            self.allocator,
            specs,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidArgument,
        };
        return .{ .node_set = nodes };
    }

    fn stringList(
        self: *Evaluator,
        context: *const value.Context,
        input: value.Value,
    ) Error![]const []const u8 {
        switch (input) {
            .node_set => |nodes| {
                const out = try self.allocator.alloc([]const u8, nodes.len);
                for (nodes, 0..) |node, index| {
                    out[index] = try self.stringValue(context, node);
                }
                return out;
            },
            else => {
                const out = try self.allocator.alloc([]const u8, 1);
                out[0] = try self.toString(input, context);
                return out;
            },
        }
    }

    fn optionalStringList(
        self: *Evaluator,
        context: *const value.Context,
        input: value.Value,
        count: usize,
    ) Error![]const ?[]const u8 {
        switch (input) {
            .node_set => |nodes| {
                const out = try self.allocator.alloc(?[]const u8, count);
                for (0..count) |index| {
                    out[index] = if (index < nodes.len)
                        try self.stringValue(context, nodes[index])
                    else
                        null;
                }
                return out;
            },
            else => {
                const out = try self.allocator.alloc(?[]const u8, count);
                const text = try self.toString(input, context);
                out[0] = text;
                for (out[1..]) |*entry| entry.* = null;
                return out;
            },
        }
    }

    /// Convert a value to a node-set, accepting result tree fragments like
    /// libxslt.
    fn toNodeSet(
        self: *Evaluator,
        context: *const value.Context,
        input: value.Value,
    ) Error![]const value.NodeRef {
        return switch (input) {
            .node_set => |nodes| nodes,
            .tree => |tree| blk: {
                const converter = context.tree_converter orelse
                    return error.InvalidArgument;
                const converted = try converter.convert(
                    converter.context,
                    self.allocator,
                    tree,
                ) orelse return error.InvalidArgument;
                const nodes = try self.allocator.alloc(value.NodeRef, 1);
                nodes[0] = converted;
                break :blk nodes;
            },
            else => error.InvalidArgument,
        };
    }

    fn requireNodeSet(
        self: *Evaluator,
        result: value.Value,
        context: *const value.Context,
    ) Error![]const value.NodeRef {
        return switch (result) {
            .node_set => |nodes| nodes,
            // libxslt treats result tree fragments as node-sets containing
            // the fragment root in node-set contexts.
            .tree => |tree| blk: {
                const converter = context.tree_converter orelse
                    return error.InvalidArgument;
                const converted = try converter.convert(
                    converter.context,
                    self.allocator,
                    tree,
                ) orelse return error.InvalidArgument;
                const nodes = try self.allocator.alloc(value.NodeRef, 1);
                nodes[0] = converted;
                break :blk nodes;
            },
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
            .tree => |tree| value.parseNumber(try self.treeStringValue(tree)),
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
            .tree => |tree| try self.treeStringValue(tree),
        };
    }

    fn treeStringValue(
        self: *Evaluator,
        tree: *const value.TreeFragment,
    ) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try self.appendDocumentText(
            tree.document,
            tree.document.documentNode(),
            &out,
        );
        return out.toOwnedSlice(self.allocator);
    }

    fn appendDocumentText(
        self: *Evaluator,
        document: *const dom.Document,
        id: dom.NodeId,
        out: *std.ArrayList(u8),
    ) Error!void {
        const node = document.node(id);
        if (node.kind == .text) {
            try out.appendSlice(self.allocator, node.value);
            return;
        }
        var child = node.first_child;
        while (child != dom.null_node) : (child = document.node(child).next_sibling) {
            try self.appendDocumentText(document, child, out);
        }
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
        // Most calls take a handful of arguments; keep them on the stack.
        var stack_args: [4]value.Value = undefined;
        var heap_args: std.ArrayList(value.Value) = .empty;
        const items: []const value.Value = if (call.args.len <= stack_args.len) blk: {
            for (call.args, 0..) |arg, index| {
                stack_args[index] = try self.eval(arg, context);
            }
            break :blk stack_args[0..call.args.len];
        } else blk: {
            for (call.args) |arg| {
                try heap_args.append(self.allocator, try self.eval(arg, context));
            }
            break :blk heap_args.items;
        };
        const name = call.name;

        if (std.mem.eql(u8, name, "last")) {
            if (items.len != 0) return error.InvalidArgument;
            return .{ .number = @floatFromInt(context.size) };
        }
        if (std.mem.eql(u8, name, "position")) {
            if (items.len != 0) return error.InvalidArgument;
            return .{ .number = @floatFromInt(context.position) };
        }
        if (std.mem.eql(u8, name, "current")) {
            if (items.len != 0) return error.InvalidArgument;
            const nodes = try self.allocator.alloc(value.NodeRef, 1);
            nodes[0] = context.current orelse context.node;
            return .{ .node_set = nodes };
        }
        if (std.mem.eql(u8, name, "format-number")) {
            if (items.len != 2 and items.len != 3) {
                return error.InvalidArgument;
            }
            const number = try self.toNumber(items[0], context);
            const pattern = try self.toString(items[1], context);
            const format_name: ?value.QualifiedName = if (items.len == 3) blk: {
                const raw = try self.toString(items[2], context);
                const qname = namespace.splitQName(raw) catch
                    return error.InvalidArgument;
                var uri: []const u8 = "";
                if (qname.prefix.len != 0) {
                    uri = context.resolvePrefix(qname.prefix) orelse
                        return error.InvalidArgument;
                }
                break :blk .{ .uri = uri, .local = qname.local };
            } else null;
            const formatter = context.number_formatter orelse
                return error.UnknownFunction;
            const text = formatter.format(
                formatter.context,
                self.allocator,
                number,
                pattern,
                format_name,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidFormat => return error.InvalidArgument,
            };
            return .{ .string = text };
        }
        if (std.mem.eql(u8, name, "key")) {
            if (items.len != 2) return error.InvalidArgument;
            const key_name = try self.toString(items[0], context);
            const key_value = try self.toString(items[1], context);
            const resolver = context.key_resolver orelse
                return .{ .node_set = &.{} };
            const nodes = resolver.lookup(
                resolver.context,
                self.allocator,
                key_name,
                key_value,
                context.node,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
            };
            return .{ .node_set = nodes };
        }
        if (std.mem.eql(u8, name, "count")) {
            if (items.len != 1) return error.InvalidArgument;
            return .{ .number = @floatFromInt(
                (try self.requireNodeSet(items[0], context)).len,
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
            const nodes = try self.requireNodeSet(items[0], context);
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
        if (std.mem.eql(u8, name, "generate-id")) {
            if (!context.xslt_functions) return error.UnknownFunction;
            if (items.len > 1) return error.InvalidArgument;
            const node = if (items.len == 0)
                context.node
            else
                self.firstInDocumentOrder(
                    try self.requireNodeSet(items[0], context),
                ) orelse return .{ .string = "" };
            const generator = context.node_id_generator orelse
                return .{ .string = "" };
            return .{ .string = try generator.generate(
                generator.context,
                self.allocator,
                context.document,
                node,
            ) };
        }
        if (std.mem.eql(u8, name, "system-property")) {
            if (!context.xslt_functions) return error.UnknownFunction;
            if (items.len != 1) return error.InvalidArgument;
            const raw = try self.toString(items[0], context);
            const qname = (try self.resolveQName(context, raw)) orelse
                return .{ .string = "" };
            if (!std.mem.eql(u8, qname.uri, namespace.xsl_uri)) {
                return .{ .string = "" };
            }
            if (std.mem.eql(u8, qname.local, "version")) {
                return .{ .string = "1.0" };
            }
            if (std.mem.eql(u8, qname.local, "vendor")) {
                return .{ .string = "xmlz" };
            }
            if (std.mem.eql(u8, qname.local, "vendor-url")) {
                return .{ .string = "https://github.com/passchaos/xmlz" };
            }
            return .{ .string = "" };
        }
        if (std.mem.eql(u8, name, "element-available")) {
            if (!context.xslt_functions) return error.UnknownFunction;
            if (items.len != 1) return error.InvalidArgument;
            const raw = try self.toString(items[0], context);
            const qname = (try self.resolveQName(context, raw)) orelse
                return .{ .boolean = false };
            var uri = qname.uri;
            if (uri.len == 0 and
                std.mem.indexOfScalar(u8, raw, ':') == null)
            {
                // An unprefixed instruction name resolves through the
                // default namespace, matching libxslt.
                uri = context.resolvePrefix("") orelse "";
            }
            if (!std.mem.eql(u8, uri, namespace.xsl_uri)) {
                // Extension instructions provided by the EXSLT functions
                // module and libxslt's test module, matching libxslt.
                if (std.mem.eql(u8, uri, "http://exslt.org/functions") and
                    std.mem.eql(u8, qname.local, "result"))
                {
                    return .{ .boolean = true };
                }
                if (std.mem.eql(u8, uri, "http://xmlsoft.org/XSLT/") and
                    std.mem.eql(u8, qname.local, "test"))
                {
                    return .{ .boolean = true };
                }
                return .{ .boolean = false };
            }
            return .{ .boolean = nameInTable(&xslt_elements, qname.local) };
        }
        if (std.mem.eql(u8, name, "function-available")) {
            if (!context.xslt_functions) return error.UnknownFunction;
            if (items.len != 1) return error.InvalidArgument;
            const raw = try self.toString(items[0], context);
            const qname = (try self.resolveQName(context, raw)) orelse
                return .{ .boolean = false };
            if (qname.uri.len == 0) {
                // libxslt compatibility: unprefixed XSLT function names are
                // reported as available in addition to core XPath functions.
                return .{ .boolean = nameInTable(
                    &xpath_core_functions,
                    qname.local,
                ) or nameInTable(&xslt_functions, qname.local) };
            }
            if (std.mem.eql(u8, qname.uri, namespace.xsl_uri)) {
                return .{ .boolean = nameInTable(
                    &xslt_functions,
                    qname.local,
                ) };
            }
            if (std.mem.eql(u8, qname.uri, namespace.exslt_uri)) {
                return .{ .boolean = std.mem.eql(
                    u8,
                    qname.local,
                    "node-set",
                ) };
            }
            if (exsltBuiltin(context, raw) != null) {
                return .{ .boolean = true };
            }
            if (context.extension_functions) |hooks| {
                if (hooks.available(hooks.context, qname.uri, qname.local)) {
                    return .{ .boolean = true };
                }
            }
            return .{ .boolean = false };
        }
        if (std.mem.eql(u8, name, "unparsed-entity-uri")) {
            if (!context.xslt_functions) return error.UnknownFunction;
            if (items.len != 1) return error.InvalidArgument;
            const entity_name = try self.toString(items[0], context);
            const dtd = context.document.dtd orelse return .{ .string = "" };
            const entity = dtd.entities.find(entity_name) orelse
                return .{ .string = "" };
            if (!entity.unparsed) return .{ .string = "" };
            return .{ .string = entity.system_id };
        }
        if (isExsltNodeSet(context, name)) {
            if (!context.xslt_functions) return error.UnknownFunction;
            if (items.len != 1) return error.InvalidArgument;
            switch (items[0]) {
                .node_set => return items[0],
                .tree => |tree| {
                    const converter = context.tree_converter orelse
                        return error.InvalidArgument;
                    const converted = try converter.convert(
                        converter.context,
                        self.allocator,
                        tree,
                    ) orelse return error.InvalidArgument;
                    const nodes = try self.allocator.alloc(value.NodeRef, 1);
                    nodes[0] = converted;
                    return .{ .node_set = nodes };
                },
                else => return self.buildTextNodeSet(
                    context,
                    try self.toString(items[0], context),
                ),
            }
        }
        if (std.mem.eql(u8, name, "document")) {
            if (!context.xslt_functions) return error.UnknownFunction;
            if (items.len == 0 or items.len > 2) return error.InvalidArgument;
            const resolver = context.document_resolver orelse
                return error.UnknownFunction;
            var base = context.document_base;
            if (items.len == 2) {
                const base_nodes = try self.requireNodeSet(items[1], context);
                if (self.firstInDocumentOrder(base_nodes)) |base_node| {
                    const base_id = switch (base_node) {
                        .node => |id| id,
                        .attribute => |attr| attr.element,
                        .namespace_node => |ns| ns.element,
                    };
                    const resolved = xmlbase.elementBase(
                        self.allocator,
                        context.document,
                        base_id,
                        context.document_base,
                    ) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                    };
                    if (resolved) |resolved_base| base = resolved_base;
                }
            }
            var hrefs: std.ArrayList([]const u8) = .empty;
            switch (items[0]) {
                .node_set => |nodes| {
                    for (nodes) |node| {
                        try hrefs.append(
                            self.allocator,
                            try self.stringValue(context, node),
                        );
                    }
                },
                else => try hrefs.append(
                    self.allocator,
                    try self.toString(items[0], context),
                ),
            }
            var out: std.ArrayList(value.NodeRef) = .empty;
            for (hrefs.items) |href| {
                const roots = resolver.resolve(
                    resolver.context,
                    self.allocator,
                    href,
                    base,
                ) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.LoadFailed => return error.InvalidArgument,
                };
                try out.appendSlice(self.allocator, roots);
            }
            return .{ .node_set = try self.sortDedup(out.items) };
        }
        if (exsltBuiltin(context, name)) |builtin| {
            switch (builtin) {
                .distinct => {
                    if (items.len != 1) return error.InvalidArgument;
                    const nodes = try self.requireNodeSet(items[0], context);
                    var out: std.ArrayList(value.NodeRef) = .empty;
                    var seen: std.ArrayList([]const u8) = .empty;
                    for (nodes) |node| {
                        const text = try self.stringValue(context, node);
                        var duplicate = false;
                        for (seen.items) |existing| {
                            if (std.mem.eql(u8, existing, text)) {
                                duplicate = true;
                                break;
                            }
                        }
                        if (duplicate) continue;
                        try seen.append(self.allocator, text);
                        try out.append(self.allocator, node);
                    }
                    return .{
                        .node_set = try out.toOwnedSlice(self.allocator),
                    };
                },
                .replace => {
                    if (items.len != 3) return error.InvalidArgument;
                    const text = try self.toString(items[0], context);
                    const search = try self.stringList(context, items[1]);
                    const replacements = try self.optionalStringList(
                        context,
                        items[2],
                        search.len,
                    );
                    const replaced = try exslt.replaceNodes(
                        self.allocator,
                        text,
                        search,
                        replacements,
                    );
                    return self.buildTextNodeSet(context, replaced);
                },
                .str_tokenize => {
                    if (items.len < 1 or items.len > 2) {
                        return error.InvalidArgument;
                    }
                    const text = try self.toString(items[0], context);
                    const delimiters = if (items.len == 2)
                        try self.toString(items[1], context)
                    else
                        "\t\r\n ";
                    const tokens = try exslt.tokenize(
                        self.allocator,
                        text,
                        delimiters,
                    );
                    return self.buildTokenNodeSet(context, tokens);
                },
                .str_split => {
                    if (items.len < 1 or items.len > 2) {
                        return error.InvalidArgument;
                    }
                    const text = try self.toString(items[0], context);
                    const delimiter = if (items.len == 2)
                        try self.toString(items[1], context)
                    else
                        " ";
                    const tokens = try exslt.split(
                        self.allocator,
                        text,
                        delimiter,
                    );
                    return self.buildTokenNodeSet(context, tokens);
                },
                .str_concat => {
                    if (items.len != 1) return error.InvalidArgument;
                    const nodes = try self.toNodeSet(context, items[0]);
                    var out: std.ArrayList(u8) = .empty;
                    for (nodes) |node| {
                        try out.appendSlice(
                            self.allocator,
                            try self.stringValue(context, node),
                        );
                    }
                    return .{ .string = try out.toOwnedSlice(
                        self.allocator,
                    ) };
                },
                .str_padding => {
                    if (items.len < 1 or items.len > 2) {
                        return error.InvalidArgument;
                    }
                    const length = try self.toNumber(items[0], context);
                    const pattern = if (items.len == 2)
                        try self.toString(items[1], context)
                    else
                        "";
                    return .{ .string = try exslt.padding(
                        self.allocator,
                        length,
                        pattern,
                    ) };
                },
                .str_align => {
                    if (items.len < 2 or items.len > 3) {
                        return error.InvalidArgument;
                    }
                    const text = try self.toString(items[0], context);
                    const pad = try self.toString(items[1], context);
                    const alignment = if (items.len == 3)
                        try self.toString(items[2], context)
                    else
                        "";
                    return .{ .string = try exslt.alignString(
                        self.allocator,
                        text,
                        pad,
                        alignment,
                    ) };
                },
                .str_encode_uri => {
                    if (items.len < 1 or items.len > 3) {
                        return error.InvalidArgument;
                    }
                    if (items.len == 3) {
                        const encoding = try self.toString(items[2], context);
                        if (!std.mem.eql(u8, encoding, "UTF-8")) {
                            return .{ .string = "" };
                        }
                    }
                    const escape_reserved = if (items.len >= 2)
                        items[1].toBoolean()
                    else
                        true;
                    return .{ .string = try exslt.encodeUri(
                        self.allocator,
                        try self.toString(items[0], context),
                        escape_reserved,
                    ) };
                },
                .str_decode_uri => {
                    if (items.len < 1 or items.len > 2) {
                        return error.InvalidArgument;
                    }
                    if (items.len == 2) {
                        const encoding = try self.toString(items[1], context);
                        if (!std.mem.eql(u8, encoding, "UTF-8")) {
                            return .{ .string = "" };
                        }
                    }
                    return .{ .string = try exslt.decodeUri(
                        self.allocator,
                        try self.toString(items[0], context),
                    ) };
                },
                .date_datetime,
                .date_date,
                .date_time,
                .date_year,
                .date_leap_year,
                .date_month_in_year,
                .date_month_name,
                .date_month_abbreviation,
                .date_week_in_year,
                .date_week_in_month,
                .date_day_in_year,
                .date_day_in_month,
                .date_day_of_week_in_month,
                .date_day_in_week,
                .date_day_name,
                .date_day_abbreviation,
                .date_hour_in_day,
                .date_minute_in_hour,
                .date_second_in_minute,
                .date_add,
                .date_add_duration,
                .date_difference,
                .date_duration,
                .date_seconds,
                => {
                    const qname = namespace.splitQName(name) catch
                        return error.InvalidArgument;
                    var text_args: [2][]const u8 = undefined;
                    var count: usize = 0;
                    for (items) |item| {
                        if (count == text_args.len) {
                            return error.InvalidArgument;
                        }
                        text_args[count] = try self.toString(item, context);
                        count += 1;
                    }
                    const result = exslt_date.call(
                        self.allocator,
                        qname.local,
                        text_args[0..count],
                        context.current_date_time,
                    ) orelse return error.InvalidArgument;
                    return switch (result) {
                        .string => |text| .{ .string = text },
                        .number => |number| .{ .number = number },
                        .boolean => |boolean| .{ .boolean = boolean },
                    };
                },
                .date_sum => {
                    if (items.len != 1) return error.InvalidArgument;
                    const nodes = try self.requireNodeSet(items[0], context);
                    const values = try self.allocator.alloc(
                        []const u8,
                        nodes.len,
                    );
                    for (nodes, 0..) |node, index| {
                        values[index] = try self.stringValue(context, node);
                    }
                    const summed = try exslt_date.sumDurations(
                        self.allocator,
                        values,
                    );
                    return .{ .string = summed orelse "" };
                },
                .set_intersection, .set_difference, .set_has_same_node => {
                    if (items.len != 2) return error.InvalidArgument;
                    const first = try self.toNodeSet(context, items[0]);
                    const second = try self.toNodeSet(context, items[1]);
                    switch (builtin) {
                        .set_has_same_node => {
                            for (first) |a| {
                                for (second) |b| {
                                    if (nodeRefEqual(a, b)) {
                                        return .{ .boolean = true };
                                    }
                                }
                            }
                            return .{ .boolean = false };
                        },
                        .set_intersection => {
                            var out: std.ArrayList(value.NodeRef) = .empty;
                            for (first) |a| {
                                for (second) |b| {
                                    if (nodeRefEqual(a, b)) {
                                        try out.append(self.allocator, a);
                                        break;
                                    }
                                }
                            }
                            return .{ .node_set = try self.sortDedup(
                                out.items,
                            ) };
                        },
                        else => {
                            var out: std.ArrayList(value.NodeRef) = .empty;
                            for (first) |a| {
                                var found = false;
                                for (second) |b| {
                                    if (nodeRefEqual(a, b)) {
                                        found = true;
                                        break;
                                    }
                                }
                                if (!found) try out.append(self.allocator, a);
                            }
                            return .{ .node_set = try self.sortDedup(
                                out.items,
                            ) };
                        },
                    }
                },
                .set_leading, .set_trailing => {
                    if (items.len != 2) return error.InvalidArgument;
                    const first = try self.toNodeSet(context, items[0]);
                    const second = try self.toNodeSet(context, items[1]);
                    if (second.len == 0) {
                        // EXSLT: an empty second node-set returns the first.
                        return .{
                            .node_set = try self.sortDedup(first),
                        };
                    }
                    var sorted_second: std.ArrayList(value.NodeRef) = .empty;
                    try sorted_second.appendSlice(self.allocator, second);
                    std.mem.sort(
                        value.NodeRef,
                        sorted_second.items,
                        {},
                        struct {
                            fn lessThan(
                                _: void,
                                a: value.NodeRef,
                                b: value.NodeRef,
                            ) bool {
                                return value.orderKeyLessThan(
                                    a.orderKey(),
                                    b.orderKey(),
                                );
                            }
                        }.lessThan,
                    );
                    const boundary_node = sorted_second.items[0];
                    // libxslt requires the boundary node to be part of the
                    // first node-set.
                    var contains_boundary = false;
                    for (first) |node| {
                        if (nodeRefEqual(node, boundary_node)) {
                            contains_boundary = true;
                            break;
                        }
                    }
                    if (!contains_boundary) {
                        return .{ .node_set = &.{} };
                    }
                    const boundary = boundary_node.orderKey();
                    var out: std.ArrayList(value.NodeRef) = .empty;
                    for (first) |node| {
                        const key = node.orderKey();
                        const before = value.orderKeyLessThan(key, boundary);
                        const after = value.orderKeyLessThan(boundary, key);
                        if ((builtin == .set_leading and before) or
                            (builtin == .set_trailing and after))
                        {
                            try out.append(self.allocator, node);
                        }
                    }
                    return .{ .node_set = try out.toOwnedSlice(
                        self.allocator,
                    ) };
                },
                .math_max, .math_min, .math_highest, .math_lowest => {
                    if (items.len != 1) return error.InvalidArgument;
                    const nodes = try self.toNodeSet(context, items[0]);
                    const want_max = builtin == .math_max or
                        builtin == .math_highest;
                    var target: f64 = if (want_max)
                        -std.math.inf(f64)
                    else
                        std.math.inf(f64);
                    var has_nan = false;
                    for (nodes) |node| {
                        const number = value.parseNumber(
                            try self.stringValue(context, node),
                        );
                        if (std.math.isNan(number)) {
                            has_nan = true;
                            break;
                        }
                        if (want_max) {
                            if (number > target) target = number;
                        } else {
                            if (number < target) target = number;
                        }
                    }
                    if (builtin == .math_max or builtin == .math_min) {
                        if (has_nan or nodes.len == 0) {
                            return .{ .number = std.math.nan(f64) };
                        }
                        return .{ .number = target };
                    }
                    if (has_nan or nodes.len == 0) {
                        return .{ .node_set = &.{} };
                    }
                    var out: std.ArrayList(value.NodeRef) = .empty;
                    for (nodes) |node| {
                        const number = value.parseNumber(
                            try self.stringValue(context, node),
                        );
                        if (number == target) {
                            try out.append(self.allocator, node);
                        }
                    }
                    return .{ .node_set = try out.toOwnedSlice(
                        self.allocator,
                    ) };
                },
                .math_power => {
                    if (items.len != 2) return error.InvalidArgument;
                    return .{ .number = std.math.pow(
                        f64,
                        try self.toNumber(items[0], context),
                        try self.toNumber(items[1], context),
                    ) };
                },
                .math_abs => {
                    if (items.len != 1) return error.InvalidArgument;
                    return .{ .number = @abs(
                        try self.toNumber(items[0], context),
                    ) };
                },
                .math_sqrt => {
                    if (items.len != 1) return error.InvalidArgument;
                    return .{ .number = @sqrt(
                        try self.toNumber(items[0], context),
                    ) };
                },
                .object_type => {
                    if (items.len != 1) return error.InvalidArgument;
                    return .{ .string = switch (items[0]) {
                        .string => "string",
                        .number => "number",
                        .boolean => "boolean",
                        .node_set => "node-set",
                        .tree => "RTF",
                    } };
                },
            }
        }
        if (context.extension_functions) |hooks| {
            const extension_name = namespace.splitQName(name) catch null;
            if (extension_name) |qname| {
                if (qname.prefix.len != 0) {
                    if (context.resolvePrefix(qname.prefix)) |uri| {
                        if (hooks.available(
                            hooks.context,
                            uri,
                            qname.local,
                        )) {
                            return hooks.call(
                                hooks.context,
                                self.allocator,
                                uri,
                                qname.local,
                                items,
                                context,
                            ) catch |err| switch (err) {
                                error.OutOfMemory => error.OutOfMemory,
                                error.UnknownFunction => error.UnknownFunction,
                                else => error.InvalidArgument,
                            };
                        }
                    }
                }
            }
        }
        return error.UnknownFunction;
    }

    const ResolvedQName = struct {
        uri: []const u8,
        local: []const u8,
    };

    fn resolveQName(
        self: *Evaluator,
        context: *const value.Context,
        raw: []const u8,
    ) Error!?ResolvedQName {
        _ = self;
        const qname = namespace.splitQName(raw) catch return null;
        if (qname.prefix.len == 0) {
            return .{ .uri = "", .local = qname.local };
        }
        const uri = context.resolvePrefix(qname.prefix) orelse
            return error.UndefinedPrefix;
        return .{ .uri = uri, .local = qname.local };
    }

    fn functionNode(
        self: *Evaluator,
        args: []const value.Value,
        context: *const value.Context,
    ) Error!?value.NodeRef {
        if (args.len == 0) return context.node;
        if (args.len != 1) return error.InvalidArgument;
        const nodes = try self.requireNodeSet(args[0], context);
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
        if (context.id_resolver) |resolver| {
            return resolver.lookup(
                resolver.context,
                self.allocator,
                text,
                context.node,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
            };
        }
        var out: std.ArrayList(value.NodeRef) = .empty;
        const range_start = if (context.document_range) |range| range.start else 0;
        const range_end = if (context.document_range) |range|
            @min(range.end, context.document.nodes.len)
        else
            context.document.nodes.len;
        const dtd = context.document.dtd;
        var tokens = std.mem.tokenizeAny(u8, text, " \t\r\n");
        while (tokens.next()) |token| {
            for (context.document.nodes[range_start..range_end], range_start..) |node, index| {
                if (node.kind != .element) continue;
                const id = @as(dom.NodeId, @intCast(index));
                var matched = false;
                if (dtd) |view| {
                    // XPath IDs are the attributes declared ID in the DTD,
                    // matched by their raw (possibly prefixed) names.
                    for (view.attributes) |decl| {
                        if (decl.attr_type != .id) continue;
                        if (!std.mem.eql(u8, decl.element, node.name)) continue;
                        const id_value = context.document.attribute(
                            id,
                            decl.name,
                        ) orelse continue;
                        if (std.mem.eql(u8, id_value, token)) {
                            try out.append(self.allocator, .{ .node = id });
                            matched = true;
                            break;
                        }
                    }
                }
                if (matched) continue;
                if (context.document.attributeNs(id, namespace.xml_uri, "id")) |xml_id| {
                    if (xmlbase.xmlIdEquals(xml_id, token)) {
                        try out.append(self.allocator, .{ .node = id });
                    }
                }
            }
        }
        return self.sortDedup(out.items);
    }
};

/// Root of the document that owns `node`. Absolute location paths start
/// here, even when the context node belongs to a document loaded through
/// `document()` rather than the principal source document.
fn isForwardAxis(axis: ast.Axis) bool {
    return switch (axis) {
        .self_axis,
        .child,
        .attribute,
        .descendant,
        .descendant_or_self,
        .following,
        .following_sibling,
        .namespace_axis,
        => true,
        .parent,
        .ancestor,
        .ancestor_or_self,
        .preceding,
        .preceding_sibling,
        => false,
    };
}

/// Whether any predicate depends on position()/last() or is a bare number.
fn predicatesNeedPositions(predicates: []const *ast.Expr) bool {
    for (predicates) |predicate| {
        if (predicate.* == .number) return true;
        if (exprUsesPositionFunction(predicate)) return true;
    }
    return false;
}

fn exprUsesPositionFunction(expression: *const ast.Expr) bool {
    return switch (expression.*) {
        .function_call => |call| blk: {
            if (std.mem.eql(u8, call.name, "position") or
                std.mem.eql(u8, call.name, "last"))
            {
                break :blk true;
            }
            for (call.args) |argument| {
                if (exprUsesPositionFunction(argument)) break :blk true;
            }
            break :blk false;
        },
        .binary => |binary| exprUsesPositionFunction(binary.lhs) or
            exprUsesPositionFunction(binary.rhs),
        .unary_minus => |inner| exprUsesPositionFunction(inner),
        .path => |path| blk: {
            if (path.start) |start| {
                if (exprUsesPositionFunction(start)) break :blk true;
            }
            for (path.steps) |step| {
                for (step.predicates) |predicate| {
                    if (exprUsesPositionFunction(predicate)) break :blk true;
                }
            }
            break :blk false;
        },
        .filter => |filter| blk: {
            if (exprUsesPositionFunction(filter.primary)) break :blk true;
            for (filter.predicates) |predicate| {
                if (exprUsesPositionFunction(predicate)) break :blk true;
            }
            break :blk false;
        },
        .literal, .number, .variable => false,
    };
}

fn documentRootOf(
    context: *const value.Context,
    node: value.NodeRef,
) value.NodeRef {
    var id: dom.NodeId = switch (node) {
        .node => |node_id| node_id,
        .attribute => |attribute| attribute.element,
        .namespace_node => |namespace_node| namespace_node.element,
    };
    while (true) {
        const current = context.document.node(id);
        if (current.kind == .document or current.parent == dom.null_node) {
            return .{ .node = id };
        }
        id = current.parent;
    }
}

fn nodeRefEqual(a: value.NodeRef, b: value.NodeRef) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .node => |id| id == b.node,
        .attribute => |attribute| attribute.element == b.attribute.element and
            attribute.index == b.attribute.index,
        .namespace_node => |namespace_node| namespace_node.element ==
            b.namespace_node.element and
            std.mem.eql(u8, namespace_node.prefix, b.namespace_node.prefix),
    };
}

const xpath_core_functions = [_][]const u8{
    "last",            "position",      "count",         "id",
    "local-name",      "namespace-uri", "name",          "string",
    "concat",          "starts-with",   "contains",      "substring-before",
    "substring-after", "substring",     "string-length", "normalize-space",
    "translate",       "boolean",       "not",           "true",
    "false",           "lang",          "number",        "sum",
    "floor",           "ceiling",       "round",
};

/// XSLT 1.0 functions implemented by this processor.
const xslt_functions = [_][]const u8{
    "current",
    "document",
    "element-available",
    "function-available",
    "generate-id",
    "key",
    "format-number",
    "system-property",
    "unparsed-entity-uri",
};

/// XSLT instruction and subsidiary elements reported by `element-available`.
/// The set matches libxslt.
const xslt_elements = [_][]const u8{
    "apply-templates",
    "call-template",
    "apply-imports",
    "for-each",
    "value-of",
    "copy-of",
    "number",
    "choose",
    "if",
    "text",
    "copy",
    "variable",
    "message",
    "fallback",
    "processing-instruction",
    "comment",
    "element",
    "attribute",
    "sort",
    "with-param",
    "param",
    "when",
    "otherwise",
    "decimal-format",
};

const ExsltBuiltin = enum {
    distinct,
    replace,
    date_datetime,
    date_date,
    date_time,
    date_year,
    date_leap_year,
    date_month_in_year,
    date_month_name,
    date_month_abbreviation,
    date_week_in_year,
    date_week_in_month,
    date_day_in_year,
    date_day_in_month,
    date_day_of_week_in_month,
    date_day_in_week,
    date_day_name,
    date_day_abbreviation,
    date_hour_in_day,
    date_minute_in_hour,
    date_second_in_minute,
    date_add,
    date_add_duration,
    date_difference,
    date_duration,
    date_seconds,
    date_sum,
    str_tokenize,
    str_split,
    str_concat,
    str_padding,
    str_align,
    str_encode_uri,
    str_decode_uri,
    set_intersection,
    set_difference,
    set_has_same_node,
    set_leading,
    set_trailing,
    math_max,
    math_min,
    math_highest,
    math_lowest,
    math_power,
    math_abs,
    math_sqrt,
    object_type,
};

fn exsltBuiltin(
    context: *const value.Context,
    raw: []const u8,
) ?ExsltBuiltin {
    const qname = namespace.splitQName(raw) catch return null;
    if (qname.prefix.len == 0) return null;
    const uri = context.resolvePrefix(qname.prefix) orelse return null;
    if (std.mem.eql(u8, uri, "http://exslt.org/sets") and
        std.mem.eql(u8, qname.local, "distinct"))
    {
        return .distinct;
    }
    if (std.mem.eql(u8, uri, "http://exslt.org/strings")) {
        if (std.mem.eql(u8, qname.local, "replace")) return .replace;
        if (std.mem.eql(u8, qname.local, "tokenize")) return .str_tokenize;
        if (std.mem.eql(u8, qname.local, "split")) return .str_split;
        if (std.mem.eql(u8, qname.local, "concat")) return .str_concat;
        if (std.mem.eql(u8, qname.local, "padding")) return .str_padding;
        if (std.mem.eql(u8, qname.local, "align")) return .str_align;
        if (std.mem.eql(u8, qname.local, "encode-uri")) {
            return .str_encode_uri;
        }
        if (std.mem.eql(u8, qname.local, "decode-uri")) {
            return .str_decode_uri;
        }
    }
    if (std.mem.eql(u8, uri, "http://exslt.org/dates-and-times")) {
        if (std.mem.eql(u8, qname.local, "date-time")) {
            return .date_datetime;
        }
        if (std.mem.eql(u8, qname.local, "date")) return .date_date;
        if (std.mem.eql(u8, qname.local, "time")) return .date_time;
        if (std.mem.eql(u8, qname.local, "year")) return .date_year;
        if (std.mem.eql(u8, qname.local, "leap-year")) {
            return .date_leap_year;
        }
        if (std.mem.eql(u8, qname.local, "month-in-year")) {
            return .date_month_in_year;
        }
        if (std.mem.eql(u8, qname.local, "month-name")) {
            return .date_month_name;
        }
        if (std.mem.eql(u8, qname.local, "month-abbreviation")) {
            return .date_month_abbreviation;
        }
        if (std.mem.eql(u8, qname.local, "week-in-year")) {
            return .date_week_in_year;
        }
        if (std.mem.eql(u8, qname.local, "week-in-month")) {
            return .date_week_in_month;
        }
        if (std.mem.eql(u8, qname.local, "day-in-year")) {
            return .date_day_in_year;
        }
        if (std.mem.eql(u8, qname.local, "day-in-month")) {
            return .date_day_in_month;
        }
        if (std.mem.eql(u8, qname.local, "day-of-week-in-month")) {
            return .date_day_of_week_in_month;
        }
        if (std.mem.eql(u8, qname.local, "day-in-week")) {
            return .date_day_in_week;
        }
        if (std.mem.eql(u8, qname.local, "day-name")) {
            return .date_day_name;
        }
        if (std.mem.eql(u8, qname.local, "day-abbreviation")) {
            return .date_day_abbreviation;
        }
        if (std.mem.eql(u8, qname.local, "hour-in-day")) {
            return .date_hour_in_day;
        }
        if (std.mem.eql(u8, qname.local, "minute-in-hour")) {
            return .date_minute_in_hour;
        }
        if (std.mem.eql(u8, qname.local, "second-in-minute")) {
            return .date_second_in_minute;
        }
        if (std.mem.eql(u8, qname.local, "add")) return .date_add;
        if (std.mem.eql(u8, qname.local, "add-duration")) {
            return .date_add_duration;
        }
        if (std.mem.eql(u8, qname.local, "difference")) {
            return .date_difference;
        }
        if (std.mem.eql(u8, qname.local, "duration")) return .date_duration;
        if (std.mem.eql(u8, qname.local, "seconds")) return .date_seconds;
        if (std.mem.eql(u8, qname.local, "sum")) return .date_sum;
    }
    if (std.mem.eql(u8, uri, "http://exslt.org/sets")) {
        if (std.mem.eql(u8, qname.local, "intersection")) {
            return .set_intersection;
        }
        if (std.mem.eql(u8, qname.local, "difference")) {
            return .set_difference;
        }
        if (std.mem.eql(u8, qname.local, "has-same-node")) {
            return .set_has_same_node;
        }
        if (std.mem.eql(u8, qname.local, "leading")) return .set_leading;
        if (std.mem.eql(u8, qname.local, "trailing")) return .set_trailing;
    }
    if (std.mem.eql(u8, uri, "http://exslt.org/math")) {
        if (std.mem.eql(u8, qname.local, "max")) return .math_max;
        if (std.mem.eql(u8, qname.local, "min")) return .math_min;
        if (std.mem.eql(u8, qname.local, "highest")) return .math_highest;
        if (std.mem.eql(u8, qname.local, "lowest")) return .math_lowest;
        if (std.mem.eql(u8, qname.local, "power")) return .math_power;
        if (std.mem.eql(u8, qname.local, "abs")) return .math_abs;
        if (std.mem.eql(u8, qname.local, "sqrt")) return .math_sqrt;
    }
    if (std.mem.eql(u8, uri, "http://exslt.org/common") and
        std.mem.eql(u8, qname.local, "object-type"))
    {
        return .object_type;
    }
    return null;
}

fn isExsltNodeSet(
    context: *const value.Context,
    raw: []const u8,
) bool {
    const qname = namespace.splitQName(raw) catch return false;
    if (qname.prefix.len == 0) return false;
    const uri = context.resolvePrefix(qname.prefix) orelse return false;
    if (!std.mem.eql(u8, qname.local, "node-set")) return false;
    return std.mem.eql(u8, uri, namespace.exslt_uri) or
        std.mem.eql(u8, uri, "http://xmlsoft.org/XSLT/namespace");
}

fn nameInTable(table: []const []const u8, name: []const u8) bool {
    for (table) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

fn codepointCount(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}
