//! RELAX NG XML syntax parsing.
//!
//! The schema is compiled into a pattern tree. References are resolved to
//! `Define` pointers so recursive grammars work without copying. Includes and
//! external references are loaded through the same resolver interface used by
//! the XML Schema compiler.

const std = @import("std");
const dom = @import("../dom.zig");
const encoding = @import("../encoding.zig");
const datatypes = @import("../xsd/datatypes.zig");
const regex = @import("../xsd/regex.zig");

pub const structure_namespace = "http://relaxng.org/ns/structure/1.0";

pub const Error = error{
    OutOfMemory,
    InvalidSchema,
    InvalidPattern,
};

pub const Name = struct {
    ns: []const u8,
    local: []const u8,
};

pub const AnyName = struct {
    except: ?*const NameClass = null,
};

pub const NsName = struct {
    ns: []const u8,
    except: ?*const NameClass = null,
};

pub const NameClass = union(enum) {
    name: Name,
    any_name: AnyName,
    ns_name: NsName,
    choice: struct {
        left: *const NameClass,
        right: *const NameClass,
    },
};

pub const Param = struct {
    name: []const u8,
    value: []const u8,
};

pub const Data = struct {
    library: []const u8 = "",
    type_name: []const u8,
    kind: datatypes.Kind,
    facets: datatypes.Facets = .{},
    params: []const Param = &.{},
    /// Optional `except` pattern; matching values are rejected.
    except: ?*const Pattern = null,
};

pub const Value = struct {
    library: []const u8 = "",
    type_name: []const u8 = "token",
    kind: datatypes.Kind = .token,
    ns: []const u8 = "",
    text: []const u8,
};

pub const Pattern = union(enum) {
    empty,
    not_allowed,
    text,
    element: struct {
        name_class: *const NameClass,
        content: *const Pattern,
    },
    attribute: struct {
        name_class: *const NameClass,
        content: *const Pattern,
    },
    group: struct {
        left: *const Pattern,
        right: *const Pattern,
    },
    interleave: struct {
        left: *const Pattern,
        right: *const Pattern,
    },
    choice: struct {
        left: *const Pattern,
        right: *const Pattern,
    },
    optional: *const Pattern,
    zero_or_more: *const Pattern,
    one_or_more: *const Pattern,
    mixed: *const Pattern,
    data: Data,
    value: Value,
    list: *const Pattern,
    ref: *const Define,
    parent_ref: *const Define,
};

pub const Define = struct {
    name: []const u8,
    pattern: ?*const Pattern = null,
};

pub const Schema = struct {
    arena: std.heap.ArenaAllocator,
    start: *const Pattern,
    documents: []const *dom.Document = &.{},
    regexes: []*regex.Regex = &.{},

    pub fn deinit(self: *Schema) void {
        for (self.regexes) |compiled| compiled.deinit();
        for (self.documents) |document| document.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Resource = struct {
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
    resolver: ?Resolver = null,
    base: []const u8 = "",
};

/// Compile a RELAX NG schema without external includes.
pub fn parse(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
) Error!Schema {
    return parseWithOptions(allocator, document, .{});
}

pub fn parseWithOptions(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
    options: Options,
) Error!Schema {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const root_scope = try arena.allocator().create(Scope);
    root_scope.* = .{
        .map = std.StringHashMap(*Define).init(arena.allocator()),
    };
    var parser: Parser = .{
        .arena = arena.allocator(),
        .backing_allocator = allocator,
        .document = document,
        .options = options,
        .base = options.base,
        .scope = root_scope,
    };
    errdefer parser.deinitDocuments();
    try parser.parseRoot();
    try parser.checkDefines();
    return .{
        .arena = arena,
        .start = parser.start orelse return error.InvalidSchema,
        .documents = try parser.documents.toOwnedSlice(parser.arena),
        .regexes = try parser.regexes.toOwnedSlice(parser.arena),
    };
}

const Scope = struct {
    map: std.StringHashMap(*Define),
    parent: ?*Scope = null,
};

const Parser = struct {
    arena: std.mem.Allocator,
    backing_allocator: std.mem.Allocator,
    document: *const dom.Document,
    options: Options,
    base: []const u8,
    documents: std.ArrayList(*dom.Document) = .empty,
    regexes: std.ArrayList(*regex.Regex) = .empty,
    defines: std.ArrayList(*Define) = .empty,
    scope: *Scope,
    grammar_depth: usize = 0,
    start_patterns: std.ArrayList(*const Pattern) = .empty,
    start: ?*const Pattern = null,
    parents: std.ArrayList(*const Define) = .empty,
    include_stack: std.ArrayList([]const u8) = .empty,

    fn deinitDocuments(self: *Parser) void {
        for (self.regexes.items) |compiled| compiled.deinit();
        for (self.documents.items) |document| document.deinit();
    }

    fn parseRoot(self: *Parser) Error!void {
        const root = self.document.root();
        if (root == dom.null_node) return error.InvalidSchema;
        const node = self.document.node(root);
        if (node.kind != .element) return error.InvalidSchema;
        if (!std.mem.eql(u8, node.ns, structure_namespace)) {
            return error.InvalidSchema;
        }
        if (std.mem.eql(u8, node.local, "grammar")) {
            try self.parseGrammarChildren(root);
            if (self.start_patterns.items.len == 0) {
                return error.InvalidSchema;
            }
            self.start = try self.combineStart();
        } else {
            self.start = try self.parsePattern(root);
        }
    }

    fn combineStart(self: *Parser) Error!*const Pattern {
        var combined = self.start_patterns.items[0];
        for (self.start_patterns.items[1..]) |next| {
            combined = try self.make(.{ .choice = .{
                .left = combined,
                .right = next,
            } });
        }
        return combined;
    }

    fn parseGrammarChildren(self: *Parser, id: dom.NodeId) Error!void {
        var child = self.document.node(id).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const node = self.document.node(child);
            if (node.kind != .element) continue;
            if (!std.mem.eql(u8, node.ns, structure_namespace)) continue;
            if (std.mem.eql(u8, node.local, "start")) {
                const pattern = try self.singlePatternChild(child);
                try self.start_patterns.append(self.arena, pattern);
                continue;
            }
            if (std.mem.eql(u8, node.local, "define")) {
                try self.parseDefine(child, false);
                continue;
            }
            if (std.mem.eql(u8, node.local, "div")) {
                try self.parseGrammarChildren(child);
                continue;
            }
            if (std.mem.eql(u8, node.local, "include")) {
                try self.parseInclude(child);
                continue;
            }
            if (std.mem.eql(u8, node.local, "annotation")) continue;
            return error.InvalidPattern;
        }
    }

    fn parseDefine(self: *Parser, id: dom.NodeId, override: bool) Error!void {
        const name = self.document.attribute(id, "name") orelse
            return error.InvalidPattern;
        const combine = self.document.attribute(id, "combine") orelse "choice";
        const interleave = if (std.mem.eql(u8, combine, "interleave"))
            true
        else if (std.mem.eql(u8, combine, "choice"))
            false
        else
            return error.InvalidPattern;
        const existing = self.findDefine(name);
        if (override and existing != null) {
            // An include override replaces the included definition. The
            // replacement gets its own Define so self-references inside the
            // new body still resolve to the included definition.
            const replacement = try self.createDefine(name);
            try self.parents.append(self.arena, replacement);
            const body = self.singlePatternChild(id) catch |err| {
                _ = self.parents.pop();
                return err;
            };
            _ = self.parents.pop();
            replacement.pattern = body;
            try self.scope.map.put(name, replacement);
            return;
        }
        const define = existing orelse try self.createDefine(name);
        try self.parents.append(self.arena, define);
        const body = self.singlePatternChild(id) catch |err| {
            _ = self.parents.pop();
            return err;
        };
        _ = self.parents.pop();
        if (define.pattern) |previous| {
            define.pattern = try self.make(if (interleave)
                .{ .interleave = .{ .left = previous, .right = body } }
            else
                .{ .choice = .{ .left = previous, .right = body } });
        } else {
            define.pattern = body;
        }
    }

    fn createDefine(self: *Parser, name: []const u8) Error!*Define {
        const define = try self.arena.create(Define);
        define.* = .{ .name = try self.arena.dupe(u8, name) };
        try self.defines.append(self.arena, define);
        try self.scope.map.put(define.name, define);
        return define;
    }

    fn parseInclude(self: *Parser, id: dom.NodeId) Error!void {
        const loaded = try self.loadReference(id);
        const saved_document = self.document;
        const saved_base = self.base;
        self.document = loaded.document;
        self.base = loaded.uri;
        defer {
            self.document = saved_document;
            self.base = saved_base;
        }
        const root = self.document.root();
        if (root == dom.null_node) return error.InvalidSchema;
        const node = self.document.node(root);
        if (!std.mem.eql(u8, node.ns, structure_namespace) or
            !std.mem.eql(u8, node.local, "grammar"))
        {
            return error.InvalidSchema;
        }
        const start_mark = self.start_patterns.items.len;
        try self.parseGrammarChildren(root);
        self.document = saved_document;
        self.base = saved_base;
        // Include children override included definitions and start patterns.
        var child = self.document.node(id).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const child_node = self.document.node(child);
            if (child_node.kind != .element) continue;
            if (!std.mem.eql(u8, child_node.ns, structure_namespace)) continue;
            if (std.mem.eql(u8, child_node.local, "start")) {
                const pattern = try self.singlePatternChild(child);
                self.start_patterns.shrinkRetainingCapacity(start_mark);
                try self.start_patterns.append(self.arena, pattern);
                continue;
            }
            if (std.mem.eql(u8, child_node.local, "define")) {
                try self.parseDefine(child, true);
                continue;
            }
            if (std.mem.eql(u8, child_node.local, "div")) {
                try self.parseIncludeOverrides(child);
                continue;
            }
            if (std.mem.eql(u8, child_node.local, "annotation")) continue;
            return error.InvalidPattern;
        }
    }

    fn parseIncludeOverrides(self: *Parser, id: dom.NodeId) Error!void {
        var child = self.document.node(id).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const node = self.document.node(child);
            if (node.kind != .element) continue;
            if (!std.mem.eql(u8, node.ns, structure_namespace)) continue;
            if (std.mem.eql(u8, node.local, "define")) {
                try self.parseDefine(child, true);
                continue;
            }
            if (std.mem.eql(u8, node.local, "div")) {
                try self.parseIncludeOverrides(child);
                continue;
            }
            if (std.mem.eql(u8, node.local, "start")) {
                const pattern = try self.singlePatternChild(child);
                try self.start_patterns.append(self.arena, pattern);
                continue;
            }
            if (std.mem.eql(u8, node.local, "annotation")) continue;
            return error.InvalidPattern;
        }
    }

    const Loaded = struct {
        document: *dom.Document,
        uri: []const u8,
    };

    fn loadReference(self: *Parser, id: dom.NodeId) Error!Loaded {
        const href = self.document.attribute(id, "href") orelse
            return error.InvalidSchema;
        const resolver = self.options.resolver orelse
            return error.InvalidSchema;
        const resource = resolver.load(
            resolver.context,
            href,
            self.base,
        ) orelse return error.InvalidSchema;
        const uri = if (resource.uri.len != 0) resource.uri else href;
        const owned_uri = try self.arena.dupe(u8, uri);
        for (self.include_stack.items) |active| {
            if (std.mem.eql(u8, active, owned_uri)) {
                return error.InvalidSchema;
            }
        }
        const owned = try self.arena.dupe(u8, resource.data);
        const decoded = encoding.decodeAlloc(
            self.arena,
            owned,
            64 * 1024 * 1024,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidSchema,
        };
        const document = try self.arena.create(dom.Document);
        document.* = dom.Document.parse(
            self.backing_allocator,
            decoded,
            .{},
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidSchema,
        };
        try self.documents.append(self.arena, document);
        return .{ .document = document, .uri = owned_uri };
    }

    fn checkDefines(self: *Parser) Error!void {
        for (self.defines.items) |define| {
            if (define.pattern == null) return error.InvalidSchema;
        }
    }

    fn make(self: *Parser, value: Pattern) Error!*const Pattern {
        const ptr = try self.arena.create(Pattern);
        ptr.* = value;
        return ptr;
    }

    fn nameClass(self: *Parser, value: NameClass) Error!*const NameClass {
        const ptr = try self.arena.create(NameClass);
        ptr.* = value;
        return ptr;
    }

    fn parsePattern(self: *Parser, id: dom.NodeId) Error!*const Pattern {
        const node = self.document.node(id);
        if (node.kind != .element or
            !std.mem.eql(u8, node.ns, structure_namespace))
        {
            return error.InvalidPattern;
        }
        const local = node.local;
        if (std.mem.eql(u8, local, "empty")) return self.make(.empty);
        if (std.mem.eql(u8, local, "notAllowed")) {
            return self.make(.not_allowed);
        }
        if (std.mem.eql(u8, local, "text")) return self.make(.text);
        if (std.mem.eql(u8, local, "element")) {
            const parts = try self.nameAndContent(id);
            return self.make(.{ .element = .{
                .name_class = parts.name_class,
                .content = parts.content,
            } });
        }
        if (std.mem.eql(u8, local, "attribute")) {
            const parts = try self.nameAndContent(id);
            return self.make(.{ .attribute = .{
                .name_class = parts.name_class,
                .content = parts.content,
            } });
        }
        if (std.mem.eql(u8, local, "group") or
            std.mem.eql(u8, local, "interleave") or
            std.mem.eql(u8, local, "choice"))
        {
            const children = try self.twoPatternChildren(id);
            const value: Pattern = if (std.mem.eql(u8, local, "group"))
                .{ .group = .{ .left = children[0], .right = children[1] } }
            else if (std.mem.eql(u8, local, "interleave"))
                .{ .interleave = .{ .left = children[0], .right = children[1] } }
            else
                .{ .choice = .{ .left = children[0], .right = children[1] } };
            return self.make(value);
        }
        if (std.mem.eql(u8, local, "optional") or
            std.mem.eql(u8, local, "zeroOrMore") or
            std.mem.eql(u8, local, "oneOrMore") or
            std.mem.eql(u8, local, "mixed") or
            std.mem.eql(u8, local, "list"))
        {
            const child = try self.singlePatternChild(id);
            const value: Pattern = if (std.mem.eql(u8, local, "optional"))
                .{ .optional = child }
            else if (std.mem.eql(u8, local, "zeroOrMore"))
                .{ .zero_or_more = child }
            else if (std.mem.eql(u8, local, "oneOrMore"))
                .{ .one_or_more = child }
            else if (std.mem.eql(u8, local, "mixed"))
                .{ .mixed = child }
            else
                .{ .list = child };
            return self.make(value);
        }
        if (std.mem.eql(u8, local, "data")) return self.parseData(id);
        if (std.mem.eql(u8, local, "value")) return self.parseValue(id);
        if (std.mem.eql(u8, local, "ref")) {
            const name = self.document.attribute(id, "name") orelse
                return error.InvalidPattern;
            const define = self.findDefine(name) orelse
                try self.createDefine(name);
            return self.make(.{ .ref = define });
        }
        if (std.mem.eql(u8, local, "parentRef")) {
            if (self.grammar_depth == 0) return error.InvalidPattern;
            const name = self.document.attribute(id, "name") orelse
                return error.InvalidPattern;
            const define = self.findDefineInParent(name) orelse
                return error.InvalidPattern;
            return self.make(.{ .parent_ref = define });
        }
        if (std.mem.eql(u8, local, "externalRef")) {
            return self.parseExternalRef(id);
        }
        if (std.mem.eql(u8, local, "grammar")) {
            return self.parseNestedGrammar(id);
        }
        return error.InvalidPattern;
    }

    fn findDefineInParent(self: *Parser, name: []const u8) ?*Define {
        var scope = self.scope.parent;
        while (scope) |current| {
            if (current.map.get(name)) |define| return define;
            scope = current.parent;
        }
        return null;
    }

    fn findDefine(self: *Parser, name: []const u8) ?*Define {
        var scope: ?*Scope = self.scope;
        while (scope) |current| {
            if (current.map.get(name)) |define| return define;
            scope = current.parent;
        }
        return null;
    }

    /// Parse a grammar used as a pattern. Defines in the nested grammar shadow
    /// outer defines, and `parentRef` refers to the enclosing define.
    fn parseNestedGrammar(self: *Parser, id: dom.NodeId) Error!*const Pattern {
        const outer_scope = self.scope;
        const scope = try self.arena.create(Scope);
        scope.* = .{
            .map = std.StringHashMap(*Define).init(self.arena),
            .parent = outer_scope,
        };
        self.scope = scope;
        defer self.scope = outer_scope;
        const outer_starts = self.start_patterns;
        self.start_patterns = .empty;
        defer self.start_patterns = outer_starts;
        self.grammar_depth += 1;
        defer self.grammar_depth -= 1;
        try self.parseGrammarChildren(id);
        if (self.start_patterns.items.len == 0) return error.InvalidPattern;
        return self.combineStart();
    }

    fn parseExternalRef(self: *Parser, id: dom.NodeId) Error!*const Pattern {
        const loaded = try self.loadReference(id);
        const saved_document = self.document;
        const saved_base = self.base;
        self.document = loaded.document;
        self.base = loaded.uri;
        defer {
            self.document = saved_document;
            self.base = saved_base;
        }
        try self.include_stack.append(self.arena, loaded.uri);
        defer _ = self.include_stack.pop();
        const root = self.document.root();
        if (root == dom.null_node) return error.InvalidSchema;
        const node = self.document.node(root);
        if (!std.mem.eql(u8, node.ns, structure_namespace) or
            std.mem.eql(u8, node.local, "grammar"))
        {
            return error.InvalidSchema;
        }
        return self.parsePattern(root);
    }

    fn parseData(self: *Parser, id: dom.NodeId) Error!*const Pattern {
        const type_name = self.document.attribute(id, "type") orelse
            return error.InvalidPattern;
        const library = try self.datatypeLibrary(id);
        const kind = try self.datatypeKind(library, type_name);
        var facets: datatypes.Facets = .{};
        var params: std.ArrayList(Param) = .empty;
        var except: ?*const Pattern = null;
        var child = self.document.node(id).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const node = self.document.node(child);
            if (node.kind != .element) continue;
            if (!std.mem.eql(u8, node.ns, structure_namespace)) continue;
            if (std.mem.eql(u8, node.local, "annotation")) continue;
            if (std.mem.eql(u8, node.local, "except")) {
                if (except != null) return error.InvalidPattern;
                except = try self.singlePatternChild(child);
                continue;
            }
            if (!std.mem.eql(u8, node.local, "param")) {
                return error.InvalidPattern;
            }
            const name = self.document.attribute(child, "name") orelse
                return error.InvalidPattern;
            const value = try self.textContent(child);
            try params.append(self.arena, .{ .name = name, .value = value });
            try self.applyParam(&facets, name, value);
        }
        return self.make(.{ .data = .{
            .library = library,
            .type_name = type_name,
            .kind = kind,
            .facets = facets,
            .params = try params.toOwnedSlice(self.arena),
            .except = except,
        } });
    }

    fn parseValue(self: *Parser, id: dom.NodeId) Error!*const Pattern {
        const library = try self.datatypeLibrary(id);
        const type_name = self.document.attribute(id, "type") orelse "token";
        const kind = try self.datatypeKind(library, type_name);
        const ns = self.document.attribute(id, "ns") orelse "";
        return self.make(.{ .value = .{
            .library = library,
            .type_name = type_name,
            .kind = kind,
            .ns = ns,
            .text = try self.textContent(id),
        } });
    }

    fn datatypeLibrary(self: *Parser, id: dom.NodeId) Error![]const u8 {
        var current = id;
        while (true) {
            if (self.document.attribute(current, "datatypeLibrary")) |value| {
                return value;
            }
            const parent = self.document.node(current).parent;
            if (parent == dom.null_node) break;
            if (self.document.node(parent).kind != .element) break;
            current = parent;
        }
        return "";
    }

    fn datatypeKind(
        self: *Parser,
        library: []const u8,
        type_name: []const u8,
    ) Error!datatypes.Kind {
        _ = self;
        if (library.len == 0) {
            if (std.mem.eql(u8, type_name, "string")) return .string;
            if (std.mem.eql(u8, type_name, "token")) return .token;
            return error.InvalidSchema;
        }
        if (!isXsdLibrary(library)) return error.InvalidSchema;
        if (datatypes.builtin(type_name)) |builtin| return builtin.kind;
        return error.InvalidSchema;
    }

    fn applyParam(
        self: *Parser,
        facets: *datatypes.Facets,
        name: []const u8,
        value: []const u8,
    ) Error!void {
        const owned = try self.arena.dupe(u8, value);
        if (std.mem.eql(u8, name, "pattern")) {
            const compiled = try self.arena.create(regex.Regex);
            compiled.* = regex.compile(self.backing_allocator, owned) catch |err|
                switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.InvalidPattern,
                };
            try self.regexes.append(self.arena, compiled);
            if (facets.patterns.len == 0) {
                const list = try self.arena.alloc(*const regex.Regex, 1);
                list[0] = compiled;
                facets.patterns = list;
            } else {
                const list = try self.arena.alloc(
                    *const regex.Regex,
                    facets.patterns.len + 1,
                );
                @memcpy(list[0..facets.patterns.len], facets.patterns);
                list[facets.patterns.len] = compiled;
                facets.patterns = list;
            }
            return;
        }
        if (std.mem.eql(u8, name, "minInclusive")) {
            facets.min_inclusive = owned;
        } else if (std.mem.eql(u8, name, "maxInclusive")) {
            facets.max_inclusive = owned;
        } else if (std.mem.eql(u8, name, "minExclusive")) {
            facets.min_exclusive = owned;
        } else if (std.mem.eql(u8, name, "maxExclusive")) {
            facets.max_exclusive = owned;
        } else if (std.mem.eql(u8, name, "length")) {
            facets.length = parseFacetLength(value) orelse
                return error.InvalidPattern;
        } else if (std.mem.eql(u8, name, "minLength")) {
            facets.min_length = parseFacetLength(value) orelse
                return error.InvalidPattern;
        } else if (std.mem.eql(u8, name, "maxLength")) {
            facets.max_length = parseFacetLength(value) orelse
                return error.InvalidPattern;
        } else if (std.mem.eql(u8, name, "totalDigits")) {
            facets.total_digits = parseFacetLength(value) orelse
                return error.InvalidPattern;
        } else if (std.mem.eql(u8, name, "fractionDigits")) {
            facets.fraction_digits = parseFacetLength(value) orelse
                return error.InvalidPattern;
        } else if (std.mem.eql(u8, name, "enumeration")) {
            const list = try self.arena.alloc(
                []const u8,
                facets.enumeration.len + 1,
            );
            @memcpy(list[0..facets.enumeration.len], facets.enumeration);
            list[facets.enumeration.len] = owned;
            facets.enumeration = list;
        } else {
            return error.InvalidPattern;
        }
    }

    const NameAndContent = struct {
        name_class: *const NameClass,
        content: *const Pattern,
    };

    /// Parse the name class and content of an `element` or `attribute`
    /// pattern. The `name` attribute is a shorthand for a `name` child.
    /// Multiple content children are implicitly grouped, which is the usual
    /// way to combine attribute patterns with element or text content.
    fn nameAndContent(self: *Parser, id: dom.NodeId) Error!NameAndContent {
        const is_attribute = std.mem.eql(
            u8,
            self.document.node(id).local,
            "attribute",
        );
        const children = try self.patternChildIds(id);
        var name_class: *const NameClass = undefined;
        var content_start: usize = 0;
        if (self.document.attribute(id, "name")) |text| {
            name_class = try self.nameClassFromQName(id, text);
        } else {
            if (children.len < 1) return error.InvalidPattern;
            const first = self.document.node(children[0]);
            if (!isNameClassElement(first.local)) {
                return error.InvalidPattern;
            }
            name_class = try self.parseNameClass(children[0]);
            content_start = 1;
        }
        const content_children = children[content_start..];
        if (content_children.len == 0) {
            // An attribute with no content accepts any value; an element
            // needs an explicit content pattern.
            if (is_attribute) {
                return .{
                    .name_class = name_class,
                    .content = try self.make(.text),
                };
            }
            return error.InvalidPattern;
        }
        var content = try self.parsePattern(content_children[0]);
        for (content_children[1..]) |child| {
            content = try self.make(.{ .group = .{
                .left = content,
                .right = try self.parsePattern(child),
            } });
        }
        return .{ .name_class = name_class, .content = content };
    }

    fn nameClassFromQName(
        self: *Parser,
        id: dom.NodeId,
        text: []const u8,
    ) Error!*const NameClass {
        const split = splitQName(text) orelse return error.InvalidPattern;
        var ns: []const u8 = "";
        if (split.prefix.len != 0) {
            ns = try self.resolvePrefix(id, split.prefix);
        }
        return self.nameClass(.{ .name = .{
            .ns = ns,
            .local = split.local,
        } });
    }

    fn patternChildIds(
        self: *Parser,
        id: dom.NodeId,
    ) Error![]const dom.NodeId {
        var children: std.ArrayList(dom.NodeId) = .empty;
        var child = self.document.node(id).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const node = self.document.node(child);
            if (node.kind != .element) continue;
            if (!std.mem.eql(u8, node.ns, structure_namespace)) continue;
            if (std.mem.eql(u8, node.local, "annotation")) continue;
            try children.append(self.arena, child);
        }
        return children.items;
    }

    fn isNameClassElement(local: []const u8) bool {
        return std.mem.eql(u8, local, "name") or
            std.mem.eql(u8, local, "anyName") or
            std.mem.eql(u8, local, "nsName") or
            std.mem.eql(u8, local, "choice");
    }

    fn parseNameClass(self: *Parser, id: dom.NodeId) Error!*const NameClass {
        const node = self.document.node(id);
        const local = node.local;
        if (std.mem.eql(u8, local, "name")) {
            const text = try self.textContent(id);
            const split = splitQName(text) orelse return error.InvalidPattern;
            var ns: []const u8 = "";
            if (split.prefix.len != 0) {
                ns = try self.resolvePrefix(id, split.prefix);
            }
            return self.nameClass(.{ .name = .{
                .ns = ns,
                .local = split.local,
            } });
        }
        if (std.mem.eql(u8, local, "anyName")) {
            return self.nameClass(.{ .any_name = .{
                .except = try self.parseExcept(id),
            } });
        }
        if (std.mem.eql(u8, local, "nsName")) {
            return self.nameClass(.{ .ns_name = .{
                .ns = try self.textContent(id),
                .except = try self.parseExcept(id),
            } });
        }
        if (std.mem.eql(u8, local, "choice")) {
            var children: std.ArrayList(*const NameClass) = .empty;
            var child = self.document.node(id).first_child;
            while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
                const child_node = self.document.node(child);
                if (child_node.kind != .element) continue;
                if (!std.mem.eql(u8, child_node.ns, structure_namespace)) continue;
                if (std.mem.eql(u8, child_node.local, "annotation")) continue;
                if (!isNameClassElement(child_node.local)) continue;
                try children.append(self.arena, try self.parseNameClass(child));
            }
            if (children.items.len != 2) return error.InvalidPattern;
            return self.nameClass(.{ .choice = .{
                .left = children.items[0],
                .right = children.items[1],
            } });
        }
        return error.InvalidPattern;
    }

    fn parseExcept(self: *Parser, id: dom.NodeId) Error!?*const NameClass {
        var child = self.document.node(id).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const node = self.document.node(child);
            if (node.kind != .element) continue;
            if (!std.mem.eql(u8, node.ns, structure_namespace)) continue;
            if (std.mem.eql(u8, node.local, "annotation")) continue;
            if (!std.mem.eql(u8, node.local, "except")) {
                return error.InvalidPattern;
            }
            var found: ?*const NameClass = null;
            var inner = self.document.node(child).first_child;
            while (inner != dom.null_node) : (inner = self.document.node(inner).next_sibling) {
                const inner_node = self.document.node(inner);
                if (inner_node.kind != .element) continue;
                if (!std.mem.eql(u8, inner_node.ns, structure_namespace)) continue;
                if (!isNameClassElement(inner_node.local)) continue;
                if (found != null) return error.InvalidPattern;
                found = try self.parseNameClass(inner);
            }
            return found orelse error.InvalidPattern;
        }
        return null;
    }

    fn resolvePrefix(
        self: *Parser,
        id: dom.NodeId,
        prefix: []const u8,
    ) Error![]const u8 {
        const bindings = try self.document.inScopeNamespaces(self.arena, id);
        for (bindings) |binding| {
            if (std.mem.eql(u8, binding.prefix, prefix)) return binding.uri;
        }
        return error.InvalidPattern;
    }

    fn singlePatternChild(self: *Parser, id: dom.NodeId) Error!*const Pattern {
        var found: ?dom.NodeId = null;
        var child = self.document.node(id).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const node = self.document.node(child);
            if (node.kind != .element) continue;
            if (!std.mem.eql(u8, node.ns, structure_namespace)) continue;
            if (std.mem.eql(u8, node.local, "annotation")) continue;
            if (found != null) return error.InvalidPattern;
            found = child;
        }
        return self.parsePattern(found orelse return error.InvalidPattern);
    }

    fn twoPatternChildren(
        self: *Parser,
        id: dom.NodeId,
    ) Error![2]*const Pattern {
        var children: [2]*const Pattern = undefined;
        var count: usize = 0;
        var child = self.document.node(id).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const node = self.document.node(child);
            if (node.kind != .element) continue;
            if (!std.mem.eql(u8, node.ns, structure_namespace)) continue;
            if (std.mem.eql(u8, node.local, "annotation")) continue;
            if (count == 2) return error.InvalidPattern;
            children[count] = try self.parsePattern(child);
            count += 1;
        }
        if (count != 2) return error.InvalidPattern;
        return children;
    }

    fn textContent(self: *Parser, id: dom.NodeId) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var child = self.document.node(id).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const node = self.document.node(child);
            if (node.kind == .text) try out.appendSlice(self.arena, node.value);
        }
        return out.toOwnedSlice(self.arena);
    }
};

fn isXsdLibrary(library: []const u8) bool {
    return std.mem.eql(
        u8,
        library,
        "http://www.w3.org/2001/XMLSchema-datatypes",
    ) or
        std.mem.eql(
            u8,
            library,
            "http://relaxng.org/ns/compatibility/datatypes/1.0",
        );
}

const QNameParts = struct {
    prefix: []const u8,
    local: []const u8,
};

fn splitQName(raw: []const u8) ?QNameParts {
    if (std.mem.indexOfScalar(u8, raw, ':')) |colon| {
        if (colon == 0 or colon + 1 == raw.len) return null;
        if (std.mem.indexOfScalarPos(u8, raw, colon + 1, ':') != null) {
            return null;
        }
        return .{
            .prefix = raw[0..colon],
            .local = raw[colon + 1 ..],
        };
    }
    if (raw.len == 0) return null;
    return .{ .prefix = "", .local = raw };
}

fn parseFacetLength(value: []const u8) ?usize {
    return std.fmt.parseInt(usize, value, 10) catch null;
}
