//! XSLT 1.0 stylesheet compilation.
//!
//! The stylesheet DOM is compiled into instruction trees, XPath expressions,
//! attribute value templates, and match selectors. Match patterns are
//! translated into XPath selectors evaluated once against the source document,
//! which reuses the full XPath engine for predicates and `//` semantics.

const std = @import("std");
const dom = @import("../dom.zig");
const encoding = @import("../encoding.zig");
const namespace = @import("../namespace.zig");
const ast = @import("../xpath/ast.zig");
const xpath_parser = @import("../xpath/parser.zig");
const xpath_variable = @import("../xpath/value.zig");
const writer_mod = @import("../writer.zig");

pub const xsl_namespace = namespace.xsl_uri;
pub const exslt_functions_namespace = "http://exslt.org/functions";
/// Namespace of libxslt's built-in extension module (xsltproc registers the
/// `test` element and function in it).
pub const libxslt_namespace = "http://xmlsoft.org/XSLT/";

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

pub const NameRef = struct {
    uri: []const u8,
    local: []const u8,
};

pub const AttributeSet = struct {
    /// Local name; the namespace is in `name_uri`.
    name: []const u8,
    name_uri: []const u8 = "",
    uses: []const NameRef,
    raw_instructions: []const Instruction,
    expanded: ?[]const Instruction = null,
    visiting: bool = false,
    /// Import precedence; lower values are applied first so higher-precedence
    /// declarations override attributes of the same name.
    precedence: usize = 0,
};

pub const SpaceRule = struct {
    strip: bool,
    any: bool = false,
    namespace_uri: ?[]const u8 = null,
    local: ?[]const u8 = null,

    pub fn matches(
        self: SpaceRule,
        namespace_uri: []const u8,
        local: []const u8,
    ) bool {
        if (self.any) return true;
        if (self.namespace_uri) |expected| {
            if (!std.mem.eql(u8, expected, namespace_uri)) return false;
        }
        if (self.local) |expected| {
            if (!std.mem.eql(u8, expected, local)) return false;
        }
        return true;
    }
};

pub const DecimalFormat = struct {
    name: ?[]const u8 = null,
    name_uri: []const u8 = "",
    decimal_separator: u21 = '.',
    grouping_separator: u21 = ',',
    infinity: []const u8 = "Infinity",
    minus_sign: u21 = '-',
    nan: []const u8 = "NaN",
    percent: u21 = '%',
    per_mille: u21 = 0x2030,
    zero_digit: u21 = '0',
    digit: u21 = '#',
    pattern_separator: u21 = ';',
};

pub const NamespaceAlias = struct {
    stylesheet_uri: []const u8,
    result_uri: []const u8,
    result_prefix: []const u8,
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
    /// Import precedence for top-level bindings.
    precedence: usize = 0,
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
    precedence: usize = 0,
    order: usize = 0,
};

pub const OutputMethod = enum { xml, html, text };

pub const Output = struct {
    method: OutputMethod = .xml,
    /// True when `method` came from an explicit `xsl:output` attribute.
    method_specified: bool = false,
    omit_xml_declaration: bool = false,
    indent: bool = false,
    /// True when `indent` came from an explicit `xsl:output` attribute.
    indent_specified: bool = false,
    version: ?[]const u8 = null,
    /// `standalone` pseudo-attribute in the XML declaration.
    standalone: ?bool = null,
    /// Explicit `encoding` attribute; empty means the default UTF-8 output
    /// without an encoding pseudo-attribute in the XML declaration.
    encoding: []const u8 = "",
    doctype_public: ?[]const u8 = null,
    doctype_system: ?[]const u8 = null,
    cdata_elements: []const writer_mod.ExpandedName = &.{},
};

pub const Stylesheet = struct {
    arena: std.heap.ArenaAllocator,
    /// Document containing the principal stylesheet element.
    principal: *const dom.Document,
    templates: []const Template = &.{},
    globals: []const Variable = &.{},
    keys: []const KeyDef = &.{},
    functions: []const FunctionDef = &.{},
    attribute_sets: []const AttributeSet = &.{},
    space_rules: []const SpaceRule = &.{},
    /// True when any compiled expression calls `last()`, which is the only
    /// consumer of the context node-set size.
    uses_last: bool = false,
    decimal_formats: []const DecimalFormat = &.{},
    aliases: []const NamespaceAlias = &.{},
    output: Output = .{},
    documents: []const *dom.Document = &.{},

    pub fn deinit(self: *Stylesheet) void {
        for (self.documents) |document| document.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Resource = struct {
    /// Resolved URI used as the base for nested references.
    uri: []const u8 = "",
    data: []const u8,
};

pub const Resolver = struct {
    context: ?*anyopaque = null,
    load: *const fn (
        context: ?*anyopaque,
        href: []const u8,
        base: []const u8,
    ) ?Resource,
};

pub const Options = struct {
    /// Values supplied for top-level `xsl:param` declarations.
    parameters: []const xpath_variable.Variable = &.{},
    resolver: ?Resolver = null,
    /// Base URI of the principal stylesheet.
    base: []const u8 = "",
    /// Current date/time in xs:dateTime form for EXSLT date functions that
    /// default to "now". Callers without a clock leave this null.
    now: ?[]const u8 = null,
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
    attribute_sets: []const NameRef = &.{},
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
    /// True when `select` is the standard identity union (`@*|node()`), which
    /// the transformer can apply without materializing the node set.
    stream_identity: bool = false,
};

pub const CallTemplate = struct {
    name: []const u8,
    params: []const ParamBinding = &.{},
};

pub const ForEach = struct {
    select: CompiledExpr,
    sorts: []const SortKey = &.{},
    body: []const Instruction,
    /// Attributes one iteration of the body creates through literal result
    /// elements (counted recursively), so the runtime can size the result
    /// attribute array before the loop instead of growing it repeatedly.
    attributes_per_iteration: u16 = 0,
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

/// Shape of a copy body that the runtime can dispatch without re-testing the
/// compiled instruction's fields per copied node.
pub const CopyBody = enum {
    /// Ordinary instruction sequence.
    instructions,
    /// A single `xsl:apply-templates` with no select, sorts, or parameters.
    plain_apply,
    /// A single `xsl:apply-templates` whose select is the `@*|node()`
    /// identity shape.
    identity_select,
    /// Any other single `xsl:apply-templates`.
    apply,
};

pub const Copy = struct {
    body: []const Instruction,
    body_kind: CopyBody = .instructions,
};

pub const ElementInstruction = struct {
    name: Avt,
    namespace_uri: ?Avt = null,
    namespaces: []const namespace.Binding = &.{},
    attribute_sets: []const NameRef = &.{},
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
    grouping_separator: ?Avt = null,
    grouping_size: ?Avt = null,
};

pub const ApplyImports = struct {
    params: []const ParamBinding = &.{},
};

pub const MessageInstruction = struct {
    body: []const Instruction,
    terminate: bool = false,
};

pub const FunctionResult = struct {
    select: ?CompiledExpr = null,
    body: []const Instruction = &.{},
};

pub const FunctionDef = struct {
    name: []const u8,
    namespace_uri: []const u8,
    params: []const Variable = &.{},
    body: []const Instruction = &.{},
    precedence: usize = 0,
    order: usize = 0,
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
    raw_text: []const u8,
    element: ElementInstruction,
    attribute: AttributeInstruction,
    variable: Variable,
    comment: CommentInstruction,
    processing_instruction: ProcessingInstruction,
    number: NumberInstruction,
    message: MessageInstruction,
    apply_imports: ApplyImports,
    function_result: FunctionResult,
};

/// Compile a stylesheet document without external includes or imports.
pub fn compile(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
) Error!Stylesheet {
    return compileWithOptions(allocator, document, .{});
}

/// Compile a stylesheet document, resolving `xsl:include` and `xsl:import`
/// through the supplied resolver.
pub fn compileWithOptions(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
    options: Options,
) Error!Stylesheet {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var compiler: Compiler = .{
        .arena = arena.allocator(),
        .backing_allocator = allocator,
        .document = document,
        .options = options,
    };
    errdefer {
        for (compiler.included_documents.items) |included| {
            included.deinit();
        }
    }
    try compiler.run();
    try compiler.expandAttributeSets();
    return .{
        .arena = arena,
        .principal = document,
        .templates = try compiler.templates.toOwnedSlice(compiler.arena),
        .globals = try compiler.dedupeGlobals(),
        .keys = try compiler.keys.toOwnedSlice(compiler.arena),
        .functions = try compiler.functions.toOwnedSlice(compiler.arena),
        .attribute_sets = try compiler.attribute_sets.toOwnedSlice(
            compiler.arena,
        ),
        .space_rules = try compiler.space_rules.toOwnedSlice(compiler.arena),
        .uses_last = compiler.uses_last,
        .decimal_formats = try compiler.decimal_formats.toOwnedSlice(
            compiler.arena,
        ),
        .aliases = try compiler.aliases.toOwnedSlice(compiler.arena),
        .output = compiler.output,
        .documents = try compiler.included_documents.toOwnedSlice(
            compiler.arena,
        ),
    };
}

const Compiler = struct {
    arena: std.mem.Allocator,
    backing_allocator: std.mem.Allocator,
    document: *const dom.Document,
    options: Options = .{},
    templates: std.ArrayList(Template) = .empty,
    globals: std.ArrayList(Variable) = .empty,
    keys: std.ArrayList(KeyDef) = .empty,
    attribute_sets: std.ArrayList(AttributeSet) = .empty,
    functions: std.ArrayList(FunctionDef) = .empty,
    next_function_order: usize = 0,
    compiling_function: bool = false,
    space_rules: std.ArrayList(SpaceRule) = .empty,
    uses_last: bool = false,
    /// Canonical slices for variable names so runtime lookups can compare
    /// pointers before falling back to string equality.
    variable_names: std.StringHashMapUnmanaged([]const u8) = .empty,
    decimal_formats: std.ArrayList(DecimalFormat) = .empty,
    aliases: std.ArrayList(NamespaceAlias) = .empty,
    output: Output = .{},
    order: usize = 0,
    next_precedence: usize = 0,
    current_precedence: usize = 0,
    current_base: []const u8 = "",
    principal: bool = false,
    included_documents: std.ArrayList(*dom.Document) = .empty,
    include_stack: std.ArrayList([]const u8) = .empty,

    fn run(self: *Compiler) Error!void {
        try self.compileDocument(
            self.document,
            self.options.base,
            null,
            true,
        );
    }

    fn compileDocument(
        self: *Compiler,
        document: *const dom.Document,
        base: []const u8,
        fixed_precedence: ?usize,
        principal: bool,
    ) Error!void {
        const saved_document = self.document;
        const saved_base = self.current_base;
        const saved_precedence = self.current_precedence;
        const saved_principal = self.principal;
        defer {
            self.document = saved_document;
            self.current_base = saved_base;
            self.current_precedence = saved_precedence;
            self.principal = saved_principal;
        }
        self.document = document;
        self.current_base = base;
        self.principal = principal;

        const root = document.root();
        if (root == dom.null_node) return error.InvalidStylesheet;
        const root_node = document.node(root);
        const full_stylesheet =
            isXsl(self.document, root_node, "stylesheet") or isXsl(self.document, root_node, "transform");
        if (full_stylesheet) {
            if (document.attribute(root, "version")) |version| {
                if (!std.mem.eql(u8, version, "1.0") and
                    !std.mem.eql(u8, version, "1.1"))
                {
                    return error.InvalidStylesheet;
                }
            }
        }
        if (!full_stylesheet) {
            if (!principal) return error.InvalidStylesheet;
            const precedence = fixed_precedence orelse blk: {
                const value = self.next_precedence;
                self.next_precedence += 1;
                break :blk value;
            };
            self.current_precedence = precedence;
            try self.compileSimplified(root);
            return;
        }

        // A stylesheet may only contain whitespace text outside its
        // top-level elements.
        var check = document.node(root).first_child;
        while (check != dom.null_node) : (check = document.node(check).next_sibling) {
            const check_node = document.node(check);
            if (check_node.kind == .text and
                !isWhitespaceOnly(check_node.value))
            {
                return error.InvalidStylesheet;
            }
        }

        // Imports must be processed before the importing stylesheet receives
        // its precedence so that imported declarations rank lower. XSLT also
        // requires imports to precede all other top-level declarations.
        var seen_non_import = false;
        var child = document.node(root).first_child;
        while (child != dom.null_node) : (child = document.node(child).next_sibling) {
            const child_node = document.node(child);
            if (child_node.kind != .element) continue;
            if (!isXsl(self.document, child_node, null)) continue;
            if (std.mem.eql(u8, child_node.localName(), "annotation")) continue;
            if (std.mem.eql(u8, child_node.localName(), "import")) {
                if (seen_non_import) return error.InvalidStylesheet;
                try self.processReference(child, true, 0);
            } else {
                seen_non_import = true;
            }
        }

        const precedence = fixed_precedence orelse blk: {
            const value = self.next_precedence;
            self.next_precedence += 1;
            break :blk value;
        };
        self.current_precedence = precedence;

        child = document.node(root).first_child;
        while (child != dom.null_node) : (child = document.node(child).next_sibling) {
            const child_node = document.node(child);
            if (child_node.kind != .element) continue;
            if (std.mem.eql(
                u8,
                self.document.ns(child_node.ns),
                exslt_functions_namespace,
            ) and std.mem.eql(u8, child_node.localName(), "function")) {
                try self.compileFunction(child);
                continue;
            }
            if (!isXsl(self.document, child_node, null)) continue;
            const local = child_node.localName();
            if (std.mem.eql(u8, local, "import")) continue;
            if (std.mem.eql(u8, local, "include")) {
                try self.processReference(child, false, precedence);
            } else if (std.mem.eql(u8, local, "template")) {
                try self.compileTemplate(child);
            } else if (std.mem.eql(u8, local, "output")) {
                try self.compileOutput(child);
            } else if (std.mem.eql(u8, local, "variable")) {
                var variable = try self.compileVariable(child, false);
                variable.precedence = self.current_precedence;
                try self.globals.append(self.arena, variable);
            } else if (std.mem.eql(u8, local, "param")) {
                var variable = try self.compileVariable(child, true);
                variable.precedence = self.current_precedence;
                try self.globals.append(self.arena, variable);
            } else if (std.mem.eql(u8, local, "key")) {
                try self.compileKey(child);
            } else if (std.mem.eql(u8, local, "attribute-set")) {
                try self.compileAttributeSet(child);
            } else if (std.mem.eql(u8, local, "strip-space")) {
                try self.compileSpaceRule(child, true);
            } else if (std.mem.eql(u8, local, "preserve-space")) {
                try self.compileSpaceRule(child, false);
            } else if (std.mem.eql(u8, local, "decimal-format")) {
                try self.compileDecimalFormat(child);
            } else if (std.mem.eql(u8, local, "namespace-alias")) {
                try self.compileNamespaceAlias(child);
            }
        }
    }

    fn processReference(
        self: *Compiler,
        id: dom.NodeId,
        is_import: bool,
        include_precedence: usize,
    ) Error!void {
        const href = self.document.attribute(id, "href") orelse
            return error.InvalidStylesheet;
        const resolver = self.options.resolver orelse
            return error.InvalidStylesheet;
        const resource = resolver.load(
            resolver.context,
            href,
            self.current_base,
        ) orelse return error.InvalidStylesheet;

        const owned = try self.arena.dupe(u8, resource.data);
        const decoded = encoding.decodeAlloc(
            self.arena,
            owned,
            64 * 1024 * 1024,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidStylesheet,
        };
        const document_ptr = try self.arena.create(dom.Document);
        document_ptr.* = dom.Document.parse(
            self.backing_allocator,
            decoded,
            .{},
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidStylesheet,
        };
        const root = document_ptr.root();
        if (root == dom.null_node) return error.InvalidStylesheet;
        const root_node = document_ptr.node(root);
        if (!isXsl(self.document, root_node, "stylesheet") and
            !isXsl(self.document, root_node, "transform"))
        {
            return error.InvalidStylesheet;
        }

        const key_uri = if (resource.uri.len != 0) resource.uri else href;
        const owned_key = try self.arena.dupe(u8, key_uri);
        for (self.include_stack.items) |active| {
            if (std.mem.eql(u8, active, owned_key)) {
                document_ptr.deinit();
                return error.InvalidStylesheet;
            }
        }
        try self.include_stack.append(self.arena, owned_key);
        defer _ = self.include_stack.pop();
        try self.included_documents.append(self.arena, document_ptr);
        try self.compileDocument(
            document_ptr,
            owned_key,
            if (is_import) null else include_precedence,
            false,
        );
    }

    fn dedupeGlobals(self: *Compiler) Error![]const Variable {
        var winners: std.ArrayList(Variable) = .empty;
        for (self.globals.items) |variable| {
            var found = false;
            for (winners.items) |*winner| {
                if (!std.mem.eql(u8, winner.name, variable.name)) continue;
                if (variable.precedence > winner.precedence) {
                    winner.* = variable;
                } else if (variable.precedence == winner.precedence) {
                    return error.InvalidStylesheet;
                }
                found = true;
                break;
            }
            if (!found) try winners.append(self.arena, variable);
        }
        return winners.toOwnedSlice(self.arena);
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
            .precedence = self.current_precedence,
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
            .precedence = self.current_precedence,
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
            if (isXsl(self.document, child_node, "param")) {
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
        if (template.name) |template_name| {
            for (self.templates.items) |existing| {
                const existing_name = existing.name orelse continue;
                if (std.mem.eql(u8, existing_name, template_name) and
                    existing.precedence == template.precedence)
                {
                    return error.InvalidStylesheet;
                }
            }
        }
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

    fn compileSpaceRule(
        self: *Compiler,
        id: dom.NodeId,
        strip: bool,
    ) Error!void {
        const elements = self.document.attribute(id, "elements") orelse
            return error.InvalidStylesheet;
        var tokens = std.mem.tokenizeAny(u8, elements, " \t\r\n");
        while (tokens.next()) |token| {
            try self.space_rules.append(
                self.arena,
                try self.parseSpaceRule(id, token, strip),
            );
        }
    }

    fn parseSpaceRule(
        self: *Compiler,
        id: dom.NodeId,
        token: []const u8,
        strip: bool,
    ) Error!SpaceRule {
        if (std.mem.eql(u8, token, "*")) {
            return .{ .strip = strip, .any = true };
        }
        if (std.mem.indexOfScalar(u8, token, ':')) |colon| {
            const prefix = token[0..colon];
            const local = token[colon + 1 ..];
            if (prefix.len == 0 or local.len == 0) {
                return error.InvalidStylesheet;
            }
            const bindings = try self.namespacesOf(id);
            var namespace_uri: ?[]const u8 = null;
            for (bindings) |binding| {
                if (std.mem.eql(u8, binding.prefix, prefix)) {
                    namespace_uri = binding.uri;
                    break;
                }
            }
            if (namespace_uri == null) return error.InvalidStylesheet;
            return .{
                .strip = strip,
                .namespace_uri = namespace_uri,
                .local = if (std.mem.eql(u8, local, "*")) null else local,
            };
        }
        return .{
            .strip = strip,
            .namespace_uri = "",
            .local = token,
        };
    }

    fn compileNamespaceAlias(
        self: *Compiler,
        id: dom.NodeId,
    ) Error!void {
        const stylesheet_value = self.document.attribute(
            id,
            "stylesheet-prefix",
        ) orelse return error.InvalidStylesheet;
        const result_value = self.document.attribute(
            id,
            "result-prefix",
        ) orelse return error.InvalidStylesheet;
        const bindings = try self.namespacesOf(id);
        const stylesheet = try resolveAliasPrefix(bindings, stylesheet_value);
        const result = try resolveAliasPrefix(bindings, result_value);
        for (self.aliases.items) |existing| {
            if (std.mem.eql(u8, existing.stylesheet_uri, stylesheet.uri)) {
                return error.InvalidStylesheet;
            }
        }
        try self.aliases.append(self.arena, .{
            .stylesheet_uri = stylesheet.uri,
            .result_uri = result.uri,
            .result_prefix = result.prefix,
        });
    }

    fn findAlias(self: *Compiler, uri: []const u8) ?*const NamespaceAlias {
        for (self.aliases.items) |*alias| {
            if (std.mem.eql(u8, alias.stylesheet_uri, uri)) return alias;
        }
        return null;
    }

    fn compileDecimalFormat(self: *Compiler, id: dom.NodeId) Error!void {
        var format: DecimalFormat = .{};
        if (self.document.attribute(id, "name")) |raw_name| {
            const name = try self.resolveName(id, raw_name);
            format.name = name.local;
            format.name_uri = name.uri;
        }
        if (self.document.attribute(id, "decimal-separator")) |value| {
            format.decimal_separator = try singleCodepoint(value);
        }
        if (self.document.attribute(id, "grouping-separator")) |value| {
            format.grouping_separator = try singleCodepoint(value);
        }
        if (self.document.attribute(id, "infinity")) |value| {
            format.infinity = value;
        }
        if (self.document.attribute(id, "minus-sign")) |value| {
            format.minus_sign = try singleCodepoint(value);
        }
        if (self.document.attribute(id, "NaN")) |value| {
            format.nan = value;
        }
        if (self.document.attribute(id, "percent")) |value| {
            format.percent = try singleCodepoint(value);
        }
        if (self.document.attribute(id, "per-mille")) |value| {
            format.per_mille = try singleCodepoint(value);
        }
        if (self.document.attribute(id, "zero-digit")) |value| {
            format.zero_digit = try singleCodepoint(value);
        }
        if (self.document.attribute(id, "digit")) |value| {
            format.digit = try singleCodepoint(value);
        }
        if (self.document.attribute(id, "pattern-separator")) |value| {
            format.pattern_separator = try singleCodepoint(value);
        }
        for (self.decimal_formats.items) |existing| {
            if (existing.name == null and format.name == null) {
                return error.InvalidStylesheet;
            }
            if (existing.name != null and format.name != null and
                std.mem.eql(u8, existing.name_uri, format.name_uri) and
                std.mem.eql(u8, existing.name.?, format.name.?))
            {
                return error.InvalidStylesheet;
            }
        }
        try self.decimal_formats.append(self.arena, format);
    }

    fn compileAttributeSet(self: *Compiler, id: dom.NodeId) Error!void {
        const raw_name = self.document.attribute(id, "name") orelse
            return error.InvalidStylesheet;
        const name = try self.resolveName(id, raw_name);
        var uses: []const NameRef = &.{};
        if (self.document.attribute(id, "use-attribute-sets")) |value| {
            uses = try self.parseNameRefs(id, value);
        }
        var instructions: std.ArrayList(Instruction) = .empty;
        var child = self.document.node(id).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const child_node = self.document.node(child);
            if (child_node.kind == .text) {
                if (isWhitespaceOnly(child_node.value)) continue;
                return error.InvalidStylesheet;
            }
            if (child_node.kind != .element) continue;
            if (!isXsl(self.document, child_node, "attribute")) {
                return error.InvalidStylesheet;
            }
            try self.compileInstruction(child, false, &instructions);
        }
        try self.attribute_sets.append(self.arena, .{
            .name = name.local,
            .name_uri = name.uri,
            .precedence = self.current_precedence,
            .uses = uses,
            .raw_instructions = try instructions.toOwnedSlice(self.arena),
        });
    }

    fn parseNameRefs(
        self: *Compiler,
        id: dom.NodeId,
        value: []const u8,
    ) Error![]const NameRef {
        var names: std.ArrayList(NameRef) = .empty;
        var tokens = std.mem.tokenizeAny(u8, value, " \t\r\n");
        while (tokens.next()) |token| {
            try names.append(self.arena, try self.resolveName(id, token));
        }
        return names.toOwnedSlice(self.arena);
    }

    fn expandAttributeSets(self: *Compiler) Error!void {
        for (self.attribute_sets.items, 0..) |_, index| {
            _ = try self.expandAttributeSet(index);
        }
    }

    /// Expand every declaration with `name`, in ascending import precedence
    /// (declarations are appended in that order). Higher-precedence
    /// declarations therefore run last and override earlier attributes.
    fn expandNamedAttributeSet(
        self: *Compiler,
        name: NameRef,
    ) Error![]const Instruction {
        var list: std.ArrayList(Instruction) = .empty;
        var found = false;
        for (self.attribute_sets.items, 0..) |set, index| {
            if (!std.mem.eql(u8, set.name, name.local) or
                !std.mem.eql(u8, set.name_uri, name.uri))
            {
                continue;
            }
            found = true;
            try list.appendSlice(
                self.arena,
                try self.expandAttributeSet(index),
            );
        }
        // An empty declaration is valid; only an undefined name is an error.
        if (!found) return error.InvalidStylesheet;
        return list.toOwnedSlice(self.arena);
    }

    fn expandAttributeSet(
        self: *Compiler,
        index: usize,
    ) Error![]const Instruction {
        const set = &self.attribute_sets.items[index];
        if (set.expanded) |expanded| return expanded;
        if (set.visiting) return error.InvalidStylesheet;
        set.visiting = true;
        defer set.visiting = false;
        var list: std.ArrayList(Instruction) = .empty;
        for (set.uses) |name| {
            try list.appendSlice(
                self.arena,
                try self.expandNamedAttributeSet(name),
            );
        }
        try list.appendSlice(self.arena, set.raw_instructions);
        set.expanded = try list.toOwnedSlice(self.arena);
        return set.expanded.?;
    }

    fn compileOutput(self: *Compiler, id: dom.NodeId) Error!void {
        // Imported and included stylesheets contribute output settings;
        // compilation visits them first so higher precedence wins.
        if (self.document.attribute(id, "method")) |method| {
            self.output.method_specified = true;
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
            self.output.indent_specified = true;
        }
        if (self.document.attribute(id, "version")) |value| {
            self.output.version = value;
        }
        if (self.document.attribute(id, "standalone")) |value| {
            if (std.mem.eql(u8, value, "yes")) {
                self.output.standalone = true;
            } else if (std.mem.eql(u8, value, "no")) {
                self.output.standalone = false;
            }
        }
        if (self.document.attribute(id, "encoding")) |value| {
            self.output.encoding = value;
        }
        if (self.document.attribute(id, "doctype-public")) |value| {
            self.output.doctype_public = value;
        }
        if (self.document.attribute(id, "doctype-system")) |value| {
            self.output.doctype_system = value;
        }
        if (self.document.attribute(id, "cdata-section-elements")) |value| {
            const bindings = try self.namespacesOf(id);
            var names: std.ArrayList(writer_mod.ExpandedName) = .empty;
            var tokens = std.mem.tokenizeAny(u8, value, " \t\r\n");
            while (tokens.next()) |token| {
                const qname = namespace.splitQName(token) catch
                    return error.InvalidStylesheet;
                var uri: []const u8 = "";
                if (qname.prefix.len != 0) {
                    uri = resolvePrefixUri(bindings, qname.prefix) orelse
                        return error.InvalidStylesheet;
                }
                try names.append(self.arena, .{
                    .uri = uri,
                    .local = qname.local,
                });
            }
            self.output.cdata_elements = try names.toOwnedSlice(self.arena);
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
                    if (isXsl(self.document, child_node, "sort") or
                        isXsl(self.document, child_node, "with-param"))
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

    /// Attributes that one pass over `body` creates through literal result
    /// elements, counted recursively through the constructs whose bodies
    /// always run. Unknown-output constructs (copies, apply-templates,
    /// nested loops) contribute nothing, so the count is a lower bound used
    /// to size result storage.
    fn literalAttributeCount(
        self: *Compiler,
        body: []const Instruction,
    ) u16 {
        var total: usize = 0;
        for (body) |*instruction| switch (instruction.*) {
            .literal_element => |element| {
                total += element.attributes.len + element.namespaces.len;
                total += self.literalAttributeCount(element.body);
            },
            .if_ => |if_instruction| {
                total += self.literalAttributeCount(if_instruction.body);
            },
            .choose => |choose| {
                for (choose.whens) |when| {
                    total += self.literalAttributeCount(when.body);
                }
                if (choose.otherwise) |otherwise| {
                    total += self.literalAttributeCount(otherwise);
                }
            },
            else => {},
        };
        return @intCast(@min(total, std.math.maxInt(u16)));
    }

    fn compileInstruction(
        self: *Compiler,
        id: dom.NodeId,
        preserve: bool,
        body: *std.ArrayList(Instruction),
    ) Error!void {
        const node = self.document.node(id);
        if (self.compiling_function and
            std.mem.eql(u8, self.document.ns(node.ns), exslt_functions_namespace) and
            std.mem.eql(u8, node.localName(), "result"))
        {
            try body.append(self.arena, .{
                .function_result = try self.compileFunctionResult(id),
            });
            return;
        }
        if (node.ns != 0 and
            !std.mem.eql(u8, self.document.ns(node.ns), xsl_namespace) and
            try self.isExtensionNamespace(id, self.document.ns(node.ns)))
        {
            // libxslt's built-in test module: the `test` element emits a
            // comment so extension dispatch can be exercised by the suite.
            if (std.mem.eql(u8, self.document.ns(node.ns), libxslt_namespace) and
                std.mem.eql(u8, node.localName(), "test"))
            {
                const comment_body = try self.arena.alloc(Instruction, 1);
                comment_body[0] = .{
                    .literal_text = "libxslt:test element test worked",
                };
                try body.append(self.arena, .{
                    .comment = .{ .body = comment_body },
                });
                return;
            }
            // Other extension instructions are unsupported: process
            // xsl:fallback children and ignore the rest.
            try self.compileFallbacks(id, preserve, body);
            return;
        }
        if (node.ns == 0 or !std.mem.eql(u8, self.document.ns(node.ns), xsl_namespace)) {
            try body.append(self.arena, .{
                .literal_element = try self.compileLiteralElement(id, preserve),
            });
            return;
        }

        const local = node.localName();
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
            const text = try out.toOwnedSlice(self.arena);
            if (isYes(
                self.document.attribute(
                    id,
                    "disable-output-escaping",
                ) orelse "no",
            )) {
                try body.append(self.arena, .{ .raw_text = text });
            } else {
                try body.append(self.arena, .{ .text = text });
            }
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
            instruction.attributes_per_iteration =
                self.literalAttributeCount(instruction.body);
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
            var instruction: Copy = .{
                .body = try self.compileBody(id, preserve),
            };
            if (instruction.body.len == 1) {
                switch (instruction.body[0]) {
                    .apply_templates => |apply_instruction| {
                        instruction.body_kind = if (apply_instruction.params.len != 0)
                            .apply
                        else if (apply_instruction.stream_identity)
                            .identity_select
                        else if (apply_instruction.select == null and
                            apply_instruction.sorts.len == 0)
                            .plain_apply
                        else
                            .apply;
                    },
                    else => {},
                }
            }
            try body.append(self.arena, .{ .copy = instruction });
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
            if (self.document.attribute(id, "use-attribute-sets")) |value| {
                instruction.attribute_sets = try self.parseNameRefs(id, value);
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
            try body.append(self.arena, .{ .apply_imports = .{
                .params = try self.compileWithParams(id),
            } });
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
        if (instruction.sorts.len == 0) {
            if (instruction.select) |select| {
                instruction.stream_identity = identitySelectShape(select.node);
            }
        }
        return instruction;
    }

    fn compileWithParams(self: *Compiler, id: dom.NodeId) Error![]const ParamBinding {
        var params: std.ArrayList(ParamBinding) = .empty;
        var child = self.document.node(id).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const child_node = self.document.node(child);
            if (child_node.kind != .element or !isXsl(self.document, child_node, "with-param")) continue;
            const name = self.document.attribute(child, "name") orelse
                return error.InvalidStylesheet;
            try params.append(self.arena, .{
                .name = try self.internVariableName(name),
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
            if (child_node.kind != .element or !isXsl(self.document, child_node, "sort")) continue;
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
            if (isXsl(self.document, child_node, "when")) {
                if (otherwise != null) return error.InvalidStylesheet;
                const test_value = self.document.attribute(child, "test") orelse
                    return error.InvalidStylesheet;
                try whens.append(self.arena, .{
                    .test_expr = try self.parseExpression(child, test_value),
                    .body = try self.compileBody(child, preserve),
                });
            } else if (isXsl(self.document, child_node, "otherwise")) {
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
        if (self.document.attribute(id, "grouping-separator")) |separator| {
            instruction.grouping_separator = try self.compileAvt(id, separator);
        }
        if (self.document.attribute(id, "grouping-size")) |size| {
            instruction.grouping_size = try self.compileAvt(id, size);
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
            instruction.count = try self.compilePatternExpression(id, count);
        }
        if (self.document.attribute(id, "from")) |from| {
            instruction.from = try self.compilePatternExpression(id, from);
        }
        return instruction;
    }

    fn resolveName(
        self: *Compiler,
        id: dom.NodeId,
        raw: []const u8,
    ) Error!NameRef {
        const parts = namespace.splitQName(raw) catch
            return error.InvalidStylesheet;
        if (parts.prefix.len == 0) {
            return .{ .uri = "", .local = parts.local };
        }
        const bindings = try self.document.inScopeNamespaces(self.arena, id);
        for (bindings) |binding| {
            if (std.mem.eql(u8, binding.prefix, parts.prefix)) {
                return .{ .uri = binding.uri, .local = parts.local };
            }
        }
        return error.InvalidStylesheet;
    }

    /// Compile an EXSLT `func:function` definition.
    fn compileFunction(self: *Compiler, id: dom.NodeId) Error!void {
        const raw_name = self.document.attribute(id, "name") orelse
            return error.InvalidStylesheet;
        const name = try self.resolveName(id, raw_name);
        var params: std.ArrayList(Variable) = .empty;
        var body: std.ArrayList(Instruction) = .empty;
        const saved_function = self.compiling_function;
        self.compiling_function = true;
        defer self.compiling_function = saved_function;
        var child = self.document.node(id).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const child_node = self.document.node(child);
            switch (child_node.kind) {
                .element => {
                    if (isXsl(self.document, child_node, "param")) {
                        try params.append(
                            self.arena,
                            try self.compileVariable(child, true),
                        );
                    } else {
                        try self.compileInstruction(child, false, &body);
                    }
                },
                .text => {
                    if (isWhitespaceOnly(child_node.value)) continue;
                    try body.append(self.arena, .{
                        .literal_text = child_node.value,
                    });
                },
                .comment, .processing_instruction => {},
                .document => unreachable,
            }
        }
        try self.functions.append(self.arena, .{
            .name = name.local,
            .namespace_uri = name.uri,
            .params = try params.toOwnedSlice(self.arena),
            .body = try body.toOwnedSlice(self.arena),
            .precedence = self.current_precedence,
            .order = self.next_function_order,
        });
        self.next_function_order += 1;
    }

    fn compileFunctionResult(
        self: *Compiler,
        id: dom.NodeId,
    ) Error!FunctionResult {
        var result: FunctionResult = .{};
        if (self.document.attribute(id, "select")) |select| {
            result.select = try self.parseExpression(id, select);
        } else {
            result.body = try self.compileBody(id, false);
        }
        return result;
    }

    fn compileVariable(self: *Compiler, id: dom.NodeId, param: bool) Error!Variable {
        const name = self.document.attribute(id, "name") orelse
            return error.InvalidStylesheet;
        return .{
            .name = try self.internVariableName(name),
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

    fn compileFallbacks(
        self: *Compiler,
        id: dom.NodeId,
        preserve: bool,
        body: *std.ArrayList(Instruction),
    ) Error!void {
        var child = self.document.node(id).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const node = self.document.node(child);
            if (node.kind != .element) continue;
            if (!isXsl(self.document, node, "fallback")) continue;
            try body.appendSlice(
                self.arena,
                try self.compileBody(child, preserve),
            );
        }
    }

    /// True when `uri` is designated by an in-scope
    /// `extension-element-prefixes` attribute.
    fn isExtensionNamespace(
        self: *Compiler,
        id: dom.NodeId,
        uri: []const u8,
    ) Error!bool {
        var current = id;
        while (true) {
            const current_node = self.document.node(current);
            const current_is_xsl = std.mem.eql(
                u8,
                self.document.ns(current_node.ns),
                xsl_namespace,
            );
            for (self.document.attributesOf(current)) |attr| {
                const namespaced = attr.ns != 0 and
                    std.mem.eql(u8, self.document.ns(attr.ns), xsl_namespace);
                if (!namespaced and
                    !(current_is_xsl and attr.ns == 0))
                {
                    continue;
                }
                if (!std.mem.eql(
                    u8,
                    attr.localName(),
                    "extension-element-prefixes",
                )) {
                    continue;
                }
                var tokens = std.mem.tokenizeAny(
                    u8,
                    attr.value,
                    " \t\r\n",
                );
                while (tokens.next()) |token| {
                    if (std.mem.eql(u8, token, "#default")) {
                        const bindings = try self.document.inScopeNamespaces(
                            self.arena,
                            current,
                        );
                        for (bindings) |binding| {
                            if (binding.prefix.len == 0 and
                                std.mem.eql(u8, binding.uri, uri))
                            {
                                return true;
                            }
                        }
                        continue;
                    }
                    const bindings = try self.document.inScopeNamespaces(
                        self.arena,
                        current,
                    );
                    for (bindings) |binding| {
                        if (std.mem.eql(u8, binding.prefix, token) and
                            std.mem.eql(u8, binding.uri, uri))
                        {
                            return true;
                        }
                    }
                }
            }
            const parent = current_node.parent;
            if (parent == dom.null_node) break;
            if (self.document.node(parent).kind != .element) break;
            current = parent;
        }
        return false;
    }

    fn compileLiteralElement(
        self: *Compiler,
        id: dom.NodeId,
        preserve: bool,
    ) Error!LiteralElement {
        const node = self.document.node(id);
        const element_alias = self.findAlias(self.document.ns(node.ns));
        const element_prefix = if (element_alias) |alias|
            alias.result_prefix
        else
            prefixOf(node);
        const element_ns = if (element_alias) |alias|
            alias.result_uri
        else
            self.document.ns(node.ns);
        var element: LiteralElement = .{
            .prefix = element_prefix,
            .local = node.localName(),
            .ns = element_ns,
            .namespaces = &.{},
            .attributes = &.{},
            .body = &.{},
        };

        const excluded = try self.excludedPrefixes(id);
        var namespaces: std.ArrayList(NamespaceDecl) = .empty;
        const in_scope = try self.document.inScopeNamespaces(self.arena, id);
        for (in_scope) |binding| {
            if (std.mem.eql(u8, binding.prefix, "xml")) continue;
            const alias = self.findAlias(binding.uri);
            if (alias == null and
                std.mem.eql(u8, binding.uri, xsl_namespace))
            {
                continue;
            }
            if (isPrefixExcluded(excluded, binding.prefix)) continue;
            if (alias) |found| {
                try setNamespaceDecl(
                    &namespaces,
                    found.result_prefix,
                    found.result_uri,
                    self.arena,
                );
            } else {
                try setNamespaceDecl(
                    &namespaces,
                    binding.prefix,
                    binding.uri,
                    self.arena,
                );
            }
        }
        // Prefixes used by the element name or its attributes must stay
        // declared even when excluded, or the result is not namespace
        // well-formed.
        if (element.ns.len != 0) {
            try setNamespaceDecl(
                &namespaces,
                element.prefix,
                element.ns,
                self.arena,
            );
        }
        for (self.document.attributesOf(id)) |attr| {
            if (namespace.Resolver.isNamespaceDeclaration(attr.name)) continue;
            if (attr.ns != 0 and
                std.mem.eql(u8, self.document.ns(attr.ns), xsl_namespace))
            {
                continue;
            }
            const alias = self.findAlias(self.document.ns(attr.ns));
            const attr_ns = if (alias) |found| found.result_uri else self.document.ns(attr.ns);
            const attr_prefix = if (alias) |found|
                found.result_prefix
            else
                attr.prefixName();
            if (attr_ns.len == 0 or attr_prefix.len == 0 or
                std.mem.eql(u8, attr_prefix, "xml"))
            {
                continue;
            }
            try setNamespaceDecl(
                &namespaces,
                attr_prefix,
                attr_ns,
                self.arena,
            );
        }
        element.namespaces = try namespaces.toOwnedSlice(self.arena);

        var attributes: std.ArrayList(LiteralAttribute) = .empty;
        for (self.document.attributesOf(id)) |attr| {
            if (namespace.Resolver.isNamespaceDeclaration(attr.name)) continue;
            if (attr.ns != 0 and
                std.mem.eql(u8, self.document.ns(attr.ns), xsl_namespace))
            {
                continue;
            }
            const alias = self.findAlias(self.document.ns(attr.ns));
            var attr_name = attr.name;
            var attr_prefix = attr.prefixName();
            var attr_ns = self.document.ns(attr.ns);
            if (alias) |found| {
                attr_prefix = found.result_prefix;
                attr_ns = found.result_uri;
                attr_name = if (attr_prefix.len == 0)
                    attr.localName()
                else
                    try std.fmt.allocPrint(
                        self.arena,
                        "{s}:{s}",
                        .{ attr_prefix, attr.localName() },
                    );
            }
            try attributes.append(self.arena, .{
                .name = attr_name,
                .prefix = attr_prefix,
                .local = attr.localName(),
                .ns = attr_ns,
                .value = try self.compileAvt(id, attr.value),
            });
        }
        element.attributes = try attributes.toOwnedSlice(self.arena);
        if (self.document.attributeNs(
            id,
            xsl_namespace,
            "use-attribute-sets",
        )) |value| {
            element.attribute_sets = try self.parseNameRefs(id, value);
        }
        element.body = try self.compileBody(id, preserve);
        return element;
    }

    fn excludedPrefixes(self: *Compiler, id: dom.NodeId) Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var current = id;
        while (true) {
            const current_is_xsl = std.mem.eql(
                u8,
                self.document.ns(self.document.node(current).ns),
                xsl_namespace,
            );
            for (self.document.attributesOf(current)) |attr| {
                const namespaced = attr.ns != 0 and
                    std.mem.eql(u8, self.document.ns(attr.ns), xsl_namespace);
                if (!namespaced and
                    !(current_is_xsl and attr.ns == 0))
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

    fn compilePatternExpression(
        self: *Compiler,
        id: dom.NodeId,
        text: []const u8,
    ) Error!CompiledExpr {
        const parsed = try self.parseExpression(id, text);
        return .{
            .node = try self.patternSelector(parsed.node),
            .namespaces = parsed.namespaces,
        };
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
        try self.internVariableNames(root);
        if (!self.uses_last and ast.usesLast(root)) {
            self.uses_last = true;
        }
        return .{
            .node = root,
            .namespaces = try self.namespacesOf(id),
        };
    }

    fn internVariableName(self: *Compiler, name: []const u8) Error![]const u8 {
        const entry = try self.variable_names.getOrPut(self.arena, name);
        if (!entry.found_existing) {
            const owned = try self.arena.dupe(u8, name);
            entry.key_ptr.* = owned;
            entry.value_ptr.* = owned;
        }
        return entry.value_ptr.*;
    }

    /// Replace every variable reference in a parsed expression with the
    /// canonical name slice.
    fn internVariableNames(self: *Compiler, expression: *ast.Expr) Error!void {
        switch (expression.*) {
            .variable => |name| expression.variable = try self.internVariableName(name),
            .binary => |binary| {
                try self.internVariableNames(binary.lhs);
                try self.internVariableNames(binary.rhs);
            },
            .unary_minus => |inner| try self.internVariableNames(inner),
            .path => |path| {
                if (path.start) |start| try self.internVariableNames(start);
                for (path.steps) |step| {
                    for (step.predicates) |predicate| {
                        try self.internVariableNames(predicate);
                    }
                }
            },
            .filter => |filter| {
                try self.internVariableNames(filter.primary);
                for (filter.predicates) |predicate| {
                    try self.internVariableNames(predicate);
                }
            },
            .function_call => |call| {
                for (call.args) |argument| {
                    try self.internVariableNames(argument);
                }
            },
            .literal, .number => {},
        }
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

fn isXsl(document: *const dom.Document, node: *const dom.Node, local: ?[]const u8) bool {
    if (!std.mem.eql(u8, document.ns(node.ns), xsl_namespace)) return false;
    if (local) |expected| return std.mem.eql(u8, node.localName(), expected);
    return true;
}

fn prefixOf(node: *const dom.Node) []const u8 {
    if (node.localName().len >= node.name.len) return "";
    return node.name[0 .. node.name.len - node.localName().len - 1];
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

fn resolvePrefixUri(
    bindings: []const namespace.Binding,
    prefix: []const u8,
) ?[]const u8 {
    if (std.mem.eql(u8, prefix, "xml")) return namespace.xml_uri;
    for (bindings) |binding| {
        if (std.mem.eql(u8, binding.prefix, prefix)) return binding.uri;
    }
    return null;
}

fn resolveAliasPrefix(
    bindings: []const namespace.Binding,
    value: []const u8,
) Error!struct { uri: []const u8, prefix: []const u8 } {
    if (std.mem.eql(u8, value, "#default")) {
        for (bindings) |binding| {
            if (binding.prefix.len == 0) {
                return .{ .uri = binding.uri, .prefix = "" };
            }
        }
        return .{ .uri = "", .prefix = "" };
    }
    for (bindings) |binding| {
        if (std.mem.eql(u8, binding.prefix, value)) {
            return .{ .uri = binding.uri, .prefix = value };
        }
    }
    return error.InvalidStylesheet;
}

fn setNamespaceDecl(
    namespaces: *std.ArrayList(NamespaceDecl),
    prefix: []const u8,
    uri: []const u8,
    allocator: std.mem.Allocator,
) Error!void {
    for (namespaces.items) |*decl| {
        if (std.mem.eql(u8, decl.prefix, prefix)) {
            decl.uri = uri;
            return;
        }
    }
    try namespaces.append(allocator, .{ .prefix = prefix, .uri = uri });
}

fn singleCodepoint(value: []const u8) Error!u21 {
    var view = std.unicode.Utf8View.init(value) catch
        return error.InvalidStylesheet;
    var iterator = view.iterator();
    const codepoint = iterator.nextCodepoint() orelse
        return error.InvalidStylesheet;
    if (iterator.nextCodepoint() != null) return error.InvalidStylesheet;
    return codepoint;
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

/// Match the standard identity select `@*|node()` (in either order), which
/// the transformer can apply by walking attributes and children directly.
fn identitySelectShape(expression: *const ast.Expr) bool {
    const binary = switch (expression.*) {
        .binary => |value| value,
        else => return false,
    };
    if (binary.op != .union_) return false;
    var saw_attributes = false;
    var saw_children = false;
    for ([_]*const ast.Expr{ binary.lhs, binary.rhs }) |branch| {
        const step = singleSelectStep(branch) orelse return false;
        switch (step.axis) {
            .attribute => {
                if (saw_attributes) return false;
                saw_attributes = true;
                switch (step.node_test) {
                    .name => |name_test| {
                        if (name_test.prefix != null or name_test.local != null) {
                            return false;
                        }
                    },
                    else => return false,
                }
            },
            .child => {
                if (saw_children) return false;
                saw_children = true;
                switch (step.node_test) {
                    .node => {},
                    else => return false,
                }
            },
            else => return false,
        }
    }
    return saw_attributes and saw_children;
}

const SingleSelectStep = struct {
    axis: ast.Axis,
    node_test: ast.NodeTest,
};

/// Match a relative select with a single child or attribute step.
fn singleSelectStep(expression: *const ast.Expr) ?SingleSelectStep {
    const path = switch (expression.*) {
        .path => |value| value,
        else => return null,
    };
    if (path.absolute or path.start != null or path.steps.len != 1) {
        return null;
    }
    const step = path.steps[0];
    if (step.predicates.len != 0) return null;
    if (step.axis != .child and step.axis != .attribute) return null;
    return .{ .axis = step.axis, .node_test = step.node_test };
}
