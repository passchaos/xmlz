//! XSLT 1.0 transformation runtime.

const std = @import("std");
const dom = @import("../dom.zig");
const dom_builder = @import("../dom_builder.zig");
const local_arena = @import("../local_arena.zig");
const name_match = @import("../names.zig");

/// Namespace comparison with a fast path for the common no-namespace case.
inline fn namespaceMatches(actual: []const u8, expected: []const u8) bool {
    if (expected.len == 0) return actual.len == 0;
    return std.mem.eql(u8, actual, expected);
}
const encoding = @import("../encoding.zig");
const namespace = @import("../namespace.zig");
const xmlbase = @import("../xmlbase.zig");
const parser_mod = @import("../parser.zig");
const xpath = @import("../xpath/root.zig");
const xpath_ast = @import("../xpath/ast.zig");
const xpath_parser = @import("../xpath/parser.zig");
const xpath_value = @import("../xpath/value.zig");
const xpath_eval = @import("../xpath/eval.zig");
const writer_mod = @import("../writer.zig");
const compile = @import("compile.zig");
const unicode_categories = @import("../xsd/unicode_categories.zig");

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
    /// Internal control flow for EXSLT `func:result`.
    FunctionResultReturned,
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

    pub const WriteOptions = struct {
        /// Match libxslt's file serialization: HTML method auto-detection,
        /// charset meta insertion, HTML formatting, and a trailing newline.
        libxslt_compat: bool = false,
    };

    pub fn write(self: *const Result, out: *std.Io.Writer) !void {
        return self.writeWithOptions(out, .{});
    }

    pub fn writeWithOptions(
        self: *const Result,
        out: *std.Io.Writer,
        options: WriteOptions,
    ) !void {
        const target = encoding.outputEncoding(self.output.encoding);
        if (target == null or target.? == .utf8) {
            var label: ?[]const u8 = null;
            if (target != null) {
                // Explicit, supported UTF-8 output keeps its label.
                label = self.output.encoding;
            } else if (!options.libxslt_compat) {
                // The library default declares UTF-8; libxslt omits the
                // encoding pseudo-attribute unless one was requested.
                label = "UTF-8";
            }
            return self.writeUtf8(out, label, options);
        }
        const allocator = self.arena.child_allocator;
        var buffer: std.Io.Writer.Allocating = .init(allocator);
        defer buffer.deinit();
        try self.writeUtf8(&buffer.writer, self.output.encoding, options);
        const encoded = encoding.encodeAlloc(
            allocator,
            buffer.written(),
            target.?,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidOutput,
        };
        defer allocator.free(encoded);
        try out.writeAll(encoded);
    }

    fn writeUtf8(
        self: *const Result,
        out: *std.Io.Writer,
        encoding_label: ?[]const u8,
        options: WriteOptions,
    ) !void {
        // libxslt auto-detects HTML output when no method was specified and
        // the result element is `html`.
        var method = self.output.method;
        if (options.libxslt_compat and !self.output.method_specified and
            method == .xml)
        {
            const root = self.document.root();
            if (root != dom.null_node) {
                const root_node = self.document.node(root);
                if (self.document.ns(root_node.ns).len == 0 and std.ascii.eqlIgnoreCase(
                    root_node.localName(),
                    "html",
                )) {
                    method = .html;
                }
            }
        }
        if (method == .text) {
            try writeTextNode(out, &self.document, self.document.documentNode());
            return;
        }
        const doctype = self.outputDoctype();
        if (method == .html) {
            if (doctype) |value| {
                try writer_mod.writeDoctype(out, value);
                try out.writeByte('\n');
            }
            const charset = if (self.output.encoding.len != 0)
                self.output.encoding
            else
                "UTF-8";
            // libxslt formats HTML output unless indent="no" was explicit.
            const format = options.libxslt_compat and
                (if (self.output.indent_specified)
                    self.output.indent
                else
                    true);
            try writeHtmlNode(
                out,
                &self.document,
                self.document.documentNode(),
                false,
                charset,
                format,
                options.libxslt_compat,
                "",
            );
            return;
        }
        const xhtml_charset: ?[]const u8 = blk: {
            if (!options.libxslt_compat) break :blk null;
            // libxml2 only switches to XHTML serialization (and inserts the
            // Content-Type meta element) when the output doctype identifies
            // an XHTML DTD.
            if (!isXhtmlDoctype(
                self.output.doctype_public,
                self.output.doctype_system,
            )) break :blk null;
            break :blk encoding_label orelse "UTF-8";
        };
        try writer_mod.writeDocument(out, &self.document, .{
            .xml_declaration = method == .xml and
                !self.output.omit_xml_declaration,
            .indent = if (self.output.indent) "  " else null,
            .trailing_newline = options.libxslt_compat and
                !(self.output.indent_specified and !self.output.indent),
            .doctype = doctype,
            .cdata_elements = self.output.cdata_elements,
            .version = self.output.version,
            .standalone = self.output.standalone,
            .encoding_label = encoding_label,
            .html_meta_charset = xhtml_charset,
        });
    }

    fn outputDoctype(self: *const Result) ?writer_mod.Doctype {
        if (self.output.doctype_public == null and
            self.output.doctype_system == null)
        {
            return null;
        }
        const root = self.document.root();
        if (root == dom.null_node) return null;
        return .{
            .name = self.document.node(root).name,
            .public_id = self.output.doctype_public,
            .system_id = self.output.doctype_system,
        };
    }

    /// libxml2's `xmlIsXHTML`: the doctype must name one of the XHTML 1.0
    /// DTDs for XHTML serialization to kick in.
    fn isXhtmlDoctype(
        public_id: ?[]const u8,
        system_id: ?[]const u8,
    ) bool {
        const public_ids = [_][]const u8{
            "-//W3C//DTD XHTML 1.0 Strict//EN",
            "-//W3C//DTD XHTML 1.0 Frameset//EN",
            "-//W3C//DTD XHTML 1.0 Transitional//EN",
        };
        const system_ids = [_][]const u8{
            "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd",
            "http://www.w3.org/TR/xhtml1/DTD/xhtml1-frameset.dtd",
            "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd",
        };
        if (public_id) |value| {
            for (public_ids) |candidate| {
                if (std.mem.eql(u8, value, candidate)) return true;
            }
        }
        if (system_id) |value| {
            for (system_ids) |candidate| {
                if (std.mem.eql(u8, value, candidate)) return true;
            }
        }
        return false;
    }

    pub fn toOwnedSlice(
        self: *const Result,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        return self.toOwnedSliceWithOptions(allocator, .{});
    }

    pub fn toOwnedSliceWithOptions(
        self: *const Result,
        allocator: std.mem.Allocator,
        options: WriteOptions,
    ) ![]u8 {
        var allocating: std.Io.Writer.Allocating = .init(allocator);
        defer allocating.deinit();
        try self.writeWithOptions(&allocating.writer, options);
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
    // Expressions allocate many small node sets and strings on one thread;
    // a bump allocator avoids the arena's atomic bookkeeping.
    var bump = local_arena.Arena.init(arena.allocator());
    const arena_allocator = bump.allocator();

    // The result document owns its arena. Parent it to the caller allocator,
    // not to the transform arena, because the transform arena struct is moved
    // into the returned Result after the document is built.
    var builder = dom_builder.Builder.init(allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidStylesheet,
    };
    builder.allow_multiple_roots = true;
    builder.reserveNodes(source.nodes.len + 16) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidStylesheet,
    };
    builder.reserveAttributes(source.attributes.len + 16) catch |err| switch (err) {
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
        .template_index = TemplateIndex.init(arena_allocator),
        .node_ids = NodeIdMap.init(arena_allocator),
        .document_cache = std.StringHashMap(dom.NodeId).init(arena_allocator),
        .resolver = options.resolver,
        .base_uri = options.base,
        .now = options.now,
        .selector_cache = std.AutoHashMap(
            *const xpath_ast.Expr,
            *SelectorEntry,
        ).init(arena_allocator),
        .selector_var_usage = std.AutoHashMap(
            *const xpath_ast.Expr,
            bool,
        ).init(arena_allocator),
        .selector_matchers = std.AutoHashMap(
            *const xpath_ast.Expr,
            ?PatternMatcher,
        ).init(arena_allocator),
    };
    runtime.variables = try arena_allocator.alloc(xpath.Variable, max_variables);
    try runtime.buildSpaceRuleIndex();
    try runtime.prepareSource();
    runtime.source_has_namespaces = documentHasNamespaces(runtime.source);
    try runtime.prepareMergedSource();
    runtime.suppress_refresh = true;
    try runtime.buildKeys();
    try runtime.buildTemplateMatches();
    runtime.suppress_refresh = false;
    try runtime.evaluateGlobals(options.parameters);
    try runtime.applyTemplates(&.{.{ .node = 0 }}, null, &.{});
    runtime.deinitMergedSource();
    runtime.deinitLoadedDocuments();
    runtime.deinitFilteredSource();
    runtime.deinitFragments();

    const output = try runtime.copyOutput();
    const messages = try runtime.messages.toOwnedSlice(arena_allocator);
    const document = builder.finish() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidStylesheet,
    };
    return .{
        .arena = arena,
        .document = document,
        .output = output,
        .messages = messages,
    };
}

/// Maximum simultaneously live XSLT variable bindings. Recursion depth is
/// bounded by the stylesheet; exceeding this reports an invalid stylesheet.
const max_variables = 16384;

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

const NamePattern = struct {
    uri: []const u8,
    /// Null matches any local name (`prefix:*`).
    local: ?[]const u8,
    /// False for the wildcard `*`, which matches any namespace.
    check_namespace: bool = true,
};

/// A match pattern of the form `child-or-attribute test` that can be tested
/// directly against a node instead of precomputing a node set. This covers
/// the common `*`, name-test, `text()`, and `@*` templates.
const SimplePattern = union(enum) {
    element_any,
    element_name: NamePattern,
    attribute_any,
    attribute_name: NamePattern,
    text,
    comment,
    processing_instruction: ?[]const u8,
    child_node,
};

/// A match pattern step that can be checked by walking up from a candidate
/// node instead of evaluating the pattern as a document-wide selection.
const StructuralTest = union(enum) {
    name: NamePattern,
    node,
    text,
    comment,
    processing_instruction: ?[]const u8,
};

/// A step predicate compiled into a cheap node test when possible.
const StepPredicate = union(enum) {
    /// General XPath expression evaluated with the node as context.
    expression: *const xpath_ast.Expr,
    attribute_exists: NamePattern,
    attribute_absent: NamePattern,
    attribute_equals: AttributeValueTest,
    attribute_not_equals: AttributeValueTest,
    child_exists: NamePattern,
    child_absent: NamePattern,
    position_compare: PositionCompare,
};

const AttributeValueTest = struct {
    name: NamePattern,
    value: []const u8,
};

const PositionCompare = struct {
    op: xpath_ast.Op,
    operand: PositionOperand,
};

const PositionOperand = union(enum) {
    number: f64,
    last,
};

const StructuralStep = struct {
    axis: xpath_ast.Axis,
    node_test: StructuralTest,
    /// Single predicate evaluated against the node matched by this step.
    predicate: ?StepPredicate = null,
};

/// A match pattern compiled into chains of child/attribute steps, one per
/// union branch. The `descendant-or-self::node()` markers produced by `//`
/// are kept as steps so patterns like `a//b` match any ancestor chain.
const StructuralPattern = struct {
    alternatives: []const []const StructuralStep,
    /// Namespace bindings of the template, used by step predicates.
    namespaces: []const namespace.Binding = &.{},
};

const PatternMatcher = union(enum) {
    simple: SimplePattern,
    /// A union of simple patterns such as `@*|node()`, tested per kind
    /// instead of falling back to the structural matcher.
    simple_union: []const SimplePattern,
    structural: StructuralPattern,
};

const TemplateState = struct {
    template: *const compile.Template,
    matcher: ?PatternMatcher = null,
};

const NameKey = struct {
    uri: []const u8,
    /// Null selects the namespace-wide wildcard (`prefix:*`).
    local: ?[]const u8,
};

const NameKeyContext = struct {
    pub fn hash(_: NameKeyContext, key: NameKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(key.uri);
        hasher.update("\x00");
        if (key.local) |local| hasher.update(local);
        return hasher.final();
    }

    pub fn eql(_: NameKeyContext, a: NameKey, b: NameKey) bool {
        if (!std.mem.eql(u8, a.uri, b.uri)) return false;
        const a_local = a.local orelse return b.local == null;
        const b_local = b.local orelse return false;
        return std.mem.eql(u8, a_local, b_local);
    }
};

const SpaceRuleEntry = struct {
    index: usize,
    strip: bool,
};

const TemplateList = std.ArrayListUnmanaged(u32);

/// Candidates for one node category, split by template mode. A template
/// without a mode only matches `apply-templates` without a mode, and a
/// template with a mode only matches that mode, so each lookup scans exactly
/// one list.
const ModeBucket = struct {
    default: TemplateList = .empty,
    by_mode: std.StringHashMapUnmanaged(TemplateList) = .empty,

    fn add(
        self: *ModeBucket,
        allocator: std.mem.Allocator,
        mode: ?[]const u8,
        index: u32,
    ) !void {
        if (mode) |name| {
            const entry = try self.by_mode.getOrPut(allocator, name);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(allocator, index);
        } else {
            try self.default.append(allocator, index);
        }
    }

    inline fn candidates(self: *const ModeBucket, mode: ?[]const u8) []const u32 {
        if (mode) |name| {
            const list = self.by_mode.get(name) orelse return &.{};
            return list.items;
        }
        return self.default.items;
    }
};

const NameBucketMap = std.HashMapUnmanaged(
    NameKey,
    ModeBucket,
    NameKeyContext,
    80,
);

const NameListMap = std.HashMapUnmanaged(
    NameKey,
    TemplateList,
    NameKeyContext,
    80,
);

/// Inverted index from nodes to the template rules that can match them.
/// Non-simple patterns are evaluated once per document into `nodes`; simple
/// patterns are bucketed by node kind, expanded name, and mode. Matching a
/// node then costs a hash lookup plus a few short category scans instead of
/// testing every rule in the stylesheet.
const TemplateIndex = struct {
    allocator: std.mem.Allocator,
    /// Bumped whenever entries are added; caches derived from the index
    /// (such as the simple child dispatch) compare this value.
    version: u32 = 0,
    nodes: std.AutoHashMapUnmanaged(NodeKey, TemplateList) = .empty,
    element_any: ModeBucket = .{},
    elements: NameBucketMap = .empty,
    elements_by_uri: std.StringHashMapUnmanaged(ModeBucket) = .empty,
    attribute_any: ModeBucket = .{},
    attributes: NameBucketMap = .empty,
    attributes_by_uri: std.StringHashMapUnmanaged(ModeBucket) = .empty,
    text: ModeBucket = .{},
    comment: ModeBucket = .{},
    processing_instruction: ModeBucket = .{},
    child_node: ModeBucket = .{},
    document_node: ModeBucket = .{},

    fn init(allocator: std.mem.Allocator) TemplateIndex {
        return .{ .allocator = allocator };
    }

    fn addMatch(self: *TemplateIndex, key: NodeKey, index: u32) !void {
        self.version +%= 1;
        const entry = try self.nodes.getOrPut(self.allocator, key);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        // A selector that reaches into documents loaded by `document()` can
        // be evaluated again when those documents are indexed.
        for (entry.value_ptr.items) |existing| {
            if (existing == index) return;
        }
        try entry.value_ptr.append(self.allocator, index);
    }

    fn addMatcher(
        self: *TemplateIndex,
        index: u32,
        matcher: PatternMatcher,
        mode: ?[]const u8,
    ) !void {
        self.version +%= 1;
        switch (matcher) {
            .simple => |pattern| try self.addSimple(index, pattern, mode),
            .simple_union => |patterns| for (patterns) |pattern| {
                try self.addSimple(index, pattern, mode);
            },
            .structural => |pattern| try self.addStructural(
                index,
                pattern,
                mode,
            ),
        }
    }

    fn addSimple(
        self: *TemplateIndex,
        index: u32,
        pattern: SimplePattern,
        mode: ?[]const u8,
    ) !void {
        switch (pattern) {
            .element_any => try self.element_any.add(
                self.allocator,
                mode,
                index,
            ),
            .element_name => |name| try self.addElementName(
                index,
                name,
                mode,
            ),
            .attribute_any => try self.attribute_any.add(
                self.allocator,
                mode,
                index,
            ),
            .attribute_name => |name| try self.addAttributeName(
                index,
                name,
                mode,
            ),
            .text => try self.text.add(self.allocator, mode, index),
            .comment => try self.comment.add(self.allocator, mode, index),
            .processing_instruction => try self.processing_instruction.add(
                self.allocator,
                mode,
                index,
            ),
            .child_node => try self.child_node.add(
                self.allocator,
                mode,
                index,
            ),
        }
    }

    fn addStructural(
        self: *TemplateIndex,
        index: u32,
        pattern: StructuralPattern,
        mode: ?[]const u8,
    ) !void {
        for (pattern.alternatives) |steps| {
            if (steps.len == 0) {
                try self.document_node.add(self.allocator, mode, index);
                continue;
            }
            const last = steps[steps.len - 1];
            switch (last.node_test) {
                .name => |name| {
                    if (last.axis == .attribute) {
                        try self.addAttributeName(index, name, mode);
                    } else {
                        try self.addElementName(index, name, mode);
                    }
                },
                .node => try self.child_node.add(
                    self.allocator,
                    mode,
                    index,
                ),
                .text => try self.text.add(self.allocator, mode, index),
                .comment => try self.comment.add(self.allocator, mode, index),
                .processing_instruction => try self.processing_instruction.add(
                    self.allocator,
                    mode,
                    index,
                ),
            }
        }
    }

    fn addElementName(
        self: *TemplateIndex,
        index: u32,
        name: NamePattern,
        mode: ?[]const u8,
    ) !void {
        if (name.local) |local| {
            try appendName(
                &self.elements,
                self.allocator,
                .{ .uri = name.uri, .local = local },
                index,
                mode,
            );
        } else if (name.check_namespace) {
            try appendUri(
                &self.elements_by_uri,
                self.allocator,
                name.uri,
                index,
                mode,
            );
        } else {
            try self.element_any.add(self.allocator, mode, index);
        }
    }

    fn addAttributeName(
        self: *TemplateIndex,
        index: u32,
        name: NamePattern,
        mode: ?[]const u8,
    ) !void {
        if (name.local) |local| {
            try appendName(
                &self.attributes,
                self.allocator,
                .{ .uri = name.uri, .local = local },
                index,
                mode,
            );
        } else if (name.check_namespace) {
            try appendUri(
                &self.attributes_by_uri,
                self.allocator,
                name.uri,
                index,
                mode,
            );
        } else {
            try self.attribute_any.add(self.allocator, mode, index);
        }
    }
};

fn appendIndex(
    map: *NameListMap,
    allocator: std.mem.Allocator,
    key: NameKey,
    index: u32,
) !void {
    const entry = try map.getOrPut(allocator, key);
    if (!entry.found_existing) entry.value_ptr.* = .empty;
    try entry.value_ptr.append(allocator, index);
}

fn appendName(
    map: *NameBucketMap,
    allocator: std.mem.Allocator,
    key: NameKey,
    index: u32,
    mode: ?[]const u8,
) !void {
    const entry = try map.getOrPut(allocator, key);
    if (!entry.found_existing) entry.value_ptr.* = .{};
    try entry.value_ptr.add(allocator, mode, index);
}

fn appendUri(
    map: *std.StringHashMapUnmanaged(ModeBucket),
    allocator: std.mem.Allocator,
    uri: []const u8,
    index: u32,
    mode: ?[]const u8,
) !void {
    const entry = try map.getOrPut(allocator, uri);
    if (!entry.found_existing) entry.value_ptr.* = .{};
    try entry.value_ptr.add(allocator, mode, index);
}

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
    /// Membership for plain node references, which is what `xsl:number`
    /// count/from patterns produce. Bit tests avoid hashing every candidate.
    bits: std.DynamicBitSetUnmanaged = .{},
};

const NamePositions = struct {
    map: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(u32)) = .empty,
};

/// Whether a selector entry contains only plain node references.
fn entryAllNodes(entry: *const SelectorEntry) bool {
    return entry.map.count() == 0;
}

fn lowerBoundNodeId(nodes: []const xpath.NodeRef, id: u32) usize {
    var lo: usize = 0;
    var hi: usize = nodes.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (nodes[mid].node < id) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

fn upperBoundNodeId(nodes: []const xpath.NodeRef, id: u32) usize {
    var lo: usize = 0;
    var hi: usize = nodes.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (nodes[mid].node <= id) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

fn lowerBoundU32(ids: []const u32, id: u32) usize {
    var lo: usize = 0;
    var hi: usize = ids.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (ids[mid] < id) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

fn upperBoundU32(ids: []const u32, id: u32) usize {
    var lo: usize = 0;
    var hi: usize = ids.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (ids[mid] <= id) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

/// Build the key used by `NamePositions` for one node, or null when the
/// expanded name does not fit the stack buffer.
fn nodeNameKey(
    document: *const dom.Document,
    node: *const dom.Node,
    buffer: []u8,
) ?[]const u8 {
    var length: usize = 0;
    switch (node.kind) {
        .document => {
            buffer[0] = 'd';
            length = 1;
        },
        .element => {
            buffer[0] = 'e';
            const uri = document.ns(node.ns);
            const total = 1 + uri.len + 1 + node.localName().len;
            if (total > buffer.len) return null;
            @memcpy(buffer[1..][0..uri.len], uri);
            length = 1 + uri.len;
            buffer[length] = 0;
            length += 1;
            @memcpy(buffer[length..][0..node.localName().len], node.localName());
            length += node.localName().len;
        },
        .text => {
            buffer[0] = 't';
            length = 1;
        },
        .comment => {
            buffer[0] = 'c';
            length = 1;
        },
        .processing_instruction => {
            buffer[0] = 'p';
            if (1 + node.name.len > buffer.len) return null;
            @memcpy(buffer[1..][0..node.name.len], node.name);
            length = 1 + node.name.len;
        },
    }
    return buffer[0..length];
}

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
    /// Fixed-capacity variable stack. Storage never moves, so evaluation
    /// contexts keep valid slices while nested templates append bindings.
    variables: []xpath.Variable = &.{},
    variable_len: usize = 0,
    /// Index of the first variable visible to the current template. Called
    /// templates and functions hide the caller's locals by raising the floor
    /// instead of copying them out.
    variable_floor: usize = 0,
    /// Value produced by the most recent EXSLT `func:result`.
    function_result: ?xpath.Value = null,
    /// Lazy global variable evaluation state.
    globals: []const compile.Variable = &.{},
    global_values: []?xpath.Value = &.{},
    global_states: []u8 = &.{},
    supplied_parameters: []const xpath.Variable = &.{},
    template_states: []TemplateState = &.{},
    template_index: TemplateIndex,
    /// Cached child dispatch for the common simple-only index; invalidated
    /// when `template_index.version` changes.
    simple_child_dispatch: SimpleChildDispatch = .{},
    simple_child_dispatch_version: u32 = std.math.maxInt(u32),
    /// Lone rules that match every child node or every attribute, cached for
    /// constant-time template lookup; invalidated with the index version.
    lone_child_template: ?*const compile.Template = null,
    lone_attribute_template: ?*const compile.Template = null,
    /// The `xsl:copy` instruction when the lone child rule is exactly the
    /// standard identity body, which needs no template bookkeeping.
    lone_child_copy: ?compile.Copy = null,
    lone_template_version: u32 = std.math.maxInt(u32),
    /// Winning template for each `xsl:template name`, keyed by name.
    named_templates: std.StringHashMapUnmanaged(
        *const compile.Template,
    ) = .empty,
    /// Global variable index by name.
    global_index: std.StringHashMapUnmanaged(usize) = .empty,
    /// Attribute sets by expanded name, in declaration order.
    attribute_set_index: NameListMap = .empty,
    /// Per-document node ids grouped by kind and name for `xsl:number`.
    name_positions: std.AutoHashMapUnmanaged(usize, NamePositions) = .empty,
    /// Pattern matchers for `xsl:number` count/from selectors that do not
    /// need a document-wide node set.
    selector_matchers: std.AutoHashMap(
        *const xpath_ast.Expr,
        ?PatternMatcher,
    ),
    last_matcher_expr: ?*const xpath_ast.Expr = null,
    last_matcher: ?PatternMatcher = null,
    /// Results of absolute `//name` selections, which depend only on the
    /// document and the expanded name.
    descendant_cache: xpath.DescendantCache = .empty,
    /// Documents whose template matches have been indexed, keyed by the
    /// merged document-root node id.
    built_match_roots: std.AutoHashMapUnmanaged(usize, void) = .empty,
    /// True once the main source document's non-simple match patterns have
    /// been indexed. Loaded documents use `built_match_roots`.
    source_matches_built: bool = false,
    /// Documents whose keys have been indexed, keyed by root node id.
    built_key_roots: std.AutoHashMapUnmanaged(usize, void) = .empty,
    /// Indexed `id()` values per document: token -> element node ids.
    id_index: std.StringHashMapUnmanaged(TemplateList) = .empty,
    built_id_roots: std.AutoHashMapUnmanaged(usize, void) = .empty,
    /// DTD-declared ID attribute names grouped by element name.
    id_attributes: ?std.StringHashMapUnmanaged(
        std.ArrayListUnmanaged([]const u8),
    ) = null,
    messages: std.ArrayList([]const u8) = .empty,
    key_map: KeyMap,
    node_ids: NodeIdMap,
    next_node_id: usize = 0,
    selector_cache: std.AutoHashMap(*const xpath_ast.Expr, *SelectorEntry),
    /// Most recently used selector entry; `xsl:number` queries the same
    /// selector for many consecutive nodes.
    last_selector: ?*const xpath_ast.Expr = null,
    last_selector_entry: ?*SelectorEntry = null,
    last_selector_cacheable: bool = false,
    /// Whether each cached selector expression references a variable.
    /// Selectors without variable references are safe to cache across
    /// template invocations.
    selector_var_usage: std.AutoHashMap(*const xpath_ast.Expr, bool),
    /// Last matching `xsl:strip-space`/`xsl:preserve-space` declaration per
    /// element name, namespace wildcard, and global wildcard.
    space_exact: std.HashMapUnmanaged(
        NameKey,
        SpaceRuleEntry,
        NameKeyContext,
        80,
    ) = .empty,
    space_by_uri: std.StringHashMapUnmanaged(SpaceRuleEntry) = .empty,
    space_any: ?SpaceRuleEntry = null,
    keys_ready: bool = false,
    /// Growable view of the source document plus documents loaded by
    /// `document()`.
    merged: ?*dom.Document = null,
    source_node_count: usize = 0,
    merged_nodes: std.ArrayList(dom.Node) = .empty,
    merged_attributes: std.ArrayList(dom.Attribute) = .empty,
    /// Namespace table for the merged view: the source table followed by the
    /// tables of documents loaded through `document()`.
    merged_namespaces: std.ArrayListUnmanaged([]const u8) = .empty,
    loaded_documents: std.ArrayList(*dom.Document) = .empty,
    document_cache: std.StringHashMap(dom.NodeId),
    /// Merged document-node ids for documents loaded by `document()`.
    document_roots: std.ArrayList(dom.NodeId) = .empty,
    resolver: ?compile.Resolver = null,
    base_uri: []const u8 = "",
    suppress_refresh: bool = false,
    refresh_depth: usize = 0,
    filtered_source: ?*dom.Document = null,
    fragment_documents: std.ArrayList(*dom.Document) = .empty,
    current_template: ?*const compile.Template = null,
    current_mode: ?[]const u8 = null,
    /// Source node whose copy is the current result parent. When a child of
    /// that node is copied, its inherited namespaces are already in scope in
    /// the result tree.
    copy_source: dom.NodeId = dom.null_node,
    now: ?[]const u8 = null,
    /// True when any document in the view declares a namespace, allowing the
    /// copy instructions to skip in-scope namespace collection.
    source_has_namespaces: bool = false,

    fn copyOutput(self: *Runtime) Error!compile.Output {
        var output = self.stylesheet.output;
        if (output.version) |version| {
            output.version = try self.allocator.dupe(u8, version);
        }
        output.encoding = try self.allocator.dupe(u8, output.encoding);
        if (output.doctype_public) |value| {
            output.doctype_public = try self.allocator.dupe(u8, value);
        }
        if (output.doctype_system) |value| {
            output.doctype_system = try self.allocator.dupe(u8, value);
        }
        if (output.cdata_elements.len != 0) {
            const names = try self.allocator.alloc(
                writer_mod.ExpandedName,
                output.cdata_elements.len,
            );
            for (output.cdata_elements, 0..) |name, index| {
                names[index] = .{
                    .uri = try self.allocator.dupe(u8, name.uri),
                    .local = try self.allocator.dupe(u8, name.local),
                };
            }
            output.cdata_elements = names;
        }
        return output;
    }

    fn prepareSource(self: *Runtime) Error!void {
        if (self.stylesheet.space_rules.len == 0) return;
        self.filtered_source = try self.buildFilteredDocument();
        self.source = self.filtered_source.?;
    }

    /// Copy the source tree with whitespace-only text nodes removed where the
    /// stylesheet strip rules apply. Only the node and attribute arrays are
    /// allocated: names and values are shared with the source document, which
    /// outlives the transformation.
    fn buildFilteredDocument(self: *Runtime) Error!*dom.Document {
        const document = try self.allocator.create(dom.Document);
        document.* = .{
            .arena = std.heap.ArenaAllocator.init(self.allocator),
            .namespaces = self.source.namespaces,
            .nodes = &.{},
            .attributes = &.{},
        };
        errdefer document.arena.deinit();
        const allocator = document.arena.allocator();
        var nodes: std.ArrayList(dom.Node) = .empty;
        var attributes: std.ArrayList(dom.Attribute) = .empty;
        try nodes.ensureTotalCapacity(allocator, self.source.nodes.len);
        try attributes.ensureTotalCapacity(
            allocator,
            self.source.attributes.len,
        );
        _ = try self.copyFilteredNode(
            allocator,
            &nodes,
            &attributes,
            self.source.documentNode(),
            dom.null_node,
        );
        // The reserved capacity stays with the arrays; the document only
        // uses the length, and the arena releases the whole buffer.
        document.nodes = nodes.items;
        document.attributes = attributes.items;
        // The filtered tree still describes the same document, so keep the
        // DTD view: id() needs DTD-declared ID attributes.
        document.dtd = self.source.dtd;
        document.declaration = self.source.declaration;
        document.doctype = self.source.doctype;
        return document;
    }

    fn deinitFilteredSource(self: *Runtime) void {
        if (self.filtered_source) |document| {
            document.deinit();
            self.filtered_source = null;
        }
    }

    /// Build the growable document view used by the transformation. Source
    /// node ids are preserved so references created before a `document()`
    /// call remain valid.
    fn prepareMergedSource(self: *Runtime) Error!void {
        // Start by aliasing the source arrays: documents loaded through
        // `document()` are rare, so the merged copy is made on first use.
        // The merged Document stays stable so evaluation contexts keep a
        // valid pointer while its arrays grow.
        self.source_node_count = self.source.nodes.len;
        const document = try self.allocator.create(dom.Document);
        document.* = .{
            .arena = std.heap.ArenaAllocator.init(self.allocator),
            .namespaces = self.source.namespaces,
            .nodes = self.source.nodes,
            .attributes = self.source.attributes,
            .declaration = self.source.declaration,
            .doctype = self.source.doctype,
            .dtd = self.source.dtd,
        };
        self.merged = document;
        self.source = document;
    }

    fn deinitMergedSource(self: *Runtime) void {
        if (self.merged) |document| {
            document.arena.deinit();
            self.merged = null;
        }
    }

    fn deinitLoadedDocuments(self: *Runtime) void {
        for (self.loaded_documents.items) |document| document.deinit();
        self.loaded_documents.clearRetainingCapacity();
    }

    /// Intern a namespace URI in the merged view's table.
    fn internMergedNamespace(self: *Runtime, uri: []const u8) Error!dom.NamespaceId {
        if (uri.len == 0) return 0;
        for (self.merged_namespaces.items, 0..) |existing, index| {
            if (std.mem.eql(u8, existing, uri)) return @intCast(index);
        }
        try self.merged_namespaces.append(self.allocator, uri);
        return @intCast(self.merged_namespaces.items.len - 1);
    }

    /// Append a document's nodes to the merged view and return the id of its
    /// document node.
    fn appendDocumentNodes(
        self: *Runtime,
        document: *const dom.Document,
    ) Error!dom.NodeId {
        if (self.merged_nodes.items.len == 0) {
            try self.merged_nodes.appendSlice(
                self.allocator,
                self.source.nodes,
            );
            try self.merged_attributes.appendSlice(
                self.allocator,
                self.source.attributes,
            );
            try self.merged_namespaces.appendSlice(
                self.allocator,
                self.source.namespaces,
            );
        }
        // Namespace ids are document-relative, so map the loaded document's
        // table into the merged one before copying its records.
        const ns_map = try self.allocator.alloc(
            dom.NamespaceId,
            document.namespaces.len,
        );
        defer self.allocator.free(ns_map);
        for (document.namespaces, 0..) |uri, index| {
            ns_map[index] = try self.internMergedNamespace(uri);
        }
        const node_offset: dom.NodeId = @intCast(self.merged_nodes.items.len);
        const attr_offset: u32 = @intCast(self.merged_attributes.items.len);
        try self.merged_nodes.ensureUnusedCapacity(
            self.allocator,
            document.nodes.len,
        );
        for (document.nodes) |node| {
            var copy = node;
            if (copy.parent != dom.null_node) copy.parent += node_offset;
            if (copy.first_child != dom.null_node) copy.first_child += node_offset;
            if (copy.last_child != dom.null_node) copy.last_child += node_offset;
            if (copy.next_sibling != dom.null_node) {
                copy.next_sibling += node_offset;
            }
            if (copy.attr_count != 0) copy.attr_start += attr_offset;
            copy.ns = ns_map[copy.ns];
            self.merged_nodes.appendAssumeCapacity(copy);
        }
        try self.merged_attributes.ensureUnusedCapacity(
            self.allocator,
            document.attributes.len,
        );
        for (document.attributes) |attribute| {
            var copy = attribute;
            copy.ns = ns_map[copy.ns];
            self.merged_attributes.appendAssumeCapacity(copy);
        }
        if (!self.source_has_namespaces and documentHasNamespaces(document)) {
            self.source_has_namespaces = true;
        }
        if (self.merged) |merged| {
            merged.nodes = self.merged_nodes.items;
            merged.attributes = self.merged_attributes.items;
            merged.namespaces = self.merged_namespaces.items;
        }
        try self.document_roots.append(self.allocator, node_offset);
        return node_offset;
    }

    /// Node-id range of the document containing `node`.
    fn documentRange(
        self: *Runtime,
        node: xpath.NodeRef,
    ) xpath_value.NodeRange {
        const id: usize = refNodeId(node);
        if (id < self.source_node_count or
            self.merged_nodes.items.len == 0)
        {
            return .{ .start = 0, .end = self.source_node_count };
        }
        var start = self.source_node_count;
        for (self.document_roots.items) |root| {
            const root_id: usize = root;
            if (root_id <= id and root_id >= start) start = root_id;
        }
        var end = self.merged_nodes.items.len;
        for (self.document_roots.items) |root| {
            const root_id: usize = root;
            if (root_id > start and root_id < end) end = root_id;
        }
        return .{ .start = start, .end = end };
    }

    fn loadDocument(
        self: *Runtime,
        allocator: std.mem.Allocator,
        href: []const u8,
        base: []const u8,
    ) xpath_value.DocumentError![]const xpath.NodeRef {
        // `document()` accepts an XPointer fragment; the document itself is
        // cached without it.
        var document_href = href;
        var fragment: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, href, '#')) |index| {
            document_href = href[0..index];
            fragment = href[index + 1 ..];
        }
        const absolute = if (document_href.len == 0)
            ""
        else if (base.len != 0)
            xmlbase.resolve(self.allocator, base, document_href) catch
                return error.OutOfMemory
        else
            try self.allocator.dupe(u8, document_href);
        if (self.document_cache.get(absolute)) |root| {
            return self.documentNodes(allocator, root, fragment);
        }
        const document = if (document_href.len == 0)
            self.stylesheet.principal
        else blk: {
            const resolver = self.resolver orelse return error.LoadFailed;
            const resource = resolver.load(
                resolver.context,
                document_href,
                if (base.len != 0) base else self.base_uri,
            ) orelse return error.LoadFailed;
            const owned = try self.allocator.dupe(u8, resource.data);
            const decoded = encoding.decodeAlloc(
                self.allocator,
                owned,
                64 * 1024 * 1024,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.LoadFailed,
            };
            // Loaded documents resolve their own external DTD subsets and
            // parsed entities through the same resolver.
            var parse_context: ParseExternal = .{
                .runtime = self,
                .base = resource.uri,
            };
            const pointer = try self.allocator.create(dom.Document);
            pointer.* = dom.Document.parse(
                self.allocator,
                decoded,
                .{
                    .keep_comments = true,
                    .keep_pis = true,
                    .parser = .{
                        .namespaces = true,
                        .allocator = self.allocator,
                        .resolver = .{
                            .context = &parse_context,
                            .resolve = resolveExternalEntity,
                        },
                    },
                },
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.LoadFailed,
            };
            try self.loaded_documents.append(self.allocator, pointer);
            break :blk pointer;
        };
        const root = self.appendDocumentNodes(document) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.LoadFailed,
        };
        const key = try self.allocator.dupe(u8, absolute);
        try self.document_cache.put(key, root);
        self.refreshAfterDocumentLoad() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.LoadFailed,
        };
        return self.documentNodes(allocator, root, fragment);
    }

    fn documentNodes(
        self: *Runtime,
        allocator: std.mem.Allocator,
        root: dom.NodeId,
        fragment: ?[]const u8,
    ) xpath_value.DocumentError![]const xpath.NodeRef {
        const text = fragment orelse {
            const nodes = try allocator.alloc(xpath.NodeRef, 1);
            nodes[0] = .{ .node = root };
            return nodes;
        };
        return self.selectDocumentFragment(allocator, root, text);
    }

    /// Evaluate the XPointer schemes supported by `document()`: `xpointer()`
    /// with an XPath expression and `element()`/bare xml:id lookups.
    fn selectDocumentFragment(
        self: *Runtime,
        allocator: std.mem.Allocator,
        root: dom.NodeId,
        fragment: []const u8,
    ) xpath_value.DocumentError![]const xpath.NodeRef {
        const trimmed = std.mem.trim(u8, fragment, " \t\r\n");
        if (std.mem.startsWith(u8, trimmed, "xpointer(") and
            trimmed.len > "xpointer()".len and
            trimmed[trimmed.len - 1] == ')')
        {
            return self.evaluateXPointer(
                allocator,
                root,
                trimmed["xpointer(".len .. trimmed.len - 1],
            );
        }
        if (std.mem.startsWith(u8, trimmed, "element(") and
            trimmed.len > "element()".len and
            trimmed[trimmed.len - 1] == ')')
        {
            const content = std.mem.trim(
                u8,
                trimmed["element(".len .. trimmed.len - 1],
                " \t\r\n",
            );
            if (content.len != 0 and content[0] == '/') {
                return error.LoadFailed;
            }
            return self.selectDocumentElementId(allocator, root, content);
        }
        return self.selectDocumentElementId(allocator, root, trimmed);
    }

    fn evaluateXPointer(
        self: *Runtime,
        allocator: std.mem.Allocator,
        root: dom.NodeId,
        expression_text: []const u8,
    ) xpath_value.DocumentError![]const xpath.NodeRef {
        var parser = xpath_parser.Parser.init(
            self.allocator,
            expression_text,
        ) catch return error.LoadFailed;
        const expression = parser.parse() catch return error.LoadFailed;
        const root_ref: xpath.NodeRef = .{ .node = root };
        var context: xpath.Context = .{
            .document = self.source,
            .node = root_ref,
            .current = root_ref,
            .position = 1,
            .size = 1,
            .namespaces = &.{},
            .variables = &.{},
            .document_range = self.documentRange(root_ref),
            .id_resolver = .{
                .context = self,
                .lookup = lookupId,
            },
            .xslt_functions = true,
            .descendant_cache = &self.descendant_cache,
            .current_date_time = self.now,
            .document_base = self.base_uri,
        };
        const result = xpath_eval.evaluateDirect(
            self.allocator,
            expression,
            &context,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.LoadFailed,
        };
        return switch (result) {
            .node_set => |nodes| blk: {
                const out = try allocator.alloc(xpath.NodeRef, nodes.len);
                @memcpy(out, nodes);
                break :blk out;
            },
            else => error.LoadFailed,
        };
    }

    fn selectDocumentElementId(
        self: *Runtime,
        allocator: std.mem.Allocator,
        root: dom.NodeId,
        id: []const u8,
    ) xpath_value.DocumentError![]const xpath.NodeRef {
        if (id.len == 0) return error.LoadFailed;
        const range = self.documentRange(.{ .node = root });
        const end = @min(range.end, self.merged_nodes.items.len);
        var index = range.start;
        while (index < end) : (index += 1) {
            if (self.merged_nodes.items[index].kind != .element) continue;
            const node_id: dom.NodeId = @intCast(index);
            const value = self.source.attributeNs(
                node_id,
                namespace.xml_uri,
                "id",
            ) orelse continue;
            if (!xmlbase.xmlIdEquals(value, id)) continue;
            const nodes = try allocator.alloc(xpath.NodeRef, 1);
            nodes[0] = .{ .node = node_id };
            return nodes;
        }
        return error.LoadFailed;
    }

    /// Invalidate document-wide caches after `document()` merges a new
    /// document. Template matches and keys for the new document are indexed
    /// lazily the first time a node from it is used, so a large lookup table
    /// that is never transformed costs nothing.
    fn refreshAfterDocumentLoad(self: *Runtime) Error!void {
        if (self.suppress_refresh or self.refresh_depth != 0) return;
        self.refresh_depth += 1;
        defer self.refresh_depth -= 1;
        self.selector_cache.clearRetainingCapacity();
        self.last_selector = null;
        self.last_selector_entry = null;
        self.last_selector_cacheable = false;
    }

    /// Copy one node and its subtree into the filtered arrays, returning the
    /// new node id. Whitespace-only text children of elements covered by a
    /// strip rule are skipped.
    fn copyFilteredNode(
        self: *Runtime,
        allocator: std.mem.Allocator,
        nodes: *std.ArrayList(dom.Node),
        attributes: *std.ArrayList(dom.Attribute),
        id: dom.NodeId,
        parent: dom.NodeId,
    ) Error!dom.NodeId {
        const source = self.source.node(id);
        const new_id: dom.NodeId = @intCast(nodes.items.len);
        var node = source.*;
        node.parent = parent;
        node.first_child = dom.null_node;
        node.last_child = dom.null_node;
        node.next_sibling = dom.null_node;
        node.attr_start = 0;
        node.attr_count = 0;
        if (source.kind == .element) {
            const list = self.source.attributesOf(id);
            node.attr_start = @intCast(attributes.items.len);
            node.attr_count = @intCast(list.len);
            try attributes.appendSlice(allocator, list);
        }
        try nodes.append(allocator, node);
        if (source.kind != .document and source.kind != .element) {
            return new_id;
        }
        const strip = source.kind == .element and
            self.shouldStrip(self.source.ns(source.ns), source.localName());
        var child = source.first_child;
        var last: dom.NodeId = dom.null_node;
        while (child != dom.null_node) : (child = self.source.node(child).next_sibling) {
            const child_node = self.source.node(child);
            if (strip and child_node.kind == .text and
                isWhitespaceText(child_node.value))
            {
                continue;
            }
            const new_child = try self.copyFilteredNode(
                allocator,
                nodes,
                attributes,
                child,
                new_id,
            );
            if (last == dom.null_node) {
                nodes.items[new_id].first_child = new_child;
            } else {
                nodes.items[last].next_sibling = new_child;
            }
            nodes.items[new_id].last_child = new_child;
            last = new_child;
        }
        return new_id;
    }

    fn buildSpaceRuleIndex(self: *Runtime) Error!void {
        for (self.stylesheet.space_rules, 0..) |rule, index| {
            const entry: SpaceRuleEntry = .{ .index = index, .strip = rule.strip };
            if (rule.any) {
                self.space_any = entry;
            } else if (rule.namespace_uri) |uri| {
                if (rule.local) |local| {
                    try self.space_exact.put(self.allocator, .{
                        .uri = uri,
                        .local = local,
                    }, entry);
                } else {
                    try self.space_by_uri.put(self.allocator, uri, entry);
                }
            }
        }
    }

    fn shouldStrip(
        self: *Runtime,
        namespace_uri: []const u8,
        local: []const u8,
    ) bool {
        // The last matching declaration wins (imports are compiled first).
        var winner: ?SpaceRuleEntry = null;
        if (self.space_exact.get(.{
            .uri = namespace_uri,
            .local = local,
        })) |entry| {
            winner = entry;
        }
        if (self.space_by_uri.get(namespace_uri)) |entry| {
            if (winner == null or entry.index > winner.?.index) {
                winner = entry;
            }
        }
        if (self.space_any) |entry| {
            if (winner == null or entry.index > winner.?.index) {
                winner = entry;
            }
        }
        return if (winner) |entry| entry.strip else false;
    }

    fn buildKeys(self: *Runtime) Error!void {
        self.keys_ready = false;
        try self.buildKeysForDocument(.{ .node = 0 });
        self.keys_ready = true;
    }

    /// Index the key definitions against one document. Keys are scoped to
    /// the document of the node passed to `key()`, so documents loaded by
    /// `document()` can be indexed on first use.
    fn buildKeysForDocument(
        self: *Runtime,
        root: xpath.NodeRef,
    ) Error!void {
        const root_id: usize = @intCast(refNodeId(root));
        if (self.built_key_roots.contains(root_id)) return;
        try self.built_key_roots.put(self.allocator, root_id, {});
        for (self.stylesheet.keys) |*key_def| {
            const selector = if (root_id == 0)
                key_def.selector
            else
                try relativePattern(self.allocator, key_def.selector);
            try self.collectKeyNodes(key_def, selector, root);
        }
        self.sortKeyLists();
    }

    /// Build the `id()` index for one document. `id()` is heavily used by
    /// cross-referencing stylesheets, so scanning every node and every DTD
    /// attribute declaration per call is far too slow.
    fn buildIdIndexForDocument(
        self: *Runtime,
        root: xpath.NodeRef,
    ) Error!void {
        const root_id: usize = @intCast(refNodeId(root));
        if (self.built_id_roots.contains(root_id)) return;
        try self.built_id_roots.put(self.allocator, root_id, {});
        try self.buildIdAttributes();
        const range = self.documentRange(root);
        const end = @min(range.end, self.source.nodes.len);
        var index = range.start;
        while (index < end) : (index += 1) {
            const node = self.source.node(@intCast(index));
            if (node.kind != .element) continue;
            const element: dom.NodeId = @intCast(index);
            if (self.id_attributes) |map| {
                if (map.get(node.name)) |names| {
                    for (names.items) |attribute_name| {
                        const value = self.source.attribute(
                            element,
                            attribute_name,
                        ) orelse continue;
                        try self.addIdEntry(value, element);
                    }
                }
            }
            if (self.source.attributeNs(
                element,
                namespace.xml_uri,
                "id",
            )) |raw| {
                var tokens = std.mem.tokenizeAny(u8, raw, " \t\r\n");
                const token = tokens.next() orelse continue;
                if (tokens.next() == null) {
                    try self.addIdEntry(token, element);
                }
            }
        }
    }

    fn buildIdAttributes(self: *Runtime) Error!void {
        if (self.id_attributes != null) return;
        var map: std.StringHashMapUnmanaged(
            std.ArrayListUnmanaged([]const u8),
        ) = .empty;
        if (self.source.dtd) |dtd| {
            for (dtd.attributes) |decl| {
                if (decl.attr_type != .id) continue;
                const entry = try map.getOrPut(self.allocator, decl.element);
                if (!entry.found_existing) entry.value_ptr.* = .empty;
                try entry.value_ptr.append(self.allocator, decl.name);
            }
        }
        self.id_attributes = map;
    }

    fn addIdEntry(
        self: *Runtime,
        token: []const u8,
        node: dom.NodeId,
    ) Error!void {
        const entry = try self.id_index.getOrPut(self.allocator, token);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        const list = entry.value_ptr;
        if (list.items.len == 0 or list.items[list.items.len - 1] != node) {
            try list.append(self.allocator, node);
        }
    }

    fn sortKeyLists(self: *Runtime) void {
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
    }

    fn collectKeyNodes(
        self: *Runtime,
        key_def: *const compile.KeyDef,
        selector: *const xpath_ast.Expr,
        node: xpath.NodeRef,
    ) Error!void {
        var context: xpath.Context = .{
            .document = self.source,
            .node = node,
            .namespaces = key_def.namespaces,
            .variables = self.variables[0..self.variable_len],
            .variable_floor = self.variable_floor,
            .document_range = self.documentRange(node),
            .key_resolver = if (self.keys_ready) .{
                .context = self,
                .lookup = lookupKey,
            } else null,
            .id_resolver = .{
                .context = self,
                .lookup = lookupId,
            },
            .xslt_functions = true,
            .descendant_cache = &self.descendant_cache,
            .current_date_time = self.now,
            .node_id_generator = .{
                .context = self,
                .generate = generateNodeId,
            },
            .document_resolver = .{
                .context = self,
                .resolve = resolveDocument,
            },
            .tree_converter = .{
                .context = self,
                .convert = convertTree,
            },
            .extension_functions = .{
                .context = self,
                .available = extensionFunctionAvailable,
                .call = callExtensionFunction,
            },
            .variable_resolver = .{
                .context = self,
                .resolve = resolveGlobalVariable,
            },
            .fragment_factory = .{
                .context = self,
                .build = buildFragmentNodes,
            },
            .document_base = self.base_uri,
        };
        const selected = xpath_eval.evaluateDirect(
            self.allocator,
            selector,
            &context,
        ) catch |err| return mapEvalError(err);
        const nodes = switch (selected) {
            .node_set => |value| value,
            else => return error.InvalidStylesheet,
        };
        for (nodes) |selected_node| {
            const value = try self.evalOwned(key_def.use, selected_node, 1, 1);
            switch (value) {
                .node_set => |value_nodes| {
                    for (value_nodes) |value_node| {
                        try self.addKeyValue(
                            key_def.name,
                            try self.stringValue(value_node),
                            selected_node,
                        );
                    }
                },
                else => {
                    try self.addKeyValue(
                        key_def.name,
                        try self.toString(value),
                        selected_node,
                    );
                },
            }
        }
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
            self.template_states[index] = .{ .template = template };
            if (template.name) |name| {
                const entry = try self.named_templates.getOrPut(
                    self.allocator,
                    name,
                );
                if (!entry.found_existing) {
                    entry.value_ptr.* = template;
                } else {
                    const current = entry.value_ptr.*;
                    if (template.precedence > current.precedence or
                        (template.precedence == current.precedence and
                            template.order > current.order))
                    {
                        entry.value_ptr.* = template;
                    }
                }
            }
            if (template.selector == null) continue;
            const matcher: PatternMatcher = if (simplePatternExpr(
                template.selector.?,
                template.namespaces,
            )) |pattern|
                .{ .simple = pattern }
            else if (try simpleUnionExpr(
                self.allocator,
                template.selector.?,
                template.namespaces,
            )) |patterns|
                .{ .simple_union = patterns }
            else if (try structuralPatternExpr(
                self.allocator,
                template.selector.?,
                template.namespaces,
            )) |pattern|
                .{ .structural = pattern }
            else
                continue;
            self.template_states[index].matcher = matcher;
            try self.template_index.addMatcher(
                @intCast(index),
                matcher,
                template.mode,
            );
        }
        try self.buildAttributeSetIndex();
        // The source document is indexed eagerly; documents loaded later by
        // `document()` are indexed on first use. Patterns that compile to a
        // structural chain are matched directly and never precomputed.
        try self.ensureDocumentMatches(.{ .node = 0 });
    }

    /// Index the nodes of the document containing `node`. Each non-simple
    /// match pattern is evaluated once per document rather than once per
    /// stylesheet, and only for documents that are actually transformed.
    fn ensureDocumentMatches(self: *Runtime, node: xpath.NodeRef) Error!void {
        const root: usize = @intCast(self.documentRange(node).start);
        if (root == 0) {
            if (self.source_matches_built) return;
            self.source_matches_built = true;
        } else {
            if (self.built_match_roots.contains(root)) return;
            try self.built_match_roots.put(self.allocator, root, {});
        }
        const root_ref: xpath.NodeRef = .{ .node = @intCast(root) };
        for (self.template_states, 0..) |state, index| {
            if (state.matcher != null) continue;
            const selector = state.template.selector orelse continue;
            const expression = if (root == 0)
                selector
            else
                try relativePattern(self.allocator, selector);
            try self.collectTemplateMatches(@intCast(index), expression, root_ref);
        }
    }

    fn collectTemplateMatches(
        self: *Runtime,
        index: usize,
        selector: *const xpath_ast.Expr,
        node: xpath.NodeRef,
    ) Error!void {
        var context: xpath.Context = .{
            .document = self.source,
            .node = node,
            .namespaces = self.template_states[index].template.namespaces,
            .variables = self.variables[0..self.variable_len],
            .variable_floor = self.variable_floor,
            .document_range = self.documentRange(node),
            .key_resolver = if (self.keys_ready) .{
                .context = self,
                .lookup = lookupKey,
            } else null,
            .id_resolver = .{
                .context = self,
                .lookup = lookupId,
            },
            .xslt_functions = true,
            .descendant_cache = &self.descendant_cache,
            .current_date_time = self.now,
            .node_id_generator = .{
                .context = self,
                .generate = generateNodeId,
            },
            .document_resolver = .{
                .context = self,
                .resolve = resolveDocument,
            },
            .tree_converter = .{
                .context = self,
                .convert = convertTree,
            },
            .extension_functions = .{
                .context = self,
                .available = extensionFunctionAvailable,
                .call = callExtensionFunction,
            },
            .variable_resolver = .{
                .context = self,
                .resolve = resolveGlobalVariable,
            },
            .fragment_factory = .{
                .context = self,
                .build = buildFragmentNodes,
            },
            .document_base = self.base_uri,
        };
        const result = xpath_eval.evaluateDirect(
            self.allocator,
            selector,
            &context,
        ) catch |err| return mapEvalError(err);
        switch (result) {
            .node_set => |nodes| {
                for (nodes) |ref| {
                    try self.template_index.addMatch(
                        nodeKey(ref),
                        @intCast(index),
                    );
                }
            },
            else => return error.InvalidStylesheet,
        }
    }

    fn evaluateGlobals(
        self: *Runtime,
        parameters: []const xpath.Variable,
    ) Error!void {
        self.globals = self.stylesheet.globals;
        for (self.globals, 0..) |global, index| {
            try self.global_index.put(self.allocator, global.name, index);
        }
        self.supplied_parameters = parameters;
        self.global_values = try self.allocator.alloc(
            ?xpath.Value,
            self.globals.len,
        );
        @memset(self.global_values, null);
        self.global_states = try self.allocator.alloc(u8, self.globals.len);
        @memset(self.global_states, 0);
        for (0..self.globals.len) |index| {
            _ = try self.ensureGlobal(index);
        }
    }

    /// Evaluate a global on demand so globals can reference each other in any
    /// order, including through templates applied from a global's body.
    fn ensureGlobal(self: *Runtime, index: usize) Error!xpath.Value {
        switch (self.global_states[index]) {
            2 => return self.global_values[index].?,
            1 => return error.InvalidStylesheet,
            else => {},
        }
        self.global_states[index] = 1;
        const global = self.globals[index];
        var supplied: ?xpath.Value = null;
        if (global.param) {
            for (self.supplied_parameters) |parameter| {
                if (std.mem.eql(u8, parameter.name, global.name)) {
                    supplied = parameter.value;
                    break;
                }
            }
        }
        var value: xpath.Value = undefined;
        if (supplied) |provided| {
            value = provided;
        } else {
            value = self.evaluateVariableValue(
                global.value,
                .{ .node = 0 },
                1,
                1,
            ) catch |err| {
                self.global_states[index] = 0;
                return err;
            };
        }
        self.global_values[index] = value;
        self.global_states[index] = 2;
        return value;
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

    fn pushVariable(self: *Runtime, variable: xpath.Variable) Error!void {
        if (self.variable_len == self.variables.len) {
            return error.InvalidStylesheet;
        }
        self.variables[self.variable_len] = variable;
        self.variable_len += 1;
    }

    fn evalOwned(
        self: *Runtime,
        expression: compile.CompiledExpr,
        node: xpath.NodeRef,
        position: usize,
        size: usize,
    ) Error!xpath.Value {
        if (try self.fastPathNodes(expression, node)) |nodes| {
            return .{ .node_set = nodes };
        }
        var context: xpath.Context = .{
            .document = self.source,
            .node = node,
            .current = node,
            .position = position,
            .size = size,
            .namespaces = expression.namespaces,
            .variables = self.variables[0..self.variable_len],
            .variable_floor = self.variable_floor,
            .document_range = self.documentRange(node),
            .key_resolver = if (self.keys_ready) .{
                .context = self,
                .lookup = lookupKey,
            } else null,
            .id_resolver = .{
                .context = self,
                .lookup = lookupId,
            },
            .number_formatter = .{
                .context = self,
                .format = formatNumberCallback,
            },
            .xslt_functions = true,
            .descendant_cache = &self.descendant_cache,
            .current_date_time = self.now,
            .node_id_generator = .{
                .context = self,
                .generate = generateNodeId,
            },
            .document_resolver = .{
                .context = self,
                .resolve = resolveDocument,
            },
            .tree_converter = .{
                .context = self,
                .convert = convertTree,
            },
            .extension_functions = .{
                .context = self,
                .available = extensionFunctionAvailable,
                .call = callExtensionFunction,
            },
            .variable_resolver = .{
                .context = self,
                .resolve = resolveGlobalVariable,
            },
            .fragment_factory = .{
                .context = self,
                .build = buildFragmentNodes,
            },
            .document_base = self.base_uri,
        };
        return xpath_eval.evaluateDirect(
            self.allocator,
            expression.node,
            &context,
        ) catch |err| return mapEvalError(err);
    }

    /// Evaluate a single-step child/attribute name test without the generic
    /// XPath step machinery. Returns null when the expression needs the full
    /// evaluator.
    fn fastPathNodes(
        self: *Runtime,
        expression: compile.CompiledExpr,
        node: xpath.NodeRef,
    ) Error!?[]const xpath.NodeRef {
        const path = switch (expression.node.*) {
            .path => |value| value,
            else => return null,
        };
        if (path.absolute or path.start != null or path.steps.len != 1) {
            return null;
        }
        const step = path.steps[0];
        if (step.predicates.len != 0) return null;
        // `.` is self::node(): the context node itself.
        if (step.axis == .self_axis) {
            if (step.node_test != .node) return null;
            const out = try self.allocator.alloc(xpath.NodeRef, 1);
            out[0] = node;
            const owned: ?[]const xpath.NodeRef = out;
            return owned;
        }
        // child::node() selects every child.
        if (step.axis == .child and step.node_test == .node) {
            const id = switch (node) {
                .node => |node_id| node_id,
                else => return &.{},
            };
            const value = self.source.node(id);
            if (value.kind != .document and value.kind != .element) {
                return &.{};
            }
            var count: usize = 0;
            var child = value.first_child;
            while (child != dom.null_node) : (child =
                self.source.node(child).next_sibling)
            {
                count += 1;
            }
            if (count == 0) return &.{};
            const out = try self.allocator.alloc(xpath.NodeRef, count);
            var write: usize = 0;
            child = value.first_child;
            while (child != dom.null_node) : (child =
                self.source.node(child).next_sibling)
            {
                out[write] = .{ .node = child };
                write += 1;
            }
            return out;
        }
        const name_test = switch (step.node_test) {
            .name => |value| value,
            else => return null,
        };
        var uri: []const u8 = "";
        if (name_test.prefix) |prefix| {
            uri = resolvePrefix(expression.namespaces, prefix) orelse
                return null;
        }
        if (step.axis == .attribute) {
            const element_id = switch (node) {
                .node => |id| id,
                else => return &.{},
            };
            if (self.source.node(element_id).kind != .element) return &.{};
            const check_namespace = name_test.prefix != null or
                name_test.local != null;
            const attributes = self.source.attributesOf(element_id);
            // Attribute names are unique, so a match is almost always a single
            // node. Collect a few matches on the stack and allocate exactly
            // instead of scanning the attribute list twice.
            var matches: [4]u32 = undefined;
            var count: usize = 0;
            var overflow = false;
            for (attributes, 0..) |attribute, index| {
                if (namespace.Resolver.isNamespaceDeclaration(attribute.name)) {
                    continue;
                }
                if (check_namespace and
                    !std.mem.eql(u8, self.source.ns(attribute.ns), uri))
                {
                    continue;
                }
                if (name_test.local) |local| {
                    if (!name_match.equal(attribute.localName(), local)) {
                        continue;
                    }
                }
                if (count == matches.len) {
                    overflow = true;
                    break;
                }
                matches[count] = @intCast(index);
                count += 1;
            }
            if (!overflow) {
                if (count == 0) return &.{};
                const out = try self.allocator.alloc(xpath.NodeRef, count);
                for (matches[0..count], 0..) |index, position| {
                    out[position] = .{ .attribute = .{
                        .element = element_id,
                        .index = index,
                    } };
                }
                return out;
            }
            // Rare: more matches than the stack buffer; rescan exactly.
            count = 0;
            for (attributes) |attribute| {
                if (namespace.Resolver.isNamespaceDeclaration(attribute.name)) {
                    continue;
                }
                if (check_namespace and
                    !std.mem.eql(u8, self.source.ns(attribute.ns), uri))
                {
                    continue;
                }
                if (name_test.local) |local| {
                    if (!name_match.equal(attribute.localName(), local)) {
                        continue;
                    }
                }
                count += 1;
            }
            if (count == 0) return &.{};
            const out = try self.allocator.alloc(xpath.NodeRef, count);
            var write: usize = 0;
            for (attributes, 0..) |attribute, index| {
                if (namespace.Resolver.isNamespaceDeclaration(attribute.name)) {
                    continue;
                }
                if (check_namespace and !std.mem.eql(u8, self.source.ns(attribute.ns), uri)) {
                    continue;
                }
                if (name_test.local) |local| {
                    if (!name_match.equal(attribute.localName(), local)) {
                        continue;
                    }
                }
                out[write] = .{ .attribute = .{
                    .element = element_id,
                    .index = @intCast(index),
                } };
                write += 1;
            }
            return out;
        }
        if (step.axis != .child) return null;
        const parent_id = switch (node) {
            .node => |id| id,
            else => return &.{},
        };
        const parent = self.source.node(parent_id);
        if (parent.kind != .element and parent.kind != .document) return &.{};
        const check_namespace = name_test.prefix != null or
            name_test.local != null;
        // Most child name selections match a single node; collect a few on
        // the stack and allocate exactly instead of scanning the children
        // twice.
        var matches: [4]xpath.NodeRef = undefined;
        var count: usize = 0;
        var overflow = false;
        var child = parent.first_child;
        while (child != dom.null_node) : (child = self.source.node(child).next_sibling) {
            const value = self.source.node(child);
            if (value.kind != .element) continue;
            if (check_namespace and !std.mem.eql(u8, self.source.ns(value.ns), uri)) continue;
            if (name_test.local) |local| {
                if (!name_match.equal(value.localName(), local)) continue;
            }
            if (count == matches.len) {
                overflow = true;
                break;
            }
            matches[count] = .{ .node = child };
            count += 1;
        }
        if (!overflow) {
            if (count == 0) return &.{};
            const out = try self.allocator.alloc(xpath.NodeRef, count);
            @memcpy(out, matches[0..count]);
            return out;
        }
        // Rare: more matches than the stack buffer; rescan exactly.
        count = 0;
        child = parent.first_child;
        while (child != dom.null_node) : (child = self.source.node(child).next_sibling) {
            const value = self.source.node(child);
            if (value.kind != .element) continue;
            if (check_namespace and !std.mem.eql(u8, self.source.ns(value.ns), uri)) continue;
            if (name_test.local) |local| {
                if (!name_match.equal(value.localName(), local)) continue;
            }
            count += 1;
        }
        if (count == 0) return &.{};
        const out = try self.allocator.alloc(xpath.NodeRef, count);
        var write: usize = 0;
        child = parent.first_child;
        while (child != dom.null_node) : (child = self.source.node(child).next_sibling) {
            const value = self.source.node(child);
            if (value.kind != .element) continue;
            if (check_namespace and !std.mem.eql(u8, self.source.ns(value.ns), uri)) continue;
            if (name_test.local) |local| {
                if (!name_match.equal(value.localName(), local)) continue;
            }
            out[write] = .{ .node = child };
            write += 1;
        }
        return out;
    }

    inline fn simpleMatches(
        self: *Runtime,
        pattern: SimplePattern,
        node: xpath.NodeRef,
    ) bool {
        return switch (pattern) {
            .element_any => switch (node) {
                .node => |id| self.source.node(id).kind == .element,
                else => false,
            },
            .element_name => |name| switch (node) {
                .node => |id| {
                    const value = self.source.node(id);
                    if (value.kind != .element) return false;
                    if (name.check_namespace and
                        !namespaceMatches(self.source.ns(value.ns), name.uri))
                    {
                        return false;
                    }
                    return if (name.local) |local|
                        name_match.equal(value.localName(), local)
                    else
                        true;
                },
                else => false,
            },
            .attribute_any => node == .attribute,
            .attribute_name => |name| switch (node) {
                .attribute => |attr| {
                    const value = self.source.attributesOf(attr.element)[attr.index];
                    if (name.check_namespace and
                        !namespaceMatches(self.source.ns(value.ns), name.uri))
                    {
                        return false;
                    }
                    return if (name.local) |local|
                        name_match.equal(value.localName(), local)
                    else
                        true;
                },
                else => false,
            },
            .text => switch (node) {
                .node => |id| self.source.node(id).kind == .text,
                else => false,
            },
            .comment => switch (node) {
                .node => |id| self.source.node(id).kind == .comment,
                else => false,
            },
            .processing_instruction => |target| switch (node) {
                .node => |id| {
                    const value = self.source.node(id);
                    if (value.kind != .processing_instruction) return false;
                    return if (target) |expected|
                        std.mem.eql(u8, value.name, expected)
                    else
                        true;
                },
                else => false,
            },
            .child_node => switch (node) {
                .node => |id| self.source.node(id).kind != .document,
                else => false,
            },
        };
    }

    fn simpleUnionMatches(
        self: *Runtime,
        patterns: []const SimplePattern,
        node: xpath.NodeRef,
    ) bool {
        for (patterns) |pattern| {
            if (self.simpleMatches(pattern, node)) return true;
        }
        return false;
    }

    /// Whether the matcher unconditionally accepts every non-document node,
    /// which lets a lone `node()` rule resolve in constant time.
    fn matcherAcceptsChildNodes(matcher: PatternMatcher) bool {
        switch (matcher) {
            .simple => |pattern| switch (pattern) {
                .child_node => return true,
                else => return false,
            },
            .simple_union => |patterns| {
                for (patterns) |pattern| switch (pattern) {
                    .child_node => return true,
                    else => {},
                };
                return false;
            },
            .structural => return false,
        }
    }

    /// Whether the matcher unconditionally accepts every attribute, which
    /// lets a lone `@*` rule resolve in constant time.
    fn matcherAcceptsAttributes(matcher: PatternMatcher) bool {
        switch (matcher) {
            .simple => |pattern| switch (pattern) {
                .attribute_any => return true,
                else => return false,
            },
            .simple_union => |patterns| {
                for (patterns) |pattern| switch (pattern) {
                    .attribute_any => return true,
                    else => {},
                };
                return false;
            },
            .structural => return false,
        }
    }

    /// The `xsl:copy` instruction when the template is exactly the standard
    /// identity body: no parameters, one copy, and a streaming identity
    /// select. Such a body references no variables and no apply-imports, so
    /// the copy can run without template bookkeeping.
    fn identityCopyOf(template: *const compile.Template) ?compile.Copy {
        if (template.params.len != 0 or template.body.len != 1) return null;
        const copy = switch (template.body[0]) {
            .copy => |value| value,
            else => return null,
        };
        if (copy.body.len != 1) return null;
        switch (copy.body[0]) {
            .apply_templates => |apply_instruction| {
                if (!apply_instruction.stream_identity or
                    apply_instruction.mode != null or
                    apply_instruction.params.len != 0)
                {
                    return null;
                }
            },
            else => return null,
        }
        return copy;
    }

    /// Recompute the cached lone rules when the template index changed.
    fn refreshLoneTemplates(self: *Runtime) void {
        if (self.lone_template_version == self.template_index.version) {
            return;
        }
        self.lone_template_version = self.template_index.version;
        self.lone_child_template = null;
        self.lone_attribute_template = null;
        self.lone_child_copy = null;
        const index = &self.template_index;
        if (index.nodes.count() != 0) return;
        if (index.element_any.default.items.len == 0 and
            index.elements.count() == 0 and
            index.elements_by_uri.count() == 0 and
            index.text.default.items.len == 0 and
            index.comment.default.items.len == 0 and
            index.processing_instruction.default.items.len == 0 and
            index.child_node.default.items.len == 1)
        {
            const state = &self.template_states[index.child_node.default.items[0]];
            if (state.matcher) |matcher| {
                if (matcherAcceptsChildNodes(matcher)) {
                    const template = state.template;
                    self.lone_child_template = template;
                    self.lone_child_copy = identityCopyOf(template);
                }
            }
        }
        if (index.attribute_any.default.items.len == 1 and
            index.attributes.count() == 0 and
            index.attributes_by_uri.count() == 0)
        {
            const state = &self.template_states[index.attribute_any.default.items[0]];
            if (state.matcher) |matcher| {
                if (matcherAcceptsAttributes(matcher)) {
                    self.lone_attribute_template = state.template;
                }
            }
        }
    }

    fn findTemplate(
        self: *Runtime,
        node: xpath.NodeRef,
        mode: ?[]const u8,
    ) Error!?*const compile.Template {
        return self.findTemplateWithLimit(node, mode, std.math.maxInt(usize));
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
            try self.applyTemplateNode(
                node,
                mode,
                params,
                index + 1,
                nodes.len,
            );
        }
    }

    fn applyTemplateNode(
        self: *Runtime,
        node: xpath.NodeRef,
        mode: ?[]const u8,
        params: []const xpath.Variable,
        position: usize,
        size: usize,
    ) Error!void {
        if (try self.findTemplate(node, mode)) |template| {
            try self.executeTemplate(template, node, position, size, params);
        } else {
            try self.builtinTemplate(node, mode, params);
        }
    }

    /// Per-kind dispatch derived from a simple-only template index. With no
    /// general-selector matches and no mode, a child can be resolved from
    /// these fields instead of running an index lookup per node.
    const SimpleChildDispatch = struct {
        active: bool = false,
        element: ?*const compile.Template = null,
        text: bool = false,
        comment: bool = false,
        processing_instruction: bool = false,
    };

    fn simpleChildDispatch(self: *Runtime) SimpleChildDispatch {
        if (self.simple_child_dispatch_version !=
            self.template_index.version)
        {
            self.simple_child_dispatch = self.computeSimpleChildDispatch();
            self.simple_child_dispatch_version = self.template_index.version;
        }
        return self.simple_child_dispatch;
    }

    fn computeSimpleChildDispatch(self: *Runtime) SimpleChildDispatch {
        const index = &self.template_index;
        if (index.nodes.count() != 0) return .{};
        const child_free = index.child_node.default.items.len == 0;
        var dispatch: SimpleChildDispatch = .{
            .active = true,
            .text = child_free and index.text.default.items.len == 0,
            .comment = child_free and index.comment.default.items.len == 0,
            .processing_instruction = child_free and
                index.processing_instruction.default.items.len == 0,
        };
        if (child_free and
            index.element_any.default.items.len == 1 and
            index.elements.count() == 0 and
            index.elements_by_uri.count() == 0)
        {
            const state = &self.template_states[index.element_any.default.items[0]];
            if (state.matcher) |matcher| {
                switch (matcher) {
                    .simple => |pattern| switch (pattern) {
                        .element_any => dispatch.element = state.template,
                        else => {},
                    },
                    .simple_union => {},
                    .structural => {},
                }
            }
        }
        return dispatch;
    }

    /// Apply templates to an element or document's children without
    /// materializing a node-set, which is the hot path for identity-style
    /// stylesheets.
    fn applyTemplateChildren(
        self: *Runtime,
        node: xpath.NodeRef,
        mode: ?[]const u8,
        params: []const xpath.Variable,
    ) Error!void {
        const id = switch (node) {
            .node => |value| value,
            .attribute, .namespace_node => return,
        };
        // Loaded documents are indexed on first use. The dispatch below is
        // only valid once the containing document's general-selector matches
        // are in the index, so do that here instead of per child.
        if (!self.source_matches_built or id >= self.source_node_count) {
            try self.ensureDocumentMatches(node);
        }
        const value = self.source.node(id);
        if (value.kind != .document and value.kind != .element) return;
        const dispatch: SimpleChildDispatch = if (mode == null)
            self.simpleChildDispatch()
        else
            .{};
        // Only `last()` reads the node-set size, so skip the counting walk
        // when the stylesheet never calls it.
        var size: usize = 0;
        if (self.stylesheet.uses_last) {
            var count_child = value.first_child;
            while (count_child != dom.null_node) : (count_child =
                self.source.node(count_child).next_sibling)
            {
                size += 1;
            }
        }
        const saved_mode = self.current_mode;
        self.current_mode = mode;
        defer self.current_mode = saved_mode;
        var position: usize = 0;
        var child = value.first_child;
        while (child != dom.null_node) {
            // Fetch the node once and advance first: the loop body would
            // otherwise reload it through `source.node` to find the sibling.
            const current = child;
            const child_value = self.source.node(current);
            child = child_value.next_sibling;
            position += 1;
            if (dispatch.active) {
                switch (child_value.kind) {
                    .element => if (dispatch.element) |template| {
                        try self.executeTemplate(
                            template,
                            .{ .node = current },
                            position,
                            size,
                            params,
                        );
                        continue;
                    },
                    .text => if (dispatch.text) {
                        try self.appendText(child_value.value);
                        continue;
                    },
                    .comment => if (dispatch.comment) continue,
                    .processing_instruction => if (dispatch.processing_instruction)
                        continue,
                    .document => {},
                }
            }
            try self.applyTemplateNode(
                .{ .node = current },
                mode,
                params,
                position,
                size,
            );
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
        // A called or applied template sees global variables and its own
        // parameters, never the caller's local bindings.
        const saved_variables = self.variable_len;
        const saved_floor = self.variable_floor;
        self.variable_floor = saved_variables;
        // A parameterless template whose whole body is one `xsl:copy` needs
        // no parameter binding and no body-level variable scope, so dispatch
        // straight to the copy instruction.
        if (template.params.len == 0 and template.body.len == 1) {
            switch (template.body[0]) {
                .copy => |copy| {
                    const result = self.executeCopy(
                        copy,
                        node,
                        position,
                        size,
                    );
                    self.variable_floor = saved_floor;
                    self.variable_len = saved_variables;
                    return result;
                },
                else => {},
            }
        }
        const result = self.runTemplateBody(
            template,
            node,
            position,
            size,
            params,
        );
        self.variable_floor = saved_floor;
        self.variable_len = saved_variables;
        return result;
    }

    fn runTemplateBody(
        self: *Runtime,
        template: *const compile.Template,
        node: xpath.NodeRef,
        position: usize,
        size: usize,
        params: []const xpath.Variable,
    ) Error!void {
        for (template.params) |param| {
            var supplied: ?xpath.Value = null;
            for (params) |candidate| {
                const same = (candidate.name.ptr == param.name.ptr and
                    candidate.name.len == param.name.len) or
                    std.mem.eql(u8, candidate.name, param.name);
                if (same) {
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
            try self.pushVariable(.{
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
        params: []const xpath.Variable,
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
                        // libxslt passes parameters through the built-in
                        // template rules (XSLT 2.0 behavior).
                        try self.applyTemplateChildren(node, mode, params);
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
        const mark = self.variable_len;
        defer self.variable_len = mark;
        for (body) |*instruction| {
            try self.executeInstruction(instruction, node, position, size);
        }
    }

    /// Literal result element bodies are dominated by text-producing
    /// instructions, so dispatch those directly and skip the large
    /// instruction switch for them.
    fn executeLiteralBody(
        self: *Runtime,
        body: []const compile.Instruction,
        node: xpath.NodeRef,
        position: usize,
        size: usize,
    ) Error!void {
        const mark = self.variable_len;
        defer self.variable_len = mark;
        for (body) |*instruction| {
            switch (instruction.*) {
                .literal_text => |text| try self.appendText(text),
                .text => |text| try self.appendText(text),
                .value_of => |value_of| try self.executeValueOf(
                    value_of,
                    node,
                    position,
                    size,
                ),
                else => try self.executeInstruction(
                    instruction,
                    node,
                    position,
                    size,
                ),
            }
        }
    }

    fn executeValueOf(
        self: *Runtime,
        value_of: compile.ValueOf,
        node: xpath.NodeRef,
        position: usize,
        size: usize,
    ) Error!void {
        // A single child name test is the common case; read its string value
        // directly instead of building a node set.
        if (try self.simpleChildString(value_of.select, node)) |text| {
            if (value_of.disable_output_escaping) {
                try self.appendTextRaw(text);
            } else {
                try self.appendText(text);
            }
            return;
        }
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
    }

    fn executeInstruction(
        self: *Runtime,
        instruction: *const compile.Instruction,
        node: xpath.NodeRef,
        position: usize,
        size: usize,
    ) Error!void {
        switch (instruction.*) {
            .literal_text => |text| try self.appendText(text),
            .text => |text| try self.appendText(text),
            .raw_text => |text| try self.appendTextRaw(text),
            .value_of => |value_of| try self.executeValueOf(
                value_of,
                node,
                position,
                size,
            ),
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
                try self.pushVariable(.{
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
                // Fast capture paths may return stylesheet- or source-owned
                // text; messages must live in the result arena.
                try self.messages.append(
                    self.allocator,
                    try self.allocator.dupe(u8, text),
                );
                if (message.terminate) return error.Terminated;
            },
            .apply_imports => |apply_imports| try self.executeApplyImports(
                apply_imports,
                node,
                position,
                size,
            ),
            .function_result => |result| {
                if (result.select) |select| {
                    self.function_result = try self.evalOwned(
                        select,
                        node,
                        position,
                        size,
                    );
                } else {
                    self.function_result = try self.captureTree(
                        result.body,
                        node,
                        position,
                        size,
                    );
                }
                return error.FunctionResultReturned;
            },
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
        if (try self.findTemplateBelow(
            node,
            self.current_mode,
            current.precedence,
        )) |template| {
            try self.executeTemplate(template, node, position, size, params);
        } else {
            // libxslt falls back to the built-in rules when no lower
            // precedence template matches.
            try self.builtinTemplate(node, self.current_mode, params);
        }
    }

    fn findTemplateBelow(
        self: *Runtime,
        node: xpath.NodeRef,
        mode: ?[]const u8,
        maximum_precedence: usize,
    ) Error!?*const compile.Template {
        return self.findTemplateWithLimit(node, mode, maximum_precedence);
    }

    /// Pick the best matching rule from the inverted index. Candidates come
    /// from the per-node match list and the node-kind buckets for simple
    /// patterns, so only rules that can match are compared.
    fn findTemplateWithLimit(
        self: *Runtime,
        node: xpath.NodeRef,
        mode: ?[]const u8,
        maximum_precedence: usize,
    ) Error!?*const compile.Template {
        // The source document is indexed before the first template lookup;
        // only nodes from lazily loaded documents need the range check.
        if (!self.source_matches_built or
            refNodeId(node) >= self.source_node_count)
        {
            try self.ensureDocumentMatches(node);
        }
        // Fast path for simple-only stylesheets: with no general-selector
        // matches and no mode, candidate lookup reduces to the per-kind
        // buckets. Text-like nodes without rules skip collection entirely,
        // and a lone unconditional element rule resolves in a few loads
        // instead of a full bucket scan.
        if (mode == null) {
            self.refreshLoneTemplates();
            switch (node) {
                .node => |id| if (self.source.node(id).kind != .document) {
                    if (self.lone_child_template) |template| {
                        if (template.precedence < maximum_precedence) {
                            return template;
                        }
                        return null;
                    }
                },
                .attribute => if (self.lone_attribute_template) |template| {
                    if (template.precedence < maximum_precedence) {
                        return template;
                    }
                    return null;
                },
                .namespace_node => {},
            }
        }
        if (mode == null and self.template_index.nodes.count() == 0) {
            const index = &self.template_index;
            switch (node) {
                .node => |id| switch (self.source.node(id).kind) {
                    .text => if (index.text.default.items.len == 0 and
                        index.child_node.default.items.len == 0)
                    {
                        return null;
                    },
                    .comment => if (index.comment.default.items.len == 0 and
                        index.child_node.default.items.len == 0)
                    {
                        return null;
                    },
                    .processing_instruction => if (index.processing_instruction.default.items.len == 0 and
                        index.child_node.default.items.len == 0)
                    {
                        return null;
                    },
                    .document => if (index.document_node.default.items.len == 0)
                        return null,
                    .element => {
                        if (index.element_any.default.items.len == 1 and
                            index.elements.count() == 0 and
                            index.elements_by_uri.count() == 0 and
                            index.child_node.default.items.len == 0)
                        {
                            const state = &self.template_states[index.element_any.default.items[0]];
                            if (state.matcher) |matcher| {
                                switch (matcher) {
                                    .simple => |pattern| switch (pattern) {
                                        .element_any => {
                                            const template = state.template;
                                            if (template.precedence < maximum_precedence) {
                                                return template;
                                            }
                                            return null;
                                        },
                                        else => {},
                                    },
                                    .simple_union => {},
                                    .structural => {},
                                }
                            }
                        }
                    },
                },
                .attribute => {},
                .namespace_node => {},
            }
        }
        var best: ?*const compile.Template = null;
        // Patterns that cannot be matched structurally are precomputed into
        // this map; most stylesheets have none, so skip the hash lookup.
        if (self.template_index.nodes.count() != 0) {
            if (self.template_index.nodes.get(nodeKey(node))) |candidates| {
                for (candidates.items) |index| {
                    const template = self.template_states[index].template;
                    if (template.precedence >= maximum_precedence) continue;
                    if (!modeMatches(template.mode, mode)) continue;
                    best = betterTemplate(best, template);
                }
            }
        }
        try self.collectCandidates(
            node,
            mode,
            maximum_precedence,
            &best,
        );
        return best;
    }

    fn collectCandidates(
        self: *Runtime,
        node: xpath.NodeRef,
        mode: ?[]const u8,
        maximum_precedence: usize,
        best: *?*const compile.Template,
    ) Error!void {
        const index = &self.template_index;
        switch (node) {
            .node => |id| {
                const value = self.source.node(id);
                switch (value.kind) {
                    .element => {
                        try self.addCandidates(
                            index.element_any.candidates(mode),
                            node,
                            maximum_precedence,
                            best,
                        );
                        if (index.elements.count() != 0) {
                            if (index.elements.get(.{
                                .uri = self.source.ns(value.ns),
                                .local = value.localName(),
                            })) |bucket| {
                                try self.addCandidates(
                                    bucket.candidates(mode),
                                    node,
                                    maximum_precedence,
                                    best,
                                );
                            }
                        }
                        if (index.elements_by_uri.count() != 0) {
                            if (index.elements_by_uri.get(self.source.ns(value.ns))) |bucket| {
                                try self.addCandidates(
                                    bucket.candidates(mode),
                                    node,
                                    maximum_precedence,
                                    best,
                                );
                            }
                        }
                        try self.addCandidates(
                            index.child_node.candidates(mode),
                            node,
                            maximum_precedence,
                            best,
                        );
                    },
                    .text => {
                        try self.addCandidates(
                            index.text.candidates(mode),
                            node,
                            maximum_precedence,
                            best,
                        );
                        try self.addCandidates(
                            index.child_node.candidates(mode),
                            node,
                            maximum_precedence,
                            best,
                        );
                    },
                    .comment => {
                        try self.addCandidates(
                            index.comment.candidates(mode),
                            node,
                            maximum_precedence,
                            best,
                        );
                        try self.addCandidates(
                            index.child_node.candidates(mode),
                            node,
                            maximum_precedence,
                            best,
                        );
                    },
                    .processing_instruction => {
                        try self.addCandidates(
                            index.processing_instruction.candidates(mode),
                            node,
                            maximum_precedence,
                            best,
                        );
                        try self.addCandidates(
                            index.child_node.candidates(mode),
                            node,
                            maximum_precedence,
                            best,
                        );
                    },
                    .document => {
                        try self.addCandidates(
                            index.document_node.candidates(mode),
                            node,
                            maximum_precedence,
                            best,
                        );
                    },
                }
            },
            .attribute => |attribute| {
                const name = self.source.attributesOf(
                    attribute.element,
                )[attribute.index];
                try self.addCandidates(
                    index.attribute_any.candidates(mode),
                    node,
                    maximum_precedence,
                    best,
                );
                if (index.attributes.count() != 0) {
                    if (index.attributes.get(.{
                        .uri = self.source.ns(name.ns),
                        .local = name.localName(),
                    })) |bucket| {
                        try self.addCandidates(
                            bucket.candidates(mode),
                            node,
                            maximum_precedence,
                            best,
                        );
                    }
                }
                if (index.attributes_by_uri.count() != 0) {
                    if (index.attributes_by_uri.get(self.source.ns(name.ns))) |bucket| {
                        try self.addCandidates(
                            bucket.candidates(mode),
                            node,
                            maximum_precedence,
                            best,
                        );
                    }
                }
            },
            .namespace_node => {},
        }
    }

    inline fn addCandidates(
        self: *Runtime,
        candidates: []const u32,
        node: xpath.NodeRef,
        maximum_precedence: usize,
        best: *?*const compile.Template,
    ) Error!void {
        for (candidates) |index| {
            const state = &self.template_states[index];
            const template = state.template;
            if (template.precedence >= maximum_precedence) continue;
            const matched = switch (state.matcher.?) {
                .simple => |pattern| self.simpleMatches(pattern, node),
                .simple_union => |patterns| self.simpleUnionMatches(
                    patterns,
                    node,
                ),
                .structural => |pattern| try self.structuralMatches(
                    pattern,
                    node,
                ),
            };
            if (!matched) continue;
            best.* = betterTemplate(best.*, template);
        }
    }

    /// Match a structural pattern by walking up from the candidate node.
    fn structuralMatches(
        self: *Runtime,
        pattern: StructuralPattern,
        node: xpath.NodeRef,
    ) Error!bool {
        for (pattern.alternatives) |steps| {
            if (steps.len == 0) {
                switch (node) {
                    .node => |id| if (self.source.node(id).kind == .document) {
                        return true;
                    },
                    else => {},
                }
                continue;
            }
            if (try self.matchStructuralStep(
                pattern,
                steps,
                steps.len - 1,
                node,
            )) {
                return true;
            }
        }
        return false;
    }

    /// Whether `node` is selected by `steps[index]` given that the prefix
    /// `steps[0..index]` selected its context.
    fn matchStructuralStep(
        self: *Runtime,
        pattern: StructuralPattern,
        steps: []const StructuralStep,
        index: usize,
        node: xpath.NodeRef,
    ) Error!bool {
        const step = steps[index];
        switch (step.axis) {
            .child => switch (node) {
                .node => {},
                else => return false,
            },
            .attribute => switch (node) {
                .attribute => {},
                else => return false,
            },
            else => return false,
        }
        if (!self.structuralTestMatches(step.node_test, node)) return false;
        if (step.axis == .attribute) {
            const element = node.attribute.element;
            return self.matchStructuralContext(
                pattern,
                steps,
                index,
                .{ .node = element },
            );
        }
        const parent = self.parentRef(node) orelse return false;
        if (!try self.matchStructuralContext(pattern, steps, index, parent)) {
            return false;
        }
        // The context chain is checked before the predicate so patterns like
        // `footnote/para[1]` only evaluate the predicate on real candidates.
        if (step.predicate) |predicate| {
            const bounds: StepBounds = if (predicateUsesPosition(predicate))
                self.childStepBounds(parent, step.node_test, node.node)
            else
                .{ .position = 1, .size = 1 };
            if (!try self.stepPredicateMatches(
                pattern,
                predicate,
                node,
                bounds.position,
                bounds.size,
            )) return false;
        }
        return true;
    }

    /// Whether `node` is selected by `steps[0..index]`. Index zero requires
    /// the initial context of an absolute path: the document root.
    fn matchStructuralContext(
        self: *Runtime,
        pattern: StructuralPattern,
        steps: []const StructuralStep,
        index: usize,
        node: xpath.NodeRef,
    ) Error!bool {
        if (index == 0) {
            return switch (node) {
                .node => |id| self.source.node(id).kind == .document,
                else => false,
            };
        }
        const step = steps[index - 1];
        if (step.axis == .descendant_or_self) {
            // A leading `//` accepts any node in the document.
            if (index == 1) return true;
            var current: ?xpath.NodeRef = node;
            while (current) |candidate| {
                if (try self.matchStructuralContext(
                    pattern,
                    steps,
                    index - 1,
                    candidate,
                )) {
                    return true;
                }
                current = self.parentRef(candidate);
            }
            return false;
        }
        return self.matchStructuralStep(pattern, steps, index - 1, node);
    }

    const StepBounds = struct {
        position: usize,
        size: usize,
    };

    /// Position of `node` and total node count among the children of
    /// `parent` selected by `node_test`, matching XPath step semantics.
    fn childStepBounds(
        self: *Runtime,
        parent: xpath.NodeRef,
        node_test: StructuralTest,
        node: dom.NodeId,
    ) StepBounds {
        const parent_id = switch (parent) {
            .node => |id| id,
            else => return .{ .position = 1, .size = 1 },
        };
        var bounds: StepBounds = .{ .position = 1, .size = 1 };
        var position: usize = 0;
        var size: usize = 0;
        var child = self.source.node(parent_id).first_child;
        while (child != dom.null_node) : (child = self.source.node(child).next_sibling) {
            if (!self.structuralTestMatches(node_test, .{ .node = child })) {
                continue;
            }
            size += 1;
            if (child == node) position = size;
        }
        if (position != 0) bounds = .{ .position = position, .size = size };
        return bounds;
    }

    /// Whether a predicate needs the step position, which is only computed
    /// for the predicates that can observe it.
    fn predicateUsesPosition(predicate: StepPredicate) bool {
        return switch (predicate) {
            .position_compare, .expression => true,
            else => false,
        };
    }

    /// Match a compiled step predicate against a candidate node.
    fn stepPredicateMatches(
        self: *Runtime,
        pattern: StructuralPattern,
        predicate: StepPredicate,
        node: xpath.NodeRef,
        position: usize,
        size: usize,
    ) Error!bool {
        switch (predicate) {
            .attribute_exists => |name| {
                return self.predicateAttribute(node, name) != null;
            },
            .attribute_absent => |name| {
                return self.predicateAttribute(node, name) == null;
            },
            .attribute_equals => |check| {
                const value = self.predicateAttribute(node, check.name) orelse
                    return false;
                return std.mem.eql(u8, value, check.value);
            },
            .attribute_not_equals => |check| {
                const value = self.predicateAttribute(node, check.name) orelse
                    return false;
                return !std.mem.eql(u8, value, check.value);
            },
            .child_exists => |name| return self.predicateChild(node, name),
            .child_absent => |name| return !self.predicateChild(node, name),
            .position_compare => |compare| {
                const lhs: f64 = @floatFromInt(position);
                const rhs: f64 = switch (compare.operand) {
                    .number => |value| value,
                    .last => @floatFromInt(size),
                };
                return switch (compare.op) {
                    .eq => lhs == rhs,
                    .ne => lhs != rhs,
                    .lt => lhs < rhs,
                    .le => lhs <= rhs,
                    .gt => lhs > rhs,
                    .ge => lhs >= rhs,
                    else => false,
                };
            },
            .expression => |expression| {
                return self.patternPredicateMatches(
                    pattern,
                    expression,
                    node,
                    position,
                    size,
                );
            },
        }
    }

    /// Value of the first attribute selected by `name` on an element node.
    fn predicateAttribute(
        self: *Runtime,
        node: xpath.NodeRef,
        name: NamePattern,
    ) ?[]const u8 {
        const id = switch (node) {
            .node => |value| value,
            else => return null,
        };
        if (self.source.node(id).kind != .element) return null;
        for (self.source.attributesOf(id)) |attribute| {
            if (namespace.Resolver.isNamespaceDeclaration(attribute.name)) {
                continue;
            }
            if (name.check_namespace and
                !namespaceMatches(self.source.ns(attribute.ns), name.uri)) continue;
            if (name.local) |local| {
                if (!name_match.equal(attribute.localName(), local)) continue;
            }
            return attribute.value;
        }
        return null;
    }

    /// Whether an element node has a child selected by `name`.
    fn predicateChild(
        self: *Runtime,
        node: xpath.NodeRef,
        name: NamePattern,
    ) bool {
        const id = switch (node) {
            .node => |value| value,
            else => return false,
        };
        const value = self.source.node(id);
        if (value.kind != .element) return false;
        var child = value.first_child;
        while (child != dom.null_node) : (child = self.source.node(child).next_sibling) {
            const child_value = self.source.node(child);
            if (child_value.kind != .element) continue;
            if (name.check_namespace and
                !namespaceMatches(self.source.ns(child_value.ns), name.uri)) continue;
            if (name.local) |local| {
                if (!name_match.equal(child_value.localName(), local)) continue;
            }
            return true;
        }
        return false;
    }

    /// Evaluate a step predicate against `node`, converted to a boolean with
    /// the XPath predicate rules (a numeric result compares to the position).
    fn patternPredicateMatches(
        self: *Runtime,
        pattern: StructuralPattern,
        predicate: *const xpath_ast.Expr,
        node: xpath.NodeRef,
        position: usize,
        size: usize,
    ) Error!bool {
        var context: xpath.Context = .{
            .document = self.source,
            .node = node,
            .position = position,
            .size = size,
            .namespaces = pattern.namespaces,
            .document_range = self.documentRange(node),
            .key_resolver = if (self.keys_ready) .{
                .context = self,
                .lookup = lookupKey,
            } else null,
            .id_resolver = .{
                .context = self,
                .lookup = lookupId,
            },
            .xslt_functions = true,
            .descendant_cache = &self.descendant_cache,
            .current_date_time = self.now,
            .node_id_generator = .{
                .context = self,
                .generate = generateNodeId,
            },
            .document_resolver = .{
                .context = self,
                .resolve = resolveDocument,
            },
            .tree_converter = .{
                .context = self,
                .convert = convertTree,
            },
            .extension_functions = .{
                .context = self,
                .available = extensionFunctionAvailable,
                .call = callExtensionFunction,
            },
            .variable_resolver = .{
                .context = self,
                .resolve = resolveGlobalVariable,
            },
            .fragment_factory = .{
                .context = self,
                .build = buildFragmentNodes,
            },
            .document_base = self.base_uri,
        };
        const result = xpath_eval.evaluateDirect(
            self.allocator,
            predicate,
            &context,
        ) catch |err| return mapEvalError(err);
        return switch (result) {
            .number => |value| value == @as(f64, @floatFromInt(position)),
            else => result.toBoolean(),
        };
    }

    fn structuralTestMatches(
        self: *Runtime,
        node_test: StructuralTest,
        node: xpath.NodeRef,
    ) bool {
        return switch (node_test) {
            .name => |name| switch (node) {
                .node => |id| {
                    const value = self.source.node(id);
                    if (value.kind != .element) return false;
                    if (name.check_namespace and
                        !namespaceMatches(self.source.ns(value.ns), name.uri))
                    {
                        return false;
                    }
                    return if (name.local) |local|
                        name_match.equal(value.localName(), local)
                    else
                        true;
                },
                .attribute => |attr| {
                    const value = self.source.attributesOf(
                        attr.element,
                    )[attr.index];
                    if (name.check_namespace and
                        !namespaceMatches(self.source.ns(value.ns), name.uri))
                    {
                        return false;
                    }
                    return if (name.local) |local|
                        name_match.equal(value.localName(), local)
                    else
                        true;
                },
                .namespace_node => false,
            },
            .node => true,
            .text => switch (node) {
                .node => |id| self.source.node(id).kind == .text,
                else => false,
            },
            .comment => switch (node) {
                .node => |id| self.source.node(id).kind == .comment,
                else => false,
            },
            .processing_instruction => |target| switch (node) {
                .node => |id| {
                    const value = self.source.node(id);
                    if (value.kind != .processing_instruction) return false;
                    return if (target) |expected|
                        std.mem.eql(u8, value.name, expected)
                    else
                        true;
                },
                else => false,
            },
        };
    }

    fn executeLiteralElement(
        self: *Runtime,
        element: compile.LiteralElement,
        node: xpath.NodeRef,
        position: usize,
        size: usize,
    ) Error!void {
        // Literal names were validated when the stylesheet was parsed.
        const id = self.builder.createElementNsUnchecked(
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
        // Attribute sets run first and may create an attribute with the same
        // name as a literal one, so the duplicate scan can only be skipped
        // when there are none.
        const literal_unique = element.attribute_sets.len == 0;
        for (element.attributes) |attr| {
            const value = try self.evaluateAvt(
                attr.value,
                node,
                position,
                size,
            );
            if (literal_unique) {
                if (attr.ns.len == 0) {
                    self.builder.setAttributeLiteral(id, attr.name, value) catch |err|
                        return mapBuilderError(err);
                } else {
                    const colon: u16 = if (attr.prefix.len == 0)
                        0xFFFF
                    else
                        @intCast(attr.prefix.len);
                    self.builder.setAttributeLiteralNs(
                        id,
                        attr.name,
                        colon,
                        attr.ns,
                        value,
                    ) catch |err| return mapBuilderError(err);
                }
                continue;
            }
            if (attr.ns.len == 0) {
                // Literal attribute names were validated with the stylesheet.
                self.builder.setAttributeValidated(id, attr.name, value) catch |err|
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
        try self.executeLiteralBody(element.body, node, position, size);
    }

    fn executeApplyTemplates(
        self: *Runtime,
        instruction: compile.ApplyTemplates,
        node: xpath.NodeRef,
        position: usize,
        size: usize,
    ) Error!void {
        if (instruction.select == null and instruction.sorts.len == 0) {
            try self.applyTemplateChildren(
                node,
                instruction.mode,
                try self.evaluateParams(
                    instruction.params,
                    node,
                    position,
                    size,
                ),
            );
            return;
        }
        if (instruction.stream_identity) {
            try self.applyIdentitySelect(
                node,
                instruction.mode,
                try self.evaluateParams(
                    instruction.params,
                    node,
                    position,
                    size,
                ),
            );
            return;
        }
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

    /// Apply the standard identity select `@*|node()` by walking attributes
    /// and children directly instead of materializing a node set.
    fn applyIdentitySelect(
        self: *Runtime,
        node: xpath.NodeRef,
        mode: ?[]const u8,
        params: []const xpath.Variable,
    ) Error!void {
        const id = switch (node) {
            .node => |value| value,
            .attribute, .namespace_node => return,
        };
        const value = self.source.node(id);
        if (value.kind != .element and value.kind != .document) return;
        var size: usize = 0;
        if (self.stylesheet.uses_last) {
            if (value.kind == .element) {
                for (self.source.attributesOf(id)) |attr| {
                    if (namespace.Resolver.isNamespaceDeclaration(attr.name)) {
                        continue;
                    }
                    size += 1;
                }
            }
            var count_child = value.first_child;
            while (count_child != dom.null_node) : (count_child =
                self.source.node(count_child).next_sibling)
            {
                size += 1;
            }
        }
        const saved_mode = self.current_mode;
        self.current_mode = mode;
        defer self.current_mode = saved_mode;
        // The standard identity index resolves to a lone child rule; dispatch
        // it here so the per-child lookup chain is skipped, and run the copy
        // directly when the template is exactly the identity body.
        var lone_child: ?*const compile.Template = null;
        var lone_copy: ?compile.Copy = null;
        if (mode == null) {
            self.refreshLoneTemplates();
            lone_child = self.lone_child_template;
            lone_copy = self.lone_child_copy;
        }
        var position: usize = 0;
        if (value.kind == .element) {
            for (self.source.attributesOf(id), 0..) |attr, index| {
                if (namespace.Resolver.isNamespaceDeclaration(attr.name)) {
                    continue;
                }
                position += 1;
                try self.applyTemplateNode(
                    .{ .attribute = .{
                        .element = id,
                        .index = @intCast(index),
                    } },
                    mode,
                    params,
                    position,
                    size,
                );
            }
        }
        var child = value.first_child;
        while (child != dom.null_node) {
            const current = child;
            const child_value = self.source.node(current);
            child = child_value.next_sibling;
            position += 1;
            const child_ref: xpath.NodeRef = .{ .node = current };
            if (lone_copy) |copy| {
                try self.executeCopy(copy, child_ref, position, size);
            } else if (lone_child) |template| {
                try self.executeTemplate(
                    template,
                    child_ref,
                    position,
                    size,
                    params,
                );
            } else {
                try self.applyTemplateNode(
                    child_ref,
                    mode,
                    params,
                    position,
                    size,
                );
            }
        }
    }

    fn executeCallTemplate(
        self: *Runtime,
        call: compile.CallTemplate,
        node: xpath.NodeRef,
        position: usize,
        size: usize,
    ) Error!void {
        const found = self.named_templates.get(call.name) orelse
            return error.InvalidStylesheet;
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
        // Each iteration usually emits at least one result node, and the
        // attributes of literal result elements are known at compile time;
        // reserving that much up front avoids the doubling copies for large
        // loops.
        self.builder.reserveNodes(
            self.builder.nodeCount() + sorted.len,
        ) catch |err| return mapBuilderError(err);
        const literal_attributes = instruction.attributes_per_iteration;
        if (literal_attributes != 0) {
            self.builder.reserveAttributes(
                self.builder.attributeCount() +
                    sorted.len * literal_attributes,
            ) catch |err| return mapBuilderError(err);
        }
        // A body that is one literal result element (the common row
        // template) skips the instruction-dispatch layers.
        if (instruction.body.len == 1) {
            const only = &instruction.body[0];
            if (only.* == .literal_element) {
                const mark = self.variable_len;
                defer self.variable_len = mark;
                for (sorted, 0..) |current, index| {
                    try self.executeLiteralElement(
                        only.literal_element,
                        current,
                        index + 1,
                        sorted.len,
                    );
                }
                return;
            }
        }
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
            if (current == .namespace_node) {
                const ns = current.namespace_node;
                // libxslt does not materialize default or implicit xml
                // namespace nodes when copying.
                if (ns.prefix.len != 0 and
                    !std.mem.eql(u8, ns.prefix, "xml"))
                {
                    try self.addNamespaceDecl(self.parent, ns.prefix, ns.uri);
                }
                continue;
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
                try self.appendAttributeRaw(
                    attribute,
                    self.source.ns(attribute.ns),
                );
            },
            .namespace_node => |ns| {
                if (ns.prefix.len != 0 and
                    !std.mem.eql(u8, ns.prefix, "xml"))
                {
                    try self.addNamespaceDecl(self.parent, ns.prefix, ns.uri);
                }
            },
            .node => |id| {
                const node_value = self.source.node(id);
                switch (node_value.kind) {
                    .element => {
                        const new_id = self.builder.createElementRaw(
                            node_value.name,
                            node_value.colon,
                            self.source.ns(node_value.ns),
                        ) catch |err| return mapBuilderError(err);
                        self.builder.appendChild(self.parent, new_id) catch |err|
                            return mapBuilderError(err);
                        if (self.source_has_namespaces) {
                            if (node_value.parent == self.copy_source) {
                                // The result parent is the copy of this
                                // element's source parent, so inherited
                                // bindings are already in scope; only the
                                // element's own declarations are missing.
                                try self.addOwnNamespaceDecls(new_id, id);
                            } else {
                                const bindings = try self.source.inScopeNamespaces(
                                    self.allocator,
                                    id,
                                );
                                for (bindings) |binding| {
                                    if (std.mem.eql(u8, binding.prefix, "xml")) {
                                        continue;
                                    }
                                    try self.addNamespaceDecl(
                                        new_id,
                                        binding.prefix,
                                        binding.uri,
                                    );
                                }
                            }
                        }
                        const saved_parent = self.parent;
                        self.parent = new_id;
                        defer self.parent = saved_parent;
                        const saved_copy_source = self.copy_source;
                        self.copy_source = id;
                        defer self.copy_source = saved_copy_source;
                        // A body that is one `xsl:apply-templates` needs no
                        // body-level variable scope; dispatch it directly.
                        if (instruction.body.len == 1) {
                            switch (instruction.body[0]) {
                                .apply_templates => |apply_instruction| {
                                    if (apply_instruction.stream_identity and
                                        apply_instruction.params.len == 0)
                                    {
                                        try self.applyIdentitySelect(
                                            node,
                                            apply_instruction.mode,
                                            &.{},
                                        );
                                        return;
                                    }
                                    // A plain apply-templates has no select,
                                    // sort keys, or parameters; skip the
                                    // parameter evaluation and select checks.
                                    if (apply_instruction.select == null and
                                        apply_instruction.sorts.len == 0 and
                                        apply_instruction.params.len == 0)
                                    {
                                        try self.applyTemplateChildren(
                                            node,
                                            apply_instruction.mode,
                                            &.{},
                                        );
                                        return;
                                    }
                                    try self.executeApplyTemplates(
                                        apply_instruction,
                                        node,
                                        position,
                                        size,
                                    );
                                    return;
                                },
                                else => {},
                            }
                        }
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

    fn buildAttributeSetIndex(self: *Runtime) Error!void {
        for (self.stylesheet.attribute_sets, 0..) |*set, index| {
            try appendIndex(
                &self.attribute_set_index,
                self.allocator,
                .{ .uri = set.name_uri, .local = set.name },
                @intCast(index),
            );
        }
    }

    fn executeAttributeSet(
        self: *Runtime,
        name: compile.NameRef,
        node: xpath.NodeRef,
        position: usize,
        size: usize,
    ) Error!void {
        const sets = self.attribute_set_index.get(.{
            .uri = name.uri,
            .local = name.local,
        }) orelse return error.InvalidStylesheet;
        for (sets.items) |index| {
            const set = &self.stylesheet.attribute_sets[index];
            const instructions = set.expanded orelse set.raw_instructions;
            try self.executeInstructions(
                instructions,
                node,
                position,
                size,
            );
        }
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
        var prefix = qname.prefix;
        if (uri.len != 0) {
            if (prefix.len == 0) {
                if (std.mem.eql(u8, uri, namespace.xml_uri)) {
                    // The xml namespace always uses the implicit xml prefix.
                    prefix = "xml";
                } else {
                    // libxslt synthesizes an ns_N prefix for unprefixed
                    // namespaced attributes.
                    prefix = try self.generatedPrefix(uri);
                }
            } else if (std.mem.eql(u8, prefix, "xmlns")) {
                // "xmlns" is reserved for namespace declarations; libxslt
                // keeps the local name and synthesizes a fresh prefix.
                prefix = try self.generatedPrefix(uri);
            }
        }
        const value = try self.captureString(
            instruction.body,
            node,
            position,
            size,
        );
        try self.appendAttribute(name, prefix, qname.local, uri, value);
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
        var grouping: ?NumberGrouping = null;
        if (instruction.grouping_size) |size_avt| {
            const size_text = try self.evaluateAvt(
                size_avt,
                node,
                position,
                size,
            );
            const digits = parseGroupingSize(size_text);
            if (digits > 0) {
                const separator = if (instruction.grouping_separator) |sep_avt|
                    try self.evaluateAvt(sep_avt, node, position, size)
                else
                    "";
                if (separator.len != 0) {
                    const length = std.unicode.utf8ByteSequenceLength(
                        separator[0],
                    ) catch 1;
                    grouping = .{
                        .separator = separator[0..@min(length, separator.len)],
                        .size = digits,
                    };
                }
            }
        }
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
            if (number < 0) {
                // libxslt reports the negative value and formats it as 0.
                try self.messages.append(
                    self.allocator,
                    "xsl-number : negative value",
                );
            }
            const rounded = @max(std.math.floor(number + 0.5), 0);
            try self.appendText(try self.formatPositions(
                &.{@intFromFloat(rounded)},
                format_text,
                grouping,
            ));
            return;
        }
        switch (instruction.level) {
            .single => try self.numberSingle(
                instruction,
                node,
                format_text,
                grouping,
            ),
            .multiple => try self.numberMultiple(
                instruction,
                node,
                format_text,
                grouping,
            ),
            .any => try self.numberAny(
                instruction,
                node,
                format_text,
                grouping,
            ),
        }
    }

    fn numberSingle(
        self: *Runtime,
        instruction: compile.NumberInstruction,
        node: xpath.NodeRef,
        format_text: []const u8,
        grouping: ?NumberGrouping,
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
            grouping,
        ));
    }

    fn numberMultiple(
        self: *Runtime,
        instruction: compile.NumberInstruction,
        node: xpath.NodeRef,
        format_text: []const u8,
        grouping: ?NumberGrouping,
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
            grouping,
        ));
    }

    fn numberAny(
        self: *Runtime,
        instruction: compile.NumberInstruction,
        node: xpath.NodeRef,
        format_text: []const u8,
        grouping: ?NumberGrouping,
    ) Error!void {
        if (try self.numberAnyFast(instruction, node, format_text, grouping)) {
            return;
        }
        // Walk backwards in document order like libxslt: attributes collapse
        // to their element, and attribute nodes of other elements are never
        // visited.
        var count: usize = 0;
        var current: ?xpath.NodeRef = node;
        while (current) |candidate| {
            if (try self.matchesCount(instruction, node, candidate)) {
                count += 1;
            }
            if (instruction.from) |from| {
                if (try self.selectorMatches(from, candidate)) break;
            }
            current = self.previousInDocumentOrder(candidate);
        }
        if (count != 0) {
            try self.appendText(try self.formatPositions(
                &.{count},
                format_text,
                grouping,
            ));
        }
    }

    /// Count `level="any"` positions with binary searches over precomputed
    /// node sets (count patterns) or the per-document name index (default
    /// count). Returns false when the generic backwards walk is required.
    fn numberAnyFast(
        self: *Runtime,
        instruction: compile.NumberInstruction,
        node: xpath.NodeRef,
        format_text: []const u8,
        grouping: ?NumberGrouping,
    ) Error!bool {
        const node_id: u32 = switch (node) {
            .node => |id| id,
            else => return false,
        };
        const range = self.documentRange(node);
        const range_start: u32 = @intCast(range.start);
        const range_end: u32 = @intCast(
            @min(range.end, self.source.nodes.len),
        );
        if (node_id < range_start or node_id >= range_end) return false;

        // The walk stops after the last `from` match at or before the node.
        var lower: u32 = range_start;
        if (instruction.from) |from| {
            const entry = try self.selectorEntry(from);
            if (!entryAllNodes(entry)) return false;
            const base = lowerBoundNodeId(entry.nodes, range_start);
            const upto = upperBoundNodeId(entry.nodes, node_id);
            if (upto > base) {
                lower = entry.nodes[upto - 1].node;
            }
        }

        var total: usize = 0;
        if (instruction.count) |count_expr| {
            const entry = try self.selectorEntry(count_expr);
            if (!entryAllNodes(entry)) return false;
            const base = lowerBoundNodeId(entry.nodes, lower);
            const upto = upperBoundNodeId(entry.nodes, node_id);
            if (upto < base) return false;
            total = upto - base;
        } else {
            const positions = try self.ensureNamePositions(range_start);
            var key_buffer: [256]u8 = undefined;
            const key = nodeNameKey(
                self.source,
                self.source.node(node_id),
                &key_buffer,
            ) orelse return false;
            if (positions.map.get(key)) |list| {
                const base = lowerBoundU32(list.items, lower);
                const upto = upperBoundU32(list.items, node_id);
                if (upto >= base) total = upto - base;
            }
        }
        if (total != 0) {
            try self.appendText(try self.formatPositions(
                &.{total},
                format_text,
                grouping,
            ));
        }
        return true;
    }

    /// Per-document index of plain node ids grouped by node kind and expanded
    /// name, used by `xsl:number level="any"` without a count pattern.
    fn ensureNamePositions(
        self: *Runtime,
        root: usize,
    ) Error!*NamePositions {
        const entry = try self.name_positions.getOrPut(
            self.allocator,
            root,
        );
        if (entry.found_existing) return entry.value_ptr;
        entry.value_ptr.* = .{};
        const range = self.documentRange(.{ .node = @intCast(root) });
        const end = @min(range.end, self.source.nodes.len);
        var key_buffer: std.ArrayList(u8) = .empty;
        defer key_buffer.deinit(self.allocator);
        var index = range.start;
        while (index < end) : (index += 1) {
            const node = self.source.node(@intCast(index));
            key_buffer.clearRetainingCapacity();
            switch (node.kind) {
                .document => try key_buffer.append(self.allocator, 'd'),
                .element => {
                    try key_buffer.append(self.allocator, 'e');
                    try key_buffer.appendSlice(self.allocator, self.source.ns(node.ns));
                    try key_buffer.append(self.allocator, 0);
                    try key_buffer.appendSlice(self.allocator, node.localName());
                },
                .text => try key_buffer.append(self.allocator, 't'),
                .comment => try key_buffer.append(self.allocator, 'c'),
                .processing_instruction => {
                    try key_buffer.append(self.allocator, 'p');
                    try key_buffer.appendSlice(self.allocator, node.name);
                },
            }
            const slot = try entry.value_ptr.map.getOrPut(
                self.allocator,
                key_buffer.items,
            );
            if (!slot.found_existing) {
                slot.key_ptr.* = try self.allocator.dupe(
                    u8,
                    key_buffer.items,
                );
                slot.value_ptr.* = .empty;
            }
            try slot.value_ptr.append(self.allocator, @intCast(index));
        }
        return entry.value_ptr;
    }

    fn previousInDocumentOrder(
        self: *Runtime,
        node: xpath.NodeRef,
    ) ?xpath.NodeRef {
        switch (node) {
            .attribute => |attribute| return .{ .node = attribute.element },
            .namespace_node => |namespace_node| return .{
                .node = namespace_node.element,
            },
            .node => |id| {
                const value = self.source.node(id);
                if (value.kind == .document) return null;
                const parent = value.parent;
                if (parent != dom.null_node) {
                    var sibling = self.source.node(parent).first_child;
                    var previous: dom.NodeId = dom.null_node;
                    while (sibling != dom.null_node and sibling != id) {
                        previous = sibling;
                        sibling = self.source.node(sibling).next_sibling;
                    }
                    if (previous != dom.null_node) {
                        var deepest = previous;
                        while (self.source.node(deepest).last_child !=
                            dom.null_node)
                        {
                            deepest = self.source.node(deepest).last_child;
                        }
                        return .{ .node = deepest };
                    }
                }
                if (parent == dom.null_node) return null;
                return .{ .node = parent };
            },
        }
    }

    fn selectorEntry(
        self: *Runtime,
        selector: compile.CompiledExpr,
    ) Error!*SelectorEntry {
        if (self.last_selector_cacheable and
            self.last_selector == selector.node)
        {
            return self.last_selector_entry.?;
        }
        const uses_variables = self.selector_var_usage.get(selector.node) orelse blk: {
            const value = exprUsesVariables(selector.node);
            try self.selector_var_usage.put(selector.node, value);
            break :blk value;
        };
        const cacheable = !uses_variables;
        if (cacheable) {
            if (self.selector_cache.get(selector.node)) |entry| return entry;
        }
        var context: xpath.Context = .{
            .document = self.source,
            .node = .{ .node = 0 },
            .namespaces = selector.namespaces,
            .variables = self.variables[0..self.variable_len],
            .variable_floor = self.variable_floor,
            .document_range = self.documentRange(.{ .node = 0 }),
            .key_resolver = if (self.keys_ready) .{
                .context = self,
                .lookup = lookupKey,
            } else null,
            .id_resolver = .{
                .context = self,
                .lookup = lookupId,
            },
            .xslt_functions = true,
            .descendant_cache = &self.descendant_cache,
            .current_date_time = self.now,
            .node_id_generator = .{
                .context = self,
                .generate = generateNodeId,
            },
            .document_resolver = .{
                .context = self,
                .resolve = resolveDocument,
            },
            .tree_converter = .{
                .context = self,
                .convert = convertTree,
            },
            .extension_functions = .{
                .context = self,
                .available = extensionFunctionAvailable,
                .call = callExtensionFunction,
            },
            .variable_resolver = .{
                .context = self,
                .resolve = resolveGlobalVariable,
            },
            .fragment_factory = .{
                .context = self,
                .build = buildFragmentNodes,
            },
            .document_base = self.base_uri,
        };
        const result = xpath_eval.evaluateDirect(
            self.allocator,
            selector.node,
            &context,
        ) catch |err| return mapEvalError(err);
        const nodes = switch (result) {
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
        const node_bound = @max(
            self.merged_nodes.items.len,
            self.source.nodes.len,
        );
        entry.bits = try std.DynamicBitSetUnmanaged.initEmpty(
            self.allocator,
            node_bound,
        );
        for (nodes) |candidate| {
            switch (candidate) {
                .node => |id| entry.bits.set(id),
                else => try entry.map.put(nodeKey(candidate), {}),
            }
        }
        if (cacheable) {
            try self.selector_cache.put(selector.node, entry);
            self.last_selector = selector.node;
            self.last_selector_entry = entry;
            self.last_selector_cacheable = true;
        }
        return entry;
    }

    /// Build (or reuse) a direct matcher for a count/from pattern. Patterns
    /// without predicates can be tested per candidate node, so they do not
    /// need a document-wide node set.
    fn selectorMatcher(
        self: *Runtime,
        selector: compile.CompiledExpr,
    ) Error!?PatternMatcher {
        if (self.last_matcher_expr == selector.node) {
            return self.last_matcher;
        }
        if (self.selector_matchers.get(selector.node)) |matcher| {
            self.last_matcher_expr = selector.node;
            self.last_matcher = matcher;
            return matcher;
        }
        const matcher: ?PatternMatcher = blk: {
            if (simplePatternExpr(selector.node, selector.namespaces)) |pattern| {
                break :blk .{ .simple = pattern };
            }
            if (try simpleUnionExpr(
                self.allocator,
                selector.node,
                selector.namespaces,
            )) |patterns| {
                break :blk .{ .simple_union = patterns };
            }
            if (try structuralPatternExpr(
                self.allocator,
                selector.node,
                selector.namespaces,
            )) |pattern| {
                break :blk .{ .structural = pattern };
            }
            break :blk null;
        };
        try self.selector_matchers.put(selector.node, matcher);
        self.last_matcher_expr = selector.node;
        self.last_matcher = matcher;
        return matcher;
    }

    fn selectorMatches(
        self: *Runtime,
        selector: compile.CompiledExpr,
        node: xpath.NodeRef,
    ) Error!bool {
        if (try self.selectorMatcher(selector)) |matcher| {
            return switch (matcher) {
                .simple => |pattern| self.simpleMatches(pattern, node),
                .simple_union => |patterns| self.simpleUnionMatches(
                    patterns,
                    node,
                ),
                .structural => |pattern| try self.structuralMatches(pattern, node),
            };
        }
        const entry = try self.selectorEntry(selector);
        switch (node) {
            .node => |id| {
                if (id >= entry.bits.bit_length) return false;
                return entry.bits.isSet(id);
            },
            .attribute, .namespace_node => {
                return entry.map.contains(nodeKey(node));
            },
        }
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
        grouping: ?NumberGrouping,
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
                grouping,
            );
            if (index + 1 < numbers.len) {
                // Repeat the last separator when there are more numbers than
                // format tokens; a format without separators uses ".".
                const separator = if (index < parsed.separators.len)
                    parsed.separators[index]
                else if (parsed.separators.len != 0)
                    parsed.separators[parsed.separators.len - 1]
                else
                    ".";
                try out.appendSlice(self.allocator, separator);
            }
        }
        try out.appendSlice(self.allocator, parsed.suffix);
        return out.toOwnedSlice(self.allocator);
    }

    fn findDecimalFormat(
        self: *Runtime,
        name: ?xpath_value.QualifiedName,
    ) ?*const compile.DecimalFormat {
        for (self.stylesheet.decimal_formats) |*format| {
            if (name) |wanted| {
                if (format.name) |local| {
                    if (std.mem.eql(u8, local, wanted.local) and
                        std.mem.eql(u8, format.name_uri, wanted.uri))
                    {
                        return format;
                    }
                }
            } else if (format.name == null) {
                return format;
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
        var default_sign = false;
        if (negative) {
            if (parsed.negative) |negative_pattern| {
                // libxslt takes only the negative prefix/suffix; digit
                // placeholders always come from the positive subpattern.
                // An explicit (even empty or identical) negative subpattern
                // suppresses the default minus sign.
                subpattern.prefix = negative_pattern.prefix;
                subpattern.suffix = negative_pattern.suffix;
            } else {
                default_sign = true;
            }
        }
        const value = @abs(number) * subpattern.scale;
        var frac_digits = subpattern.frac_digits;
        var frac_hash = subpattern.frac_hash;
        if (subpattern.integer_digits + subpattern.integer_hash +
            frac_digits == 0 and frac_hash > 0)
        {
            // Java treats '.#' like '.0' and '.##' like '.0#'.
            frac_digits += 1;
            frac_hash -= 1;
        }
        const max_fraction = @min(frac_digits + frac_hash, 18);
        var scale: u128 = 1;
        for (0..max_fraction) |_| scale *= 10;
        const scaled_value = std.math.floor(
            value * @as(f64, @floatFromInt(scale)) + 0.5,
        );
        if (!std.math.isFinite(scaled_value) or scaled_value > 1e30) {
            var out: std.ArrayList(u8) = .empty;
            if (default_sign) {
                try appendCodepoint(allocator, &out, format.minus_sign);
            }
            try out.appendSlice(allocator, subpattern.prefix);
            try out.appendSlice(
                allocator,
                try std.fmt.allocPrint(allocator, "{d}", .{value}),
            );
            try out.appendSlice(allocator, subpattern.suffix);
            return out.toOwnedSlice(allocator);
        }
        const scaled_total: u128 = @intFromFloat(scaled_value);
        const integer_value = scaled_total / scale;
        const fraction_value = scaled_total % scale;

        var out: std.ArrayList(u8) = .empty;
        if (default_sign) {
            try appendCodepoint(allocator, &out, format.minus_sign);
        }
        try out.appendSlice(allocator, subpattern.prefix);
        if (integer_value != 0 or subpattern.integer_digits != 0) {
            var integer_buffer: [64]u8 = undefined;
            const integer_digits = std.fmt.bufPrint(
                &integer_buffer,
                "{d}",
                .{integer_value},
            ) catch return error.InvalidFormat;
            try appendFormattedInteger(
                allocator,
                &out,
                integer_digits,
                subpattern.integer_digits,
                subpattern.group_size,
                format,
            );
        }
        if (integer_value == 0 and
            subpattern.integer_digits + frac_digits == 0)
        {
            try appendDigit(allocator, &out, '0', format.zero_digit);
        }
        if (frac_digits + frac_hash == 0) {
            if (subpattern.add_decimal) {
                try appendCodepoint(allocator, &out, format.decimal_separator);
            }
        } else if (fraction_value != 0 or frac_digits != 0) {
            try appendCodepoint(allocator, &out, format.decimal_separator);
            var fraction_buffer: [32]u8 = undefined;
            var divisor: u128 = 1;
            for (0..max_fraction) |_| divisor *= 10;
            divisor /= 10;
            var remaining = fraction_value;
            for (0..max_fraction) |index| {
                const digit: u8 = @intCast(remaining / divisor);
                fraction_buffer[index] = '0' + digit;
                remaining %= divisor;
                if (divisor >= 10) divisor /= 10;
            }
            var length = max_fraction;
            while (length > frac_digits and fraction_buffer[length - 1] == '0') {
                length -= 1;
            }
            for (fraction_buffer[0..length]) |digit| {
                try appendDigit(allocator, &out, digit, format.zero_digit);
            }
        }
        try out.appendSlice(allocator, subpattern.suffix);
        return out.toOwnedSlice(allocator);
    }

    inline fn evaluateParams(
        self: *Runtime,
        params: []const compile.ParamBinding,
        node: xpath.NodeRef,
        position: usize,
        size: usize,
    ) Error![]const xpath.Variable {
        if (params.len == 0) return &.{};
        return self.evaluateParamsSlow(params, node, position, size);
    }

    fn evaluateParamsSlow(
        self: *Runtime,
        params: []const compile.ParamBinding,
        node: xpath.NodeRef,
        position: usize,
        size: usize,
    ) Error![]const xpath.Variable {
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
        // Most attribute value templates are a single literal or a single
        // expression; return those without building and copying a buffer.
        if (avt.len == 1) {
            switch (avt[0]) {
                .literal => |text| return text,
                .expr => |expression| {
                    if (try self.simpleChildString(expression, node)) |text| {
                        return text;
                    }
                    return self.toString(
                        try self.evalOwned(expression, node, position, size),
                    );
                },
            }
        }
        var out: std.ArrayList(u8) = .empty;
        for (avt) |part| {
            switch (part) {
                .literal => |text| try out.appendSlice(self.allocator, text),
                .expr => |expression| {
                    if (try self.simpleChildString(expression, node)) |text| {
                        try out.appendSlice(self.allocator, text);
                        continue;
                    }
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
        temp.allow_multiple_roots = true;
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
        // A body that is just character data or a single value-of has the
        // same text content without materializing a temporary result tree.
        if (body.len == 1) {
            switch (body[0]) {
                .literal_text, .text, .raw_text => |text| return text,
                .value_of => |value_of| return self.toString(
                    try self.evalOwned(value_of.select, node, position, size),
                ),
                else => {},
            }
        }
        var temp = dom_builder.Builder.init(self.allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidStylesheet,
        };
        temp.allow_multiple_roots = true;
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

    inline fn appendText(self: *Runtime, text: []const u8) Error!void {
        if (text.len == 0) return;
        if (try self.mergeIntoLastText(text, false)) return;
        const id = self.builder.createText(text) catch |err|
            return mapBuilderError(err);
        self.builder.appendChild(self.parent, id) catch |err|
            return mapBuilderError(err);
    }

    fn appendTextRaw(self: *Runtime, text: []const u8) Error!void {
        if (text.len == 0) return;
        if (try self.mergeIntoLastText(text, true)) return;
        const id = self.builder.createTextRaw(text) catch |err|
            return mapBuilderError(err);
        self.builder.appendChild(self.parent, id) catch |err|
            return mapBuilderError(err);
    }

    /// XSLT result trees merge adjacent text nodes; disable-output-escaping
    /// text only merges with other raw text so serializers keep its meaning.
    inline fn mergeIntoLastText(
        self: *Runtime,
        text: []const u8,
        raw: bool,
    ) Error!bool {
        if (self.parent == dom.null_node) return false;
        const parent_node = self.builder.nodeAt(self.parent);
        if (parent_node.last_child == dom.null_node) return false;
        const last = self.builder.nodeAt(parent_node.last_child);
        if (last.kind != .text or last.isRawText() != raw) return false;
        self.builder.appendToText(parent_node.last_child, text) catch |err|
            return mapBuilderError(err);
        return true;
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

    /// Append an attribute copied from a parsed document; its qualified name
    /// and namespace were validated by the parser.
    fn appendAttributeRaw(
        self: *Runtime,
        attr: dom.Attribute,
        uri: []const u8,
    ) Error!void {
        if (uri.len == 0) {
            self.builder.setAttributeRaw(
                self.parent,
                attr.name,
                attr.colon(),
                attr.value,
            ) catch |err| return mapBuilderError(err);
        } else {
            try self.addNamespaceDecl(self.parent, attr.prefixName(), uri);
            self.builder.setAttributeNsRaw(
                self.parent,
                attr.name,
                attr.colon(),
                uri,
                attr.value,
            ) catch |err| return mapBuilderError(err);
        }
    }

    fn generatedPrefix(self: *Runtime, uri: []const u8) Error![]const u8 {
        var buffer: [32]u8 = undefined;
        var index: usize = 1;
        while (index < 1000) : (index += 1) {
            const candidate = std.fmt.bufPrint(
                &buffer,
                "ns_{d}",
                .{index},
            ) catch break;
            if (self.outputPrefixUri(self.parent, candidate)) |bound| {
                if (std.mem.eql(u8, bound, uri)) {
                    return self.allocator.dupe(u8, candidate);
                }
                continue;
            }
            return self.allocator.dupe(u8, candidate);
        }
        return error.InvalidArgument;
    }

    fn outputPrefixUri(
        self: *Runtime,
        id: dom.NodeId,
        prefix: []const u8,
    ) ?[]const u8 {
        var current = id;
        while (current != dom.null_node) {
            const node = self.builder.nodeAt(current);
            if (node.kind != .element) break;
            for (self.builder.attributesOf(current)) |attr| {
                if (attr.name.len != "xmlns:".len + prefix.len) continue;
                if (!std.mem.startsWith(u8, attr.name, "xmlns:")) continue;
                if (!std.mem.eql(u8, attr.name["xmlns:".len..], prefix)) {
                    continue;
                }
                return attr.value;
            }
            current = node.parent;
        }
        return null;
    }

    fn addNamespaceDecl(
        self: *Runtime,
        id: dom.NodeId,
        prefix: []const u8,
        uri: []const u8,
    ) Error!void {
        if (self.namespaceDeclInScope(id, prefix, uri)) return;
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

    /// Add only the namespace declarations authored on one source element.
    /// The caller guarantees the result parent already carries the inherited
    /// ones, so walking the source ancestors is unnecessary.
    fn addOwnNamespaceDecls(
        self: *Runtime,
        new_id: dom.NodeId,
        id: dom.NodeId,
    ) Error!void {
        for (self.source.attributesOf(id)) |attr| {
            if (!namespace.Resolver.isNamespaceDeclaration(attr.name)) {
                continue;
            }
            const prefix = if (attr.name.len == 5)
                ""
            else
                attr.name["xmlns:".len..];
            if (std.mem.eql(u8, prefix, "xml")) continue;
            // An empty URI undeclares the prefix, so it binds no namespace.
            if (attr.value.len == 0) continue;
            try self.addNamespaceDecl(new_id, prefix, attr.value);
        }
    }

    /// True when an ancestor already binds `prefix` to `uri`, so the result
    /// element does not need to repeat the declaration.
    fn namespaceDeclInScope(
        self: *Runtime,
        id: dom.NodeId,
        prefix: []const u8,
        uri: []const u8,
    ) bool {
        var current = self.builder.nodeAt(id).parent;
        while (current != dom.null_node) {
            const node = self.builder.nodeAt(current);
            if (node.kind == .element) {
                for (self.builder.attributesOf(current)) |attr| {
                    const matches = if (prefix.len == 0)
                        std.mem.eql(u8, attr.name, "xmlns")
                    else
                        attr.name.len == prefix.len + 6 and
                            std.mem.startsWith(u8, attr.name, "xmlns:") and
                            std.mem.eql(u8, attr.name[6..], prefix);
                    if (matches) return std.mem.eql(u8, attr.value, uri);
                }
            }
            current = node.parent;
        }
        return prefix.len == 0 and uri.len == 0;
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
                try self.appendAttributeRaw(
                    attribute,
                    self.source.ns(attribute.ns),
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
                const new_id = self.builder.createElementRaw(
                    node_value.name,
                    node_value.colon,
                    self.source.ns(node_value.ns),
                ) catch |err| return mapBuilderError(err);
                self.builder.appendChild(self.parent, new_id) catch |err|
                    return mapBuilderError(err);
                try self.copyElementNamespacesFrom(source, id, new_id);
                for (source.attributesOf(id)) |attr| {
                    if (namespace.Resolver.isNamespaceDeclaration(attr.name)) {
                        continue;
                    }
                    if (source.ns(attr.ns).len == 0) {
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
                            source.ns(attr.ns),
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
        if (!has_default and prefix.len == 0 and
            self.source.ns(node_value.ns).len != 0)
        {
            try self.addNamespaceDecl(new_id, "", self.source.ns(node_value.ns));
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
        const all_keys = try self.allocator.alloc(
            SortValue,
            nodes.len * sorts.len,
        );
        for (nodes, 0..) |current, index| {
            const base = index * sorts.len;
            for (sorts, 0..) |sort, key_index| {
                var text: ?[]const u8 = null;
                if (sort.select) |select| {
                    text = try self.simpleChildString(select, current);
                    if (text == null) {
                        const value = try self.evalOwned(
                            select,
                            current,
                            index + 1,
                            nodes.len,
                        );
                        text = try self.toString(value);
                    }
                } else {
                    text = try self.stringValue(current);
                }
                all_keys[base + key_index] = switch (sort.data_type) {
                    .text => .{ .text = text.? },
                    .number => .{ .number = xpath_value.parseNumber(text.?) },
                };
            }
            entries[index] = .{
                .node = current,
                .index = index,
                .keys = all_keys[base..][0..sorts.len],
            };
        }
        // A stable sort whose keys all compare equal preserves the input
        // order, so low-cardinality sort keys skip the comparison sort.
        if (sortKeysAllEqual(all_keys, entries[0].keys, sorts.len)) return nodes;
        // The comparator breaks ties by original index, so the order is
        // total and the cheaper unstable sort produces the same sequence.
        std.mem.sortUnstable(SortEntry, entries, sorts, sortEntryLessThan);
        const out = try self.allocator.alloc(xpath.NodeRef, nodes.len);
        for (entries, 0..) |entry, index| out[index] = entry.node;
        _ = node;
        _ = position;
        _ = size;
        return out;
    }

    /// Fast path for a single child name test such as `lastname` in a sort
    /// key, `xsl:value-of`, or an attribute value template: the string value
    /// is the first matching child's text.
    inline fn simpleChildString(
        self: *Runtime,
        select: compile.CompiledExpr,
        node: xpath.NodeRef,
    ) Error!?[]const u8 {
        const path = switch (select.node.*) {
            .path => |value| value,
            else => return null,
        };
        if (path.absolute or path.start != null or path.steps.len != 1) {
            return null;
        }
        const step = path.steps[0];
        if (step.axis != .child or step.predicates.len != 0) return null;
        const name_test = switch (step.node_test) {
            .name => |value| value,
            else => return null,
        };
        const local = name_test.local orelse return null;
        // Namespace URIs are interned in the document table, so resolve the
        // expected URI to a table index once instead of comparing strings for
        // every child.
        const expected_ns: dom.NamespaceId = if (name_test.prefix) |prefix| blk: {
            const uri = resolvePrefix(select.namespaces, prefix) orelse return null;
            break :blk self.source.lookupNamespace(uri) orelse return null;
        } else 0;
        const id = switch (node) {
            .node => |value| value,
            else => return null,
        };
        const parent = self.source.node(id);
        if (parent.kind != .element and parent.kind != .document) return null;
        var child = parent.first_child;
        while (child != dom.null_node) {
            // Fetch each child once and advance first, like the template
            // child loop.
            const current = child;
            const value = self.source.node(current);
            child = value.next_sibling;
            if (value.kind != .element) continue;
            if (value.ns != expected_ns) continue;
            if (!name_match.equal(value.localName(), local)) continue;
            // Inline `stringValue`'s single-text-child case: it covers the
            // common leaf lookup without another call.
            const first = value.first_child;
            if (first != dom.null_node) {
                const text = self.source.node(first);
                if (text.kind == .text and text.next_sibling == dom.null_node) {
                    return text.value;
                }
            }
            return try self.stringValue(.{ .node = current });
        }
        return "";
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
        return switch (value) {
            .node_set => |nodes| nodes,
            // libxslt treats result tree fragments as node-sets containing
            // the fragment root in node-set contexts.
            .tree => |tree| blk: {
                const converted = try convertTree(
                    self,
                    self.allocator,
                    tree,
                ) orelse return error.InvalidArgument;
                const nodes = try self.allocator.alloc(xpath.NodeRef, 1);
                nodes[0] = converted;
                break :blk nodes;
            },
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
                        // The string value of an element with no children is
                        // empty, and with a single text child it is exactly
                        // that child's value, which the source already owns.
                        const first = node_value.first_child;
                        if (first == dom.null_node) break :blk "";
                        const first_node = self.source.node(first);
                        if (first_node.kind == .text and
                            first_node.next_sibling == dom.null_node)
                        {
                            break :blk first_node.value;
                        }
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
    node: xpath.NodeRef,
) xpath_value.KeyError![]const xpath.NodeRef {
    _ = allocator;
    const runtime: *Runtime = @ptrCast(@alignCast(context.?));
    const range = runtime.documentRange(node);
    runtime.buildKeysForDocument(.{ .node = @intCast(range.start) }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return &.{},
    };
    if (runtime.key_map.get(.{ .name = name, .value = value })) |list| {
        var all_in_range = true;
        for (list.items) |candidate| {
            const id = refNodeId(candidate);
            if (id < range.start or id >= range.end) {
                all_in_range = false;
                break;
            }
        }
        if (all_in_range) return list.items;
        var out: std.ArrayList(xpath.NodeRef) = .empty;
        for (list.items) |candidate| {
            const id = refNodeId(candidate);
            if (id >= range.start and id < range.end) {
                try out.append(runtime.allocator, candidate);
            }
        }
        return out.toOwnedSlice(runtime.allocator);
    }
    return &.{};
}

fn lookupId(
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    text: []const u8,
    node: xpath.NodeRef,
) xpath_value.IdError![]const xpath.NodeRef {
    const runtime: *Runtime = @ptrCast(@alignCast(context.?));
    const range = runtime.documentRange(node);
    runtime.buildIdIndexForDocument(.{ .node = @intCast(range.start) }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return &.{},
    };
    var tokens = std.mem.tokenizeAny(u8, text, " \t\r\n");
    const first_token = tokens.next() orelse return &.{};
    if (tokens.next() == null) {
        // A single id token normally selects a single element; allocate the
        // result exactly instead of sorting and deduplicating.
        const list = runtime.id_index.get(first_token) orelse return &.{};
        var found: ?dom.NodeId = null;
        var count: usize = 0;
        for (list.items) |id| {
            if (id < range.start or id >= range.end) continue;
            found = id;
            count += 1;
            if (count > 1) break;
        }
        if (count == 1) {
            const nodes = try allocator.alloc(xpath.NodeRef, 1);
            nodes[0] = .{ .node = found.? };
            return nodes;
        }
        if (count == 0) return &.{};
    }
    var out: std.ArrayList(xpath.NodeRef) = .empty;
    var all_tokens = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (all_tokens.next()) |token| {
        const list = runtime.id_index.get(token) orelse continue;
        for (list.items) |id| {
            if (id < range.start or id >= range.end) continue;
            try out.append(allocator, .{ .node = id });
        }
    }
    std.mem.sort(xpath.NodeRef, out.items, {}, xpath_value.orderLessThan);
    var write: usize = 0;
    for (out.items) |candidate| {
        if (write == 0 or !out.items[write - 1].eql(candidate)) {
            out.items[write] = candidate;
            write += 1;
        }
    }
    out.shrinkRetainingCapacity(write);
    return out.toOwnedSlice(allocator);
}

fn documentHasNamespaces(document: *const dom.Document) bool {
    for (document.attributes) |attr| {
        if (namespace.Resolver.isNamespaceDeclaration(attr.name)) return true;
    }
    return false;
}

fn refNodeId(node: xpath.NodeRef) usize {
    return switch (node) {
        .node => |id| id,
        .attribute => |attribute| attribute.element,
        .namespace_node => |namespace_node| namespace_node.element,
    };
}

fn buildFragmentNodes(
    context: *anyopaque,
    allocator: std.mem.Allocator,
    nodes: []const xpath_value.FragmentNode,
) anyerror![]const xpath.NodeRef {
    const self: *Runtime = @ptrCast(@alignCast(context));
    var temp = dom_builder.Builder.init(self.allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidStylesheet,
    };
    temp.allow_multiple_roots = true;
    var finished = false;
    defer if (!finished) temp.deinit();
    const ids = try allocator.alloc(dom.NodeId, nodes.len);
    const document_id = temp.document();
    for (nodes, 0..) |spec, index| {
        if (spec.name) |name| {
            const element = temp.createElement(name) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidStylesheet,
            };
            if (spec.text.len != 0) {
                const text = temp.createText(spec.text) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.InvalidStylesheet,
                };
                temp.appendChild(element, text) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.InvalidStylesheet,
                };
            }
            temp.appendChild(document_id, element) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidStylesheet,
            };
            ids[index] = element;
        } else {
            const text = temp.createText(spec.text) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidStylesheet,
            };
            temp.appendChild(document_id, text) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidStylesheet,
            };
            ids[index] = text;
        }
    }
    const document = temp.finish() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidStylesheet,
    };
    finished = true;
    const pointer = try self.allocator.create(dom.Document);
    pointer.* = document;
    try self.fragment_documents.append(self.allocator, pointer);
    // Merge the fragment into the shared view without rebuilding keys and
    // template matches: generated nodes are not part of the source document.
    const root_id = self.appendDocumentNodes(pointer) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidArgument,
    };
    const refs = try allocator.alloc(xpath.NodeRef, nodes.len);
    for (ids, 0..) |id, index| {
        refs[index] = .{ .node = root_id + id };
    }
    return refs;
}

fn convertTree(
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    tree: *const xpath_value.TreeFragment,
) error{OutOfMemory}!?xpath.NodeRef {
    _ = allocator;
    const runtime: *Runtime = @ptrCast(@alignCast(context.?));
    if (tree.merged_root) |root| return .{ .node = root };
    const root = runtime.appendDocumentNodes(tree.document) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    @constCast(tree).merged_root = root;
    runtime.refreshAfterDocumentLoad() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    return .{ .node = root };
}

const ParseExternal = struct {
    runtime: *Runtime,
    base: []const u8,
};

fn resolveExternalEntity(
    context: ?*anyopaque,
    system_id: []const u8,
    public_id: ?[]const u8,
    base_system_id: ?[]const u8,
) ?parser_mod.ExternalResource {
    _ = public_id;
    const holder: *const ParseExternal = @ptrCast(@alignCast(context.?));
    const resolver = holder.runtime.resolver orelse return null;
    const resource = resolver.load(
        resolver.context,
        system_id,
        base_system_id orelse holder.base,
    ) orelse return null;
    return .{ .data = resource.data, .uri = resource.uri };
}

fn resolveDocument(
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    href: []const u8,
    base: []const u8,
) xpath_value.DocumentError![]const xpath.NodeRef {
    const runtime: *Runtime = @ptrCast(@alignCast(context.?));
    return runtime.loadDocument(allocator, href, base);
}

/// Whether an expression references any variable. Selectors that do not are
/// independent of the local template bindings in scope and can be cached.
fn exprUsesVariables(expression: *const xpath_ast.Expr) bool {
    return switch (expression.*) {
        .variable => true,
        .binary => |binary| exprUsesVariables(binary.lhs) or
            exprUsesVariables(binary.rhs),
        .unary_minus => |inner| exprUsesVariables(inner),
        .path => |path| blk: {
            if (path.start) |start| {
                if (exprUsesVariables(start)) break :blk true;
            }
            for (path.steps) |step| {
                for (step.predicates) |predicate| {
                    if (exprUsesVariables(predicate)) break :blk true;
                }
            }
            break :blk false;
        },
        .filter => |filter| blk: {
            if (exprUsesVariables(filter.primary)) break :blk true;
            for (filter.predicates) |predicate| {
                if (exprUsesVariables(predicate)) break :blk true;
            }
            break :blk false;
        },
        .function_call => |call| blk: {
            for (call.args) |argument| {
                if (exprUsesVariables(argument)) break :blk true;
            }
            break :blk false;
        },
        .literal, .number => false,
    };
}

/// Strip the absolute-path root from a match selector so it can be evaluated
/// with a document node as the context node. This lets template rules match
/// nodes from documents loaded by `document()`.
fn relativePattern(
    allocator: std.mem.Allocator,
    selector: *xpath_ast.Expr,
) Error!*xpath_ast.Expr {
    return switch (selector.*) {
        .binary => |binary| blk: {
            if (binary.op != .union_) break :blk selector;
            const out = try allocator.create(xpath_ast.Expr);
            out.* = .{ .binary = .{
                .op = .union_,
                .lhs = try relativePattern(allocator, binary.lhs),
                .rhs = try relativePattern(allocator, binary.rhs),
            } };
            break :blk out;
        },
        .path => |path| blk: {
            if (!path.absolute or path.start != null) break :blk selector;
            const out = try allocator.create(xpath_ast.Expr);
            out.* = .{ .path = .{
                .absolute = false,
                .start = null,
                .steps = path.steps,
            } };
            break :blk out;
        },
        else => selector,
    };
}

fn generateNodeId(
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    document: *const dom.Document,
    node: xpath.NodeRef,
) error{OutOfMemory}![]const u8 {
    const runtime: *Runtime = @ptrCast(@alignCast(context.?));
    // libxslt derives namespace ids from their element's id and appends
    // "ns" plus the hex-encoded prefix.
    var target = node;
    var prefix: ?[]const u8 = null;
    switch (node) {
        .namespace_node => |namespace_node| {
            target = .{ .node = namespace_node.element };
            prefix = namespace_node.prefix;
        },
        else => {},
    }
    const entry = try runtime.node_ids.getOrPut(.{
        .document = document,
        .node = target,
    });
    if (!entry.found_existing) {
        runtime.next_node_id += 1;
        entry.value_ptr.* = runtime.next_node_id;
    }
    if (prefix) |bytes| {
        var buffer: [32]u8 = undefined;
        const base = std.fmt.bufPrint(
            &buffer,
            "id{d}ns",
            .{entry.value_ptr.*},
        ) catch return error.OutOfMemory;
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(allocator, base);
        const hex = "0123456789ABCDEF";
        for (bytes) |byte| {
            try out.append(allocator, hex[byte >> 4]);
            try out.append(allocator, hex[byte & 0x0F]);
        }
        return out.toOwnedSlice(allocator);
    }
    return std.fmt.allocPrint(allocator, "id{d}", .{entry.value_ptr.*});
}

/// Compile a union of simple match patterns such as `@*|node()` into the
/// list of per-kind tests. Returns null when any branch needs the structural
/// or selector matcher.
fn simpleUnionExpr(
    allocator: std.mem.Allocator,
    expression: *const xpath_ast.Expr,
    namespaces: []const namespace.Binding,
) Error!?[]const SimplePattern {
    const binary = switch (expression.*) {
        .binary => |value| value,
        else => return null,
    };
    if (binary.op != .union_) return null;
    var branches: std.ArrayListUnmanaged(*const xpath_ast.Expr) = .empty;
    try collectUnionBranches(allocator, &branches, expression);
    const patterns = try allocator.alloc(SimplePattern, branches.items.len);
    for (branches.items, 0..) |branch, index| {
        patterns[index] = simplePatternExpr(branch, namespaces) orelse
            return null;
    }
    return patterns;
}

fn collectUnionBranches(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(*const xpath_ast.Expr),
    expression: *const xpath_ast.Expr,
) Error!void {
    switch (expression.*) {
        .binary => |binary| if (binary.op == .union_) {
            try collectUnionBranches(allocator, out, binary.lhs);
            try collectUnionBranches(allocator, out, binary.rhs);
            return;
        },
        else => {},
    }
    try out.append(allocator, expression);
}

fn simplePatternExpr(
    expression: *const xpath_ast.Expr,
    namespaces: []const namespace.Binding,
) ?SimplePattern {
    const path = switch (expression.*) {
        .path => |value| value,
        else => return null,
    };
    if (!path.absolute or path.start != null or path.steps.len != 2) {
        return null;
    }
    const first = path.steps[0];
    if (first.axis != .descendant_or_self or first.predicates.len != 0) {
        return null;
    }
    switch (first.node_test) {
        .node => {},
        else => return null,
    }
    const second = path.steps[1];
    if (second.predicates.len != 0) return null;
    const axis = second.axis;
    if (axis != .child and axis != .attribute) return null;
    switch (second.node_test) {
        .name => |name_test| {
            var uri: []const u8 = "";
            if (name_test.prefix) |prefix| {
                uri = resolvePrefix(namespaces, prefix) orelse
                    return null;
            }
            if (axis == .attribute) {
                if (name_test.prefix == null and name_test.local == null) {
                    return .attribute_any;
                }
                return .{ .attribute_name = .{
                    .uri = uri,
                    .local = name_test.local,
                    .check_namespace = true,
                } };
            }
            if (name_test.prefix == null and name_test.local == null) {
                return .element_any;
            }
            return .{ .element_name = .{
                .uri = uri,
                .local = name_test.local,
                .check_namespace = true,
            } };
        },
        .node => {
            if (axis != .child) return null;
            return .child_node;
        },
        .text => {
            if (axis != .child) return null;
            return .text;
        },
        .comment => {
            if (axis != .child) return null;
            return .comment;
        },
        .processing_instruction => |target| {
            if (axis != .child) return null;
            return .{ .processing_instruction = target };
        },
    }
}

/// Compile a match pattern into structural chains when every union branch
/// consists only of child/attribute steps and `//` markers without
/// predicates. Such patterns are matched per candidate node and never
/// evaluated against whole documents.
fn structuralPatternExpr(
    allocator: std.mem.Allocator,
    expression: *const xpath_ast.Expr,
    namespaces: []const namespace.Binding,
) Error!?StructuralPattern {
    var alternatives: std.ArrayListUnmanaged([]const StructuralStep) = .empty;
    if (!try appendStructuralAlternative(
        allocator,
        namespaces,
        expression,
        &alternatives,
    )) return null;
    return .{
        .alternatives = try alternatives.toOwnedSlice(allocator),
        .namespaces = namespaces,
    };
}

fn appendStructuralAlternative(
    allocator: std.mem.Allocator,
    namespaces: []const namespace.Binding,
    expression: *const xpath_ast.Expr,
    alternatives: *std.ArrayListUnmanaged([]const StructuralStep),
) Error!bool {
    switch (expression.*) {
        .binary => |binary| {
            if (binary.op != .union_) return false;
            if (!try appendStructuralAlternative(
                allocator,
                namespaces,
                binary.lhs,
                alternatives,
            )) return false;
            return appendStructuralAlternative(
                allocator,
                namespaces,
                binary.rhs,
                alternatives,
            );
        },
        .path => |path| {
            if (!path.absolute or path.start != null) return false;
            const steps = try allocator.alloc(StructuralStep, path.steps.len);
            for (path.steps, 0..) |step, index| {
                // Positional and other predicates are evaluated per candidate
                // node; only a single predicate per step is supported.
                if (step.predicates.len > 1) return false;
                const predicate: ?StepPredicate = if (step.predicates.len == 1)
                    compileStepPredicate(step.predicates[0], namespaces)
                else
                    null;
                switch (step.axis) {
                    .child => {},
                    .attribute => {
                        // Attribute axes only select a single node per name.
                        if (predicate != null) return false;
                    },
                    .descendant_or_self => switch (step.node_test) {
                        .node => {
                            if (predicate != null) return false;
                        },
                        else => return false,
                    },
                    else => return false,
                }
                const structural_test: StructuralTest = switch (step.node_test) {
                    .name => |name_test| blk: {
                        var uri: []const u8 = "";
                        if (name_test.prefix) |prefix| {
                            uri = resolvePrefix(namespaces, prefix) orelse
                                return false;
                        }
                        break :blk .{ .name = .{
                            .uri = uri,
                            .local = name_test.local,
                            .check_namespace = name_test.prefix != null or
                                name_test.local != null,
                        } };
                    },
                    .node => .node,
                    .text => .text,
                    .comment => .comment,
                    .processing_instruction => |target| .{
                        .processing_instruction = target,
                    },
                };
                if (predicate) |value| {
                    // A general expression would run for every element of the
                    // document when the anchor is a wildcard, so those stay on
                    // the eager path. Compiled predicates are cheap enough.
                    switch (value) {
                        .expression => switch (structural_test) {
                            .name => |name| if (name.local == null) return false,
                            else => return false,
                        },
                        else => {},
                    }
                }
                steps[index] = .{
                    .axis = step.axis,
                    .node_test = structural_test,
                    .predicate = predicate,
                };
            }
            if (steps.len != 0) {
                const last = steps[steps.len - 1];
                if (last.axis == .descendant_or_self) return false;
                if (last.axis == .attribute) {
                    switch (last.node_test) {
                        .name => {},
                        else => return false,
                    }
                }
            }
            try alternatives.append(allocator, steps);
            return true;
        },
        else => return false,
    }
}

/// Compile a step predicate into a cheap node test when its shape is known;
/// anything else keeps the general expression evaluator.
fn compileStepPredicate(
    expression: *const xpath_ast.Expr,
    namespaces: []const namespace.Binding,
) StepPredicate {
    switch (expression.*) {
        .number => |value| {
            if (value >= 1 and value <= 1_000_000_000 and
                value == @trunc(value))
            {
                return .{ .position_compare = .{
                    .op = .eq,
                    .operand = .{ .number = value },
                } };
            }
        },
        .path => |path| {
            if (!path.absolute and path.start == null and
                path.steps.len == 1 and path.steps[0].predicates.len == 0)
            {
                const step = path.steps[0];
                if (predicateNamePattern(step, namespaces)) |name| {
                    switch (step.axis) {
                        .attribute => return .{ .attribute_exists = name },
                        .child => return .{ .child_exists = name },
                        else => {},
                    }
                }
            }
        },
        .binary => |binary| {
            switch (binary.op) {
                .eq, .ne => {
                    if (attributeValueTest(binary, namespaces)) |check| {
                        return if (binary.op == .eq)
                            .{ .attribute_equals = check }
                        else
                            .{ .attribute_not_equals = check };
                    }
                    if (positionCompare(binary)) |compare| {
                        return .{ .position_compare = compare };
                    }
                },
                .lt, .le, .gt, .ge => {
                    if (positionCompare(binary)) |compare| {
                        return .{ .position_compare = compare };
                    }
                },
                else => {},
            }
        },
        .function_call => |call| {
            if (std.mem.eql(u8, call.name, "not") and call.args.len == 1) {
                return switch (compileStepPredicate(
                    call.args[0],
                    namespaces,
                )) {
                    .attribute_exists => |name| .{ .attribute_absent = name },
                    .child_exists => |name| .{ .child_absent = name },
                    else => .{ .expression = expression },
                };
            }
        },
        else => {},
    }
    return .{ .expression = expression };
}

/// Name test of a single child or attribute step, if it is a plain name.
fn predicateNamePattern(
    step: xpath_ast.Step,
    namespaces: []const namespace.Binding,
) ?NamePattern {
    const name_test = switch (step.node_test) {
        .name => |value| value,
        else => return null,
    };
    var uri: []const u8 = "";
    if (name_test.prefix) |prefix| {
        uri = resolvePrefix(namespaces, prefix) orelse return null;
    }
    return .{
        .uri = uri,
        .local = name_test.local,
        .check_namespace = name_test.prefix != null or name_test.local != null,
    };
}

/// `@name` operand of a predicate, if the expression is exactly that.
fn predicateAttributeOperand(
    expression: *const xpath_ast.Expr,
    namespaces: []const namespace.Binding,
) ?NamePattern {
    const path = switch (expression.*) {
        .path => |value| value,
        else => return null,
    };
    if (path.absolute or path.start != null or path.steps.len != 1) return null;
    const step = path.steps[0];
    if (step.axis != .attribute or step.predicates.len != 0) return null;
    return predicateNamePattern(step, namespaces);
}

/// `@name = 'value'` / `@name != 'value'`, in either operand order.
fn attributeValueTest(
    binary: xpath_ast.Binary,
    namespaces: []const namespace.Binding,
) ?AttributeValueTest {
    if (predicateAttributeOperand(binary.lhs, namespaces)) |name| {
        if (name.local != null and binary.rhs.* == .literal) {
            return .{ .name = name, .value = binary.rhs.literal };
        }
    }
    if (predicateAttributeOperand(binary.rhs, namespaces)) |name| {
        if (name.local != null and binary.lhs.* == .literal) {
            return .{ .name = name, .value = binary.lhs.literal };
        }
    }
    return null;
}

/// `position()` compared with a number or `last()`.
fn positionCompare(binary: xpath_ast.Binary) ?PositionCompare {
    if (isPositionCall(binary.lhs)) {
        if (isPositionCall(binary.rhs)) return null;
        const operand = positionOperand(binary.rhs) orelse return null;
        return .{ .op = binary.op, .operand = operand };
    }
    if (isPositionCall(binary.rhs)) {
        const operand = positionOperand(binary.lhs) orelse return null;
        return .{ .op = flipCompare(binary.op), .operand = operand };
    }
    return null;
}

fn isPositionCall(expression: *const xpath_ast.Expr) bool {
    const call = switch (expression.*) {
        .function_call => |value| value,
        else => return false,
    };
    return call.args.len == 0 and std.mem.eql(u8, call.name, "position");
}

fn positionOperand(expression: *const xpath_ast.Expr) ?PositionOperand {
    switch (expression.*) {
        .number => |value| return .{ .number = value },
        .function_call => |call| {
            if (call.args.len == 0 and std.mem.eql(u8, call.name, "last")) {
                return .last;
            }
        },
        else => {},
    }
    return null;
}

fn flipCompare(op: xpath_ast.Op) xpath_ast.Op {
    return switch (op) {
        .lt => .gt,
        .le => .ge,
        .gt => .lt,
        .ge => .le,
        else => op,
    };
}

/// Rule precedence: later imports lose, lower priority loses, and the later
/// rule wins a full tie.
fn betterTemplate(
    current: ?*const compile.Template,
    candidate: *const compile.Template,
) *const compile.Template {
    const existing = current orelse return candidate;
    if (candidate.precedence < existing.precedence) return existing;
    if (candidate.precedence == existing.precedence) {
        if (candidate.priority < existing.priority) return existing;
        if (candidate.priority == existing.priority and
            candidate.order < existing.order)
        {
            return existing;
        }
    }
    return candidate;
}

fn modeMatches(template_mode: ?[]const u8, mode: ?[]const u8) bool {
    if (template_mode == null) return mode == null;
    if (mode == null) return false;
    return std.mem.eql(u8, template_mode.?, mode.?);
}

/// Whether every entry's sort keys compare equal to the first entry's keys.
/// A stable sort over equal keys keeps document order, so callers can skip it.
fn sortKeysAllEqual(
    all_keys: []const SortValue,
    first: []const SortValue,
    key_count: usize,
) bool {
    var index: usize = 1;
    while (index * key_count < all_keys.len) : (index += 1) {
        const keys = all_keys[index * key_count ..][0..key_count];
        for (keys, first) |value, expected| {
            if (compareSortValues(value, expected) != .eq) return false;
        }
    }
    return true;
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
    /// Zero-digit (`0`) placeholders in the integer and fraction parts.
    integer_digits: usize = 0,
    frac_digits: usize = 0,
    /// Optional-digit (`#`) placeholders; only the fraction count matters for
    /// output, but the integer count feeds libxslt's `.#` special case.
    integer_hash: usize = 0,
    frac_hash: usize = 0,
    group_size: usize = 0,
    scale: f64 = 1,
    add_decimal: bool = false,
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
    format_name: ?xpath_value.QualifiedName,
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
        return .{ .prefix = "", .suffix = "" };
    }

    var scale: f64 = 1;
    scanScale(text, format, &scale);

    // Prefix: literal text up to the first numeric or grouping character.
    // Percent/per-mille are literal here and also set the multiplier.
    var index: usize = 0;
    while (index < text.len) {
        const decoded = decodeAt(text, index) orelse
            return error.InvalidFormat;
        const cp = decoded.cp;
        if (cp == format.zero_digit or cp == format.digit or
            cp == format.decimal_separator or
            cp == format.grouping_separator)
        {
            break;
        }
        index = decoded.end;
    }
    const prefix = text[0..index];

    var integer_digits: usize = 0;
    var integer_hash: usize = 0;
    var group_size: usize = 0;
    var group_active = false;
    var group_count: usize = 0;
    while (index < text.len) {
        const decoded = decodeAt(text, index) orelse
            return error.InvalidFormat;
        const cp = decoded.cp;
        if (cp == format.decimal_separator) break;
        if (cp == format.zero_digit) {
            integer_digits += 1;
            if (group_active) group_count += 1;
        } else if (cp == format.digit) {
            integer_hash += 1;
            if (group_active) group_count += 1;
        } else if (cp == format.grouping_separator) {
            group_active = true;
            group_count = 0;
        } else {
            break;
        }
        index = decoded.end;
    }
    if (group_active) group_size = group_count;

    var add_decimal = false;
    if (index < text.len) {
        const decoded = decodeAt(text, index) orelse
            return error.InvalidFormat;
        if (decoded.cp == format.decimal_separator) {
            add_decimal = true;
            index = decoded.end;
        }
    }

    var frac_digits: usize = 0;
    var frac_hash: usize = 0;
    while (index < text.len) {
        const decoded = decodeAt(text, index) orelse
            return error.InvalidFormat;
        const cp = decoded.cp;
        if (cp == format.zero_digit) {
            if (frac_hash != 0) return error.InvalidFormat;
            frac_digits += 1;
        } else if (cp == format.digit) {
            frac_hash += 1;
        } else if (cp == format.grouping_separator) {
            // Grouping in the fraction is ignored.
        } else {
            // Percent/per-mille belong to the suffix (the whole-pattern
            // scan above already applied the multiplier).
            break;
        }
        index = decoded.end;
    }

    return .{
        .prefix = prefix,
        .suffix = text[index..],
        .integer_digits = integer_digits,
        .integer_hash = integer_hash,
        .frac_digits = frac_digits,
        .frac_hash = frac_hash,
        .group_size = group_size,
        .scale = scale,
        .add_decimal = add_decimal,
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
    /// Zero digit for decimal tokens; non-ASCII digit runs carry their own.
    zero: u21 = '0',
};

const ParsedNumberFormat = struct {
    prefix: []const u8,
    suffix: []const u8,
    tokens: []const NumberToken,
    separators: []const []const u8,
};

fn isUnicodeDecimalDigit(codepoint: u21) bool {
    return digitValue(codepoint) != null;
}

fn digitValue(codepoint: u21) ?u8 {
    if (codepoint < 0x80) {
        return if (std.ascii.isDigit(@intCast(codepoint)))
            @intCast(codepoint - '0')
        else
            null;
    }
    var low: usize = 0;
    var high: usize = unicode_categories.ranges.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const range = unicode_categories.ranges[mid];
        if (codepoint < range.start) {
            high = mid;
        } else if (codepoint > range.end) {
            low = mid + 1;
        } else {
            if (range.category != .nd) return null;
            return @intCast((codepoint - range.start) % 10);
        }
    }
    return null;
}

fn isUnicodeLetter(codepoint: u21) bool {
    if (codepoint < 0x80) {
        return std.ascii.isAlphabetic(@intCast(codepoint));
    }
    return switch (unicode_categories.categoryOf(codepoint)) {
        .lu, .ll, .lt, .lm, .lo => true,
        else => false,
    };
}

fn isFormatAlphanumeric(codepoint: u21) bool {
    return isUnicodeDecimalDigit(codepoint) or isUnicodeLetter(codepoint);
}

/// Tokenize an xsl:number format string following libxslt's rules: a digit
/// run uses its zero digit and width, letters select alphabetic or Roman
/// numbering, and other alphanumerics fall back to decimal.
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
        const current = decodeAt(text, index) orelse break;
        if (isFormatAlphanumeric(current.cp)) break;
        index = current.end;
    }
    while (index < text.len) {
        const start = index;
        const current = decodeAt(text, index) orelse break;
        var token: NumberToken = .{ .kind = .decimal };
        const initial_value = digitValue(current.cp);
        if (initial_value != null) {
            var cursor = index;
            var value = initial_value.?;
            var width: usize = 1;
            var zero: u21 = '0';
            while (value == 0) {
                width += 1;
                const digit = decodeAt(text, cursor) orelse break;
                cursor = digit.end;
                const next = decodeAt(text, cursor) orelse break;
                value = digitValue(next.cp) orelse 99;
            }
            if (value == 1) {
                const one = decodeAt(text, cursor) orelse break;
                zero = one.cp - 1;
                cursor = one.end;
            } else {
                width = 1;
                zero = '0';
            }
            token = .{ .kind = .decimal, .width = width, .zero = zero };
            index = cursor;
        } else if (current.cp == 'a' or current.cp == 'A' or
            current.cp == 'i' or current.cp == 'I')
        {
            token = .{
                .kind = if (current.cp == 'a' or current.cp == 'A')
                    .alphabetic
                else
                    .roman,
                .upper = current.cp == 'A' or current.cp == 'I',
            };
            index = current.end;
        }
        while (index < text.len) {
            const next = decodeAt(text, index) orelse break;
            if (!isFormatAlphanumeric(next.cp)) break;
            index = next.end;
        }
        try spans.append(allocator, .{
            .start = start,
            .end = index,
            .token = token,
        });
        while (index < text.len) {
            const next = decodeAt(text, index) orelse break;
            if (isFormatAlphanumeric(next.cp)) break;
            index = next.end;
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

const NumberGrouping = struct {
    separator: []const u8,
    size: usize,
};

/// libxslt reads `grouping-size` with `sscanf("%d")`: leading whitespace and
/// a sign are accepted, and trailing junk is ignored. Values that don't
/// parse disable grouping.
fn parseGroupingSize(text: []const u8) usize {
    var index: usize = 0;
    while (index < text.len and std.ascii.isWhitespace(text[index])) {
        index += 1;
    }
    var negative = false;
    if (index < text.len and (text[index] == '+' or text[index] == '-')) {
        negative = text[index] == '-';
        index += 1;
    }
    var value: usize = 0;
    var saw_digit = false;
    while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) {
        saw_digit = true;
        value = value * 10 + (text[index] - '0');
        if (value > 100000) break;
    }
    if (!saw_digit or negative) return 0;
    return value;
}

fn appendFormattedNumber(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    number: usize,
    token: NumberToken,
    grouping: ?NumberGrouping,
) Error!void {
    switch (token.kind) {
        .decimal => try appendDecimal(
            allocator,
            out,
            number,
            token.width,
            token.zero,
            grouping,
        ),
        .alphabetic => {
            if (number == 0) {
                try appendDecimal(
                    allocator,
                    out,
                    number,
                    token.width,
                    '0',
                    grouping,
                );
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
                try appendDecimal(
                    allocator,
                    out,
                    number,
                    token.width,
                    '0',
                    grouping,
                );
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
    zero: u21,
    grouping: ?NumberGrouping,
) Error!void {
    var buffer: [32]u8 = undefined;
    const digits = std.fmt.bufPrint(&buffer, "{d}", .{number}) catch
        return error.InvalidArgument;
    const padding = if (digits.len < width) width - digits.len else 0;
    const total = padding + digits.len;
    const group_size = if (grouping) |group| group.size else 0;
    var index: usize = 0;
    while (index < total) : (index += 1) {
        if (group_size > 0 and index > 0 and
            (total - index) % group_size == 0)
        {
            try out.appendSlice(allocator, grouping.?.separator);
        }
        if (index < padding) {
            try appendNumberDigit(allocator, out, zero);
        } else {
            const byte = digits[index - padding];
            try appendNumberDigit(allocator, out, zero + (byte - '0'));
        }
    }
}

fn appendNumberDigit(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    codepoint: u21,
) Error!void {
    var encoded: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(codepoint, &encoded) catch
        return error.InvalidArgument;
    try out.appendSlice(allocator, encoded[0..length]);
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
                            candidate_node.localName(),
                            current_node.localName(),
                        ) and std.mem.eql(
                            u8,
                            document.ns(candidate_node.ns),
                            document.ns(current_node.ns),
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
                    ) and std.mem.eql(
                        u8,
                        document.ns(left.ns),
                        document.ns(right.ns),
                    );
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

fn resolveGlobalVariable(
    context: *anyopaque,
    name: []const u8,
) anyerror!?xpath.Value {
    const self: *Runtime = @ptrCast(@alignCast(context));
    const index = self.global_index.get(name) orelse return null;
    return try self.ensureGlobal(index);
}

fn findExtensionFunction(
    stylesheet: *const compile.Stylesheet,
    uri: []const u8,
    local: []const u8,
) ?*const compile.FunctionDef {
    var found: ?*const compile.FunctionDef = null;
    for (stylesheet.functions) |*function| {
        if (!std.mem.eql(u8, function.namespace_uri, uri) or
            !std.mem.eql(u8, function.name, local))
        {
            continue;
        }
        if (found) |current| {
            if (function.precedence < current.precedence) continue;
            if (function.precedence == current.precedence and
                function.order < current.order)
            {
                continue;
            }
        }
        found = function;
    }
    return found;
}

fn extensionFunctionAvailable(
    context: *anyopaque,
    uri: []const u8,
    local: []const u8,
) bool {
    const self: *Runtime = @ptrCast(@alignCast(context));
    return findExtensionFunction(self.stylesheet, uri, local) != null;
}

fn callExtensionFunction(
    context: *anyopaque,
    allocator: std.mem.Allocator,
    uri: []const u8,
    local: []const u8,
    args: []const xpath.Value,
    xpath_context: *const xpath_value.Context,
) anyerror!xpath.Value {
    _ = allocator;
    const self: *Runtime = @ptrCast(@alignCast(context));
    const function = findExtensionFunction(
        self.stylesheet,
        uri,
        local,
    ) orelse return error.UnknownFunction;

    // Function bodies see globals and their own parameters, never the
    // caller's local bindings.
    const saved_variables = self.variable_len;
    const saved_floor = self.variable_floor;
    self.variable_floor = saved_variables;
    const saved_result = self.function_result;
    self.function_result = null;
    const value = runExtensionFunction(
        self,
        function,
        args,
        xpath_context,
    ) catch |err| {
        self.function_result = saved_result;
        self.variable_floor = saved_floor;
        self.variable_len = saved_variables;
        return err;
    };
    self.function_result = saved_result;
    self.variable_floor = saved_floor;
    self.variable_len = saved_variables;
    return value;
}

fn runExtensionFunction(
    self: *Runtime,
    function: *const compile.FunctionDef,
    args: []const xpath.Value,
    xpath_context: *const xpath_value.Context,
) Error!xpath.Value {
    const node = xpath_context.node;
    const position = xpath_context.position;
    const size = xpath_context.size;
    var index: usize = 0;
    for (function.params) |param| {
        const value = if (index < args.len)
            args[index]
        else
            try self.evaluateVariableValue(
                param.value,
                node,
                position,
                size,
            );
        try self.pushVariable(.{
            .name = param.name,
            .value = value,
        });
        index += 1;
    }
    if (self.executeInstructions(function.body, node, position, size)) |_| {
        // EXSLT functions without a result return an empty string.
        return self.function_result orelse .{ .string = "" };
    } else |err| {
        if (err == error.FunctionResultReturned) {
            return self.function_result orelse .{ .string = "" };
        }
        return err;
    }
}

fn prefixOf(node: *const dom.Node) []const u8 {
    if (node.localName().len >= node.name.len) return "";
    return node.name[0 .. node.name.len - node.localName().len - 1];
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
    charset: []const u8,
    format: bool,
    compat: bool,
    default_ns: []const u8,
) std.Io.Writer.Error!void {
    const node_value = document.node(id);
    switch (node_value.kind) {
        .document => {
            var child = node_value.first_child;
            while (child != dom.null_node) : (child = document.node(child).next_sibling) {
                try writeHtmlNode(
                    out,
                    document,
                    child,
                    false,
                    charset,
                    format,
                    compat,
                    "",
                );
            }
            if (compat) try out.writeByte('\n');
        },
        .element => try writeHtmlElement(
            out,
            document,
            id,
            charset,
            format,
            compat,
            default_ns,
        ),
        .text => {
            if (raw_text or node_value.isRawText()) {
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
            try out.writeByte('>');
        },
    }
}

fn writeHtmlElement(
    out: *std.Io.Writer,
    document: *const dom.Document,
    id: dom.NodeId,
    charset: []const u8,
    format: bool,
    compat: bool,
    default_ns: []const u8,
) std.Io.Writer.Error!void {
    const node_value = document.node(id);
    const info = if (document.ns(node_value.ns).len == 0)
        htmlTagInfo(node_value.localName())
    else
        null;
    const is_p = node_value.localName().len != 0 and node_value.localName()[0] == 'p';
    const prefixed = std.mem.indexOfScalar(u8, node_value.name, ':') != null;
    var declared_default: ?[]const u8 = null;
    for (document.attributesOf(id)) |attr| {
        if (std.mem.eql(u8, attr.name, "xmlns")) {
            declared_default = attr.value;
        }
    }
    var child_default = default_ns;
    var synthesize_default = false;
    if (!prefixed) {
        if (declared_default) |value| {
            child_default = value;
        } else if (!std.mem.eql(u8, document.ns(node_value.ns), default_ns)) {
            synthesize_default = true;
            child_default = document.ns(node_value.ns);
        }
    }
    try out.writeByte('<');
    try out.writeAll(node_value.name);
    if (synthesize_default) {
        try out.writeAll(" xmlns=\"");
        try writeHtmlAttribute(out, document.ns(node_value.ns));
        try out.writeByte('"');
    }
    for (document.attributesOf(id)) |attr| {
        try out.writeByte(' ');
        try out.writeAll(attr.name);
        if (document.ns(attr.ns).len == 0 and isHtmlBooleanAttribute(attr.name)) {
            continue;
        }
        try out.writeAll("=\"");
        if (isHtmlUriAttribute(attr.name)) {
            try writeHtmlUriAttribute(out, attr.value);
        } else {
            try writeHtmlAttribute(out, attr.value);
        }
        try out.writeByte('"');
    }
    if (info) |tag| {
        if (tag.empty) {
            try out.writeByte('>');
            return;
        }
    }
    if (node_value.first_child == dom.null_node and
        !(compat and isHtmlHeadWithMeta(document, id)))
    {
        if (info != null and info.?.save_end and !is_p and
            !std.ascii.eqlIgnoreCase(node_value.localName(), "html") and
            !std.ascii.eqlIgnoreCase(node_value.localName(), "body"))
        {
            try out.writeByte('>');
        } else {
            try out.writeAll("></");
            try out.writeAll(node_value.name);
            try out.writeByte('>');
        }
    } else {
        try out.writeByte('>');
        const insert_meta = compat and isHtmlHeadWithMeta(document, id);
        const first = if (node_value.first_child != dom.null_node)
            document.node(node_value.first_child)
        else
            null;
        const last = if (node_value.last_child != dom.null_node)
            document.node(node_value.last_child)
        else
            null;
        var child_count: usize = if (insert_meta) 1 else 0;
        var real_count: usize = 0;
        var child = node_value.first_child;
        while (child != dom.null_node) : (child = document.node(child).next_sibling) {
            real_count += 1;
            child_count += 1;
        }
        const first_is_text = if (insert_meta)
            false
        else if (first) |value|
            value.kind == .text
        else
            false;
        if (format and info != null and !info.?.is_inline and
            !first_is_text and child_count > 1 and !is_p)
        {
            try out.writeByte('\n');
        }
        if (insert_meta) {
            const prefix = node_value.name[0 .. node_value.name.len - node_value.localName().len];
            try out.writeByte('<');
            try out.writeAll(prefix);
            try out.writeAll("meta charset=\"");
            try writeHtmlAttribute(out, charset);
            try out.writeAll("\">");
            if (format and info != null and !info.?.is_inline and
                real_count != 0 and child_count > 1 and !is_p)
            {
                if (first) |value| {
                    if (value.kind != .text) try out.writeByte('\n');
                }
            }
        }
        const raw_text = document.ns(node_value.ns).len == 0 and
            (std.ascii.eqlIgnoreCase(node_value.localName(), "script") or
                std.ascii.eqlIgnoreCase(node_value.localName(), "style"));
        child = node_value.first_child;
        while (child != dom.null_node) : (child = document.node(child).next_sibling) {
            try writeHtmlNode(
                out,
                document,
                child,
                raw_text,
                charset,
                format,
                compat,
                child_default,
            );
        }
        const last_is_text = if (last) |value| value.kind == .text else false;
        if (format and info != null and !info.?.is_inline and
            !last_is_text and child_count > 1 and !is_p)
        {
            try out.writeByte('\n');
        }
        try out.writeAll("</");
        try out.writeAll(node_value.name);
        try out.writeByte('>');
    }
    if (format and info != null and !info.?.is_inline and
        node_value.next_sibling != dom.null_node)
    {
        const next = document.node(node_value.next_sibling);
        if (next.kind != .text and node_value.parent != dom.null_node) {
            const parent = document.node(node_value.parent);
            if (parent.kind == .element and
                (parent.localName().len == 0 or parent.localName()[0] != 'p'))
            {
                try out.writeByte('\n');
            }
        }
    }
}

fn isHtmlHeadWithMeta(document: *const dom.Document, id: dom.NodeId) bool {
    const node_value = document.node(id);
    if (!std.ascii.eqlIgnoreCase(node_value.localName(), "head")) return false;
    return !hasHtmlCharsetMeta(document, id);
}

fn hasHtmlCharsetMeta(document: *const dom.Document, id: dom.NodeId) bool {
    var child = document.node(id).first_child;
    while (child != dom.null_node) : (child = document.node(child).next_sibling) {
        const node_value = document.node(child);
        if (node_value.kind != .element) continue;
        if (!std.ascii.eqlIgnoreCase(node_value.localName(), "meta")) continue;
        if (document.attribute(child, "charset") != null or
            document.attribute(child, "http-equiv") != null)
        {
            return true;
        }
    }
    return false;
}

const HtmlTagInfo = struct {
    name: []const u8,
    empty: bool = false,
    save_end: bool = false,
    is_inline: bool = false,
};

const html_tag_table = [_]HtmlTagInfo{
    .{ .name = "a", .is_inline = true },
    .{ .name = "abbr", .is_inline = true },
    .{ .name = "acronym", .is_inline = true },
    .{ .name = "address" },
    .{ .name = "applet" },
    .{ .name = "area", .empty = true },
    .{ .name = "b", .is_inline = true },
    .{ .name = "base", .empty = true },
    .{ .name = "basefont", .empty = true, .is_inline = true },
    .{ .name = "bdo", .is_inline = true },
    .{ .name = "big", .is_inline = true },
    .{ .name = "blockquote" },
    .{ .name = "body" },
    .{ .name = "br", .empty = true, .is_inline = true },
    .{ .name = "button" },
    .{ .name = "caption" },
    .{ .name = "center" },
    .{ .name = "cite", .is_inline = true },
    .{ .name = "code", .is_inline = true },
    .{ .name = "col", .empty = true },
    .{ .name = "colgroup" },
    .{ .name = "dd" },
    .{ .name = "del" },
    .{ .name = "dfn", .is_inline = true },
    .{ .name = "dir" },
    .{ .name = "div" },
    .{ .name = "dl" },
    .{ .name = "dt" },
    .{ .name = "em", .is_inline = true },
    .{ .name = "embed", .is_inline = true },
    .{ .name = "fieldset" },
    .{ .name = "font", .is_inline = true },
    .{ .name = "form" },
    .{ .name = "frame", .empty = true },
    .{ .name = "frameset" },
    .{ .name = "h1" },
    .{ .name = "h2" },
    .{ .name = "h3" },
    .{ .name = "h4" },
    .{ .name = "h5" },
    .{ .name = "h6" },
    .{ .name = "head" },
    .{ .name = "hr", .empty = true },
    .{ .name = "html" },
    .{ .name = "i", .is_inline = true },
    .{ .name = "iframe" },
    .{ .name = "img", .empty = true, .is_inline = true },
    .{ .name = "input", .empty = true, .is_inline = true },
    .{ .name = "ins" },
    .{ .name = "isindex", .empty = true },
    .{ .name = "kbd", .is_inline = true },
    .{ .name = "label", .is_inline = true },
    .{ .name = "legend" },
    .{ .name = "li", .save_end = true },
    .{ .name = "link", .empty = true },
    .{ .name = "map" },
    .{ .name = "menu" },
    .{ .name = "meta", .empty = true },
    .{ .name = "noframes" },
    .{ .name = "noscript" },
    .{ .name = "object" },
    .{ .name = "ol" },
    .{ .name = "optgroup" },
    .{ .name = "option" },
    .{ .name = "p" },
    .{ .name = "param", .empty = true },
    .{ .name = "pre" },
    .{ .name = "q", .is_inline = true },
    .{ .name = "s", .is_inline = true },
    .{ .name = "samp", .is_inline = true },
    .{ .name = "script" },
    .{ .name = "select", .is_inline = true },
    .{ .name = "small", .is_inline = true },
    .{ .name = "span", .is_inline = true },
    .{ .name = "strike", .is_inline = true },
    .{ .name = "strong", .is_inline = true },
    .{ .name = "style" },
    .{ .name = "sub", .is_inline = true },
    .{ .name = "sup", .is_inline = true },
    .{ .name = "table" },
    .{ .name = "tbody" },
    .{ .name = "td" },
    .{ .name = "textarea", .is_inline = true },
    .{ .name = "tfoot" },
    .{ .name = "th" },
    .{ .name = "thead" },
    .{ .name = "title" },
    .{ .name = "tr" },
    .{ .name = "tt", .is_inline = true },
    .{ .name = "u", .is_inline = true },
    .{ .name = "ul" },
    .{ .name = "var", .is_inline = true },
};

const html_tag_map = std.StaticStringMap(HtmlTagInfo).initComptime(blk: {
    var entries: [html_tag_table.len]struct {
        []const u8,
        HtmlTagInfo,
    } = undefined;
    for (html_tag_table, 0..) |info, index| {
        entries[index] = .{ info.name, info };
    }
    break :blk entries;
});

const html_uri_attributes = std.StaticStringMap(void).initComptime(.{
    .{ "href", {} },
    .{ "src", {} },
    .{ "action", {} },
    .{ "name", {} },
    .{ "cite", {} },
    .{ "longdesc", {} },
    .{ "usemap", {} },
    .{ "background", {} },
    .{ "profile", {} },
    .{ "classid", {} },
    .{ "codebase", {} },
    .{ "data", {} },
    .{ "formaction", {} },
    .{ "icon", {} },
    .{ "manifest", {} },
    .{ "poster", {} },
});

const html_boolean_attributes = std.StaticStringMap(void).initComptime(.{
    .{ "checked", {} },
    .{ "compact", {} },
    .{ "declare", {} },
    .{ "defer", {} },
    .{ "disabled", {} },
    .{ "ismap", {} },
    .{ "multiple", {} },
    .{ "nohref", {} },
    .{ "noresize", {} },
    .{ "noshade", {} },
    .{ "nowrap", {} },
    .{ "readonly", {} },
    .{ "selected", {} },
});

/// HTML element and attribute names are ASCII; lowercase into a stack buffer
/// before the table lookup so lookups stay case-insensitive.
fn htmlNameLower(name: []const u8, buffer: []u8) ?[]const u8 {
    if (name.len > buffer.len) return null;
    return std.ascii.lowerString(buffer, name);
}

fn htmlTagInfo(name: []const u8) ?HtmlTagInfo {
    var buffer: [64]u8 = undefined;
    const lower = htmlNameLower(name, &buffer) orelse return null;
    return html_tag_map.get(lower);
}

fn isHtmlUriAttribute(name: []const u8) bool {
    var buffer: [64]u8 = undefined;
    const lower = htmlNameLower(name, &buffer) orelse return false;
    return html_uri_attributes.has(lower);
}

fn writeHtmlUriAttribute(
    out: *std.Io.Writer,
    value: []const u8,
) std.Io.Writer.Error!void {
    const hex = "0123456789ABCDEF";
    // libxml2 drops leading whitespace from URI attribute values and
    // escapes interior/trailing whitespace.
    var start: usize = 0;
    while (start < value.len and std.ascii.isWhitespace(value[start])) {
        start += 1;
    }
    for (value[start..]) |byte| {
        switch (byte) {
            '&' => try out.writeAll("&amp;"),
            '<' => try out.writeAll("&lt;"),
            '>' => try out.writeAll("&gt;"),
            '"' => try out.writeAll("&quot;"),
            else => {
                if (byte >= 0x80 or byte == ' ') {
                    try out.writeByte('%');
                    try out.writeByte(hex[byte >> 4]);
                    try out.writeByte(hex[byte & 0x0F]);
                } else {
                    try out.writeByte(byte);
                }
            },
        }
    }
}

fn findHtmlTextSpecial(text: []const u8, start: usize) usize {
    const Vec = @Vector(32, u8);
    const amp: Vec = @splat('&');
    const lt: Vec = @splat('<');
    const gt: Vec = @splat('>');
    var index = start;
    while (index + 32 <= text.len) : (index += 32) {
        const chunk: Vec = text[index..][0..32].*;
        const mask: u32 = @bitCast((chunk == amp) | (chunk == lt) | (chunk == gt));
        if (mask != 0) return index + @ctz(mask);
    }
    while (index < text.len) : (index += 1) {
        switch (text[index]) {
            '&', '<', '>' => return index,
            else => {},
        }
    }
    return text.len;
}

fn findHtmlAttributeSpecial(value: []const u8, start: usize) usize {
    const Vec = @Vector(32, u8);
    const amp: Vec = @splat('&');
    const lt: Vec = @splat('<');
    const gt: Vec = @splat('>');
    const quote: Vec = @splat('"');
    var index = start;
    while (index + 32 <= value.len) : (index += 32) {
        const chunk: Vec = value[index..][0..32].*;
        const mask: u32 = @bitCast(
            (chunk == amp) | (chunk == lt) | (chunk == gt) | (chunk == quote),
        );
        if (mask != 0) return index + @ctz(mask);
    }
    while (index < value.len) : (index += 1) {
        switch (value[index]) {
            '&', '<', '>', '"' => return index,
            else => {},
        }
    }
    return value.len;
}

fn writeHtmlText(
    out: *std.Io.Writer,
    text: []const u8,
) std.Io.Writer.Error!void {
    var pos: usize = 0;
    while (pos < text.len) {
        const special = findHtmlTextSpecial(text, pos);
        if (special > pos) {
            try out.writeAll(text[pos..special]);
            pos = special;
            if (pos >= text.len) break;
        }
        switch (text[pos]) {
            '&' => try out.writeAll("&amp;"),
            '<' => try out.writeAll("&lt;"),
            '>' => try out.writeAll("&gt;"),
            else => unreachable,
        }
        pos += 1;
    }
}

fn writeHtmlAttribute(
    out: *std.Io.Writer,
    value: []const u8,
) std.Io.Writer.Error!void {
    var pos: usize = 0;
    while (pos < value.len) {
        const special = findHtmlAttributeSpecial(value, pos);
        if (special > pos) {
            try out.writeAll(value[pos..special]);
            pos = special;
            if (pos >= value.len) break;
        }
        switch (value[pos]) {
            '&' => try out.writeAll("&amp;"),
            '<' => try out.writeAll("&lt;"),
            '>' => try out.writeAll("&gt;"),
            '"' => try out.writeAll("&quot;"),
            else => unreachable,
        }
        pos += 1;
    }
}

fn isHtmlBooleanAttribute(name: []const u8) bool {
    var buffer: [64]u8 = undefined;
    const lower = htmlNameLower(name, &buffer) orelse return false;
    return html_boolean_attributes.has(lower);
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
