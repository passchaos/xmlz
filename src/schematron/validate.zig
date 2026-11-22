//! ISO Schematron validation over `dom.Document`.

const std = @import("std");
const dom = @import("../dom.zig");
const xpath_value = @import("../xpath/value.zig");
const xpath_eval = @import("../xpath/eval.zig");
const schema_mod = @import("schema.zig");

pub const Error = error{
    OutOfMemory,
    InvalidSchema,
};

pub const Options = struct {
    /// Select a phase by id. When null, `defaultPhase` or all patterns apply.
    phase: ?[]const u8 = null,
};

pub const Reference = struct {
    id: []const u8,
    scheme: []const u8 = "",
    role: []const u8 = "",
    message: []const u8,
};

pub const Failure = struct {
    node: dom.NodeId,
    /// Exact context node, including attribute and namespace nodes.
    node_ref: xpath_value.NodeRef = .{ .node = 0 },
    pattern_id: []const u8,
    kind: schema_mod.AssertionKind,
    test_source: []const u8 = "",
    message: []const u8,
    diagnostics: []const Reference = &.{},
    properties: []const Reference = &.{},
};

pub const FiredRule = struct {
    pattern_id: []const u8,
    context: []const u8,
    node: xpath_value.NodeRef,
};

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    failures: []const Failure,
    active_patterns: []const []const u8 = &.{},
    fired_rules: []const FiredRule = &.{},

    /// Failed assertions invalidate the document; successful `report`
    /// findings are recorded but do not.
    pub fn isValid(self: *const Result) bool {
        for (self.failures) |failure| {
            if (failure.kind == .assert) return false;
        }
        return true;
    }

    pub fn deinit(self: *Result) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn validate(
    compiled: *const schema_mod.Schema,
    allocator: std.mem.Allocator,
    document: *const dom.Document,
    options: Options,
) Error!Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var validator: Validator = .{
        .allocator = arena.allocator(),
        .document = document,
        .failures = .empty,
        .schema_variables = .empty,
    };
    try validator.run(compiled, options);
    // All arena-backed slices must be built before the arena is copied into
    // the result: a later allocation may add a chunk that the copy's list
    // head would not see.
    const failures = try arena.allocator().dupe(
        Failure,
        validator.failures.items,
    );
    const active_patterns = try arena.allocator().dupe(
        []const u8,
        validator.active_patterns.items,
    );
    const fired_rules = try arena.allocator().dupe(
        FiredRule,
        validator.fired_rules.items,
    );
    return .{
        .arena = arena,
        .failures = failures,
        .active_patterns = active_patterns,
        .fired_rules = fired_rules,
    };
}

const Validator = struct {
    allocator: std.mem.Allocator,
    document: *const dom.Document,
    failures: std.ArrayList(Failure),
    active_patterns: std.ArrayList([]const u8) = .empty,
    fired_rules: std.ArrayList(FiredRule) = .empty,
    schema_variables: std.ArrayList(xpath_value.Variable),

    fn run(
        self: *Validator,
        compiled: *const schema_mod.Schema,
        options: Options,
    ) Error!void {
        for (compiled.variables) |variable| {
            try self.defineVariable(&self.schema_variables, variable, .{
                .node = 0,
            });
        }
        const phase = options.phase orelse compiled.default_phase;
        var active_phase: ?*const schema_mod.Phase = null;
        if (phase) |phase_id| {
            active_phase = findPhase(compiled, phase_id) orelse
                return error.InvalidSchema;
        }
        for (compiled.patterns) |*pattern| {
            if (active_phase) |selected| {
                if (!phaseSelects(selected, pattern.id)) continue;
            }
            try self.active_patterns.append(self.allocator, pattern.id);
            try self.runPattern(compiled, pattern);
        }
    }

    fn runPattern(
        self: *Validator,
        compiled: *const schema_mod.Schema,
        pattern: *const schema_mod.Pattern,
    ) Error!void {
        var variables: std.ArrayList(xpath_value.Variable) = .empty;
        try variables.appendSlice(self.allocator, self.schema_variables.items);
        for (pattern.variables) |variable| {
            try self.defineVariable(&variables, variable, .{ .node = 0 });
        }
        for (pattern.rules) |*rule| {
            var selected = try self.evaluate(
                rule.context,
                .{ .node = 0 },
                variables.items,
            );
            defer selected.deinit();
            const nodes = switch (selected.value) {
                .node_set => |nodes| nodes,
                else => return error.InvalidSchema,
            };
            for (nodes) |node| {
                try self.runRule(compiled, pattern, rule, node, variables.items);
            }
        }
    }

    fn runRule(
        self: *Validator,
        compiled: *const schema_mod.Schema,
        pattern: *const schema_mod.Pattern,
        rule: *const schema_mod.Rule,
        node: xpath_value.NodeRef,
        variables: []const xpath_value.Variable,
    ) Error!void {
        var local: std.ArrayList(xpath_value.Variable) = .empty;
        try local.appendSlice(self.allocator, variables);
        try self.fired_rules.append(self.allocator, .{
            .pattern_id = pattern.id,
            .context = rule.context_source,
            .node = node,
        });
        for (rule.variables) |variable| {
            try self.defineVariable(&local, variable, node);
        }
        for (rule.assertions) |*assertion| {
            var result = try self.evaluate(
                assertion.test_expr,
                node,
                local.items,
            );
            defer result.deinit();
            const matched = result.value.toBoolean();
            const failed = if (assertion.kind == .assert) !matched else matched;
            if (!failed) continue;
            try self.failures.append(self.allocator, .{
                .node = refNodeId(node),
                .node_ref = node,
                .pattern_id = pattern.id,
                .kind = assertion.kind,
                .test_source = assertion.test_source,
                .message = try self.renderParts(
                    assertion.message,
                    node,
                    local.items,
                ),
                .diagnostics = try self.renderDiagnostics(
                    compiled,
                    assertion.diagnostic_ids,
                    node,
                    local.items,
                ),
                .properties = try self.renderProperties(
                    compiled,
                    assertion.property_ids,
                    node,
                    local.items,
                ),
            });
        }
    }

    fn renderDiagnostics(
        self: *Validator,
        compiled: *const schema_mod.Schema,
        ids: []const []const u8,
        node: xpath_value.NodeRef,
        variables: []const xpath_value.Variable,
    ) Error![]const Reference {
        var out: std.ArrayList(Reference) = .empty;
        for (ids) |id| {
            for (compiled.diagnostics) |diagnostic| {
                if (!std.mem.eql(u8, diagnostic.id, id)) continue;
                try out.append(self.allocator, .{
                    .id = diagnostic.id,
                    .message = try self.renderParts(
                        diagnostic.message,
                        node,
                        variables,
                    ),
                });
                break;
            }
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn renderProperties(
        self: *Validator,
        compiled: *const schema_mod.Schema,
        ids: []const []const u8,
        node: xpath_value.NodeRef,
        variables: []const xpath_value.Variable,
    ) Error![]const Reference {
        var out: std.ArrayList(Reference) = .empty;
        for (ids) |id| {
            for (compiled.properties) |property| {
                if (!std.mem.eql(u8, property.id, id)) continue;
                try out.append(self.allocator, .{
                    .id = property.id,
                    .scheme = property.scheme,
                    .role = property.role,
                    .message = try self.renderParts(
                        property.message,
                        node,
                        variables,
                    ),
                });
                break;
            }
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn defineVariable(
        self: *Validator,
        variables: *std.ArrayList(xpath_value.Variable),
        variable: schema_mod.Variable,
        node: xpath_value.NodeRef,
    ) Error!void {
        var result = try self.evaluate(variable.value, node, variables.items);
        defer result.deinit();
        try variables.append(self.allocator, .{
            .name = variable.name,
            .value = try self.ownValue(result.value),
        });
    }

    fn ownValue(self: *Validator, value: xpath_value.Value) Error!xpath_value.Value {
        return switch (value) {
            .string => |text| .{ .string = try self.allocator.dupe(u8, text) },
            .number => |number| .{ .number = number },
            .boolean => |boolean| .{ .boolean = boolean },
            .node_set => |nodes| .{
                .node_set = try self.allocator.dupe(xpath_value.NodeRef, nodes),
            },
            .tree => |tree| .{ .tree = tree },
        };
    }

    fn evaluate(
        self: *Validator,
        expression: schema_mod.CompiledExpr,
        node: xpath_value.NodeRef,
        variables: []const xpath_value.Variable,
    ) Error!xpath_value.Result {
        const context: xpath_value.Context = .{
            .document = self.document,
            .node = node,
            .namespaces = expression.namespaces,
            .variables = variables,
        };
        return xpath_eval.evaluate(
            self.allocator,
            expression.root,
            &context,
        ) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidSchema,
        };
    }

    fn renderParts(
        self: *Validator,
        parts: []const schema_mod.MessagePart,
        node: xpath_value.NodeRef,
        variables: []const xpath_value.Variable,
    ) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (parts) |part| {
            switch (part) {
                .text => |text| try out.appendSlice(self.allocator, text),
                .value_of => |expression| {
                    var result = try self.evaluate(
                        expression,
                        node,
                        variables,
                    );
                    defer result.deinit();
                    try self.appendValueString(&out, result.value);
                },
                .name => |maybe_path| {
                    var selected: ?xpath_value.Result = null;
                    if (maybe_path) |expression| {
                        selected = try self.evaluate(
                            expression,
                            node,
                            variables,
                        );
                    }
                    defer if (selected) |*result| result.deinit();
                    if (selected) |result| {
                        switch (result.value) {
                            .node_set => |nodes| {
                                if (nodes.len != 0) {
                                    try self.appendNameString(&out, nodes[0]);
                                }
                            },
                            else => {},
                        }
                    } else {
                        try self.appendNameString(&out, node);
                    }
                },
            }
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn appendValueString(
        self: *Validator,
        out: *std.ArrayList(u8),
        value: xpath_value.Value,
    ) Error!void {
        switch (value) {
            .string => |text| try out.appendSlice(self.allocator, text),
            .number => |number| {
                if (std.math.isNan(number)) {
                    try out.appendSlice(self.allocator, "NaN");
                } else if (std.math.isInf(number)) {
                    try out.appendSlice(
                        self.allocator,
                        if (number < 0) "-Infinity" else "Infinity",
                    );
                } else if (number == 0) {
                    try out.append(self.allocator, '0');
                } else {
                    var buffer: [64]u8 = undefined;
                    const text = std.fmt.bufPrint(&buffer, "{d}", .{number}) catch
                        return error.OutOfMemory;
                    try out.appendSlice(self.allocator, text);
                }
            },
            .boolean => |boolean| try out.appendSlice(
                self.allocator,
                if (boolean) "true" else "false",
            ),
            .node_set => |nodes| {
                if (nodes.len != 0) {
                    try self.appendNodeString(out, nodes[0]);
                }
            },
            .tree => |tree| {
                const text = tree.document.textContentAlloc(
                    self.allocator,
                    tree.document.documentNode(),
                ) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                };
                defer self.allocator.free(text);
                try out.appendSlice(self.allocator, text);
            },
        }
    }

    fn appendNodeString(
        self: *Validator,
        out: *std.ArrayList(u8),
        node: xpath_value.NodeRef,
    ) Error!void {
        switch (node) {
            .attribute => |attribute| {
                const value = self.document.attributesOf(
                    attribute.element,
                )[attribute.index].value;
                try out.appendSlice(self.allocator, value);
            },
            .namespace_node => |namespace_node| try out.appendSlice(
                self.allocator,
                namespace_node.uri,
            ),
            .node => |id| {
                const node_value = self.document.node(id);
                switch (node_value.kind) {
                    .text, .comment, .processing_instruction => try out.appendSlice(
                        self.allocator,
                        node_value.value,
                    ),
                    .element, .document => {
                        const text = self.document.textContentAlloc(
                            self.allocator,
                            id,
                        ) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                        };
                        defer self.allocator.free(text);
                        try out.appendSlice(self.allocator, text);
                    },
                }
            },
        }
    }

    fn appendNameString(
        self: *Validator,
        out: *std.ArrayList(u8),
        node: xpath_value.NodeRef,
    ) Error!void {
        switch (node) {
            .attribute => |attribute| try out.appendSlice(
                self.allocator,
                self.document.attributesOf(attribute.element)[attribute.index].name,
            ),
            .namespace_node => |namespace_node| try out.appendSlice(
                self.allocator,
                namespace_node.prefix,
            ),
            .node => |id| {
                const node_value = self.document.node(id);
                switch (node_value.kind) {
                    .element, .processing_instruction => try out.appendSlice(
                        self.allocator,
                        node_value.name,
                    ),
                    else => {},
                }
            },
        }
    }
};

fn refNodeId(node: xpath_value.NodeRef) dom.NodeId {
    return switch (node) {
        .node => |id| id,
        .attribute => |attribute| attribute.element,
        .namespace_node => |namespace_node| namespace_node.element,
    };
}

fn findPhase(
    compiled: *const schema_mod.Schema,
    id: []const u8,
) ?*const schema_mod.Phase {
    for (compiled.phases) |*phase| {
        if (std.mem.eql(u8, phase.id, id)) return phase;
    }
    return null;
}

fn phaseSelects(phase: *const schema_mod.Phase, pattern_id: []const u8) bool {
    if (pattern_id.len == 0) return false;
    for (phase.active) |active| {
        if (std.mem.eql(u8, active, pattern_id)) return true;
    }
    return false;
}
