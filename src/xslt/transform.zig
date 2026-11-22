//! XSLT 1.0 transformation runtime.

const std = @import("std");
const dom = @import("../dom.zig");
const dom_builder = @import("../dom_builder.zig");
const namespace = @import("../namespace.zig");
const xpath = @import("../xpath/root.zig");
const xpath_value = @import("../xpath/value.zig");
const xpath_eval = @import("../xpath/eval.zig");
const writer_mod = @import("../writer.zig");
const compile = @import("compile.zig");

pub const Error = error{
    OutOfMemory,
    InvalidStylesheet,
    InvalidExpression,
    UndefinedVariable,
    UndefinedPrefix,
    UnknownFunction,
    InvalidArgument,
    Terminated,
    InvalidOutput,
};

pub const Options = struct {
    /// Values supplied for top-level `xsl:param` declarations.
    parameters: []const xpath.Variable = &.{},
};

pub const Result = struct {
    /// Arena holding runtime strings and messages.
    arena: std.heap.ArenaAllocator,
    document: dom.Document,
    output: compile.Output,
    messages: []const []const u8 = &.{},

    pub fn deinit(self: *Result) void {
        self.document.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn write(self: *const Result, out: *std.Io.Writer) !void {
        if (self.output.method == .text) {
            try writeTextNode(out, &self.document, self.document.documentNode());
            return;
        }
        try writer_mod.writeDocument(out, &self.document, .{
            .xml_declaration = self.output.method == .xml and
                !self.output.omit_xml_declaration,
            .indent = if (self.output.indent) "  " else null,
        });
    }

    pub fn toOwnedSlice(
        self: *const Result,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        var allocating: std.Io.Writer.Allocating = .init(allocator);
        defer allocating.deinit();
        try self.write(&allocating.writer);
        return allocating.toOwnedSlice();
    }
};

pub fn apply(
    allocator: std.mem.Allocator,
    stylesheet: *const compile.Stylesheet,
    source: *const dom.Document,
    options: Options,
) Error!Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    // The result document owns its arena. Parent it to the caller allocator,
    // not to the transform arena, because the transform arena struct is moved
    // into the returned Result after the document is built.
    var builder = dom_builder.Builder.init(allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidStylesheet,
    };
    errdefer builder.deinit();

    var runtime: Runtime = .{
        .allocator = arena_allocator,
        .stylesheet = stylesheet,
        .source = source,
        .builder = &builder,
    };
    try runtime.buildTemplateMatches();
    try runtime.evaluateGlobals(options.parameters);
    try runtime.applyTemplates(&.{.{ .node = 0 }}, null, &.{});

    const document = builder.finish() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidStylesheet,
    };
    return .{
        .arena = arena,
        .document = document,
        .output = try runtime.copyOutput(),
        .messages = try runtime.messages.toOwnedSlice(arena_allocator),
    };
}

const NodeKey = struct {
    tag: u8,
    element: u32,
    index: u32,
};

fn nodeKey(ref: xpath.NodeRef) NodeKey {
    return switch (ref) {
        .node => |id| .{ .tag = 0, .element = id, .index = 0 },
        .attribute => |attr| .{
            .tag = 1,
            .element = attr.element,
            .index = attr.index,
        },
        .namespace_node => |ns| .{
            .tag = 2,
            .element = ns.element,
            .index = ns.order,
        },
    };
}

const TemplateState = struct {
    template: *const compile.Template,
    matches: std.AutoHashMap(NodeKey, void),
};

const SortEntry = struct {
    node: xpath.NodeRef,
    index: usize,
    keys: []const SortValue,
};

const SortValue = union(enum) {
    text: []const u8,
    number: f64,
};

const Runtime = struct {
    allocator: std.mem.Allocator,
    stylesheet: *const compile.Stylesheet,
    source: *const dom.Document,
    builder: *dom_builder.Builder,
    parent: dom.NodeId = 0,
    variables: std.ArrayList(xpath.Variable) = .empty,
    template_states: []TemplateState = &.{},
    messages: std.ArrayList([]const u8) = .empty,

    fn copyOutput(self: *Runtime) Error!compile.Output {
        var output = self.stylesheet.output;
        if (output.version) |version| {
            output.version = try self.allocator.dupe(u8, version);
        }
        output.encoding = try self.allocator.dupe(u8, output.encoding);
        return output;
    }

    fn buildTemplateMatches(self: *Runtime) Error!void {
        const templates = self.stylesheet.templates;
        self.template_states = try self.allocator.alloc(TemplateState, templates.len);
        for (templates, 0..) |*template, index| {
            self.template_states[index] = .{
                .template = template,
                .matches = std.AutoHashMap(NodeKey, void).init(self.allocator),
            };
            const selector = template.selector orelse continue;
            var context: xpath.Context = .{
                .document = self.source,
                .node = .{ .node = 0 },
                .namespaces = template.namespaces,
            };
            var result = xpath_eval.evaluate(
                self.allocator,
                selector,
                &context,
            ) catch |err| return mapEvalError(err);
            defer result.deinit();
            switch (result.value) {
                .node_set => |nodes| {
                    for (nodes) |ref| {
                        try self.template_states[index].matches.put(
                            nodeKey(ref),
                            {},
                        );
                    }
                },
                else => return error.InvalidStylesheet,
            }
        }
    }

    fn evaluateGlobals(
        self: *Runtime,
        parameters: []const xpath.Variable,
    ) Error!void {
        for (self.stylesheet.globals) |global| {
            var supplied: ?xpath.Value = null;
            if (global.param) {
                for (parameters) |parameter| {
                    if (std.mem.eql(u8, parameter.name, global.name)) {
                        supplied = parameter.value;
                        break;
                    }
                }
            }
            const value = supplied orelse try self.evaluateVariableValue(
                global.value,
                .{ .node = 0 },
                1,
                1,
            );
            try self.variables.append(self.allocator, .{
                .name = global.name,
                .value = value,
            });
        }
    }

    fn evaluateVariableValue(
        self: *Runtime,
        value: compile.VariableValue,
        node: xpath.NodeRef,
        position: usize,
        size: usize,
    ) Error!xpath.Value {
        return switch (value) {
            .select => |expression| self.evalOwned(expression, node, position, size),
            .body => |body| .{
                .string = try self.captureString(body, node, position, size),
            },
        };
    }

    fn evalOwned(
        self: *Runtime,
        expression: compile.CompiledExpr,
        node: xpath.NodeRef,
        position: usize,
        size: usize,
    ) Error!xpath.Value {
        var context: xpath.Context = .{
            .document = self.source,
            .node = node,
            .current = node,
            .position = position,
            .size = size,
            .namespaces = expression.namespaces,
            .variables = self.variables.items,
        };
        var result = xpath_eval.evaluate(
            self.allocator,
            expression.node,
            &context,
        ) catch |err| return mapEvalError(err);
        defer result.deinit();
        return switch (result.value) {
            .node_set => |nodes| .{
                .node_set = try self.allocator.dupe(xpath.NodeRef, nodes),
            },
            .boolean => |boolean| .{ .boolean = boolean },
            .number => |number| .{ .number = number },
            .string => |string| .{
                .string = try self.allocator.dupe(u8, string),
            },
        };
    }

    fn findTemplate(
        self: *Runtime,
        node: xpath.NodeRef,
        mode: ?[]const u8,
    ) ?*const compile.Template {
        const key = nodeKey(node);
        var best: ?*const compile.Template = null;
        for (self.template_states) |state| {
            if (state.template.selector == null) continue;
            if (!modeMatches(state.template.mode, mode)) continue;
            if (!state.matches.contains(key)) continue;
            if (best) |current| {
                if (state.template.priority < current.priority) continue;
                if (state.template.priority == current.priority and
                    state.template.order < current.order)
                {
                    continue;
                }
            }
            best = state.template;
        }
        return best;
    }

    fn applyTemplates(
        self: *Runtime,
        nodes: []const xpath.NodeRef,
        mode: ?[]const u8,
        params: []const xpath.Variable,
    ) Error!void {
        for (nodes, 0..) |node, index| {
            if (self.findTemplate(node, mode)) |template| {
                try self.executeTemplate(
                    template,
                    node,
                    index + 1,
                    nodes.len,
                    params,
                );
            } else {
                try self.builtinTemplate(node, mode);
            }
        }
    }

    fn executeTemplate(
        self: *Runtime,
        template: *const compile.Template,
        node: xpath.NodeRef,
        position: usize,
        size: usize,
        params: []const xpath.Variable,
    ) Error!void {
        const mark = self.variables.items.len;
        defer self.variables.shrinkRetainingCapacity(mark);
        for (template.params) |param| {
            var supplied: ?xpath.Value = null;
            for (params) |candidate| {
                if (std.mem.eql(u8, candidate.name, param.name)) {
                    supplied = candidate.value;
                    break;
                }
            }
            const value = supplied orelse try self.evaluateVariableValue(
                param.value,
                node,
                position,
                size,
            );
            try self.variables.append(self.allocator, .{
                .name = param.name,
                .value = value,
            });
        }
        try self.executeInstructions(template.body, node, position, size);
    }

    fn builtinTemplate(
        self: *Runtime,
        node: xpath.NodeRef,
        mode: ?[]const u8,
    ) Error!void {
        switch (node) {
            .attribute => |attr| {
                try self.appendText(
                    self.source.attributesOf(attr.element)[attr.index].value,
                );
            },
            .namespace_node => {},
            .node => |id| {
                const node_value = self.source.node(id);
                switch (node_value.kind) {
                    .document, .element => {
                        const children = try self.childrenOf(node);
                        try self.applyTemplates(children, mode, &.{});
                    },
                    .text => try self.appendText(node_value.value),
                    .comment, .processing_instruction => {},
                }
            },
        }
    }

    fn executeInstructions(
        self: *Runtime,
        body: []const compile.Instruction,
        node: xpath.NodeRef,
        position: usize,
        size: usize,
    ) Error!void {
        const mark = self.variables.items.len;
        defer self.variables.shrinkRetainingCapacity(mark);
        for (body) |instruction| {
            try self.executeInstruction(instruction, node, position, size);
        }
    }

    fn executeInstruction(
        self: *Runtime,
        instruction: compile.Instruction,
        node: xpath.NodeRef,
        position: usize,
        size: usize,
    ) Error!void {
        switch (instruction) {
            .literal_text => |text| try self.appendText(text),
            .text => |text| try self.appendText(text),
            .value_of => |value_of| {
                const value = try self.evalOwned(
                    value_of.select,
                    node,
                    position,
                    size,
                );
                try self.appendText(try self.toString(value));
            },
            .literal_element => |element| try self.executeLiteralElement(
                element,
                node,
                position,
                size,
            ),
            .apply_templates => |apply_templates| try self.executeApplyTemplates(
                apply_templates,
                node,
                position,
                size,
            ),
            .call_template => |call| try self.executeCallTemplate(
                call,
                node,
                position,
                size,
            ),
            .for_each => |for_each| try self.executeForEach(
                for_each,
                node,
                position,
                size,
            ),
            .if_ => |if_instruction| {
                const value = try self.evalOwned(
                    if_instruction.test_expr,
                    node,
                    position,
                    size,
                );
                if (value.toBoolean()) {
                    try self.executeInstructions(
                        if_instruction.body,
                        node,
                        position,
                        size,
                    );
                }
            },
            .choose => |choose| try self.executeChoose(
                choose,
                node,
                position,
                size,
            ),
            .copy_of => |copy_of| try self.executeCopyOf(
                copy_of,
                node,
                position,
                size,
            ),
            .copy => |copy| try self.executeCopy(
                copy,
                node,
                position,
                size,
            ),
            .element => |element| try self.executeElement(
                element,
                node,
                position,
                size,
            ),
            .attribute => |attr| try self.executeAttribute(
                attr,
                node,
                position,
                size,
            ),
            .variable => |variable| {
                const value = try self.evaluateVariableValue(
                    variable.value,
                    node,
                    position,
                    size,
                );
                try self.variables.append(self.allocator, .{
                    .name = variable.name,
                    .value = value,
                });
            },
            .comment => |comment| {
                const text = try self.captureString(
                    comment.body,
                    node,
                    position,
                    size,
                );
                try self.appendComment(text);
            },
            .processing_instruction => |pi| {
                const name = try self.evaluateAvt(
                    pi.name,
                    node,
                    position,
                    size,
                );
                const text = try self.captureString(
                    pi.body,
                    node,
                    position,
                    size,
                );
                try self.appendProcessingInstruction(name, text);
            },
            .number => |number| try self.executeNumber(
                number,
                node,
                position,
                size,
            ),
            .message => |message| {
                const text = try self.captureString(
                    message.body,
                    node,
                    position,
                    size,
                );
                try self.messages.append(self.allocator, text);
                if (message.terminate) return error.Terminated;
            },
            .apply_imports => {},
        }
    }

    fn executeLiteralElement(
        self: *Runtime,
        element: compile.LiteralElement,
        node: xpath.NodeRef,
        position: usize,
        size: usize,
    ) Error!void {
        const id = self.builder.createElementNs(
            element.prefix,
            element.local,
            element.ns,
        ) catch |err| return mapBuilderError(err);
        self.builder.appendChild(self.parent, id) catch |err|
            return mapBuilderError(err);
        for (element.namespaces) |decl| {
            try self.addNamespaceDecl(id, decl.prefix, decl.uri);
        }
        for (element.attributes) |attr| {
            const value = try self.evaluateAvt(
                attr.value,
                node,
                position,
                size,
            );
            if (attr.ns.len == 0) {
                self.builder.setAttribute(id, attr.name, value) catch |err|
                    return mapBuilderError(err);
            } else {
                self.builder.setAttributeNs(
                    id,
                    attr.prefix,
                    attr.local,
                    attr.ns,
                    value,
                ) catch |err| return mapBuilderError(err);
            }
        }
        const saved_parent = self.parent;
        self.parent = id;
        defer self.parent = saved_parent;
        try self.executeInstructions(element.body, node, position, size);
    }

    fn executeApplyTemplates(
        self: *Runtime,
        instruction: compile.ApplyTemplates,
        node: xpath.NodeRef,
        position: usize,
        size: usize,
    ) Error!void {
        const selected: []const xpath.NodeRef = if (instruction.select) |select|
            try self.requireNodeSet(try self.evalOwned(
                select,
                node,
                position,
                size,
            ))
        else
            try self.childrenOf(node);
        const sorted = try self.sortNodes(
            selected,
            instruction.sorts,
            node,
            position,
            size,
        );
        const params = try self.evaluateParams(
            instruction.params,
            node,
            position,
            size,
        );
        try self.applyTemplates(sorted, instruction.mode, params);
    }

    fn executeCallTemplate(
        self: *Runtime,
        call: compile.CallTemplate,
        node: xpath.NodeRef,
        position: usize,
        size: usize,
    ) Error!void {
        var template: ?*const compile.Template = null;
        for (self.stylesheet.templates) |*candidate| {
            if (candidate.name) |name| {
                if (std.mem.eql(u8, name, call.name)) {
                    template = candidate;
                    break;
                }
            }
        }
        const found = template orelse return error.InvalidStylesheet;
        const params = try self.evaluateParams(
            call.params,
            node,
            position,
            size,
        );
        try self.executeTemplate(found, node, position, size, params);
    }

    fn executeForEach(
        self: *Runtime,
        instruction: compile.ForEach,
        node: xpath.NodeRef,
        position: usize,
        size: usize,
    ) Error!void {
        const selected = try self.requireNodeSet(try self.evalOwned(
            instruction.select,
            node,
            position,
            size,
        ));
        const sorted = try self.sortNodes(
            selected,
            instruction.sorts,
            node,
            position,
            size,
        );
        for (sorted, 0..) |current, index| {
            try self.executeInstructions(
                instruction.body,
                current,
                index + 1,
                sorted.len,
            );
        }
    }

    fn executeChoose(
        self: *Runtime,
        choose: compile.Choose,
        node: xpath.NodeRef,
        position: usize,
        size: usize,
    ) Error!void {
        for (choose.whens) |when| {
            const value = try self.evalOwned(when.test_expr, node, position, size);
            if (value.toBoolean()) {
                try self.executeInstructions(when.body, node, position, size);
                return;
            }
        }
        if (choose.otherwise) |otherwise| {
            try self.executeInstructions(otherwise, node, position, size);
        }
    }

    fn executeCopyOf(
        self: *Runtime,
        instruction: compile.CopyOf,
        node: xpath.NodeRef,
        position: usize,
        size: usize,
    ) Error!void {
        const nodes = try self.requireNodeSet(try self.evalOwned(
            instruction.select,
            node,
            position,
            size,
        ));
        var last_element: ?dom.NodeId = null;
        for (nodes) |current| {
            if (last_element) |copied| {
                switch (current) {
                    .node => |id| if (self.isDescendantOf(id, copied)) continue,
                    .attribute => |attr| {
                        if (attr.element == copied or
                            self.isDescendantOf(attr.element, copied))
                        {
                            continue;
                        }
                    },
                    .namespace_node => |ns| {
                        if (ns.element == copied or
                            self.isDescendantOf(ns.element, copied))
                        {
                            continue;
                        }
                    },
                }
            }
            try self.copyDeepNode(current);
            if (current == .node and
                self.source.node(current.node).kind == .element)
            {
                last_element = current.node;
            }
        }
    }

    fn executeCopy(
        self: *Runtime,
        instruction: compile.Copy,
        node: xpath.NodeRef,
        position: usize,
        size: usize,
    ) Error!void {
        switch (node) {
            .attribute => |attr| {
                const attribute = self.source.attributesOf(attr.element)[attr.index];
                try self.appendAttribute(
                    attribute.name,
                    attribute.prefixName(),
                    attribute.localName(),
                    attribute.ns,
                    attribute.value,
                );
            },
            .namespace_node => |ns| {
                try self.addNamespaceDecl(self.parent, ns.prefix, ns.uri);
            },
            .node => |id| {
                const node_value = self.source.node(id);
                switch (node_value.kind) {
                    .element => {
                        const new_id = self.builder.createElementNs(
                            prefixOf(node_value),
                            node_value.local,
                            node_value.ns,
                        ) catch |err| return mapBuilderError(err);
                        self.builder.appendChild(self.parent, new_id) catch |err|
                            return mapBuilderError(err);
                        const bindings = try self.source.inScopeNamespaces(
                            self.allocator,
                            id,
                        );
                        for (bindings) |binding| {
                            if (std.mem.eql(u8, binding.prefix, "xml")) continue;
                            try self.addNamespaceDecl(
                                new_id,
                                binding.prefix,
                                binding.uri,
                            );
                        }
                        const saved_parent = self.parent;
                        self.parent = new_id;
                        defer self.parent = saved_parent;
                        try self.executeInstructions(
                            instruction.body,
                            node,
                            position,
                            size,
                        );
                    },
                    .text => try self.appendText(node_value.value),
                    .comment => try self.appendComment(node_value.value),
                    .processing_instruction => try self.appendProcessingInstruction(
                        node_value.name,
                        node_value.value,
                    ),
                    .document => try self.executeInstructions(
                        instruction.body,
                        node,
                        position,
                        size,
                    ),
                }
            },
        }
    }

    fn executeElement(
        self: *Runtime,
        instruction: compile.ElementInstruction,
        node: xpath.NodeRef,
        position: usize,
        size: usize,
    ) Error!void {
        const name = try self.evaluateAvt(
            instruction.name,
            node,
            position,
            size,
        );
        const qname = namespace.splitQName(name) catch
            return error.InvalidArgument;
        var uri: []const u8 = "";
        if (instruction.namespace_uri) |namespace_avt| {
            uri = try self.evaluateAvt(
                namespace_avt,
                node,
                position,
                size,
            );
        } else if (qname.prefix.len != 0) {
            uri = resolvePrefix(instruction.namespaces, qname.prefix) orelse
                return error.UndefinedPrefix;
        } else {
            uri = resolveDefaultNamespace(instruction.namespaces);
        }
        if (qname.prefix.len != 0 and uri.len == 0) {
            return error.UndefinedPrefix;
        }

        const id = self.builder.createElementNs(
            qname.prefix,
            qname.local,
            uri,
        ) catch |err| return mapBuilderError(err);
        self.builder.appendChild(self.parent, id) catch |err|
            return mapBuilderError(err);
        if (uri.len != 0) {
            try self.addNamespaceDecl(id, qname.prefix, uri);
        }
        const saved_parent = self.parent;
        self.parent = id;
        defer self.parent = saved_parent;
        try self.executeInstructions(instruction.body, node, position, size);
    }

    fn executeAttribute(
        self: *Runtime,
        instruction: compile.AttributeInstruction,
        node: xpath.NodeRef,
        position: usize,
        size: usize,
    ) Error!void {
        if (self.parent == self.builder.document()) {
            return error.InvalidStylesheet;
        }
        const name = try self.evaluateAvt(
            instruction.name,
            node,
            position,
            size,
        );
        const qname = namespace.splitQName(name) catch
            return error.InvalidArgument;
        var uri: []const u8 = "";
        if (instruction.namespace_uri) |namespace_avt| {
            uri = try self.evaluateAvt(
                namespace_avt,
                node,
                position,
                size,
            );
        } else if (qname.prefix.len != 0) {
            uri = resolvePrefix(instruction.namespaces, qname.prefix) orelse
                return error.UndefinedPrefix;
        }
        if (uri.len != 0 and qname.prefix.len == 0) {
            // Serializing an unprefixed namespaced attribute would lose its
            // namespace; require a prefix.
            return error.InvalidArgument;
        }
        const value = try self.captureString(
            instruction.body,
            node,
            position,
            size,
        );
        try self.appendAttribute(name, qname.prefix, qname.local, uri, value);
    }

    fn executeNumber(
        self: *Runtime,
        instruction: compile.NumberInstruction,
        node: xpath.NodeRef,
        position: usize,
        size: usize,
    ) Error!void {
        if (instruction.value) |value| {
            const number = try self.toNumber(try self.evalOwned(
                value,
                node,
                position,
                size,
            ));
            try self.appendText(try self.formatNumber(number));
            return;
        }
        const number: f64 = @floatFromInt(self.countSiblings(node));
        try self.appendText(try self.formatNumber(number));
    }

    fn countSiblings(self: *Runtime, node: xpath.NodeRef) usize {
        const id = switch (node) {
            .node => |value| value,
            else => return 1,
        };
        const node_value = self.source.node(id);
        if (node_value.kind != .element) return 1;
        var count: usize = 0;
        var sibling = self.source.node(node_value.parent).first_child;
        while (sibling != dom.null_node) : (sibling = self.source.node(sibling).next_sibling) {
            const sibling_value = self.source.node(sibling);
            if (sibling_value.kind == .element and
                std.mem.eql(u8, sibling_value.name, node_value.name))
            {
                count += 1;
            }
            if (sibling == id) break;
        }
        return count;
    }

    fn formatNumber(self: *Runtime, number: f64) Error![]const u8 {
        if (std.math.isNan(number)) return "NaN";
        if (std.math.isInf(number)) {
            return if (number < 0) "-Infinity" else "Infinity";
        }
        const rounded = std.math.floor(number + 0.5);
        return std.fmt.allocPrint(self.allocator, "{d}", .{rounded});
    }

    fn evaluateParams(
        self: *Runtime,
        params: []const compile.ParamBinding,
        node: xpath.NodeRef,
        position: usize,
        size: usize,
    ) Error![]const xpath.Variable {
        if (params.len == 0) return &.{};
        const out = try self.allocator.alloc(xpath.Variable, params.len);
        for (params, 0..) |param, index| {
            out[index] = .{
                .name = param.name,
                .value = try self.evaluateVariableValue(
                    param.value,
                    node,
                    position,
                    size,
                ),
            };
        }
        return out;
    }

    fn evaluateAvt(
        self: *Runtime,
        avt: compile.Avt,
        node: xpath.NodeRef,
        position: usize,
        size: usize,
    ) Error![]const u8 {
        if (avt.len == 0) return "";
        var out: std.ArrayList(u8) = .empty;
        for (avt) |part| {
            switch (part) {
                .literal => |text| try out.appendSlice(self.allocator, text),
                .expr => |expression| {
                    const value = try self.evalOwned(
                        expression,
                        node,
                        position,
                        size,
                    );
                    try out.appendSlice(
                        self.allocator,
                        try self.toString(value),
                    );
                },
            }
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn captureString(
        self: *Runtime,
        body: []const compile.Instruction,
        node: xpath.NodeRef,
        position: usize,
        size: usize,
    ) Error![]const u8 {
        var temp = dom_builder.Builder.init(self.allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidStylesheet,
        };
        const saved_builder = self.builder;
        const saved_parent = self.parent;
        self.builder = &temp;
        self.parent = temp.document();
        var finished = false;
        defer {
            self.builder = saved_builder;
            self.parent = saved_parent;
            if (!finished) temp.deinit();
        }
        try self.executeInstructions(body, node, position, size);
        var document = temp.finish() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidStylesheet,
        };
        finished = true;
        defer document.deinit();
        return document.textContentAlloc(
            self.allocator,
            document.documentNode(),
        ) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    fn appendText(self: *Runtime, text: []const u8) Error!void {
        if (text.len == 0) return;
        const id = self.builder.createText(text) catch |err|
            return mapBuilderError(err);
        self.builder.appendChild(self.parent, id) catch |err|
            return mapBuilderError(err);
    }

    fn appendComment(self: *Runtime, text: []const u8) Error!void {
        const id = self.builder.createComment(text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidArgument,
        };
        self.builder.appendChild(self.parent, id) catch |err|
            return mapBuilderError(err);
    }

    fn appendProcessingInstruction(
        self: *Runtime,
        name: []const u8,
        text: []const u8,
    ) Error!void {
        const id = self.builder.createProcessingInstruction(
            name,
            text,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidArgument,
        };
        self.builder.appendChild(self.parent, id) catch |err|
            return mapBuilderError(err);
    }

    fn appendAttribute(
        self: *Runtime,
        name: []const u8,
        prefix: []const u8,
        local: []const u8,
        uri: []const u8,
        value: []const u8,
    ) Error!void {
        if (uri.len == 0) {
            self.builder.setAttribute(self.parent, name, value) catch |err|
                return mapBuilderError(err);
        } else {
            try self.addNamespaceDecl(self.parent, prefix, uri);
            self.builder.setAttributeNs(
                self.parent,
                prefix,
                local,
                uri,
                value,
            ) catch |err| return mapBuilderError(err);
        }
    }

    fn addNamespaceDecl(
        self: *Runtime,
        id: dom.NodeId,
        prefix: []const u8,
        uri: []const u8,
    ) Error!void {
        if (prefix.len == 0) {
            self.builder.setAttribute(id, "xmlns", uri) catch |err|
                return mapBuilderError(err);
        } else {
            const name = try std.fmt.allocPrint(
                self.allocator,
                "xmlns:{s}",
                .{prefix},
            );
            self.builder.setAttribute(id, name, uri) catch |err|
                return mapBuilderError(err);
        }
    }

    fn copyDeepNode(self: *Runtime, node: xpath.NodeRef) Error!void {
        switch (node) {
            .attribute => |attr| {
                const attribute = self.source.attributesOf(attr.element)[attr.index];
                try self.appendAttribute(
                    attribute.name,
                    attribute.prefixName(),
                    attribute.localName(),
                    attribute.ns,
                    attribute.value,
                );
            },
            .namespace_node => |ns| {
                try self.addNamespaceDecl(self.parent, ns.prefix, ns.uri);
            },
            .node => |id| try self.copyDeepNodeId(id),
        }
    }

    fn copyDeepNodeId(self: *Runtime, id: dom.NodeId) Error!void {
        const node_value = self.source.node(id);
        switch (node_value.kind) {
            .document => {
                var child = node_value.first_child;
                while (child != dom.null_node) : (child = self.source.node(child).next_sibling) {
                    try self.copyDeepNodeId(child);
                }
            },
            .element => {
                const new_id = self.builder.createElementNs(
                    prefixOf(node_value),
                    node_value.local,
                    node_value.ns,
                ) catch |err| return mapBuilderError(err);
                self.builder.appendChild(self.parent, new_id) catch |err|
                    return mapBuilderError(err);
                try self.copyElementNamespaces(id, new_id);
                for (self.source.attributesOf(id)) |attr| {
                    if (namespace.Resolver.isNamespaceDeclaration(attr.name)) {
                        continue;
                    }
                    if (attr.ns.len == 0) {
                        self.builder.setAttribute(
                            new_id,
                            attr.name,
                            attr.value,
                        ) catch |err| return mapBuilderError(err);
                    } else {
                        self.builder.setAttributeNs(
                            new_id,
                            attr.prefixName(),
                            attr.localName(),
                            attr.ns,
                            attr.value,
                        ) catch |err| return mapBuilderError(err);
                    }
                }
                const saved_parent = self.parent;
                self.parent = new_id;
                defer self.parent = saved_parent;
                var child = node_value.first_child;
                while (child != dom.null_node) : (child = self.source.node(child).next_sibling) {
                    try self.copyDeepNodeId(child);
                }
            },
            .text => try self.appendText(node_value.value),
            .comment => try self.appendComment(node_value.value),
            .processing_instruction => try self.appendProcessingInstruction(
                node_value.name,
                node_value.value,
            ),
        }
    }

    fn copyElementNamespaces(
        self: *Runtime,
        id: dom.NodeId,
        new_id: dom.NodeId,
    ) Error!void {
        const node_value = self.source.node(id);
        const prefix = prefixOf(node_value);
        var has_default = false;
        var has_prefix = false;
        for (self.source.attributesOf(id)) |attr| {
            if (!namespace.Resolver.isNamespaceDeclaration(attr.name)) continue;
            self.builder.setAttribute(new_id, attr.name, attr.value) catch |err|
                return mapBuilderError(err);
            if (attr.name.len == 5) {
                has_default = true;
            } else if (std.mem.eql(u8, attr.name["xmlns:".len..], prefix)) {
                has_prefix = true;
            }
        }
        if (!has_default and prefix.len == 0 and node_value.ns.len != 0) {
            try self.addNamespaceDecl(new_id, "", node_value.ns);
        }
        if (prefix.len != 0 and !has_prefix) {
            const bindings = try self.source.inScopeNamespaces(self.allocator, id);
            for (bindings) |binding| {
                if (std.mem.eql(u8, binding.prefix, prefix)) {
                    try self.addNamespaceDecl(new_id, prefix, binding.uri);
                    break;
                }
            }
        }
        // Attributes may use prefixes declared on an ancestor.
        for (self.source.attributesOf(id)) |attr| {
            if (namespace.Resolver.isNamespaceDeclaration(attr.name)) continue;
            const attr_prefix = attr.prefixName();
            if (attr_prefix.len == 0 or std.mem.eql(u8, attr_prefix, "xml")) {
                continue;
            }
            var declared = false;
            for (self.source.attributesOf(id)) |decl| {
                if (std.mem.eql(u8, decl.name, attr.name)) continue;
                if (namespace.Resolver.isNamespaceDeclaration(decl.name) and
                    decl.name.len > "xmlns:".len and
                    std.mem.eql(u8, decl.name["xmlns:".len..], attr_prefix))
                {
                    declared = true;
                    break;
                }
            }
            if (declared) continue;
            const bindings = try self.source.inScopeNamespaces(self.allocator, id);
            for (bindings) |binding| {
                if (std.mem.eql(u8, binding.prefix, attr_prefix)) {
                    try self.addNamespaceDecl(new_id, attr_prefix, binding.uri);
                    break;
                }
            }
        }
    }

    fn sortNodes(
        self: *Runtime,
        nodes: []const xpath.NodeRef,
        sorts: []const compile.SortKey,
        node: xpath.NodeRef,
        position: usize,
        size: usize,
    ) Error![]const xpath.NodeRef {
        if (sorts.len == 0 or nodes.len <= 1) return nodes;
        const entries = try self.allocator.alloc(SortEntry, nodes.len);
        for (nodes, 0..) |current, index| {
            const keys = try self.allocator.alloc(SortValue, sorts.len);
            for (sorts, 0..) |sort, key_index| {
                if (sort.select) |select| {
                    const value = try self.evalOwned(
                        select,
                        current,
                        index + 1,
                        nodes.len,
                    );
                    keys[key_index] = switch (sort.data_type) {
                        .text => .{ .text = try self.toString(value) },
                        .number => .{ .number = try self.toNumber(value) },
                    };
                } else {
                    const text = try self.stringValue(current);
                    keys[key_index] = switch (sort.data_type) {
                        .text => .{ .text = text },
                        .number => .{ .number = xpath_value.parseNumber(text) },
                    };
                }
            }
            entries[index] = .{ .node = current, .index = index, .keys = keys };
        }
        std.mem.sort(SortEntry, entries, sorts, sortEntryLessThan);
        const out = try self.allocator.alloc(xpath.NodeRef, nodes.len);
        for (entries, 0..) |entry, index| out[index] = entry.node;
        _ = node;
        _ = position;
        _ = size;
        return out;
    }

    fn childrenOf(
        self: *Runtime,
        node: xpath.NodeRef,
    ) Error![]const xpath.NodeRef {
        const id = switch (node) {
            .node => |value| value,
            .attribute, .namespace_node => return &.{},
        };
        const node_value = self.source.node(id);
        if (node_value.kind != .document and node_value.kind != .element) {
            return &.{};
        }
        var out: std.ArrayList(xpath.NodeRef) = .empty;
        var child = node_value.first_child;
        while (child != dom.null_node) : (child = self.source.node(child).next_sibling) {
            try out.append(self.allocator, .{ .node = child });
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn requireNodeSet(self: *Runtime, value: xpath.Value) Error![]const xpath.NodeRef {
        _ = self;
        return switch (value) {
            .node_set => |nodes| nodes,
            else => error.InvalidArgument,
        };
    }

    fn toString(self: *Runtime, value: xpath.Value) Error![]const u8 {
        return switch (value) {
            .string => |string| string,
            .boolean => |boolean| if (boolean) "true" else "false",
            .number => |number| xpath_value.formatNumber(self.allocator, number),
            .node_set => |nodes| blk: {
                var best: ?xpath.NodeRef = null;
                for (nodes) |node| {
                    if (best == null or xpath_value.orderLessThan({}, node, best.?)) {
                        best = node;
                    }
                }
                if (best) |node| break :blk try self.stringValue(node);
                break :blk "";
            },
        };
    }

    fn toNumber(self: *Runtime, value: xpath.Value) Error!f64 {
        return switch (value) {
            .number => |number| number,
            .boolean => |boolean| if (boolean) 1 else 0,
            .string => |string| xpath_value.parseNumber(string),
            .node_set => xpath_value.parseNumber(try self.toString(value)),
        };
    }

    fn stringValue(self: *Runtime, node: xpath.NodeRef) Error![]const u8 {
        return switch (node) {
            .attribute => |attr| self.source
                .attributesOf(attr.element)[attr.index].value,
            .namespace_node => |ns| ns.uri,
            .node => |id| blk: {
                const node_value = self.source.node(id);
                break :blk switch (node_value.kind) {
                    .text, .comment, .processing_instruction => node_value.value,
                    .element, .document => {
                        var out: std.ArrayList(u8) = .empty;
                        try self.appendDescendantText(id, &out);
                        break :blk try out.toOwnedSlice(self.allocator);
                    },
                };
            },
        };
    }

    fn appendDescendantText(
        self: *Runtime,
        id: dom.NodeId,
        out: *std.ArrayList(u8),
    ) Error!void {
        const node_value = self.source.node(id);
        if (node_value.kind == .text) {
            try out.appendSlice(self.allocator, node_value.value);
            return;
        }
        var child = node_value.first_child;
        while (child != dom.null_node) : (child = self.source.node(child).next_sibling) {
            try self.appendDescendantText(child, out);
        }
    }

    fn isDescendantOf(
        self: *Runtime,
        candidate: dom.NodeId,
        ancestor: dom.NodeId,
    ) bool {
        var current = self.source.node(candidate).parent;
        while (current != dom.null_node) {
            if (current == ancestor) return true;
            current = self.source.node(current).parent;
        }
        return false;
    }
};

fn modeMatches(template_mode: ?[]const u8, mode: ?[]const u8) bool {
    if (template_mode == null) return mode == null;
    if (mode == null) return false;
    return std.mem.eql(u8, template_mode.?, mode.?);
}

fn sortEntryLessThan(
    sorts: []const compile.SortKey,
    a: SortEntry,
    b: SortEntry,
) bool {
    for (sorts, 0..) |sort, index| {
        const order = compareSortValues(a.keys[index], b.keys[index]);
        if (order == .eq) continue;
        return if (sort.descending) order == .gt else order == .lt;
    }
    return a.index < b.index;
}

fn compareSortValues(a: SortValue, b: SortValue) std.math.Order {
    return switch (a) {
        .text => |a_text| switch (b) {
            .text => |b_text| std.mem.order(u8, a_text, b_text),
            .number => .lt,
        },
        .number => |a_number| switch (b) {
            .text => .gt,
            .number => |b_number| compareNumbers(a_number, b_number),
        },
    };
}

fn compareNumbers(a: f64, b: f64) std.math.Order {
    const a_nan = std.math.isNan(a);
    const b_nan = std.math.isNan(b);
    if (a_nan and b_nan) return .eq;
    if (a_nan) return .lt;
    if (b_nan) return .gt;
    return std.math.order(a, b);
}

fn prefixOf(node: *const dom.Node) []const u8 {
    if (node.local.len >= node.name.len) return "";
    return node.name[0 .. node.name.len - node.local.len - 1];
}

fn resolvePrefix(
    bindings: []const namespace.Binding,
    prefix: []const u8,
) ?[]const u8 {
    if (std.mem.eql(u8, prefix, "xml")) return namespace.xml_uri;
    for (bindings) |binding| {
        if (std.mem.eql(u8, binding.prefix, prefix)) return binding.uri;
    }
    return null;
}

fn resolveDefaultNamespace(bindings: []const namespace.Binding) []const u8 {
    for (bindings) |binding| {
        if (binding.prefix.len == 0) return binding.uri;
    }
    return "";
}

fn writeTextNode(
    out: *std.Io.Writer,
    document: *const dom.Document,
    id: dom.NodeId,
) !void {
    const node_value = document.node(id);
    if (node_value.kind == .text) {
        try out.writeAll(node_value.value);
        return;
    }
    if (node_value.kind != .document and node_value.kind != .element) return;
    var child = node_value.first_child;
    while (child != dom.null_node) : (child = document.node(child).next_sibling) {
        try writeTextNode(out, document, child);
    }
}

fn mapEvalError(err: xpath_eval.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidExpression => error.InvalidExpression,
        error.UndefinedVariable => error.UndefinedVariable,
        error.UndefinedPrefix => error.UndefinedPrefix,
        error.UnknownFunction => error.UnknownFunction,
        error.InvalidArgument => error.InvalidArgument,
    };
}

fn mapBuilderError(err: dom_builder.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidStylesheet,
    };
}
