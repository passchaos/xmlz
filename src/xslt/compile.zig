//! XSLT 1.0 stylesheet compilation.
//!
//! The stylesheet DOM is compiled into instruction trees, XPath expressions,
//! attribute value templates, and match selectors. Match patterns are
//! translated into XPath selectors evaluated once against the source document,
//! which reuses the full XPath engine for predicates and `//` semantics.

const std = @import("std");
const dom = @import("../dom.zig");
const namespace = @import("../namespace.zig");
const ast = @import("../xpath/ast.zig");
const xpath_parser = @import("../xpath/parser.zig");

pub const xsl_namespace = "http://www.w3.org/1999/XSL/Transform";

pub const Error = error{
    OutOfMemory,
    InvalidStylesheet,
    InvalidExpression,
};

pub const CompiledExpr = struct {
    node: *ast.Expr,
    namespaces: []const namespace.Binding,
};

pub const AvtPart = union(enum) {
    literal: []const u8,
    expr: CompiledExpr,
};

pub const Avt = []const AvtPart;

pub const KeyDef = struct {
    name: []const u8,
    selector: *ast.Expr,
    namespaces: []const namespace.Binding,
    use: CompiledExpr,
};

pub const SortKey = struct {
    select: ?CompiledExpr = null,
    data_type: enum { text, number } = .text,
    descending: bool = false,
};

pub const VariableValue = union(enum) {
    select: CompiledExpr,
    body: []const Instruction,
};

pub const Variable = struct {
    name: []const u8,
    value: VariableValue,
    /// True for `xsl:param` declarations, which callers may override.
    param: bool = false,
};

pub const Template = struct {
    /// Original match pattern, used to compute the default priority.
    match: ?*ast.Expr = null,
    /// XPath selector equivalent to the match pattern.
    selector: ?*ast.Expr = null,
    namespaces: []const namespace.Binding = &.{},
    name: ?[]const u8 = null,
    mode: ?[]const u8 = null,
    priority: f64 = 0,
    explicit_priority: bool = false,
    params: []const Variable = &.{},
    body: []const Instruction = &.{},
    order: usize = 0,
};

pub const OutputMethod = enum { xml, html, text };

pub const Output = struct {
    method: OutputMethod = .xml,
    omit_xml_declaration: bool = false,
    indent: bool = false,
    version: ?[]const u8 = null,
    encoding: []const u8 = "UTF-8",
};

pub const Stylesheet = struct {
    arena: std.heap.ArenaAllocator,
    templates: []const Template = &.{},
    globals: []const Variable = &.{},
    keys: []const KeyDef = &.{},
    output: Output = .{},

    pub fn deinit(self: *Stylesheet) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const NamespaceDecl = struct {
    prefix: []const u8,
    uri: []const u8,
};

pub const LiteralAttribute = struct {
    name: []const u8,
    prefix: []const u8,
    local: []const u8,
    ns: []const u8,
    value: Avt,
};

pub const LiteralElement = struct {
    prefix: []const u8,
    local: []const u8,
    ns: []const u8,
    namespaces: []const NamespaceDecl,
    attributes: []const LiteralAttribute,
    body: []const Instruction,
};

pub const ValueOf = struct {
    select: CompiledExpr,
    disable_output_escaping: bool = false,
};

pub const ParamBinding = struct {
    name: []const u8,
    value: VariableValue,
};

pub const ApplyTemplates = struct {
    select: ?CompiledExpr = null,
    mode: ?[]const u8 = null,
    params: []const ParamBinding = &.{},
    sorts: []const SortKey = &.{},
};

pub const CallTemplate = struct {
    name: []const u8,
    params: []const ParamBinding = &.{},
};

pub const ForEach = struct {
    select: CompiledExpr,
    sorts: []const SortKey = &.{},
    body: []const Instruction,
};

pub const If = struct {
    test_expr: CompiledExpr,
    body: []const Instruction,
};

pub const When = struct {
    test_expr: CompiledExpr,
    body: []const Instruction,
};

pub const Choose = struct {
    whens: []const When,
    otherwise: ?[]const Instruction = null,
};

pub const CopyOf = struct {
    select: CompiledExpr,
};

pub const Copy = struct {
    body: []const Instruction,
};

pub const ElementInstruction = struct {
    name: Avt,
    namespace_uri: ?Avt = null,
    namespaces: []const namespace.Binding = &.{},
    body: []const Instruction,
};

pub const AttributeInstruction = struct {
    name: Avt,
    namespace_uri: ?Avt = null,
    namespaces: []const namespace.Binding = &.{},
    body: []const Instruction,
};

pub const CommentInstruction = struct {
    body: []const Instruction,
};

pub const ProcessingInstruction = struct {
    name: Avt,
    body: []const Instruction,
};

pub const NumberInstruction = struct {
    value: ?CompiledExpr = null,
    format: ?Avt = null,
    level: enum { single, multiple, any } = .single,
    count: ?CompiledExpr = null,
    from: ?CompiledExpr = null,
};

pub const MessageInstruction = struct {
    body: []const Instruction,
    terminate: bool = false,
};

pub const Instruction = union(enum) {
    literal_element: LiteralElement,
    literal_text: []const u8,
    value_of: ValueOf,
    apply_templates: ApplyTemplates,
    call_template: CallTemplate,
    for_each: ForEach,
    if_: If,
    choose: Choose,
    copy_of: CopyOf,
    copy: Copy,
    text: []const u8,
    element: ElementInstruction,
    attribute: AttributeInstruction,
    variable: Variable,
    comment: CommentInstruction,
    processing_instruction: ProcessingInstruction,
    number: NumberInstruction,
    message: MessageInstruction,
    apply_imports,
};

/// Compile a stylesheet document. The returned `Stylesheet` owns its arena.
pub fn compile(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
) Error!Stylesheet {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var compiler: Compiler = .{
        .arena = arena.allocator(),
        .document = document,
    };
    try compiler.run();
    return .{
        .arena = arena,
        .templates = try compiler.templates.toOwnedSlice(compiler.arena),
        .globals = try compiler.globals.toOwnedSlice(compiler.arena),
        .keys = try compiler.keys.toOwnedSlice(compiler.arena),
        .output = compiler.output,
    };
}

const Compiler = struct {
    arena: std.mem.Allocator,
    document: *const dom.Document,
    templates: std.ArrayList(Template) = .empty,
    globals: std.ArrayList(Variable) = .empty,
    keys: std.ArrayList(KeyDef) = .empty,
    output: Output = .{},
    order: usize = 0,

    fn run(self: *Compiler) Error!void {
        const root = self.document.root();
        if (root == dom.null_node) return error.InvalidStylesheet;
        const root_node = self.document.node(root);
        if (isXsl(root_node, "stylesheet") or isXsl(root_node, "transform")) {
            try self.compileTopLevel(root);
        } else {
            try self.compileSimplified(root);
        }
    }

    fn compileTopLevel(self: *Compiler, root: dom.NodeId) Error!void {
        var child = self.document.node(root).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const child_node = self.document.node(child);
            if (child_node.kind != .element) continue;
            if (!isXsl(child_node, null)) continue;
            const local = child_node.local;
            if (std.mem.eql(u8, local, "template")) {
                try self.compileTemplate(child);
            } else if (std.mem.eql(u8, local, "output")) {
                try self.compileOutput(child);
            } else if (std.mem.eql(u8, local, "variable")) {
                try self.globals.append(self.arena, try self.compileVariable(child, false));
            } else if (std.mem.eql(u8, local, "param")) {
                try self.globals.append(self.arena, try self.compileVariable(child, true));
            } else if (std.mem.eql(u8, local, "key")) {
                try self.compileKey(child);
            } else if (std.mem.eql(u8, local, "strip-space") or
                std.mem.eql(u8, local, "preserve-space"))
            {
                // Whitespace stripping is not applied to the source tree yet.
            } else if (std.mem.eql(u8, local, "include") or
                std.mem.eql(u8, local, "import") or
                std.mem.eql(u8, local, "attribute-set") or
                std.mem.eql(u8, local, "key") or
                std.mem.eql(u8, local, "decimal-format") or
                std.mem.eql(u8, local, "namespace-alias"))
            {
                return error.InvalidStylesheet;
            }
        }
    }

    fn compileSimplified(self: *Compiler, root: dom.NodeId) Error!void {
        const preserve = preserveSpace(root, self.document, false);
        const literal = try self.compileLiteralElement(root, preserve);
        const instructions = try self.arena.alloc(Instruction, 1);
        instructions[0] = .{ .literal_element = literal };
        const match = (try self.parseExpression(root, "/")).node;
        const selector = try self.patternSelector(match);
        try self.templates.append(self.arena, .{
            .match = match,
            .selector = selector,
            .namespaces = try self.namespacesOf(root),
            .body = instructions,
            .priority = 0.5,
            .order = self.nextOrder(),
        });
    }

    fn compileTemplate(self: *Compiler, id: dom.NodeId) Error!void {
        const node = self.document.node(id);
        const match_text = self.document.attribute(id, "match");
        const name = self.document.attribute(id, "name");
        if (match_text == null and name == null) return error.InvalidStylesheet;

        var template: Template = .{
            .name = name,
            .mode = self.document.attribute(id, "mode"),
            .order = self.nextOrder(),
        };
        template.namespaces = try self.namespacesOf(id);
        if (match_text) |text| {
            template.match = (try self.parseExpression(id, text)).node;
            template.selector = try self.patternSelector(template.match.?);
            if (self.document.attribute(id, "priority")) |priority| {
                template.priority = std.fmt.parseFloat(f64, priority) catch
                    return error.InvalidStylesheet;
                template.explicit_priority = true;
            } else {
                template.priority = defaultPriority(template.match.?);
            }
        }

        var params: std.ArrayList(Variable) = .empty;
        var body: std.ArrayList(Instruction) = .empty;
        const preserve = preserveSpace(id, self.document, false);
        var seen_non_param = false;
        var child = node.first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const child_node = self.document.node(child);
            if (child_node.kind == .text) {
                if (!preserve and isWhitespaceOnly(child_node.value)) continue;
                if (child_node.value.len == 0) continue;
                try body.append(self.arena, .{ .literal_text = child_node.value });
                continue;
            }
            if (child_node.kind != .element) continue;
            if (isXsl(child_node, "param")) {
                if (seen_non_param) return error.InvalidStylesheet;
                try params.append(self.arena, try self.compileVariable(child, true));
                continue;
            }
            seen_non_param = true;
            const child_preserve = preserveSpace(
                child,
                self.document,
                preserve,
            );
            try self.compileInstruction(child, child_preserve, &body);
        }
        template.params = try params.toOwnedSlice(self.arena);
        template.body = try body.toOwnedSlice(self.arena);
        try self.templates.append(self.arena, template);
    }

    fn compileKey(self: *Compiler, id: dom.NodeId) Error!void {
        const name = self.document.attribute(id, "name") orelse
            return error.InvalidStylesheet;
        const match_text = self.document.attribute(id, "match") orelse
            return error.InvalidStylesheet;
        const use_text = self.document.attribute(id, "use") orelse
            return error.InvalidStylesheet;
        const match = (try self.parseExpression(id, match_text)).node;
        try self.keys.append(self.arena, .{
            .name = name,
            .selector = try self.patternSelector(match),
            .namespaces = try self.namespacesOf(id),
            .use = try self.parseExpression(id, use_text),
        });
    }

    fn compileOutput(self: *Compiler, id: dom.NodeId) Error!void {
        if (self.document.attribute(id, "method")) |method| {
            if (std.mem.eql(u8, method, "xml")) {
                self.output.method = .xml;
            } else if (std.mem.eql(u8, method, "html")) {
                self.output.method = .html;
            } else if (std.mem.eql(u8, method, "text")) {
                self.output.method = .text;
            } else {
                return error.InvalidStylesheet;
            }
        }
        if (self.document.attribute(id, "omit-xml-declaration")) |value| {
            self.output.omit_xml_declaration = isYes(value);
        }
        if (self.document.attribute(id, "indent")) |value| {
            self.output.indent = isYes(value);
        }
        if (self.document.attribute(id, "version")) |value| {
            self.output.version = value;
        }
        if (self.document.attribute(id, "encoding")) |value| {
            self.output.encoding = value;
        }
    }

    fn compileBody(
        self: *Compiler,
        id: dom.NodeId,
        preserve: bool,
    ) Error![]const Instruction {
        var body: std.ArrayList(Instruction) = .empty;
        var child = self.document.node(id).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const child_node = self.document.node(child);
            switch (child_node.kind) {
                .element => {
                    if (isXsl(child_node, "sort") or
                        isXsl(child_node, "with-param"))
                    {
                        continue;
                    }
                    const child_preserve = preserveSpace(
                        child,
                        self.document,
                        preserve,
                    );
                    try self.compileInstruction(child, child_preserve, &body);
                },
                .text => {
                    if (!preserve and isWhitespaceOnly(child_node.value)) continue;
                    if (child_node.value.len == 0) continue;
                    try body.append(self.arena, .{ .literal_text = child_node.value });
                },
                .comment, .processing_instruction => {},
                .document => unreachable,
            }
        }
        return body.toOwnedSlice(self.arena);
    }

    fn compileInstruction(
        self: *Compiler,
        id: dom.NodeId,
        preserve: bool,
        body: *std.ArrayList(Instruction),
    ) Error!void {
        const node = self.document.node(id);
        if (node.ns.len == 0 or !std.mem.eql(u8, node.ns, xsl_namespace)) {
            try body.append(self.arena, .{
                .literal_element = try self.compileLiteralElement(id, preserve),
            });
            return;
        }

        const local = node.local;
        if (std.mem.eql(u8, local, "value-of")) {
            const select = self.document.attribute(id, "select") orelse
                return error.InvalidStylesheet;
            try body.append(self.arena, .{ .value_of = .{
                .select = try self.parseExpression(id, select),
                .disable_output_escaping = isYes(
                    self.document.attribute(id, "disable-output-escaping") orelse "no",
                ),
            } });
        } else if (std.mem.eql(u8, local, "text")) {
            var out: std.ArrayList(u8) = .empty;
            var child = node.first_child;
            while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
                const child_node = self.document.node(child);
                if (child_node.kind == .text) {
                    try out.appendSlice(self.arena, child_node.value);
                }
            }
            try body.append(self.arena, .{ .text = try out.toOwnedSlice(self.arena) });
        } else if (std.mem.eql(u8, local, "apply-templates")) {
            try body.append(self.arena, .{ .apply_templates = try self.compileApplyTemplates(id) });
        } else if (std.mem.eql(u8, local, "call-template")) {
            const name = self.document.attribute(id, "name") orelse
                return error.InvalidStylesheet;
            try body.append(self.arena, .{ .call_template = .{
                .name = name,
                .params = try self.compileWithParams(id),
            } });
        } else if (std.mem.eql(u8, local, "for-each")) {
            const select = self.document.attribute(id, "select") orelse
                return error.InvalidStylesheet;
            var instruction: ForEach = .{
                .select = try self.parseExpression(id, select),
                .body = &.{},
            };
            instruction.sorts = try self.compileSorts(id);
            instruction.body = try self.compileBody(id, preserve);
            try body.append(self.arena, .{ .for_each = instruction });
        } else if (std.mem.eql(u8, local, "if")) {
            const test_value = self.document.attribute(id, "test") orelse
                return error.InvalidStylesheet;
            try body.append(self.arena, .{ .if_ = .{
                .test_expr = try self.parseExpression(id, test_value),
                .body = try self.compileBody(id, preserve),
            } });
        } else if (std.mem.eql(u8, local, "choose")) {
            try body.append(self.arena, .{ .choose = try self.compileChoose(id, preserve) });
        } else if (std.mem.eql(u8, local, "copy-of")) {
            const select = self.document.attribute(id, "select") orelse
                return error.InvalidStylesheet;
            try body.append(self.arena, .{ .copy_of = .{
                .select = try self.parseExpression(id, select),
            } });
        } else if (std.mem.eql(u8, local, "copy")) {
            try body.append(self.arena, .{ .copy = .{
                .body = try self.compileBody(id, preserve),
            } });
        } else if (std.mem.eql(u8, local, "element")) {
            const name = self.document.attribute(id, "name") orelse
                return error.InvalidStylesheet;
            var instruction: ElementInstruction = .{
                .name = try self.compileAvt(id, name),
                .namespaces = try self.namespacesOf(id),
                .body = try self.compileBody(id, preserve),
            };
            if (self.document.attribute(id, "namespace")) |uri| {
                instruction.namespace_uri = try self.compileAvt(id, uri);
            }
            try body.append(self.arena, .{ .element = instruction });
        } else if (std.mem.eql(u8, local, "attribute")) {
            const name = self.document.attribute(id, "name") orelse
                return error.InvalidStylesheet;
            var instruction: AttributeInstruction = .{
                .name = try self.compileAvt(id, name),
                .namespaces = try self.namespacesOf(id),
                .body = try self.compileBody(id, preserve),
            };
            if (self.document.attribute(id, "namespace")) |uri| {
                instruction.namespace_uri = try self.compileAvt(id, uri);
            }
            try body.append(self.arena, .{ .attribute = instruction });
        } else if (std.mem.eql(u8, local, "variable")) {
            try body.append(self.arena, .{
                .variable = try self.compileVariable(id, false),
            });
        } else if (std.mem.eql(u8, local, "comment")) {
            try body.append(self.arena, .{ .comment = .{
                .body = try self.compileBody(id, preserve),
            } });
        } else if (std.mem.eql(u8, local, "processing-instruction")) {
            const name = self.document.attribute(id, "name") orelse
                return error.InvalidStylesheet;
            try body.append(self.arena, .{ .processing_instruction = .{
                .name = try self.compileAvt(id, name),
                .body = try self.compileBody(id, preserve),
            } });
        } else if (std.mem.eql(u8, local, "number")) {
            try body.append(self.arena, .{ .number = try self.compileNumber(id) });
        } else if (std.mem.eql(u8, local, "message")) {
            try body.append(self.arena, .{ .message = .{
                .body = try self.compileBody(id, preserve),
                .terminate = isYes(self.document.attribute(id, "terminate") orelse "no"),
            } });
        } else if (std.mem.eql(u8, local, "apply-imports")) {
            try body.append(self.arena, .apply_imports);
        } else if (std.mem.eql(u8, local, "fallback")) {
            // Ignored: extension instructions are unsupported.
        } else if (std.mem.eql(u8, local, "param") or
            std.mem.eql(u8, local, "sort") or
            std.mem.eql(u8, local, "with-param") or
            std.mem.eql(u8, local, "when") or
            std.mem.eql(u8, local, "otherwise"))
        {
            return error.InvalidStylesheet;
        } else {
            return error.InvalidStylesheet;
        }
    }

    fn compileApplyTemplates(self: *Compiler, id: dom.NodeId) Error!ApplyTemplates {
        var instruction: ApplyTemplates = .{};
        if (self.document.attribute(id, "select")) |select| {
            instruction.select = try self.parseExpression(id, select);
        }
        instruction.mode = self.document.attribute(id, "mode");
        instruction.params = try self.compileWithParams(id);
        instruction.sorts = try self.compileSorts(id);
        return instruction;
    }

    fn compileWithParams(self: *Compiler, id: dom.NodeId) Error![]const ParamBinding {
        var params: std.ArrayList(ParamBinding) = .empty;
        var child = self.document.node(id).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const child_node = self.document.node(child);
            if (child_node.kind != .element or !isXsl(child_node, "with-param")) continue;
            const name = self.document.attribute(child, "name") orelse
                return error.InvalidStylesheet;
            try params.append(self.arena, .{
                .name = name,
                .value = try self.compileValue(child, "select"),
            });
        }
        return params.toOwnedSlice(self.arena);
    }

    fn compileSorts(self: *Compiler, id: dom.NodeId) Error![]const SortKey {
        var sorts: std.ArrayList(SortKey) = .empty;
        var child = self.document.node(id).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const child_node = self.document.node(child);
            if (child_node.kind != .element or !isXsl(child_node, "sort")) continue;
            var sort: SortKey = .{};
            if (self.document.attribute(child, "select")) |select| {
                sort.select = try self.parseExpression(child, select);
            }
            if (self.document.attribute(child, "data-type")) |data_type| {
                if (std.mem.eql(u8, data_type, "number")) {
                    sort.data_type = .number;
                } else if (!std.mem.eql(u8, data_type, "text")) {
                    return error.InvalidStylesheet;
                }
            }
            if (self.document.attribute(child, "order")) |order| {
                sort.descending = std.mem.eql(u8, order, "descending");
            }
            try sorts.append(self.arena, sort);
        }
        return sorts.toOwnedSlice(self.arena);
    }

    fn compileChoose(
        self: *Compiler,
        id: dom.NodeId,
        preserve: bool,
    ) Error!Choose {
        var whens: std.ArrayList(When) = .empty;
        var otherwise: ?[]const Instruction = null;
        var child = self.document.node(id).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const child_node = self.document.node(child);
            if (child_node.kind != .element) continue;
            if (isXsl(child_node, "when")) {
                if (otherwise != null) return error.InvalidStylesheet;
                const test_value = self.document.attribute(child, "test") orelse
                    return error.InvalidStylesheet;
                try whens.append(self.arena, .{
                    .test_expr = try self.parseExpression(child, test_value),
                    .body = try self.compileBody(child, preserve),
                });
            } else if (isXsl(child_node, "otherwise")) {
                if (otherwise != null) return error.InvalidStylesheet;
                otherwise = try self.compileBody(child, preserve);
            }
        }
        return .{
            .whens = try whens.toOwnedSlice(self.arena),
            .otherwise = otherwise,
        };
    }

    fn compileNumber(self: *Compiler, id: dom.NodeId) Error!NumberInstruction {
        var instruction: NumberInstruction = .{};
        if (self.document.attribute(id, "value")) |value| {
            instruction.value = try self.parseExpression(id, value);
        }
        if (self.document.attribute(id, "format")) |format| {
            instruction.format = try self.compileAvt(id, format);
        }
        if (self.document.attribute(id, "level")) |level| {
            if (std.mem.eql(u8, level, "single")) {
                instruction.level = .single;
            } else if (std.mem.eql(u8, level, "multiple")) {
                instruction.level = .multiple;
            } else if (std.mem.eql(u8, level, "any")) {
                instruction.level = .any;
            } else {
                return error.InvalidStylesheet;
            }
        }
        if (self.document.attribute(id, "count")) |count| {
            instruction.count = try self.parseExpression(id, count);
        }
        if (self.document.attribute(id, "from")) |from| {
            instruction.from = try self.parseExpression(id, from);
        }
        return instruction;
    }

    fn compileVariable(self: *Compiler, id: dom.NodeId, param: bool) Error!Variable {
        const name = self.document.attribute(id, "name") orelse
            return error.InvalidStylesheet;
        return .{
            .name = name,
            .value = try self.compileValue(id, "select"),
            .param = param,
        };
    }

    fn compileValue(self: *Compiler, id: dom.NodeId, select_attribute: []const u8) Error!VariableValue {
        if (self.document.attribute(id, select_attribute)) |select| {
            return .{ .select = try self.parseExpression(id, select) };
        }
        return .{ .body = try self.compileBody(id, false) };
    }

    fn compileLiteralElement(
        self: *Compiler,
        id: dom.NodeId,
        preserve: bool,
    ) Error!LiteralElement {
        const node = self.document.node(id);
        var element: LiteralElement = .{
            .prefix = prefixOf(node),
            .local = node.local,
            .ns = node.ns,
            .namespaces = &.{},
            .attributes = &.{},
            .body = &.{},
        };

        const excluded = try self.excludedPrefixes(id);
        var namespaces: std.ArrayList(NamespaceDecl) = .empty;
        const in_scope = try self.document.inScopeNamespaces(self.arena, id);
        for (in_scope) |binding| {
            if (std.mem.eql(u8, binding.prefix, "xml")) continue;
            if (std.mem.eql(u8, binding.uri, xsl_namespace)) continue;
            if (isPrefixExcluded(excluded, binding.prefix)) continue;
            try namespaces.append(self.arena, .{
                .prefix = binding.prefix,
                .uri = binding.uri,
            });
        }
        // Prefixes used by the element name or its attributes must stay
        // declared even when excluded, or the result is not namespace
        // well-formed.
        if (element.prefix.len != 0) {
            try appendScopeNamespace(&namespaces, in_scope, element.prefix, self.arena);
        } else if (element.ns.len != 0) {
            try appendScopeNamespace(&namespaces, in_scope, "", self.arena);
        }
        for (self.document.attributesOf(id)) |attr| {
            if (namespace.Resolver.isNamespaceDeclaration(attr.name)) continue;
            if (attr.ns.len != 0 and std.mem.eql(u8, attr.ns, xsl_namespace)) {
                continue;
            }
            const attr_prefix = attr.prefixName();
            if (attr_prefix.len == 0 or
                std.mem.eql(u8, attr_prefix, "xml"))
            {
                continue;
            }
            try appendScopeNamespace(&namespaces, in_scope, attr_prefix, self.arena);
        }
        element.namespaces = try namespaces.toOwnedSlice(self.arena);

        var attributes: std.ArrayList(LiteralAttribute) = .empty;
        for (self.document.attributesOf(id)) |attr| {
            if (namespace.Resolver.isNamespaceDeclaration(attr.name)) continue;
            if (attr.ns.len != 0 and std.mem.eql(u8, attr.ns, xsl_namespace)) continue;
            try attributes.append(self.arena, .{
                .name = attr.name,
                .prefix = attr.prefixName(),
                .local = attr.localName(),
                .ns = attr.ns,
                .value = try self.compileAvt(id, attr.value),
            });
        }
        element.attributes = try attributes.toOwnedSlice(self.arena);
        element.body = try self.compileBody(id, preserve);
        return element;
    }

    fn excludedPrefixes(self: *Compiler, id: dom.NodeId) Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var current = id;
        while (true) {
            for (self.document.attributesOf(current)) |attr| {
                if (attr.ns.len == 0 or
                    !std.mem.eql(u8, attr.ns, xsl_namespace))
                {
                    continue;
                }
                if (!std.mem.eql(u8, attr.localName(), "exclude-result-prefixes") and
                    !std.mem.eql(u8, attr.localName(), "extension-element-prefixes"))
                {
                    continue;
                }
                var tokens = std.mem.tokenizeAny(u8, attr.value, " \t\r\n");
                while (tokens.next()) |token| {
                    if (std.mem.eql(u8, token, "#default")) {
                        try out.append(self.arena, "");
                    } else {
                        try out.append(self.arena, token);
                    }
                }
            }
            const parent = self.document.node(current).parent;
            if (parent == dom.null_node) break;
            if (self.document.node(parent).kind != .element) break;
            current = parent;
        }
        return out.toOwnedSlice(self.arena);
    }

    fn compileAvt(self: *Compiler, id: dom.NodeId, text: []const u8) Error!Avt {
        var parts: std.ArrayList(AvtPart) = .empty;
        var literal: std.ArrayList(u8) = .empty;
        var index: usize = 0;
        while (index < text.len) {
            const byte = text[index];
            if (byte == '{') {
                if (index + 1 < text.len and text[index + 1] == '{') {
                    try literal.append(self.arena, '{');
                    index += 2;
                    continue;
                }
                if (literal.items.len != 0) {
                    try parts.append(self.arena, .{
                        .literal = try literal.toOwnedSlice(self.arena),
                    });
                    literal = .empty;
                }
                const end = findAvtEnd(text, index + 1) orelse
                    return error.InvalidStylesheet;
                const expression = try self.parseExpression(id, text[index + 1 .. end]);
                try parts.append(self.arena, .{ .expr = expression });
                index = end + 1;
            } else if (byte == '}') {
                if (index + 1 < text.len and text[index + 1] == '}') {
                    try literal.append(self.arena, '}');
                    index += 2;
                } else {
                    return error.InvalidStylesheet;
                }
            } else {
                try literal.append(self.arena, byte);
                index += 1;
            }
        }
        if (literal.items.len != 0) {
            try parts.append(self.arena, .{
                .literal = try literal.toOwnedSlice(self.arena),
            });
        }
        return parts.toOwnedSlice(self.arena);
    }

    fn parseExpression(self: *Compiler, id: dom.NodeId, text: []const u8) Error!CompiledExpr {
        var parser = xpath_parser.Parser.init(self.arena, text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidExpression,
        };
        const root = parser.parse() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidExpression,
        };
        return .{
            .node = root,
            .namespaces = try self.namespacesOf(id),
        };
    }

    fn namespacesOf(self: *Compiler, id: dom.NodeId) Error![]const namespace.Binding {
        return self.document.inScopeNamespaces(self.arena, id) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    /// Translate an XSLT match pattern into an XPath selector. Relative
    /// patterns are prefixed with `//`; union branches are translated
    /// independently.
    fn patternSelector(self: *Compiler, expression: *ast.Expr) Error!*ast.Expr {
        return switch (expression.*) {
            .binary => |binary| blk: {
                if (binary.op != .union_) return error.InvalidStylesheet;
                const lhs = try self.patternSelector(binary.lhs);
                const rhs = try self.patternSelector(binary.rhs);
                const out = try self.arena.create(ast.Expr);
                out.* = .{ .binary = .{
                    .op = .union_,
                    .lhs = lhs,
                    .rhs = rhs,
                } };
                break :blk out;
            },
            .path => |path| blk: {
                if (path.start != null) return error.InvalidStylesheet;
                if (path.absolute) break :blk expression;
                var steps: std.ArrayList(ast.Step) = .empty;
                try steps.append(self.arena, .{
                    .axis = .descendant_or_self,
                    .node_test = .node,
                    .predicates = &.{},
                });
                try steps.appendSlice(self.arena, path.steps);
                const out = try self.arena.create(ast.Expr);
                out.* = .{ .path = .{
                    .absolute = true,
                    .start = null,
                    .steps = try steps.toOwnedSlice(self.arena),
                } };
                break :blk out;
            },
            .function_call => |call| blk: {
                if (std.mem.eql(u8, call.name, "id") or
                    std.mem.eql(u8, call.name, "key"))
                {
                    break :blk expression;
                }
                return error.InvalidStylesheet;
            },
            else => error.InvalidStylesheet,
        };
    }

    fn nextOrder(self: *Compiler) usize {
        const order = self.order;
        self.order += 1;
        return order;
    }
};

fn isXsl(node: *const dom.Node, local: ?[]const u8) bool {
    if (!std.mem.eql(u8, node.ns, xsl_namespace)) return false;
    if (local) |expected| return std.mem.eql(u8, node.local, expected);
    return true;
}

fn prefixOf(node: *const dom.Node) []const u8 {
    if (node.local.len >= node.name.len) return "";
    return node.name[0 .. node.name.len - node.local.len - 1];
}

fn preserveSpace(
    id: dom.NodeId,
    document: *const dom.Document,
    inherited: bool,
) bool {
    const value = document.attributeNs(id, namespace.xml_uri, "space") orelse
        return inherited;
    if (std.mem.eql(u8, value, "preserve")) return true;
    if (std.mem.eql(u8, value, "default")) return false;
    return inherited;
}

fn isWhitespaceOnly(value: []const u8) bool {
    for (value) |byte| {
        if (byte != ' ' and byte != '\t' and byte != '\r' and byte != '\n') {
            return false;
        }
    }
    return true;
}

fn isYes(value: []const u8) bool {
    return std.mem.eql(u8, value, "yes") or std.mem.eql(u8, value, "true") or
        std.mem.eql(u8, value, "1");
}

fn isPrefixExcluded(excluded: []const []const u8, prefix: []const u8) bool {
    for (excluded) |candidate| {
        if (std.mem.eql(u8, candidate, prefix)) return true;
    }
    return false;
}

fn appendScopeNamespace(
    namespaces: *std.ArrayList(NamespaceDecl),
    in_scope: []const namespace.Binding,
    prefix: []const u8,
    allocator: std.mem.Allocator,
) Error!void {
    for (namespaces.items) |decl| {
        if (std.mem.eql(u8, decl.prefix, prefix)) return;
    }
    for (in_scope) |binding| {
        if (std.mem.eql(u8, binding.prefix, prefix)) {
            try namespaces.append(allocator, .{
                .prefix = prefix,
                .uri = binding.uri,
            });
            return;
        }
    }
}

fn findAvtEnd(text: []const u8, start: usize) ?usize {
    var index = start;
    var quote: u8 = 0;
    while (index < text.len) : (index += 1) {
        const byte = text[index];
        if (quote != 0) {
            if (byte == quote) quote = 0;
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
            continue;
        }
        if (byte == '}') return index;
    }
    return null;
}

/// Default priority from XSLT 1.0 section 5.5.
fn defaultPriority(expression: *const ast.Expr) f64 {
    return switch (expression.*) {
        .binary => |binary| if (binary.op == .union_)
            @max(defaultPriority(binary.lhs), defaultPriority(binary.rhs))
        else
            0.5,
        .path => |path| blk: {
            if (path.absolute or path.start != null) break :blk 0.5;
            if (path.steps.len != 1) break :blk 0.5;
            const step = path.steps[0];
            if (step.predicates.len != 0) break :blk 0.5;
            if (step.axis != .child and step.axis != .attribute) break :blk 0.5;
            break :blk switch (step.node_test) {
                .name => |name_test| if (name_test.local == null)
                    if (name_test.prefix == null) -0.5 else -0.25
                else
                    0,
                .processing_instruction => |target| if (target == null) -0.5 else 0,
                .node, .text, .comment => -0.5,
            };
        },
        else => 0.5,
    };
}
