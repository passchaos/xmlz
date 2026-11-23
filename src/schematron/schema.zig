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

pub const Diagnostic = struct {
    id: []const u8,
    message: []const MessagePart = &.{},
};

pub const Property = struct {
    id: []const u8,
    scheme: []const u8 = "",
    role: []const u8 = "",
    message: []const MessagePart = &.{},
};

pub const Assertion = struct {
    kind: AssertionKind,
    test_expr: CompiledExpr,
    /// Test expression text after abstract-pattern substitution.
    test_source: []const u8 = "",
    message: []const MessagePart = &.{},
    diagnostic_ids: []const []const u8 = &.{},
    property_ids: []const []const u8 = &.{},
    node: dom.NodeId = dom.null_node,
};

pub const Variable = struct {
    name: []const u8,
    value: CompiledExpr,
};

pub const Rule = struct {
    context: CompiledExpr,
    /// Context expression text after abstract-pattern substitution.
    context_source: []const u8 = "",
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
    diagnostics: []const Diagnostic = &.{},
    properties: []const Property = &.{},

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
        .abstract_patterns = std.StringHashMap(dom.NodeId).init(arena.allocator()),
        .abstract_rules = std.StringHashMap(dom.NodeId).init(arena.allocator()),
    };
    try compiler.compile();
    return finish(arena, &compiler);
}

/// Compile `sch:pattern` elements embedded in a host schema (RELAX NG or
/// XSD `xs:appinfo`). Schema-level declarations such as `sch:ns`,
/// `sch:phase`, and `sch:let` are not present in embedded patterns; prefixes
/// resolve through in-scope `xmlns` declarations.
pub fn parsePatterns(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
    pattern_nodes: []const dom.NodeId,
) Error!Schema {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var compiler: Compiler = .{
        .arena = arena.allocator(),
        .document = document,
        .abstract_patterns = std.StringHashMap(dom.NodeId).init(arena.allocator()),
        .abstract_rules = std.StringHashMap(dom.NodeId).init(arena.allocator()),
    };
    try compiler.compilePatternNodes(pattern_nodes);
    return finish(arena, &compiler);
}

fn finish(
    arena: std.heap.ArenaAllocator,
    compiler: *Compiler,
) Error!Schema {
    return .{
        .arena = arena,
        .patterns = try compiler.patterns.toOwnedSlice(compiler.arena),
        .phases = try compiler.phases.toOwnedSlice(compiler.arena),
        .default_phase = compiler.default_phase,
        .variables = try compiler.variables.toOwnedSlice(compiler.arena),
        .diagnostics = try compiler.diagnostics.toOwnedSlice(compiler.arena),
        .properties = try compiler.properties.toOwnedSlice(compiler.arena),
    };
}

const Compiler = struct {
    arena: std.mem.Allocator,
    document: *const dom.Document,
    patterns: std.ArrayList(Pattern) = .empty,
    phases: std.ArrayList(Phase) = .empty,
    schema_namespaces: std.ArrayList(namespace.Binding) = .empty,
    abstract_patterns: std.StringHashMap(dom.NodeId),
    abstract_rules: std.StringHashMap(dom.NodeId),
    variables: std.ArrayList(Variable) = .empty,
    diagnostics: std.ArrayList(Diagnostic) = .empty,
    properties: std.ArrayList(Property) = .empty,
    default_phase: ?[]const u8 = null,

    fn compile(self: *Compiler) Error!void {
        const root = self.document.root();
        if (root == dom.null_node) return error.InvalidSchema;
        const node = self.document.node(root);
        if (node.kind != .element or
            !std.mem.eql(u8, self.document.ns(node.ns), namespace_uri) or
            !std.mem.eql(u8, node.localName(), "schema"))
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
                !std.mem.eql(u8, self.document.ns(child_node.ns), namespace_uri))
            {
                continue;
            }
            if (std.mem.eql(u8, child_node.localName(), "ns")) {
                try self.collectNamespace(child);
            }
        }

        try self.collectAbstracts(root);

        child = node.first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const child_node = self.document.node(child);
            if (child_node.kind != .element or
                !std.mem.eql(u8, self.document.ns(child_node.ns), namespace_uri))
            {
                continue;
            }
            if (std.mem.eql(u8, child_node.localName(), "let")) {
                try self.variables.append(
                    self.arena,
                    try self.parseVariable(child, &.{}),
                );
            } else if (std.mem.eql(u8, child_node.localName(), "diagnostics")) {
                try self.parseDiagnostics(child);
            } else if (std.mem.eql(u8, child_node.localName(), "properties")) {
                try self.parseProperties(child);
            } else if (std.mem.eql(u8, child_node.localName(), "phase")) {
                try self.phases.append(self.arena, try self.parsePhase(child));
            } else if (std.mem.eql(u8, child_node.localName(), "pattern")) {
                try self.appendPattern(child);
            }
        }
    }

    /// Compile patterns embedded in a host schema document.
    fn compilePatternNodes(
        self: *Compiler,
        pattern_nodes: []const dom.NodeId,
    ) Error!void {
        for (pattern_nodes) |id| {
            try self.collectAbstractPattern(id);
        }
        for (pattern_nodes) |id| {
            try self.appendPattern(id);
        }
    }

    fn appendPattern(self: *Compiler, id: dom.NodeId) Error!void {
        if (self.document.attribute(id, "abstract")) |value| {
            if (isYes(value)) return;
        }
        if (self.document.attribute(id, "is-a")) |abstract_id| {
            const abstract_node = self.abstract_patterns.get(
                abstract_id,
            ) orelse return error.InvalidSchema;
            const params = try self.parseParams(id);
            var pattern = try self.parsePattern(
                abstract_node,
                params,
            );
            if (self.document.attribute(id, "id")) |value| {
                pattern.id = try self.arena.dupe(u8, value);
            }
            try self.appendPatternContent(id, params, &pattern);
            try self.patterns.append(self.arena, pattern);
        } else {
            try self.patterns.append(
                self.arena,
                try self.parsePattern(id, &.{}),
            );
        }
    }

    fn collectAbstracts(self: *Compiler, schema_id: dom.NodeId) Error!void {
        var child = self.document.node(schema_id).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const node = self.document.node(child);
            if (node.kind != .element or
                !std.mem.eql(u8, self.document.ns(node.ns), namespace_uri) or
                !std.mem.eql(u8, node.localName(), "pattern"))
            {
                continue;
            }
            try self.collectAbstractPattern(child);
        }
    }

    fn collectAbstractPattern(self: *Compiler, id: dom.NodeId) Error!void {
        const node = self.document.node(id);
        if (node.kind != .element or
            !std.mem.eql(u8, self.document.ns(node.ns), namespace_uri) or
            !std.mem.eql(u8, node.localName(), "pattern"))
        {
            return error.InvalidSchema;
        }
        if (self.document.attribute(id, "abstract")) |value| {
            if (isYes(value)) {
                const abstract_id = self.document.attribute(id, "id") orelse
                    return error.InvalidSchema;
                try self.abstract_patterns.put(
                    try self.arena.dupe(u8, abstract_id),
                    id,
                );
            }
        }
        var rule_child = node.first_child;
        while (rule_child != dom.null_node) : (rule_child = self.document.node(rule_child).next_sibling) {
            const rule_node = self.document.node(rule_child);
            if (rule_node.kind != .element or
                !std.mem.eql(u8, self.document.ns(rule_node.ns), namespace_uri) or
                !std.mem.eql(u8, rule_node.localName(), "rule"))
            {
                continue;
            }
            if (self.document.attribute(rule_child, "abstract")) |value| {
                if (isYes(value)) {
                    const rule_id = self.document.attribute(
                        rule_child,
                        "id",
                    ) orelse return error.InvalidSchema;
                    try self.abstract_rules.put(
                        try self.arena.dupe(u8, rule_id),
                        rule_child,
                    );
                }
            }
        }
    }

    const Param = struct {
        name: []const u8,
        value: []const u8,
    };

    fn parseParams(self: *Compiler, id: dom.NodeId) Error![]const Param {
        var params: std.ArrayList(Param) = .empty;
        var child = self.document.node(id).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const node = self.document.node(child);
            if (node.kind != .element or
                !std.mem.eql(u8, self.document.ns(node.ns), namespace_uri) or
                !std.mem.eql(u8, node.localName(), "param"))
            {
                continue;
            }
            const name = self.document.attribute(child, "name") orelse
                return error.InvalidSchema;
            const value = self.document.attribute(child, "value") orelse
                return error.InvalidSchema;
            try params.append(self.arena, .{ .name = name, .value = value });
        }
        return params.toOwnedSlice(self.arena);
    }

    fn substitute(
        self: *Compiler,
        text: []const u8,
        params: []const Param,
    ) Error![]const u8 {
        if (params.len == 0) return text;
        var out: std.ArrayList(u8) = .empty;
        var index: usize = 0;
        while (index < text.len) {
            if (text[index] == '$') {
                var end = index + 1;
                while (end < text.len and isParamNameChar(text[end])) end += 1;
                if (end > index + 1) {
                    const name = text[index + 1 .. end];
                    var replaced = false;
                    for (params) |param| {
                        if (std.mem.eql(u8, param.name, name)) {
                            try out.appendSlice(self.arena, param.value);
                            replaced = true;
                            break;
                        }
                    }
                    if (replaced) {
                        index = end;
                        continue;
                    }
                }
            }
            try out.append(self.arena, text[index]);
            index += 1;
        }
        return out.toOwnedSlice(self.arena);
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
                !std.mem.eql(u8, self.document.ns(node.ns), namespace_uri) or
                !std.mem.eql(u8, node.localName(), "active"))
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

    fn parseDiagnostics(self: *Compiler, id: dom.NodeId) Error!void {
        var child = self.document.node(id).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const node = self.document.node(child);
            if (node.kind != .element or
                !std.mem.eql(u8, self.document.ns(node.ns), namespace_uri) or
                !std.mem.eql(u8, node.localName(), "diagnostic"))
            {
                continue;
            }
            const diagnostic_id = self.document.attribute(child, "id") orelse
                return error.InvalidSchema;
            try self.diagnostics.append(self.arena, .{
                .id = try self.arena.dupe(u8, diagnostic_id),
                .message = try self.parseMessage(child, &.{}),
            });
        }
    }

    fn parseProperties(self: *Compiler, id: dom.NodeId) Error!void {
        var child = self.document.node(id).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const node = self.document.node(child);
            if (node.kind != .element or
                !std.mem.eql(u8, self.document.ns(node.ns), namespace_uri) or
                !std.mem.eql(u8, node.localName(), "property"))
            {
                continue;
            }
            const property_id = self.document.attribute(child, "id") orelse
                return error.InvalidSchema;
            try self.properties.append(self.arena, .{
                .id = try self.arena.dupe(u8, property_id),
                .scheme = try self.arena.dupe(
                    u8,
                    self.document.attribute(child, "scheme") orelse "",
                ),
                .role = try self.arena.dupe(
                    u8,
                    self.document.attribute(child, "role") orelse "",
                ),
                .message = try self.parseMessage(child, &.{}),
            });
        }
    }

    fn parseIdRefs(
        self: *Compiler,
        id: dom.NodeId,
        attribute: []const u8,
    ) Error![]const []const u8 {
        const value = self.document.attribute(id, attribute) orelse return &.{};
        var ids: std.ArrayList([]const u8) = .empty;
        var tokens = std.mem.tokenizeAny(u8, value, " \t\r\n");
        while (tokens.next()) |token| {
            try ids.append(self.arena, try self.arena.dupe(u8, token));
        }
        return ids.toOwnedSlice(self.arena);
    }

    fn parsePattern(
        self: *Compiler,
        id: dom.NodeId,
        params: []const Param,
    ) Error!Pattern {
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
                !std.mem.eql(u8, self.document.ns(node.ns), namespace_uri))
            {
                continue;
            }
            if (std.mem.eql(u8, node.localName(), "let")) {
                try variables.append(
                    self.arena,
                    try self.parseVariable(child, params),
                );
            } else if (std.mem.eql(u8, node.localName(), "rule")) {
                if (self.document.attribute(child, "abstract")) |value| {
                    if (isYes(value)) continue;
                }
                try rules.append(self.arena, try self.parseRule(child, params));
            }
        }
        pattern.variables = try variables.toOwnedSlice(self.arena);
        pattern.rules = try rules.toOwnedSlice(self.arena);
        return pattern;
    }

    fn appendPatternContent(
        self: *Compiler,
        id: dom.NodeId,
        params: []const Param,
        pattern: *Pattern,
    ) Error!void {
        var variables: std.ArrayList(Variable) = .empty;
        try variables.appendSlice(self.arena, pattern.variables);
        var rules: std.ArrayList(Rule) = .empty;
        try rules.appendSlice(self.arena, pattern.rules);
        var child = self.document.node(id).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const node = self.document.node(child);
            if (node.kind != .element or
                !std.mem.eql(u8, self.document.ns(node.ns), namespace_uri))
            {
                continue;
            }
            if (std.mem.eql(u8, node.localName(), "let")) {
                try variables.append(
                    self.arena,
                    try self.parseVariable(child, params),
                );
            } else if (std.mem.eql(u8, node.localName(), "rule")) {
                try rules.append(self.arena, try self.parseRule(child, params));
            }
        }
        pattern.variables = try variables.toOwnedSlice(self.arena);
        pattern.rules = try rules.toOwnedSlice(self.arena);
    }

    fn parseRule(
        self: *Compiler,
        id: dom.NodeId,
        params: []const Param,
    ) Error!Rule {
        if (self.document.attribute(id, "abstract") != null and
            isYes(self.document.attribute(id, "abstract").?))
        {
            return error.InvalidSchema;
        }
        const context_source = self.document.attribute(id, "context") orelse
            return error.InvalidSchema;
        var variables: std.ArrayList(Variable) = .empty;
        var assertions: std.ArrayList(Assertion) = .empty;
        var extensions: std.ArrayList([]const u8) = .empty;
        try self.parseRuleContent(
            id,
            params,
            &variables,
            &assertions,
            &extensions,
        );
        const context_text = try self.substitute(context_source, params);
        return .{
            .context = try self.compilePattern(id, context_text),
            .context_source = context_text,
            .variables = try variables.toOwnedSlice(self.arena),
            .assertions = try assertions.toOwnedSlice(self.arena),
        };
    }

    fn parseRuleContent(
        self: *Compiler,
        id: dom.NodeId,
        params: []const Param,
        variables: *std.ArrayList(Variable),
        assertions: *std.ArrayList(Assertion),
        extensions: *std.ArrayList([]const u8),
    ) Error!void {
        var child = self.document.node(id).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const node = self.document.node(child);
            if (node.kind != .element or
                !std.mem.eql(u8, self.document.ns(node.ns), namespace_uri))
            {
                continue;
            }
            if (std.mem.eql(u8, node.localName(), "let")) {
                try variables.append(
                    self.arena,
                    try self.parseVariable(child, params),
                );
            } else if (std.mem.eql(u8, node.localName(), "assert") or
                std.mem.eql(u8, node.localName(), "report"))
            {
                try assertions.append(
                    self.arena,
                    try self.parseAssertion(child, params),
                );
            } else if (std.mem.eql(u8, node.localName(), "extends")) {
                const reference = self.document.attribute(
                    child,
                    "rule",
                ) orelse return error.InvalidSchema;
                for (extensions.items) |active| {
                    if (std.mem.eql(u8, active, reference)) {
                        return error.InvalidSchema;
                    }
                }
                const abstract_node = self.abstract_rules.get(reference) orelse
                    return error.InvalidSchema;
                try extensions.append(self.arena, reference);
                defer _ = extensions.pop();
                try self.parseRuleContent(
                    abstract_node,
                    &.{},
                    variables,
                    assertions,
                    extensions,
                );
            }
        }
    }

    fn parseAssertion(
        self: *Compiler,
        id: dom.NodeId,
        params: []const Param,
    ) Error!Assertion {
        const node = self.document.node(id);
        const test_source = self.document.attribute(id, "test") orelse
            return error.InvalidSchema;
        const test_text = try self.substitute(test_source, params);
        return .{
            .kind = if (std.mem.eql(u8, node.localName(), "assert"))
                .assert
            else
                .report,
            .test_expr = try self.compileExpression(id, test_text),
            .test_source = test_text,
            .message = try self.parseMessage(id, params),
            .diagnostic_ids = try self.parseIdRefs(id, "diagnostics"),
            .property_ids = try self.parseIdRefs(id, "properties"),
            .node = id,
        };
    }

    fn parseMessage(
        self: *Compiler,
        id: dom.NodeId,
        params: []const Param,
    ) Error![]const MessagePart {
        var parts: std.ArrayList(MessagePart) = .empty;
        var child = self.document.node(id).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const node = self.document.node(child);
            switch (node.kind) {
                .text => try parts.append(self.arena, .{
                    .text = try self.substitute(node.value, params),
                }),
                .element => {
                    if (std.mem.eql(u8, self.document.ns(node.ns), namespace_uri) and
                        std.mem.eql(u8, node.localName(), "value-of"))
                    {
                        const select = self.document.attribute(
                            child,
                            "select",
                        ) orelse return error.InvalidSchema;
                        try parts.append(self.arena, .{
                            .value_of = try self.compileExpression(
                                child,
                                try self.substitute(select, params),
                            ),
                        });
                    } else if (std.mem.eql(u8, self.document.ns(node.ns), namespace_uri) and
                        std.mem.eql(u8, node.localName(), "name"))
                    {
                        const path = self.document.attribute(child, "path");
                        try parts.append(self.arena, .{
                            .name = if (path) |source|
                                try self.compileExpression(
                                    child,
                                    try self.substitute(source, params),
                                )
                            else
                                null,
                        });
                    } else {
                        const text = try self.textContent(child);
                        try parts.append(self.arena, .{
                            .text = try self.substitute(text, params),
                        });
                    }
                },
                else => {},
            }
        }
        return parts.toOwnedSlice(self.arena);
    }

    fn parseVariable(
        self: *Compiler,
        id: dom.NodeId,
        params: []const Param,
    ) Error!Variable {
        const name = self.document.attribute(id, "name") orelse
            return error.InvalidSchema;
        const value = self.document.attribute(id, "value") orelse
            return error.InvalidSchema;
        return .{
            .name = try self.arena.dupe(u8, name),
            .value = try self.compileExpression(
                id,
                try self.substitute(value, params),
            ),
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

fn isParamNameChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or
        byte == '.' or byte >= 0x80;
}

fn isYes(value: []const u8) bool {
    return std.mem.eql(u8, value, "true") or
        std.mem.eql(u8, value, "1") or
        std.mem.eql(u8, value, "yes");
}
