//! XSLT 1.0 transformation runtime.

const std = @import("std");
const dom = @import("../dom.zig");
const dom_builder = @import("../dom_builder.zig");
const namespace = @import("../namespace.zig");
const xpath = @import("../xpath/root.zig");
const xpath_ast = @import("../xpath/ast.zig");
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

pub const Options = compile.Options;

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
        if (self.output.method == .html) {
            try writeHtmlNode(
                out,
                &self.document,
                self.document.documentNode(),
                false,
            );
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
        .key_map = KeyMap.init(arena_allocator),
        .node_ids = NodeIdMap.init(arena_allocator),
        .selector_cache = std.AutoHashMap(
            *const xpath_ast.Expr,
            *SelectorEntry,
        ).init(arena_allocator),
    };
    try runtime.prepareSource();
    try runtime.buildKeys();
    try runtime.buildTemplateMatches();
    try runtime.evaluateGlobals(options.parameters);
    try runtime.applyTemplates(&.{.{ .node = 0 }}, null, &.{});
    runtime.deinitFilteredSource();
    runtime.deinitFragments();

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

const KeyQuery = struct {
    name: []const u8,
    value: []const u8,
};

const KeyQueryContext = struct {
    pub fn hash(_: KeyQueryContext, key: KeyQuery) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(key.name);
        hasher.update("\x00");
        hasher.update(key.value);
        return hasher.final();
    }

    pub fn eql(_: KeyQueryContext, a: KeyQuery, b: KeyQuery) bool {
        return std.mem.eql(u8, a.name, b.name) and
            std.mem.eql(u8, a.value, b.value);
    }
};

const KeyMap = std.HashMap(
    KeyQuery,
    std.ArrayList(xpath.NodeRef),
    KeyQueryContext,
    80,
);

const NodeIdKey = struct {
    document: *const dom.Document,
    node: xpath.NodeRef,
};

const NodeIdKeyContext = struct {
    pub fn hash(_: NodeIdKeyContext, key: NodeIdKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        const pointer = @intFromPtr(key.document);
        hasher.update(std.mem.asBytes(&pointer));
        switch (key.node) {
            .node => |id| {
                hasher.update("n");
                hasher.update(std.mem.asBytes(&id));
            },
            .attribute => |attr| {
                hasher.update("a");
                hasher.update(std.mem.asBytes(&attr.element));
                hasher.update(std.mem.asBytes(&attr.index));
            },
            .namespace_node => |ns| {
                hasher.update("s");
                hasher.update(std.mem.asBytes(&ns.element));
                hasher.update(ns.prefix);
            },
        }
        return hasher.final();
    }

    pub fn eql(_: NodeIdKeyContext, a: NodeIdKey, b: NodeIdKey) bool {
        if (a.document != b.document) return false;
        return switch (a.node) {
            .node => |id| switch (b.node) {
                .node => |other| id == other,
                else => false,
            },
            .attribute => |attr| switch (b.node) {
                .attribute => |other| attr.element == other.element and
                    attr.index == other.index,
                else => false,
            },
            .namespace_node => |ns| switch (b.node) {
                .namespace_node => |other| ns.element == other.element and
                    std.mem.eql(u8, ns.prefix, other.prefix),
                else => false,
            },
        };
    }
};

const NodeIdMap = std.HashMap(NodeIdKey, usize, NodeIdKeyContext, 80);

const SelectorEntry = struct {
    nodes: []const xpath.NodeRef,
    map: std.AutoHashMap(NodeKey, void),
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
    key_map: KeyMap,
    node_ids: NodeIdMap,
    next_node_id: usize = 0,
    selector_cache: std.AutoHashMap(*const xpath_ast.Expr, *SelectorEntry),
    keys_ready: bool = false,
    filtered_source: ?*dom.Document = null,
    fragment_documents: std.ArrayList(*dom.Document) = .empty,
    current_template: ?*const compile.Template = null,
    current_mode: ?[]const u8 = null,

    fn copyOutput(self: *Runtime) Error!compile.Output {
        var output = self.stylesheet.output;
        if (output.version) |version| {
            output.version = try self.allocator.dupe(u8, version);
        }
        output.encoding = try self.allocator.dupe(u8, output.encoding);
        return output;
    }

    fn prepareSource(self: *Runtime) Error!void {
        if (self.stylesheet.space_rules.len == 0) return;
        var builder = dom_builder.Builder.init(self.allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidStylesheet,
        };
        var finished = false;
        defer {
            if (!finished) builder.deinit();
        }
        try self.copyFilteredNode(
            &builder,
            self.source.documentNode(),
            builder.document(),
        );
        const document = builder.finish() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidStylesheet,
        };
        finished = true;
        const pointer = try self.allocator.create(dom.Document);
        pointer.* = document;
        self.filtered_source = pointer;
        self.source = pointer;
    }

    fn deinitFilteredSource(self: *Runtime) void {
        if (self.filtered_source) |document| {
            document.deinit();
            self.filtered_source = null;
        }
    }

    fn copyFilteredNode(
        self: *Runtime,
        builder: *dom_builder.Builder,
        id: dom.NodeId,
        parent: dom.NodeId,
    ) Error!void {
        const node = self.source.node(id);
        switch (node.kind) {
            .document => {
                var child = node.first_child;
                while (child != dom.null_node) : (child = self.source.node(child).next_sibling) {
                    try self.copyFilteredNode(builder, child, parent);
                }
            },
            .element => {
                const new_id = builder.createElementNs(
                    prefixOf(node),
                    node.local,
                    node.ns,
                ) catch |err| return mapBuilderError(err);
                builder.appendChild(parent, new_id) catch |err|
                    return mapBuilderError(err);
                for (self.source.attributesOf(id)) |attr| {
                    if (namespace.Resolver.isNamespaceDeclaration(attr.name)) {
                        builder.setAttribute(
                            new_id,
                            attr.name,
                            attr.value,
                        ) catch |err| return mapBuilderError(err);
                    } else if (attr.ns.len == 0) {
                        builder.setAttribute(
                            new_id,
                            attr.name,
                            attr.value,
                        ) catch |err| return mapBuilderError(err);
                    } else {
                        builder.setAttributeNs(
                            new_id,
                            attr.prefixName(),
                            attr.localName(),
                            attr.ns,
                            attr.value,
                        ) catch |err| return mapBuilderError(err);
                    }
                }
                const strip = self.shouldStrip(node.ns, node.local);
                var child = node.first_child;
                while (child != dom.null_node) : (child = self.source.node(child).next_sibling) {
                    const child_node = self.source.node(child);
                    if (child_node.kind == .text and strip and
                        isWhitespaceText(child_node.value))
                    {
                        continue;
                    }
                    try self.copyFilteredNode(builder, child, new_id);
                }
            },
            .text => {
                const new_id = builder.createText(node.value) catch |err|
                    return mapBuilderError(err);
                builder.appendChild(parent, new_id) catch |err|
                    return mapBuilderError(err);
            },
            .comment => {
                const new_id = builder.createComment(node.value) catch |err|
                    return mapBuilderError(err);
                builder.appendChild(parent, new_id) catch |err|
                    return mapBuilderError(err);
            },
            .processing_instruction => {
                const new_id = builder.createProcessingInstruction(
                    node.name,
                    node.value,
                ) catch |err| return mapBuilderError(err);
                builder.appendChild(parent, new_id) catch |err|
                    return mapBuilderError(err);
            },
        }
    }

    fn shouldStrip(
        self: *Runtime,
        namespace_uri: []const u8,
        local: []const u8,
    ) bool {
        var strip = false;
        for (self.stylesheet.space_rules) |rule| {
            if (!rule.matches(namespace_uri, local)) continue;
            if (!rule.strip) return false;
            strip = true;
        }
        return strip;
    }

    fn buildKeys(self: *Runtime) Error!void {
        self.keys_ready = false;
        for (self.stylesheet.keys) |*key_def| {
            var context: xpath.Context = .{
                .document = self.source,
                .node = .{ .node = 0 },
                .namespaces = key_def.namespaces,
            };
            var selected = xpath_eval.evaluate(
                self.allocator,
                key_def.selector,
                &context,
            ) catch |err| return mapEvalError(err);
            defer selected.deinit();
            const nodes = switch (selected.value) {
                .node_set => |value| value,
                else => return error.InvalidStylesheet,
            };
            for (nodes) |node| {
                const value = try self.evalOwned(key_def.use, node, 1, 1);
                switch (value) {
                    .node_set => |value_nodes| {
                        for (value_nodes) |value_node| {
                            try self.addKeyValue(
                                key_def.name,
                                try self.stringValue(value_node),
                                node,
                            );
                        }
                    },
                    else => {
                        try self.addKeyValue(
                            key_def.name,
                            try self.toString(value),
                            node,
                        );
                    },
                }
            }
        }
        var iterator = self.key_map.iterator();
        while (iterator.next()) |entry| {
            const list = entry.value_ptr;
            std.mem.sort(
                xpath.NodeRef,
                list.items,
                {},
                xpath_value.orderLessThan,
            );
            var write: usize = 0;
            for (list.items) |node| {
                if (write == 0 or !list.items[write - 1].eql(node)) {
                    list.items[write] = node;
                    write += 1;
                }
            }
            list.shrinkRetainingCapacity(write);
        }
        self.keys_ready = true;
    }

    fn addKeyValue(
        self: *Runtime,
        name: []const u8,
        value: []const u8,
        node: xpath.NodeRef,
    ) Error!void {
        const result = try self.key_map.getOrPut(.{
            .name = name,
            .value = value,
        });
        if (!result.found_existing) result.value_ptr.* = .empty;
        try result.value_ptr.append(self.allocator, node);
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
                .key_resolver = if (self.keys_ready) .{
                    .context = self,
                    .lookup = lookupKey,
                } else null,
                .xslt_functions = true,
                .node_id_generator = .{
                    .context = self,
                    .generate = generateNodeId,
                },
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
            .body => |body| try self.captureTree(body, node, position, size),
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
            .key_resolver = if (self.keys_ready) .{
                .context = self,
                .lookup = lookupKey,
            } else null,
            .number_formatter = .{
                .context = self,
                .format = formatNumberCallback,
            },
            .xslt_functions = true,
            .node_id_generator = .{
                .context = self,
                .generate = generateNodeId,
            },
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
            .tree => |tree| .{ .tree = tree },
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
                if (state.template.precedence < current.precedence) continue;
                if (state.template.precedence == current.precedence) {
                    if (state.template.priority < current.priority) continue;
                    if (state.template.priority == current.priority and
                        state.template.order < current.order)
                    {
                        continue;
                    }
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
        const saved_mode = self.current_mode;
        self.current_mode = mode;
        defer self.current_mode = saved_mode;
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
        const saved_template = self.current_template;
        self.current_template = template;
        defer self.current_template = saved_template;
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
            .raw_text => |text| try self.appendTextRaw(text),
            .value_of => |value_of| {
                const value = try self.evalOwned(
                    value_of.select,
                    node,
                    position,
                    size,
                );
                const text = try self.toString(value);
                if (value_of.disable_output_escaping) {
                    try self.appendTextRaw(text);
                } else {
                    try self.appendText(text);
                }
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
            .apply_imports => |apply_imports| try self.executeApplyImports(
                apply_imports,
                node,
                position,
                size,
            ),
        }
    }

    fn executeApplyImports(
        self: *Runtime,
        instruction: compile.ApplyImports,
        node: xpath.NodeRef,
        position: usize,
        size: usize,
    ) Error!void {
        const current = self.current_template orelse return;
        const params = try self.evaluateParams(
            instruction.params,
            node,
            position,
            size,
        );
        if (self.findTemplateBelow(
            node,
            self.current_mode,
            current.precedence,
        )) |template| {
            try self.executeTemplate(template, node, position, size, params);
        } else {
            try self.builtinTemplate(node, self.current_mode);
        }
    }

    fn findTemplateBelow(
        self: *Runtime,
        node: xpath.NodeRef,
        mode: ?[]const u8,
        maximum_precedence: usize,
    ) ?*const compile.Template {
        const key = nodeKey(node);
        var best: ?*const compile.Template = null;
        for (self.template_states) |state| {
            if (state.template.selector == null) continue;
            if (state.template.precedence >= maximum_precedence) continue;
            if (!modeMatches(state.template.mode, mode)) continue;
            if (!state.matches.contains(key)) continue;
            if (best) |current| {
                if (state.template.precedence < current.precedence) continue;
                if (state.template.precedence == current.precedence) {
                    if (state.template.priority < current.priority) continue;
                    if (state.template.priority == current.priority and
                        state.template.order < current.order)
                    {
                        continue;
                    }
                }
            }
            best = state.template;
        }
        return best;
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
        const saved_parent = self.parent;
        self.parent = id;
        defer self.parent = saved_parent;
        for (element.attribute_sets) |set_name| {
            try self.executeAttributeSet(set_name, node, position, size);
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
            const name = candidate.name orelse continue;
            if (!std.mem.eql(u8, name, call.name)) continue;
            if (template) |current| {
                if (candidate.precedence < current.precedence) continue;
                if (candidate.precedence == current.precedence and
                    candidate.order < current.order)
                {
                    continue;
                }
            }
            template = candidate;
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
        const value = try self.evalOwned(
            instruction.select,
            node,
            position,
            size,
        );
        if (value == .tree) {
            try self.copyFragment(value.tree);
            return;
        }
        const nodes = try self.requireNodeSet(value);
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
        for (instruction.attribute_sets) |set_name| {
            try self.executeAttributeSet(set_name, node, position, size);
        }
        try self.executeInstructions(instruction.body, node, position, size);
    }

    fn executeAttributeSet(
        self: *Runtime,
        name: []const u8,
        node: xpath.NodeRef,
        position: usize,
        size: usize,
    ) Error!void {
        for (self.stylesheet.attribute_sets) |set| {
            if (!std.mem.eql(u8, set.name, name)) continue;
            const instructions = set.expanded orelse set.raw_instructions;
            try self.executeInstructions(
                instructions,
                node,
                position,
                size,
            );
            return;
        }
        return error.InvalidStylesheet;
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
        const format_text = if (instruction.format) |format|
            try self.evaluateAvt(format, node, position, size)
        else
            "1";
        if (instruction.value) |value| {
            const number = try self.toNumber(try self.evalOwned(
                value,
                node,
                position,
                size,
            ));
            if (std.math.isNan(number)) {
                try self.appendText("NaN");
                return;
            }
            if (std.math.isInf(number)) {
                try self.appendText(if (number < 0) "-Infinity" else "Infinity");
                return;
            }
            const rounded = std.math.floor(number + 0.5);
            if (rounded < 1) {
                try self.appendText(try std.fmt.allocPrint(
                    self.allocator,
                    "{d}",
                    .{rounded},
                ));
                return;
            }
            try self.appendText(try self.formatPositions(
                &.{@intFromFloat(rounded)},
                format_text,
            ));
            return;
        }
        switch (instruction.level) {
            .single => try self.numberSingle(instruction, node, format_text),
            .multiple => try self.numberMultiple(instruction, node, format_text),
            .any => try self.numberAny(instruction, node, format_text),
        }
    }

    fn numberSingle(
        self: *Runtime,
        instruction: compile.NumberInstruction,
        node: xpath.NodeRef,
        format_text: []const u8,
    ) Error!void {
        var target: ?xpath.NodeRef = null;
        var current = node;
        while (true) {
            if (instruction.from) |from| {
                if (try self.selectorMatches(from, current)) break;
            }
            if (try self.matchesCount(instruction, node, current)) {
                target = current;
                break;
            }
            current = self.parentRef(current) orelse break;
        }
        const found = target orelse return;
        const sibling_position = try self.siblingPosition(
            instruction,
            node,
            found,
        );
        if (sibling_position == 0) return;
        try self.appendText(try self.formatPositions(
            &.{sibling_position},
            format_text,
        ));
    }

    fn numberMultiple(
        self: *Runtime,
        instruction: compile.NumberInstruction,
        node: xpath.NodeRef,
        format_text: []const u8,
    ) Error!void {
        var positions: std.ArrayList(usize) = .empty;
        var current = node;
        while (true) {
            if (instruction.from) |from| {
                if (try self.selectorMatches(from, current)) break;
            }
            if (try self.matchesCount(instruction, node, current)) {
                const sibling_position = try self.siblingPosition(
                    instruction,
                    node,
                    current,
                );
                if (sibling_position != 0) {
                    try positions.append(self.allocator, sibling_position);
                }
            }
            current = self.parentRef(current) orelse break;
        }
        if (positions.items.len == 0) return;
        std.mem.reverse(usize, positions.items);
        try self.appendText(try self.formatPositions(
            positions.items,
            format_text,
        ));
    }

    fn numberAny(
        self: *Runtime,
        instruction: compile.NumberInstruction,
        node: xpath.NodeRef,
        format_text: []const u8,
    ) Error!void {
        var boundary: ?xpath.NodeRef = null;
        if (instruction.from) |from| {
            var current = node;
            while (true) {
                if (try self.selectorMatches(from, current)) {
                    boundary = current;
                    break;
                }
                current = self.parentRef(current) orelse break;
            }
        }
        var count: usize = 0;
        if (instruction.count) |count_selector| {
            const entry = try self.selectorEntry(count_selector);
            for (entry.nodes) |candidate| {
                if (!numberInRange(candidate, node, boundary)) continue;
                count += 1;
            }
        } else {
            for (self.source.nodes, 0..) |_, index| {
                const candidate: xpath.NodeRef = .{
                    .node = @intCast(index),
                };
                if (!defaultCountMatches(self.source, node, candidate)) {
                    continue;
                }
                if (!numberInRange(candidate, node, boundary)) continue;
                count += 1;
            }
        }
        if (count != 0) {
            try self.appendText(try self.formatPositions(
                &.{count},
                format_text,
            ));
        }
    }

    fn selectorEntry(
        self: *Runtime,
        selector: compile.CompiledExpr,
    ) Error!*SelectorEntry {
        if (self.selector_cache.get(selector.node)) |entry| return entry;
        var context: xpath.Context = .{
            .document = self.source,
            .node = .{ .node = 0 },
            .namespaces = selector.namespaces,
            .key_resolver = if (self.keys_ready) .{
                .context = self,
                .lookup = lookupKey,
            } else null,
            .xslt_functions = true,
            .node_id_generator = .{
                .context = self,
                .generate = generateNodeId,
            },
        };
        var result = xpath_eval.evaluate(
            self.allocator,
            selector.node,
            &context,
        ) catch |err| return mapEvalError(err);
        defer result.deinit();
        const nodes = switch (result.value) {
            .node_set => |value| try self.allocator.dupe(
                xpath.NodeRef,
                value,
            ),
            else => return error.InvalidStylesheet,
        };
        const entry = try self.allocator.create(SelectorEntry);
        entry.* = .{
            .nodes = nodes,
            .map = std.AutoHashMap(NodeKey, void).init(self.allocator),
        };
        for (nodes) |candidate| {
            try entry.map.put(nodeKey(candidate), {});
        }
        try self.selector_cache.put(selector.node, entry);
        return entry;
    }

    fn selectorMatches(
        self: *Runtime,
        selector: compile.CompiledExpr,
        node: xpath.NodeRef,
    ) Error!bool {
        const entry = try self.selectorEntry(selector);
        return entry.map.contains(nodeKey(node));
    }

    fn matchesCount(
        self: *Runtime,
        instruction: compile.NumberInstruction,
        current: xpath.NodeRef,
        candidate: xpath.NodeRef,
    ) Error!bool {
        if (instruction.count) |selector| {
            return self.selectorMatches(selector, candidate);
        }
        return defaultCountMatches(self.source, current, candidate);
    }

    fn parentRef(
        self: *Runtime,
        node: xpath.NodeRef,
    ) ?xpath.NodeRef {
        return switch (node) {
            .node => |id| blk: {
                const parent = self.source.node(id).parent;
                if (parent == dom.null_node) break :blk null;
                break :blk .{ .node = parent };
            },
            .attribute => |attr| .{ .node = attr.element },
            .namespace_node => |ns| .{ .node = ns.element },
        };
    }

    fn siblingPosition(
        self: *Runtime,
        instruction: compile.NumberInstruction,
        current: xpath.NodeRef,
        target: xpath.NodeRef,
    ) Error!usize {
        switch (target) {
            .node => |id| {
                const node = self.source.node(id);
                const parent = node.parent;
                if (parent == dom.null_node) return 1;
                var position: usize = 0;
                var sibling = self.source.node(parent).first_child;
                while (sibling != dom.null_node) : (sibling = self.source.node(sibling).next_sibling) {
                    const candidate: xpath.NodeRef = .{ .node = sibling };
                    if (try self.matchesCount(instruction, current, candidate)) {
                        position += 1;
                    }
                    if (sibling == id) break;
                }
                return position;
            },
            .attribute => |attr| {
                var position: usize = 0;
                const attributes = self.source.attributesOf(attr.element);
                for (attributes, 0..) |_, index| {
                    const candidate: xpath.NodeRef = .{
                        .attribute = .{
                            .element = attr.element,
                            .index = @intCast(index),
                        },
                    };
                    if (try self.matchesCount(instruction, current, candidate)) {
                        position += 1;
                    }
                    if (index == attr.index) break;
                }
                return position;
            },
            .namespace_node => return 1,
        }
    }

    fn formatPositions(
        self: *Runtime,
        numbers: []const usize,
        format_text: []const u8,
    ) Error![]const u8 {
        const parsed = try parseNumberFormat(self.allocator, format_text);
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(self.allocator, parsed.prefix);
        for (numbers, 0..) |number, index| {
            const token_index = @min(index, parsed.tokens.len - 1);
            try appendFormattedNumber(
                self.allocator,
                &out,
                number,
                parsed.tokens[token_index],
            );
            if (index + 1 < numbers.len) {
                if (index < parsed.separators.len) {
                    try out.appendSlice(
                        self.allocator,
                        parsed.separators[index],
                    );
                }
            }
        }
        try out.appendSlice(self.allocator, parsed.suffix);
        return out.toOwnedSlice(self.allocator);
    }

    fn findDecimalFormat(
        self: *Runtime,
        name: ?[]const u8,
    ) ?*const compile.DecimalFormat {
        for (self.stylesheet.decimal_formats) |*format| {
            if (name == null) {
                if (format.name == null) return format;
            } else if (format.name) |format_name| {
                if (std.mem.eql(u8, format_name, name.?)) return format;
            }
        }
        if (name == null) return &default_decimal_format;
        return null;
    }

    fn formatNumberPattern(
        self: *Runtime,
        allocator: std.mem.Allocator,
        number: f64,
        pattern: []const u8,
        format: *const compile.DecimalFormat,
    ) xpath_value.NumberFormatError![]const u8 {
        _ = self;
        const parsed = try parseFormatPattern(pattern, format);
        if (std.math.isNan(number)) return format.nan;
        if (std.math.isInf(number)) {
            var out: std.ArrayList(u8) = .empty;
            if (number < 0) try appendCodepoint(allocator, &out, format.minus_sign);
            try out.appendSlice(allocator, format.infinity);
            return out.toOwnedSlice(allocator);
        }
        const negative = number < 0;
        var subpattern = parsed.positive;
        var auto_minus = false;
        if (negative) {
            if (parsed.negative) |negative_pattern| {
                if (negative_pattern.has_digits) {
                    subpattern = negative_pattern;
                } else {
                    subpattern.prefix = negative_pattern.prefix;
                    subpattern.suffix = negative_pattern.suffix;
                }
            } else {
                auto_minus = true;
            }
        }
        const value = @abs(number) * subpattern.scale;
        const max_fraction = @min(subpattern.max_fraction, 18);
        var scale: f64 = 1;
        for (0..max_fraction) |_| scale *= 10;
        const rounded = std.math.floor(value * scale + 0.5);
        if (!std.math.isFinite(rounded) or rounded > 1e30) {
            var out: std.ArrayList(u8) = .empty;
            if (auto_minus) try appendCodepoint(allocator, &out, format.minus_sign);
            try out.appendSlice(allocator, subpattern.prefix);
            try out.appendSlice(
                allocator,
                try std.fmt.allocPrint(allocator, "{d}", .{value}),
            );
            try out.appendSlice(allocator, subpattern.suffix);
            return out.toOwnedSlice(allocator);
        }
        const integer_value: u128 = @intFromFloat(rounded / scale);
        const fraction_value: u128 = @intFromFloat(
            rounded - @as(f64, @floatFromInt(integer_value)) * scale,
        );
        var integer_buffer: [64]u8 = undefined;
        const integer_digits = std.fmt.bufPrint(
            &integer_buffer,
            "{d}",
            .{integer_value},
        ) catch return error.InvalidFormat;
        var fraction_buffer: [32]u8 = undefined;
        var fraction_length: usize = 0;
        if (max_fraction != 0) {
            var divisor: u128 = 1;
            for (0..max_fraction - 1) |_| divisor *= 10;
            var remaining = fraction_value;
            var index: usize = 0;
            while (index < max_fraction) : (index += 1) {
                const digit: u8 = @intCast(remaining / divisor);
                fraction_buffer[index] = '0' + digit;
                remaining %= divisor;
                if (divisor >= 10) divisor /= 10;
                fraction_length += 1;
            }
            while (fraction_length > subpattern.min_fraction and
                fraction_buffer[fraction_length - 1] == '0')
            {
                fraction_length -= 1;
            }
        }
        var out: std.ArrayList(u8) = .empty;
        if (auto_minus) try appendCodepoint(allocator, &out, format.minus_sign);
        try out.appendSlice(allocator, subpattern.prefix);
        try appendFormattedInteger(
            allocator,
            &out,
            integer_digits,
            subpattern.min_integer,
            subpattern.group_size,
            format,
        );
        if (fraction_length != 0) {
            try appendCodepoint(allocator, &out, format.decimal_separator);
            for (fraction_buffer[0..fraction_length]) |digit| {
                try appendDigit(allocator, &out, digit, format.zero_digit);
            }
        }
        try out.appendSlice(allocator, subpattern.suffix);
        return out.toOwnedSlice(allocator);
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

    fn captureTree(
        self: *Runtime,
        body: []const compile.Instruction,
        node: xpath.NodeRef,
        position: usize,
        size: usize,
    ) Error!xpath.Value {
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
        const document = temp.finish() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidStylesheet,
        };
        finished = true;
        const pointer = try self.allocator.create(dom.Document);
        pointer.* = document;
        try self.fragment_documents.append(self.allocator, pointer);
        const fragment = try self.allocator.create(xpath_value.TreeFragment);
        fragment.* = .{ .document = pointer };
        return .{ .tree = fragment };
    }

    fn deinitFragments(self: *Runtime) void {
        for (self.fragment_documents.items) |document| {
            document.deinit();
        }
        self.fragment_documents.clearRetainingCapacity();
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

    fn appendTextRaw(self: *Runtime, text: []const u8) Error!void {
        if (text.len == 0) return;
        const id = self.builder.createTextRaw(text) catch |err|
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

    fn copyFragment(
        self: *Runtime,
        fragment: *const xpath_value.TreeFragment,
    ) Error!void {
        var child = fragment.document.node(
            fragment.document.documentNode(),
        ).first_child;
        while (child != dom.null_node) : (child = fragment.document.node(child).next_sibling) {
            try self.copyDeepNodeFrom(fragment.document, .{ .node = child });
        }
    }

    fn copyDeepNode(self: *Runtime, node: xpath.NodeRef) Error!void {
        try self.copyDeepNodeFrom(self.source, node);
    }

    fn copyDeepNodeFrom(
        self: *Runtime,
        source: *const dom.Document,
        node: xpath.NodeRef,
    ) Error!void {
        switch (node) {
            .attribute => |attr| {
                const attribute = source.attributesOf(attr.element)[attr.index];
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
            .node => |id| try self.copyDeepNodeIdFrom(source, id),
        }
    }

    fn copyDeepNodeIdFrom(
        self: *Runtime,
        source: *const dom.Document,
        id: dom.NodeId,
    ) Error!void {
        const node_value = source.node(id);
        switch (node_value.kind) {
            .document => {
                var child = node_value.first_child;
                while (child != dom.null_node) : (child = source.node(child).next_sibling) {
                    try self.copyDeepNodeIdFrom(source, child);
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
                try self.copyElementNamespacesFrom(source, id, new_id);
                for (source.attributesOf(id)) |attr| {
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
                while (child != dom.null_node) : (child = source.node(child).next_sibling) {
                    try self.copyDeepNodeIdFrom(source, child);
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

    fn copyElementNamespacesFrom(
        self: *Runtime,
        source: *const dom.Document,
        id: dom.NodeId,
        new_id: dom.NodeId,
    ) Error!void {
        const node_value = source.node(id);
        const prefix = prefixOf(node_value);
        var has_default = false;
        var has_prefix = false;
        for (source.attributesOf(id)) |attr| {
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
            const bindings = try source.inScopeNamespaces(self.allocator, id);
            for (bindings) |binding| {
                if (std.mem.eql(u8, binding.prefix, prefix)) {
                    try self.addNamespaceDecl(new_id, prefix, binding.uri);
                    break;
                }
            }
        }
        // Attributes may use prefixes declared on an ancestor.
        for (source.attributesOf(id)) |attr| {
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
            const bindings = try source.inScopeNamespaces(self.allocator, id);
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
            .tree => |tree| try self.fragmentString(tree),
        };
    }

    fn fragmentString(
        self: *Runtime,
        tree: *const xpath_value.TreeFragment,
    ) Error![]const u8 {
        return tree.document.textContentAlloc(
            self.allocator,
            tree.document.documentNode(),
        ) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    fn toNumber(self: *Runtime, value: xpath.Value) Error!f64 {
        return switch (value) {
            .number => |number| number,
            .boolean => |boolean| if (boolean) 1 else 0,
            .string => |string| xpath_value.parseNumber(string),
            .node_set => xpath_value.parseNumber(try self.toString(value)),
            .tree => xpath_value.parseNumber(try self.toString(value)),
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

fn lookupKey(
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    name: []const u8,
    value: []const u8,
) xpath_value.KeyError![]const xpath.NodeRef {
    _ = allocator;
    const runtime: *Runtime = @ptrCast(@alignCast(context.?));
    if (runtime.key_map.get(.{ .name = name, .value = value })) |list| {
        return list.items;
    }
    return &.{};
}

fn generateNodeId(
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    document: *const dom.Document,
    node: xpath.NodeRef,
) error{OutOfMemory}![]const u8 {
    const runtime: *Runtime = @ptrCast(@alignCast(context.?));
    const entry = try runtime.node_ids.getOrPut(.{
        .document = document,
        .node = node,
    });
    if (!entry.found_existing) {
        runtime.next_node_id += 1;
        entry.value_ptr.* = runtime.next_node_id;
    }
    return std.fmt.allocPrint(allocator, "id{d}", .{entry.value_ptr.*});
}

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

fn isWhitespaceText(value: []const u8) bool {
    for (value) |byte| {
        if (byte != ' ' and byte != '\t' and byte != '\r' and byte != '\n') {
            return false;
        }
    }
    return true;
}

const default_decimal_format: compile.DecimalFormat = .{};

const Subpattern = struct {
    prefix: []const u8,
    suffix: []const u8,
    min_integer: usize,
    min_fraction: usize,
    max_fraction: usize,
    group_size: usize,
    scale: f64,
    has_digits: bool = true,
};

const ParsedFormatPattern = struct {
    positive: Subpattern,
    negative: ?Subpattern,
};

fn formatNumberCallback(
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    number: f64,
    pattern: []const u8,
    format_name: ?[]const u8,
) xpath_value.NumberFormatError![]const u8 {
    const runtime: *Runtime = @ptrCast(@alignCast(context.?));
    const format = runtime.findDecimalFormat(format_name) orelse
        return error.InvalidFormat;
    return runtime.formatNumberPattern(allocator, number, pattern, format);
}

const DecodedCodepoint = struct {
    cp: u21,
    end: usize,
};

fn decodeAt(text: []const u8, index: usize) ?DecodedCodepoint {
    const length = std.unicode.utf8ByteSequenceLength(text[index]) catch
        return null;
    if (index + length > text.len) return null;
    const cp = std.unicode.utf8Decode(text[index..][0..length]) catch
        return null;
    return .{ .cp = cp, .end = index + length };
}

fn parseFormatPattern(
    pattern: []const u8,
    format: *const compile.DecimalFormat,
) xpath_value.NumberFormatError!ParsedFormatPattern {
    var separator_start: ?usize = null;
    var separator_end: usize = 0;
    var index: usize = 0;
    while (index < pattern.len) {
        const decoded = decodeAt(pattern, index) orelse
            return error.InvalidFormat;
        if (decoded.cp == format.pattern_separator) {
            if (separator_start != null) return error.InvalidFormat;
            separator_start = index;
            separator_end = decoded.end;
        }
        index = decoded.end;
    }
    if (separator_start) |start| {
        return .{
            .positive = try parseSubpattern(
                pattern[0..start],
                format,
                false,
            ),
            .negative = try parseSubpattern(
                pattern[separator_end..],
                format,
                true,
            ),
        };
    }
    return .{
        .positive = try parseSubpattern(pattern, format, false),
        .negative = null,
    };
}

fn parseSubpattern(
    text: []const u8,
    format: *const compile.DecimalFormat,
    allow_empty: bool,
) xpath_value.NumberFormatError!Subpattern {
    if (text.len == 0) {
        if (!allow_empty) return error.InvalidFormat;
        return .{
            .prefix = "",
            .suffix = "",
            .min_integer = 0,
            .min_fraction = 0,
            .max_fraction = 0,
            .group_size = 0,
            .scale = 1,
            .has_digits = false,
        };
    }

    var first_start: ?usize = null;
    var last_end: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const decoded = decodeAt(text, index) orelse
            return error.InvalidFormat;
        if (decoded.cp == format.zero_digit or decoded.cp == format.digit) {
            if (first_start == null) first_start = index;
            last_end = decoded.end;
        }
        index = decoded.end;
    }
    const placeholder_start = first_start orelse return error.InvalidFormat;

    var structural_start = placeholder_start;
    index = 0;
    while (index < placeholder_start) {
        const decoded = decodeAt(text, index) orelse
            return error.InvalidFormat;
        if (decoded.cp == format.decimal_separator) {
            structural_start = index;
        }
        index = decoded.end;
    }

    var min_integer: usize = 0;
    var min_fraction: usize = 0;
    var max_fraction: usize = 0;
    var integer_digits: usize = 0;
    var last_group_integer_digits: ?usize = null;
    var decimal_seen = false;
    index = structural_start;
    while (index < last_end) {
        const decoded = decodeAt(text, index) orelse
            return error.InvalidFormat;
        const cp = decoded.cp;
        if (cp == format.zero_digit or cp == format.digit) {
            if (decimal_seen) {
                max_fraction += 1;
                if (cp == format.zero_digit) min_fraction += 1;
            } else {
                integer_digits += 1;
                if (cp == format.zero_digit) min_integer += 1;
            }
        } else if (cp == format.decimal_separator) {
            decimal_seen = true;
        } else if (cp == format.grouping_separator and !decimal_seen) {
            last_group_integer_digits = integer_digits;
        }
        index = decoded.end;
    }

    const prefix = text[0..structural_start];
    const suffix = text[last_end..];
    var scale: f64 = 1;
    scanScale(prefix, format, &scale);
    scanScale(suffix, format, &scale);
    return .{
        .prefix = prefix,
        .suffix = suffix,
        .min_integer = min_integer,
        .min_fraction = min_fraction,
        .max_fraction = max_fraction,
        .group_size = if (last_group_integer_digits) |group_start|
            integer_digits - group_start
        else
            0,
        .scale = scale,
        .has_digits = true,
    };
}

fn scanScale(
    text: []const u8,
    format: *const compile.DecimalFormat,
    scale: *f64,
) void {
    var index: usize = 0;
    while (index < text.len) {
        const decoded = decodeAt(text, index) orelse return;
        if (decoded.cp == format.percent) {
            scale.* = 100;
        } else if (decoded.cp == format.per_mille) {
            scale.* = 1000;
        }
        index = decoded.end;
    }
}

fn appendCodepoint(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    codepoint: u21,
) xpath_value.NumberFormatError!void {
    var buffer: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(codepoint, &buffer) catch
        return error.InvalidFormat;
    try out.appendSlice(allocator, buffer[0..length]);
}

fn appendDigit(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    digit: u8,
    zero_digit: u21,
) xpath_value.NumberFormatError!void {
    const codepoint = zero_digit + @as(u21, digit - '0');
    try appendCodepoint(allocator, out, codepoint);
}

fn appendFormattedInteger(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    digits: []const u8,
    min_integer: usize,
    group_size: usize,
    format: *const compile.DecimalFormat,
) xpath_value.NumberFormatError!void {
    var padded: std.ArrayList(u8) = .empty;
    var padding = digits.len;
    while (padding < min_integer) : (padding += 1) {
        try padded.append(allocator, '0');
    }
    try padded.appendSlice(allocator, digits);
    for (padded.items, 0..) |digit, index| {
        if (group_size != 0 and index != 0 and
            (padded.items.len - index) % group_size == 0)
        {
            try appendCodepoint(allocator, out, format.grouping_separator);
        }
        try appendDigit(allocator, out, digit, format.zero_digit);
    }
}

const NumberTokenKind = enum { decimal, alphabetic, roman };

const NumberToken = struct {
    kind: NumberTokenKind,
    width: usize = 1,
    upper: bool = false,
};

const ParsedNumberFormat = struct {
    prefix: []const u8,
    suffix: []const u8,
    tokens: []const NumberToken,
    separators: []const []const u8,
};

fn parseNumberFormat(
    allocator: std.mem.Allocator,
    text: []const u8,
) Error!ParsedNumberFormat {
    const Span = struct {
        start: usize,
        end: usize,
        token: NumberToken,
    };
    var spans: std.ArrayList(Span) = .empty;
    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        if (byte == '0' or byte == '1') {
            const start = index;
            while (index < text.len and
                (text[index] == '0' or text[index] == '1'))
            {
                index += 1;
            }
            try spans.append(allocator, .{
                .start = start,
                .end = index,
                .token = .{ .kind = .decimal, .width = index - start },
            });
        } else if (byte == 'a' or byte == 'A' or byte == 'i' or byte == 'I') {
            const start = index;
            while (index < text.len and text[index] == byte) index += 1;
            const kind: NumberTokenKind = if (byte == 'a' or byte == 'A')
                .alphabetic
            else
                .roman;
            try spans.append(allocator, .{
                .start = start,
                .end = index,
                .token = .{
                    .kind = kind,
                    .width = index - start,
                    .upper = byte == 'A' or byte == 'I',
                },
            });
        } else {
            index += 1;
        }
    }
    if (spans.items.len == 0) {
        const tokens = try allocator.alloc(NumberToken, 1);
        tokens[0] = .{ .kind = .decimal };
        return .{
            .prefix = "",
            .suffix = "",
            .tokens = tokens,
            .separators = &.{},
        };
    }
    const tokens = try allocator.alloc(NumberToken, spans.items.len);
    for (spans.items, 0..) |span, span_index| {
        tokens[span_index] = span.token;
    }
    const separator_count = if (spans.items.len > 1)
        spans.items.len - 1
    else
        0;
    const separators = try allocator.alloc([]const u8, separator_count);
    for (0..separator_count) |separator_index| {
        separators[separator_index] = text[spans.items[separator_index].end..][0..(spans.items[separator_index + 1].start -
            spans.items[separator_index].end)];
    }
    return .{
        .prefix = text[0..spans.items[0].start],
        .suffix = text[spans.items[spans.items.len - 1].end..],
        .tokens = tokens,
        .separators = separators,
    };
}

fn appendFormattedNumber(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    number: usize,
    token: NumberToken,
) Error!void {
    switch (token.kind) {
        .decimal => try appendDecimal(allocator, out, number, token.width),
        .alphabetic => {
            if (number == 0) {
                try appendDecimal(allocator, out, number, token.width);
                return;
            }
            var buffer: [32]u8 = undefined;
            var length: usize = 0;
            var value = number;
            while (value > 0) {
                value -= 1;
                const base: u8 = if (token.upper) 'A' else 'a';
                buffer[length] = base + @as(u8, @intCast(value % 26));
                value /= 26;
                length += 1;
            }
            while (length > 0) {
                length -= 1;
                try out.append(allocator, buffer[length]);
            }
        },
        .roman => {
            if (number == 0 or number >= 4000) {
                try appendDecimal(allocator, out, number, token.width);
                return;
            }
            const roman = [_]struct { usize, []const u8 }{
                .{ 1000, "m" }, .{ 900, "cm" }, .{ 500, "d" },
                .{ 400, "cd" }, .{ 100, "c" },  .{ 90, "xc" },
                .{ 50, "l" },   .{ 40, "xl" },  .{ 10, "x" },
                .{ 9, "ix" },   .{ 5, "v" },    .{ 4, "iv" },
                .{ 1, "i" },
            };
            var value = number;
            for (roman) |entry| {
                while (value >= entry[0]) {
                    value -= entry[0];
                    for (entry[1]) |byte| {
                        try out.append(
                            allocator,
                            if (token.upper) std.ascii.toUpper(byte) else byte,
                        );
                    }
                }
            }
        },
    }
}

fn appendDecimal(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    number: usize,
    width: usize,
) Error!void {
    var buffer: [32]u8 = undefined;
    const digits = std.fmt.bufPrint(&buffer, "{d}", .{number}) catch
        return error.InvalidArgument;
    if (digits.len < width) {
        var padding = digits.len;
        while (padding < width) : (padding += 1) {
            try out.append(allocator, '0');
        }
    }
    try out.appendSlice(allocator, digits);
}

fn defaultCountMatches(
    document: *const dom.Document,
    current: xpath.NodeRef,
    candidate: xpath.NodeRef,
) bool {
    switch (current) {
        .node => |id| {
            const current_node = document.node(id);
            return switch (candidate) {
                .node => |candidate_id| blk: {
                    const candidate_node = document.node(candidate_id);
                    if (candidate_node.kind != current_node.kind) {
                        break :blk false;
                    }
                    break :blk switch (current_node.kind) {
                        .element => std.mem.eql(
                            u8,
                            candidate_node.local,
                            current_node.local,
                        ) and std.mem.eql(
                            u8,
                            candidate_node.ns,
                            current_node.ns,
                        ),
                        .processing_instruction => std.mem.eql(
                            u8,
                            candidate_node.name,
                            current_node.name,
                        ),
                        .text, .comment, .document => true,
                    };
                },
                else => false,
            };
        },
        .attribute => |attribute| {
            return switch (candidate) {
                .attribute => |other| blk: {
                    const left = document.attributesOf(
                        attribute.element,
                    )[attribute.index];
                    const right = document.attributesOf(
                        other.element,
                    )[other.index];
                    break :blk std.mem.eql(
                        u8,
                        left.localName(),
                        right.localName(),
                    ) and std.mem.eql(u8, left.ns, right.ns);
                },
                else => false,
            };
        },
        .namespace_node => |namespace_node| {
            return switch (candidate) {
                .namespace_node => |other| std.mem.eql(
                    u8,
                    namespace_node.prefix,
                    other.prefix,
                ),
                else => false,
            };
        },
    }
}

fn numberInRange(
    candidate: xpath.NodeRef,
    current: xpath.NodeRef,
    boundary: ?xpath.NodeRef,
) bool {
    const candidate_key = candidate.orderKey();
    if (boundary) |boundary_node| {
        const boundary_key = boundary_node.orderKey();
        if (valueOrderKeyLessThan(candidate_key, boundary_key) or
            orderKeysEqual(candidate_key, boundary_key))
        {
            return false;
        }
    }
    const current_key = current.orderKey();
    if (valueOrderKeyLessThan(current_key, candidate_key)) return false;
    return true;
}

fn valueOrderKeyLessThan(
    a: xpath_value.OrderKey,
    b: xpath_value.OrderKey,
) bool {
    return xpath_value.orderKeyLessThan(a, b);
}

fn orderKeysEqual(
    a: xpath_value.OrderKey,
    b: xpath_value.OrderKey,
) bool {
    return a.primary == b.primary and a.phase == b.phase and
        a.index == b.index;
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

fn writeHtmlNode(
    out: *std.Io.Writer,
    document: *const dom.Document,
    id: dom.NodeId,
    raw_text: bool,
) std.Io.Writer.Error!void {
    const node_value = document.node(id);
    switch (node_value.kind) {
        .document => {
            var child = node_value.first_child;
            while (child != dom.null_node) : (child = document.node(child).next_sibling) {
                try writeHtmlNode(out, document, child, false);
            }
        },
        .element => try writeHtmlElement(out, document, id),
        .text => {
            if (raw_text or node_value.raw_text) {
                try out.writeAll(node_value.value);
            } else {
                try writeHtmlText(out, node_value.value);
            }
        },
        .comment => {
            try out.writeAll("<!--");
            try out.writeAll(node_value.value);
            try out.writeAll("-->");
        },
        .processing_instruction => {
            try out.writeAll("<?");
            try out.writeAll(node_value.name);
            if (node_value.value.len != 0) {
                try out.writeByte(' ');
                try out.writeAll(node_value.value);
            }
            try out.writeAll("?>");
        },
    }
}

fn writeHtmlElement(
    out: *std.Io.Writer,
    document: *const dom.Document,
    id: dom.NodeId,
) std.Io.Writer.Error!void {
    const node_value = document.node(id);
    try out.writeByte('<');
    try out.writeAll(node_value.name);
    for (document.attributesOf(id)) |attr| {
        try out.writeByte(' ');
        try out.writeAll(attr.name);
        if (attr.ns.len == 0 and isHtmlBooleanAttribute(attr.name)) {
            continue;
        }
        try out.writeAll("=\"");
        try writeHtmlAttribute(out, attr.value);
        try out.writeByte('"');
    }
    try out.writeByte('>');
    if (node_value.ns.len == 0 and isHtmlVoidElement(node_value.local)) {
        return;
    }
    const raw_text = node_value.ns.len == 0 and
        (std.ascii.eqlIgnoreCase(node_value.local, "script") or
            std.ascii.eqlIgnoreCase(node_value.local, "style"));
    var child = node_value.first_child;
    while (child != dom.null_node) : (child = document.node(child).next_sibling) {
        try writeHtmlNode(out, document, child, raw_text);
    }
    try out.writeAll("</");
    try out.writeAll(node_value.name);
    try out.writeByte('>');
}

fn writeHtmlText(
    out: *std.Io.Writer,
    text: []const u8,
) std.Io.Writer.Error!void {
    for (text) |byte| {
        switch (byte) {
            '&' => try out.writeAll("&amp;"),
            '<' => try out.writeAll("&lt;"),
            '>' => try out.writeAll("&gt;"),
            else => try out.writeByte(byte),
        }
    }
}

fn writeHtmlAttribute(
    out: *std.Io.Writer,
    value: []const u8,
) std.Io.Writer.Error!void {
    for (value) |byte| {
        switch (byte) {
            '&' => try out.writeAll("&amp;"),
            '<' => try out.writeAll("&lt;"),
            '>' => try out.writeAll("&gt;"),
            '"' => try out.writeAll("&quot;"),
            else => try out.writeByte(byte),
        }
    }
}

fn isHtmlVoidElement(local: []const u8) bool {
    const void_elements = [_][]const u8{
        "area", "base",  "basefont", "br",   "col",  "frame", "hr",
        "img",  "input", "isindex",  "link", "meta", "param",
    };
    for (void_elements) |candidate| {
        if (std.ascii.eqlIgnoreCase(local, candidate)) return true;
    }
    return false;
}

fn isHtmlBooleanAttribute(name: []const u8) bool {
    const boolean_attributes = [_][]const u8{
        "checked", "compact",  "declare",  "defer",    "disabled",
        "ismap",   "multiple", "nohref",   "noresize", "noshade",
        "nowrap",  "readonly", "selected",
    };
    for (boolean_attributes) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
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
