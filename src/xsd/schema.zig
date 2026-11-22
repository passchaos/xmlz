//! XML Schema 1.0 structure compiler.
//!
//! Supported: global/local elements and attributes, simple types with
//! restriction/list/union and facets, complex types with sequence/choice/all
//! particles, groups, attribute groups, wildcards, substitution groups,
//! identity constraints, attribute uses, simple/complex content extension and
//! restriction, include/import/redefine resolution, and schema-component
//! constraints such as reference restrictions, facet applicability, and
//! default/fixed lexical validity.

const std = @import("std");
const dom = @import("../dom.zig");
const encoding = @import("../encoding.zig");
const namespace = @import("../namespace.zig");
const xpath_ast = @import("../xpath/ast.zig");
const xpath_parser = @import("../xpath/parser.zig");
const datatypes = @import("datatypes.zig");
const regex = @import("regex.zig");

pub const xsd_namespace = "http://www.w3.org/2001/XMLSchema";
pub const xsi_namespace = "http://www.w3.org/2001/XMLSchema-instance";

pub const Error = error{
    OutOfMemory,
    InvalidSchema,
    InvalidRegex,
};

pub const QName = struct {
    namespace_uri: []const u8,
    local: []const u8,
};

pub const TypeInfo = union(enum) {
    any_type,
    any_simple,
    simple: *const SimpleInfo,
    complex: *const ComplexInfo,
};

pub const SimpleInfo = struct {
    variety: enum { atomic, list, union_ } = .atomic,
    kind: datatypes.Kind = .string,
    facets: datatypes.Facets = .{},
    item: ?*const SimpleInfo = null,
    members: []const *const SimpleInfo = &.{},
    /// Type declaration this info was compiled from, when named or anonymous.
    decl: ?*const TypeDecl = null,
    /// Immediate base type for restrictions.
    base: ?TypeInfo = null,
};

pub const ComplexInfo = struct {
    mixed: bool = false,
    simple: ?*const SimpleInfo = null,
    particle: ?*const Particle = null,
    attributes: []const AttributeUse = &.{},
    any_attribute: ?Wildcard = null,
    /// Type declaration this info was compiled from, when named or anonymous.
    decl: ?*const TypeDecl = null,
    /// Immediate base type for extension or restriction.
    base: ?TypeInfo = null,
    derivation: enum { none, extension, restriction } = .none,
    abstract: bool = false,
};

pub const DerivationMethod = enum { extension, restriction, substitution };

pub const DerivationSet = struct {
    extension: bool = false,
    restriction: bool = false,
    substitution: bool = false,

    pub fn has(self: DerivationSet, method: DerivationMethod) bool {
        return switch (method) {
            .extension => self.extension,
            .restriction => self.restriction,
            .substitution => self.substitution,
        };
    }

    pub fn merge(self: DerivationSet, other: DerivationSet) DerivationSet {
        return .{
            .extension = self.extension or other.extension,
            .restriction = self.restriction or other.restriction,
            .substitution = self.substitution or other.substitution,
        };
    }
};

pub const NamespaceRule = enum { any, other, target_namespace, local };

pub const Wildcard = struct {
    namespace_rule: NamespaceRule = .any,
    /// Explicit namespace URI list; takes precedence over `namespace_rule`.
    namespaces: []const []const u8 = &.{},
    process: enum { skip, lax, strict } = .strict,
    target_namespace: []const u8 = "",
};

pub const Particle = union(enum) {
    element: struct {
        decl: *const ElementDecl,
        min: usize = 1,
        max: ?usize = 1,
    },
    sequence: struct {
        items: []const *const Particle,
        min: usize = 1,
        max: ?usize = 1,
    },
    choice: struct {
        items: []const *const Particle,
        min: usize = 1,
        max: ?usize = 1,
    },
    all: struct {
        items: []const *const Particle,
        min: usize = 1,
        max: ?usize = 1,
    },
    any: struct {
        wildcard: Wildcard,
        min: usize = 1,
        max: ?usize = 1,
    },
    group: struct {
        decl: *const GroupDecl,
        min: usize = 1,
        max: ?usize = 1,
    },
};

pub const Use = enum { optional, required, prohibited };

pub const AttributeUse = struct {
    decl: *const AttributeDecl,
    use: Use = .optional,
};

pub const ElementDecl = struct {
    name: []const u8 = "",
    namespace_uri: []const u8 = "",
    type_use: TypeUse = .any_type,
    type_info: TypeInfo = .any_type,
    nillable: bool = false,
    abstract: bool = false,
    default_value: ?[]const u8 = null,
    fixed_value: ?[]const u8 = null,
    global: bool = false,
    substitution_qname: ?QName = null,
    substitution_group: ?*const ElementDecl = null,
    /// Disallowed substitutions for this element declaration.
    block: DerivationSet = .{},
    /// Substitution group exclusions for this element declaration.
    final: DerivationSet = .{},
    identity: []const *const IdentityConstraint = &.{},
    doc: ?*const SchemaDocument = null,
    node: dom.NodeId = dom.null_node,
};

pub const GroupDecl = struct {
    name: []const u8 = "",
    namespace_uri: []const u8 = "",
    particle: ?*const Particle = null,
    parsed: bool = false,
    resolving: bool = false,
    cycle_checked: bool = false,
    visiting: bool = false,
    /// Original declaration when this group redefines an included group.
    original: ?*const GroupDecl = null,
    doc: ?*const SchemaDocument = null,
    node: dom.NodeId = dom.null_node,
};

pub const AttributeGroupDecl = struct {
    name: []const u8 = "",
    namespace_uri: []const u8 = "",
    attributes: []const AttributeUse = &.{},
    any_attribute: ?Wildcard = null,
    parsed: bool = false,
    resolving: bool = false,
    /// Original declaration when this group redefines an included group.
    original: ?*const AttributeGroupDecl = null,
    doc: ?*const SchemaDocument = null,
    node: dom.NodeId = dom.null_node,
};

pub const CompiledXPath = struct {
    expr: *xpath_ast.Expr,
    namespaces: []const namespace.Binding,
};

pub const IdentityKind = enum { key, keyref, unique };

pub const IdentityConstraint = struct {
    kind: IdentityKind,
    name: []const u8,
    namespace_uri: []const u8,
    selector: CompiledXPath,
    fields: []const CompiledXPath,
    refer: ?QName = null,
    referenced: ?*const IdentityConstraint = null,
    node: dom.NodeId = dom.null_node,
};

pub const AttributeDecl = struct {
    name: []const u8 = "",
    namespace_uri: []const u8 = "",
    type_use: TypeUse = .any_simple,
    type_info: TypeInfo = .any_simple,
    default_value: ?[]const u8 = null,
    fixed_value: ?[]const u8 = null,
    global: bool = false,
    doc: ?*const SchemaDocument = null,
    node: dom.NodeId = dom.null_node,
};

pub const NotationDecl = struct {
    name: []const u8 = "",
    namespace_uri: []const u8 = "",
    public_id: ?[]const u8 = null,
    system_id: ?[]const u8 = null,
};

pub const TypeUse = union(enum) {
    any_type,
    any_simple,
    builtin: datatypes.Kind,
    qname: QName,
    anonymous: *const TypeDecl,
};

pub const SimpleDecl = union(enum) {
    restriction: struct {
        base: TypeUse,
        facets: datatypes.Facets = .{},
    },
    list: struct {
        item: TypeUse,
    },
    union_: struct {
        members: []const TypeUse,
    },
};

pub const ContentDecl = union(enum) {
    empty,
    particle: *const Particle,
    simple_content: struct {
        base: TypeUse,
        facets: datatypes.Facets = .{},
        restriction: bool = false,
    },
    complex_content: struct {
        base: TypeUse,
        particle: ?*const Particle = null,
        restriction: bool = false,
    },
};

pub const ComplexDecl = struct {
    mixed: bool = false,
    content: ContentDecl = .empty,
    attributes: []const AttributeUse = &.{},
    any_attribute: ?Wildcard = null,
};

pub const TypeDecl = struct {
    name: []const u8 = "",
    namespace_uri: []const u8 = "",
    global: bool = false,
    /// Complex types marked abstract require an `xsi:type` substitution.
    abstract: bool = false,
    /// Disallowed derivations for elements using this type.
    block: DerivationSet = .{},
    /// Derivations prohibited from this type.
    final: DerivationSet = .{},
    /// Original declaration when this type redefines an included type.
    original: ?*const TypeDecl = null,
    body: union(enum) {
        simple: SimpleDecl,
        complex: ComplexDecl,
        unresolved,
    } = .unresolved,
    info: ?TypeInfo = null,
    resolving: bool = false,
    doc: ?*const SchemaDocument = null,
    node: dom.NodeId = dom.null_node,
};

pub const SchemaDocument = struct {
    document: *const dom.Document,
    target_namespace: []const u8 = "",
    element_form_qualified: bool = false,
    attribute_form_qualified: bool = false,
    base_uri: []const u8 = "",
    chameleon: bool = false,
};

pub const Schema = struct {
    arena: std.heap.ArenaAllocator,
    target_namespace: []const u8,
    element_form_qualified: bool,
    attribute_form_qualified: bool,
    elements: []const *const ElementDecl,
    attributes: []const *const AttributeDecl,
    types: []const *const TypeDecl,
    groups: []const *const GroupDecl,
    attribute_groups: []const *const AttributeGroupDecl,
    notations: []const *const NotationDecl = &.{},
    documents: []const *dom.Document = &.{},

    pub fn deinit(self: *Schema) void {
        for (self.documents) |document| document.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn findElement(
        self: *const Schema,
        namespace_uri: []const u8,
        local: []const u8,
    ) ?*const ElementDecl {
        for (self.elements) |decl| {
            if (std.mem.eql(u8, decl.namespace_uri, namespace_uri) and
                std.mem.eql(u8, decl.name, local))
            {
                return decl;
            }
        }
        return null;
    }

    pub fn findAttribute(
        self: *const Schema,
        namespace_uri: []const u8,
        local: []const u8,
    ) ?*const AttributeDecl {
        for (self.attributes) |decl| {
            if (std.mem.eql(u8, decl.namespace_uri, namespace_uri) and
                std.mem.eql(u8, decl.name, local))
            {
                return decl;
            }
        }
        return null;
    }

    pub fn findType(
        self: *const Schema,
        namespace_uri: []const u8,
        local: []const u8,
    ) ?*const TypeDecl {
        var index = self.types.len;
        while (index > 0) {
            index -= 1;
            const decl = self.types[index];
            if (decl.global and
                std.mem.eql(u8, decl.namespace_uri, namespace_uri) and
                std.mem.eql(u8, decl.name, local))
            {
                return decl;
            }
        }
        return null;
    }

    pub fn findGroup(
        self: *const Schema,
        namespace_uri: []const u8,
        local: []const u8,
    ) ?*const GroupDecl {
        var index = self.groups.len;
        while (index > 0) {
            index -= 1;
            const decl = self.groups[index];
            if (std.mem.eql(u8, decl.namespace_uri, namespace_uri) and
                std.mem.eql(u8, decl.name, local))
            {
                return decl;
            }
        }
        return null;
    }

    pub fn findAttributeGroup(
        self: *const Schema,
        namespace_uri: []const u8,
        local: []const u8,
    ) ?*const AttributeGroupDecl {
        var index = self.attribute_groups.len;
        while (index > 0) {
            index -= 1;
            const decl = self.attribute_groups[index];
            if (std.mem.eql(u8, decl.namespace_uri, namespace_uri) and
                std.mem.eql(u8, decl.name, local))
            {
                return decl;
            }
        }
        return null;
    }

    pub fn findNotation(
        self: *const Schema,
        namespace_uri: []const u8,
        local: []const u8,
    ) ?*const NotationDecl {
        for (self.notations) |decl| {
            if (std.mem.eql(u8, decl.namespace_uri, namespace_uri) and
                std.mem.eql(u8, decl.name, local))
            {
                return decl;
            }
        }
        return null;
    }

    /// True when `member` can substitute for `head` through the substitution
    /// group chain.
    pub fn isSubstitutionMember(
        self: *const Schema,
        member: *const ElementDecl,
        head: *const ElementDecl,
    ) bool {
        _ = self;
        var current = member.substitution_group;
        var steps: usize = 0;
        while (current) |candidate| {
            if (candidate == head) return true;
            steps += 1;
            if (steps > 1024) return false;
            current = candidate.substitution_group;
        }
        return false;
    }
};

pub fn typeInfoEqual(a: TypeInfo, b: TypeInfo) bool {
    return switch (a) {
        .any_type => switch (b) {
            .any_type => true,
            else => false,
        },
        .any_simple => switch (b) {
            .any_simple => true,
            else => false,
        },
        .simple => |sa| switch (b) {
            .simple => |sb| blk: {
                if (sa == sb) break :blk true;
                if (sa.decl != null or sb.decl != null) {
                    break :blk sa.decl != null and sb.decl != null and
                        sa.decl == sb.decl;
                }
                break :blk sa.variety == sb.variety and sa.kind == sb.kind and
                    sa.item == sb.item and
                    sa.members.len == sb.members.len;
            },
            else => false,
        },
        .complex => |ca| switch (b) {
            .complex => |cb| blk: {
                if (ca == cb) break :blk true;
                break :blk ca.decl != null and cb.decl != null and
                    ca.decl == cb.decl;
            },
            else => false,
        },
    };
}

fn builtinDerivesFrom(derived: datatypes.Kind, base: datatypes.Kind) bool {
    var kind = derived;
    var steps: usize = 0;
    while (datatypes.baseKind(kind)) |parent| {
        if (parent == base) return true;
        kind = parent;
        steps += 1;
        if (steps > 64) break;
    }
    return false;
}

/// True when `derived` is the same type as `base` or validly derived from it.
pub fn isDerivedFrom(derived: TypeInfo, base: TypeInfo) bool {
    if (typeInfoEqual(derived, base)) return true;
    return switch (base) {
        .any_type => true,
        .any_simple => switch (derived) {
            .simple, .any_simple => true,
            else => false,
        },
        .simple => |base_simple| switch (derived) {
            .simple => |simple| blk: {
                if (simple.base) |parent| {
                    break :blk isDerivedFrom(parent, base);
                }
                if (simple.decl == null and base_simple.decl == null) {
                    break :blk builtinDerivesFrom(simple.kind, base_simple.kind);
                }
                break :blk false;
            },
            else => false,
        },
        .complex => |base_complex| switch (derived) {
            .complex => |complex| blk: {
                if (complex.base) |parent| {
                    break :blk isDerivedFrom(parent, base);
                }
                break :blk complex == base_complex;
            },
            else => false,
        },
    };
}

/// Derivation methods used along the chain from `derived` up to `base`.
pub fn derivationMethods(derived: TypeInfo, base: TypeInfo) DerivationSet {
    var methods: DerivationSet = .{};
    var current = derived;
    var steps: usize = 0;
    while (steps < 1024) : (steps += 1) {
        if (typeInfoEqual(current, base)) return methods;
        switch (current) {
            .simple => |simple| {
                if (simple.base) |parent| {
                    methods.restriction = true;
                    current = parent;
                    continue;
                }
                if (base == .simple) {
                    if (simple.decl == null and base.simple.decl == null) {
                        var kind = simple.kind;
                        while (datatypes.baseKind(kind)) |parent_kind| {
                            methods.restriction = true;
                            if (parent_kind == base.simple.kind) return methods;
                            kind = parent_kind;
                        }
                    }
                }
                return methods;
            },
            .complex => |complex| {
                if (complex.base) |parent| {
                    switch (complex.derivation) {
                        .extension => methods.extension = true,
                        .restriction => methods.restriction = true,
                        .none => {},
                    }
                    current = parent;
                    continue;
                }
                return methods;
            },
            .any_type, .any_simple => return methods,
        }
    }
    return methods;
}

pub fn typeFinal(info: TypeInfo) DerivationSet {
    return switch (info) {
        .simple => |simple| if (simple.decl) |decl| decl.final else .{},
        .complex => |complex| if (complex.decl) |decl| decl.final else .{},
        else => .{},
    };
}

pub fn typeBlock(info: TypeInfo) DerivationSet {
    return switch (info) {
        .simple => |simple| if (simple.decl) |decl| decl.block else .{},
        .complex => |complex| if (complex.decl) |decl| decl.block else .{},
        else => .{},
    };
}

pub fn typeAbstract(info: TypeInfo) bool {
    return switch (info) {
        .complex => |complex| complex.abstract,
        else => false,
    };
}

pub const Resource = struct {
    /// Resolved URI used as the base for nested schema references.
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
    /// Base URI of the top-level schema document.
    base: []const u8 = "",
};

/// Compile an XML Schema document without external includes or imports.
pub fn parse(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
) Error!Schema {
    return parseWithOptions(allocator, document, .{});
}

/// Compile an XML Schema document, resolving `xs:include` and `xs:import`
/// through the supplied resolver.
pub fn parseWithOptions(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
    options: Options,
) Error!Schema {
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
    // Build every arena-backed slice before copying the arena: a new chunk
    // allocated afterwards would not be reachable from the copy.
    const elements = try compiler.elements.toOwnedSlice(compiler.arena);
    const attributes = try compiler.attributes.toOwnedSlice(compiler.arena);
    const types = try compiler.types.toOwnedSlice(compiler.arena);
    const groups = try compiler.groups.toOwnedSlice(compiler.arena);
    const attribute_groups = try compiler.attribute_groups.toOwnedSlice(
        compiler.arena,
    );
    const notations = try compiler.notations.toOwnedSlice(compiler.arena);
    const documents = try compiler.included_documents.toOwnedSlice(
        compiler.arena,
    );
    return .{
        .arena = arena,
        .target_namespace = compiler.target_namespace,
        .element_form_qualified = compiler.element_form_qualified,
        .attribute_form_qualified = compiler.attribute_form_qualified,
        .elements = elements,
        .attributes = attributes,
        .types = types,
        .groups = groups,
        .attribute_groups = attribute_groups,
        .notations = notations,
        .documents = documents,
    };
}

const LoadedDocument = struct {
    uri: []const u8,
    target_namespace: []const u8,
};

const Compiler = struct {
    arena: std.mem.Allocator,
    backing_allocator: std.mem.Allocator,
    document: *const dom.Document,
    target_namespace: []const u8 = "",
    element_form_qualified: bool = false,
    attribute_form_qualified: bool = false,
    options: Options = .{},
    current_schema: *const SchemaDocument = undefined,
    root_schema: *const SchemaDocument = undefined,
    included_documents: std.ArrayList(*dom.Document) = .empty,
    loaded_documents: std.ArrayList(LoadedDocument) = .empty,
    include_stack: std.ArrayList(LoadedDocument) = .empty,
    elements: std.ArrayList(*const ElementDecl) = .empty,
    attributes: std.ArrayList(*const AttributeDecl) = .empty,
    types: std.ArrayList(*const TypeDecl) = .empty,
    groups: std.ArrayList(*const GroupDecl) = .empty,
    attribute_groups: std.ArrayList(*const AttributeGroupDecl) = .empty,
    notations: std.ArrayList(*const NotationDecl) = .empty,
    identity_constraints: std.ArrayList(*const IdentityConstraint) = .empty,
    local_elements: std.ArrayList(*const ElementDecl) = .empty,
    local_attributes: std.ArrayList(*const AttributeDecl) = .empty,
    redefining_type: ?*const TypeDecl = null,
    redefining_group: ?*const GroupDecl = null,
    redefining_attribute_group: ?*const AttributeGroupDecl = null,
    root: dom.NodeId = dom.null_node,

    const SavedContext = struct {
        document: *const dom.Document,
        target_namespace: []const u8,
        element_form_qualified: bool,
        attribute_form_qualified: bool,
        schema: *const SchemaDocument,
    };

    fn enterSchema(
        self: *Compiler,
        schema: *const SchemaDocument,
    ) SavedContext {
        const saved: SavedContext = .{
            .document = self.document,
            .target_namespace = self.target_namespace,
            .element_form_qualified = self.element_form_qualified,
            .attribute_form_qualified = self.attribute_form_qualified,
            .schema = self.current_schema,
        };
        self.document = schema.document;
        self.target_namespace = schema.target_namespace;
        self.element_form_qualified = schema.element_form_qualified;
        self.attribute_form_qualified = schema.attribute_form_qualified;
        self.current_schema = schema;
        return saved;
    }

    fn leaveSchema(self: *Compiler, saved: SavedContext) void {
        self.document = saved.document;
        self.target_namespace = saved.target_namespace;
        self.element_form_qualified = saved.element_form_qualified;
        self.attribute_form_qualified = saved.attribute_form_qualified;
        self.current_schema = saved.schema;
    }

    fn run(self: *Compiler) Error!void {
        const root = self.document.root();
        if (root == dom.null_node) return error.InvalidSchema;
        const root_node = self.document.node(root);
        if (!isXsd(root_node, "schema")) return error.InvalidSchema;
        self.root = root;

        const schema_document = try self.arena.create(SchemaDocument);
        schema_document.* = .{
            .document = self.document,
            .target_namespace = self.document.attribute(
                root,
                "targetNamespace",
            ) orelse "",
            .element_form_qualified = try self.formDefault(
                root,
                "elementFormDefault",
            ),
            .attribute_form_qualified = try self.formDefault(
                root,
                "attributeFormDefault",
            ),
            .base_uri = self.options.base,
        };
        self.root_schema = schema_document;
        if (self.options.base.len != 0) {
            try self.include_stack.append(self.arena, .{
                .uri = self.options.base,
                .target_namespace = schema_document.target_namespace,
            });
            defer _ = self.include_stack.pop();
        }

        try self.collectGlobalsFor(schema_document);
        try self.parseGlobalBodies();
        try self.resolveSubstitutions();
        try self.resolveIdentityReferences();
        try self.resolveAllTypes();
        try self.resolveAllDeclarations();
        try self.checkSubstitutionTypes();
    }

    fn formDefault(
        self: *Compiler,
        id: dom.NodeId,
        attribute_name: []const u8,
    ) Error!bool {
        const value = self.document.attribute(id, attribute_name) orelse
            return false;
        if (std.mem.eql(u8, value, "qualified")) return true;
        if (std.mem.eql(u8, value, "unqualified")) return false;
        return error.InvalidSchema;
    }

    fn collectGlobalsFor(
        self: *Compiler,
        schema: *const SchemaDocument,
    ) Error!void {
        const saved = self.enterSchema(schema);
        defer self.leaveSchema(saved);
        const root = self.document.root();
        if (root == dom.null_node) return error.InvalidSchema;
        const root_node = self.document.node(root);
        if (!isXsd(root_node, "schema")) return error.InvalidSchema;
        var child = self.document.node(root).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const child_node = self.document.node(child);
            if (child_node.kind != .element) continue;
            if (!isXsd(child_node, null)) continue;
            if (std.mem.eql(u8, child_node.local, "annotation")) continue;
            if (std.mem.eql(u8, child_node.local, "element")) {
                const decl = try self.globalElement(child);
                if (self.findGlobalElement(.{
                    .namespace_uri = decl.namespace_uri,
                    .local = decl.name,
                }) != null) return error.InvalidSchema;
                try self.elements.append(self.arena, decl);
            } else if (std.mem.eql(u8, child_node.local, "attribute")) {
                const decl = try self.globalAttribute(child);
                if (self.findGlobalAttribute(.{
                    .namespace_uri = decl.namespace_uri,
                    .local = decl.name,
                }) != null) return error.InvalidSchema;
                try self.attributes.append(self.arena, decl);
            } else if (std.mem.eql(u8, child_node.local, "complexType") or
                std.mem.eql(u8, child_node.local, "simpleType"))
            {
                const decl = try self.globalType(child);
                if (self.findGlobalType(.{
                    .namespace_uri = decl.namespace_uri,
                    .local = decl.name,
                }) != null) return error.InvalidSchema;
                try self.types.append(self.arena, decl);
            } else if (std.mem.eql(u8, child_node.local, "group")) {
                const decl = try self.globalGroup(child);
                if (self.findGlobalGroup(.{
                    .namespace_uri = decl.namespace_uri,
                    .local = decl.name,
                }) != null) return error.InvalidSchema;
                try self.groups.append(self.arena, decl);
            } else if (std.mem.eql(u8, child_node.local, "attributeGroup")) {
                const decl = try self.globalAttributeGroup(child);
                if (self.findGlobalAttributeGroup(.{
                    .namespace_uri = decl.namespace_uri,
                    .local = decl.name,
                }) != null) return error.InvalidSchema;
                try self.attribute_groups.append(self.arena, decl);
            } else if (std.mem.eql(u8, child_node.local, "include")) {
                try self.processSchemaReference(child, false);
            } else if (std.mem.eql(u8, child_node.local, "import")) {
                try self.processSchemaReference(child, true);
            } else if (std.mem.eql(u8, child_node.local, "notation")) {
                const decl = try self.globalNotation(child);
                for (self.notations.items) |existing| {
                    if (std.mem.eql(
                        u8,
                        existing.namespace_uri,
                        decl.namespace_uri,
                    ) and std.mem.eql(u8, existing.name, decl.name)) {
                        return error.InvalidSchema;
                    }
                }
                try self.notations.append(self.arena, decl);
            } else if (std.mem.eql(u8, child_node.local, "redefine")) {
                try self.processRedefine(child);
            }
        }
    }

    /// Process `xs:redefine`: include the referenced schema, then replace the
    /// named components. Self-references inside a redefinition resolve to the
    /// original included component.
    fn processRedefine(self: *Compiler, id: dom.NodeId) Error!void {
        try self.processSchemaReference(id, false);
        var child = self.document.node(id).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const node = self.document.node(child);
            if (node.kind != .element or !isXsd(node, null)) continue;
            if (std.mem.eql(u8, node.local, "annotation")) continue;
            if (std.mem.eql(u8, node.local, "simpleType") or
                std.mem.eql(u8, node.local, "complexType"))
            {
                const decl = try self.globalType(child);
                const original = self.findGlobalType(.{
                    .namespace_uri = decl.namespace_uri,
                    .local = decl.name,
                }) orelse return error.InvalidSchema;
                @constCast(decl).original = original;
                try self.types.append(self.arena, decl);
                continue;
            }
            if (std.mem.eql(u8, node.local, "group")) {
                const decl = try self.globalGroup(child);
                const original = self.findGlobalGroup(.{
                    .namespace_uri = decl.namespace_uri,
                    .local = decl.name,
                }) orelse return error.InvalidSchema;
                @constCast(decl).original = original;
                try self.groups.append(self.arena, decl);
                continue;
            }
            if (std.mem.eql(u8, node.local, "attributeGroup")) {
                const decl = try self.globalAttributeGroup(child);
                const original = self.findGlobalAttributeGroup(.{
                    .namespace_uri = decl.namespace_uri,
                    .local = decl.name,
                }) orelse return error.InvalidSchema;
                @constCast(decl).original = original;
                try self.attribute_groups.append(self.arena, decl);
                continue;
            }
            return error.InvalidSchema;
        }
    }

    fn processSchemaReference(
        self: *Compiler,
        id: dom.NodeId,
        is_import: bool,
    ) Error!void {
        const href = self.document.attribute(id, "schemaLocation");
        if (href == null) {
            if (is_import) return;
            return error.InvalidSchema;
        }
        const resolver = self.options.resolver orelse
            return error.InvalidSchema;
        const resource = resolver.load(
            resolver.context,
            href.?,
            self.current_schema.base_uri,
        ) orelse return error.InvalidSchema;

        const owned = try self.arena.dupe(u8, resource.data);
        const decoded = encoding.decodeAlloc(
            self.arena,
            owned,
            64 * 1024 * 1024,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidSchema,
        };
        const document_ptr = try self.arena.create(dom.Document);
        document_ptr.* = dom.Document.parse(
            self.backing_allocator,
            decoded,
            .{},
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidSchema,
        };
        const root = document_ptr.root();
        if (root == dom.null_node) return error.InvalidSchema;
        const root_node = document_ptr.node(root);
        if (!isXsd(root_node, "schema")) return error.InvalidSchema;

        const included_namespace = document_ptr.attribute(
            root,
            "targetNamespace",
        ) orelse "";
        var effective_namespace = included_namespace;
        var chameleon = false;
        if (is_import) {
            if (self.document.attribute(id, "namespace")) |declared| {
                if (std.mem.eql(u8, declared, self.target_namespace) or
                    !std.mem.eql(u8, declared, included_namespace))
                {
                    document_ptr.deinit();
                    return error.InvalidSchema;
                }
            } else if (included_namespace.len != 0) {
                document_ptr.deinit();
                return error.InvalidSchema;
            }
        } else {
            if (included_namespace.len == 0) {
                effective_namespace = self.target_namespace;
                chameleon = self.target_namespace.len != 0;
            } else if (!std.mem.eql(
                u8,
                included_namespace,
                self.target_namespace,
            )) {
                document_ptr.deinit();
                return error.InvalidSchema;
            }
        }

        const key_uri = if (resource.uri.len != 0)
            resource.uri
        else
            href.?;
        const owned_key = try self.arena.dupe(u8, key_uri);
        const owned_namespace = try self.arena.dupe(u8, effective_namespace);
        for (self.loaded_documents.items) |loaded| {
            if (std.mem.eql(u8, loaded.uri, owned_key) and
                std.mem.eql(
                    u8,
                    loaded.target_namespace,
                    owned_namespace,
                ))
            {
                document_ptr.deinit();
                return;
            }
        }
        for (self.include_stack.items) |active| {
            if (std.mem.eql(u8, active.uri, owned_key) and
                std.mem.eql(
                    u8,
                    active.target_namespace,
                    owned_namespace,
                ))
            {
                document_ptr.deinit();
                return error.InvalidSchema;
            }
        }
        try self.include_stack.append(self.arena, .{
            .uri = owned_key,
            .target_namespace = owned_namespace,
        });
        defer _ = self.include_stack.pop();

        try self.included_documents.append(self.arena, document_ptr);
        const schema_document = try self.arena.create(SchemaDocument);
        schema_document.* = .{
            .document = document_ptr,
            .target_namespace = effective_namespace,
            .element_form_qualified = try formDefaultFor(
                document_ptr,
                root,
                "elementFormDefault",
            ),
            .attribute_form_qualified = try formDefaultFor(
                document_ptr,
                root,
                "attributeFormDefault",
            ),
            .base_uri = owned_key,
            .chameleon = chameleon,
        };
        try self.collectGlobalsFor(schema_document);
        try self.loaded_documents.append(self.arena, .{
            .uri = owned_key,
            .target_namespace = owned_namespace,
        });
    }

    fn globalElement(self: *Compiler, id: dom.NodeId) Error!*const ElementDecl {
        if (self.document.attribute(id, "ref") != null or
            self.document.attribute(id, "form") != null or
            self.document.attribute(id, "minOccurs") != null or
            self.document.attribute(id, "maxOccurs") != null)
        {
            return error.InvalidSchema;
        }
        if (self.document.attribute(id, "default") != null and
            self.document.attribute(id, "fixed") != null)
        {
            return error.InvalidSchema;
        }
        const name = self.document.attribute(id, "name") orelse
            return error.InvalidSchema;
        const decl = try self.arena.create(ElementDecl);
        var substitution_qname: ?QName = null;
        if (self.document.attribute(id, "substitutionGroup")) |value| {
            substitution_qname = try self.resolveQName(id, value);
        }
        decl.* = .{
            .name = name,
            .namespace_uri = self.target_namespace,
            .global = true,
            .node = id,
            .nillable = try self.booleanAttribute(id, "nillable"),
            .abstract = try self.booleanAttribute(id, "abstract"),
            .block = try self.derivationSet(id, "block", true, false),
            .final = try self.derivationSet(id, "final", false, false),
            .default_value = self.document.attribute(id, "default"),
            .fixed_value = self.document.attribute(id, "fixed"),
            .substitution_qname = substitution_qname,
            .identity = try self.parseIdentityConstraints(id),
            .doc = self.current_schema,
        };
        return decl;
    }

    fn globalAttribute(
        self: *Compiler,
        id: dom.NodeId,
    ) Error!*const AttributeDecl {
        if (self.document.attribute(id, "ref") != null or
            self.document.attribute(id, "use") != null or
            self.document.attribute(id, "form") != null)
        {
            return error.InvalidSchema;
        }
        if (self.document.attribute(id, "default") != null and
            self.document.attribute(id, "fixed") != null)
        {
            return error.InvalidSchema;
        }
        const name = self.document.attribute(id, "name") orelse
            return error.InvalidSchema;
        const decl = try self.arena.create(AttributeDecl);
        decl.* = .{
            .name = name,
            .namespace_uri = self.target_namespace,
            .global = true,
            .node = id,
            .default_value = self.document.attribute(id, "default"),
            .fixed_value = self.document.attribute(id, "fixed"),
            .doc = self.current_schema,
        };
        return decl;
    }

    fn globalType(self: *Compiler, id: dom.NodeId) Error!*const TypeDecl {
        const name = self.document.attribute(id, "name") orelse
            return error.InvalidSchema;
        const decl = try self.arena.create(TypeDecl);
        const complex = std.mem.eql(
            u8,
            self.document.node(id).local,
            "complexType",
        );
        decl.* = .{
            .name = name,
            .namespace_uri = self.target_namespace,
            .global = true,
            .abstract = if (complex)
                try self.booleanAttribute(id, "abstract")
            else
                false,
            .block = if (complex)
                try self.derivationSet(id, "block", false, false)
            else
                .{},
            .final = try self.derivationSet(id, "final", false, !complex),
            .node = id,
            .doc = self.current_schema,
        };
        return decl;
    }

    fn globalNotation(
        self: *Compiler,
        id: dom.NodeId,
    ) Error!*const NotationDecl {
        const name = self.document.attribute(id, "name") orelse
            return error.InvalidSchema;
        const public_id = self.document.attribute(id, "public");
        const system_id = self.document.attribute(id, "system");
        if (public_id == null and system_id == null) {
            return error.InvalidSchema;
        }
        const decl = try self.arena.create(NotationDecl);
        decl.* = .{
            .name = name,
            .namespace_uri = self.target_namespace,
            .public_id = public_id,
            .system_id = system_id,
        };
        return decl;
    }

    fn globalGroup(self: *Compiler, id: dom.NodeId) Error!*const GroupDecl {
        const name = self.document.attribute(id, "name") orelse
            return error.InvalidSchema;
        const decl = try self.arena.create(GroupDecl);
        decl.* = .{
            .name = name,
            .namespace_uri = self.target_namespace,
            .node = id,
            .doc = self.current_schema,
        };
        return decl;
    }

    fn globalAttributeGroup(
        self: *Compiler,
        id: dom.NodeId,
    ) Error!*const AttributeGroupDecl {
        const name = self.document.attribute(id, "name") orelse
            return error.InvalidSchema;
        const decl = try self.arena.create(AttributeGroupDecl);
        decl.* = .{
            .name = name,
            .namespace_uri = self.target_namespace,
            .node = id,
            .doc = self.current_schema,
        };
        return decl;
    }

    fn parseGlobalBodies(self: *Compiler) Error!void {
        for (self.attribute_groups.items) |decl| {
            try self.parseAttributeGroupBody(decl);
        }
        const global_count = self.types.items.len;
        var type_index: usize = 0;
        while (type_index < global_count) : (type_index += 1) {
            try self.parseTypeBody(self.types.items[type_index]);
        }
        for (self.groups.items) |decl| {
            try self.parseGroupBody(decl);
        }
        for (self.groups.items) |decl| {
            try self.checkGroupCycle(decl);
        }
        for (self.elements.items) |decl| {
            const saved = self.enterSchema(decl.doc orelse
                return error.InvalidSchema);
            defer self.leaveSchema(saved);
            @constCast(decl).type_use = try self.elementTypeUse(
                decl.node,
                null,
            );
        }
        for (self.attributes.items) |decl| {
            const saved = self.enterSchema(decl.doc orelse
                return error.InvalidSchema);
            defer self.leaveSchema(saved);
            @constCast(decl).type_use = try self.attributeTypeUse(decl.node);
        }
    }

    fn parseGroupBody(self: *Compiler, decl: *const GroupDecl) Error!void {
        if (decl.parsed) return;
        if (decl.resolving) return error.InvalidSchema;
        const saved = self.enterSchema(decl.doc orelse
            return error.InvalidSchema);
        defer self.leaveSchema(saved);
        const saved_redefinition = self.redefining_group;
        self.redefining_group = if (decl.original != null) decl else null;
        defer self.redefining_group = saved_redefinition;
        @constCast(decl).resolving = true;
        var particle: ?*const Particle = null;
        var child = self.document.node(decl.node).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const child_node = self.document.node(child);
            if (child_node.kind != .element or !isXsd(child_node, null)) {
                continue;
            }
            if (std.mem.eql(u8, child_node.local, "annotation")) continue;
            if (std.mem.eql(u8, child_node.local, "sequence") or
                std.mem.eql(u8, child_node.local, "choice") or
                std.mem.eql(u8, child_node.local, "all"))
            {
                if (particle != null) return error.InvalidSchema;
                particle = try self.parseParticle(child);
                continue;
            }
            return error.InvalidSchema;
        }
        @constCast(decl).particle = particle orelse
            return error.InvalidSchema;
        @constCast(decl).parsed = true;
        @constCast(decl).resolving = false;
    }

    fn checkGroupCycle(self: *Compiler, decl: *const GroupDecl) Error!void {
        if (decl.cycle_checked) return;
        if (decl.visiting) return error.InvalidSchema;
        @constCast(decl).visiting = true;
        if (decl.particle) |particle| {
            try self.checkParticleGroups(particle);
        }
        @constCast(decl).visiting = false;
        @constCast(decl).cycle_checked = true;
    }

    fn checkParticleGroups(
        self: *Compiler,
        particle: *const Particle,
    ) Error!void {
        switch (particle.*) {
            .group => |group| try self.checkGroupCycle(group.decl),
            .sequence => |sequence| {
                for (sequence.items) |item| try self.checkParticleGroups(item);
            },
            .choice => |choice| {
                for (choice.items) |item| try self.checkParticleGroups(item);
            },
            .all => |all| {
                for (all.items) |item| try self.checkParticleGroups(item);
            },
            .element, .any => {},
        }
    }

    fn parseAttributeGroupBody(
        self: *Compiler,
        decl: *const AttributeGroupDecl,
    ) Error!void {
        if (decl.parsed) return;
        if (decl.resolving) return error.InvalidSchema;
        const saved = self.enterSchema(decl.doc orelse
            return error.InvalidSchema);
        defer self.leaveSchema(saved);
        const saved_redefinition = self.redefining_attribute_group;
        self.redefining_attribute_group = if (decl.original != null)
            decl
        else
            null;
        defer self.redefining_attribute_group = saved_redefinition;
        @constCast(decl).resolving = true;
        var attributes: []const AttributeUse = &.{};
        var any_attribute: ?Wildcard = null;
        var child = self.document.node(decl.node).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const child_node = self.document.node(child);
            if (child_node.kind != .element or !isXsd(child_node, null)) {
                continue;
            }
            if (std.mem.eql(u8, child_node.local, "annotation")) continue;
            if (std.mem.eql(u8, child_node.local, "attribute") or
                std.mem.eql(u8, child_node.local, "attributeGroup") or
                std.mem.eql(u8, child_node.local, "anyAttribute"))
            {
                try self.parseAttributeContent(
                    child,
                    &attributes,
                    &any_attribute,
                );
                continue;
            }
            return error.InvalidSchema;
        }
        @constCast(decl).attributes = attributes;
        @constCast(decl).any_attribute = any_attribute;
        @constCast(decl).parsed = true;
        @constCast(decl).resolving = false;
    }

    fn parseIdentityConstraints(
        self: *Compiler,
        id: dom.NodeId,
    ) Error![]const *const IdentityConstraint {
        var constraints: std.ArrayList(*const IdentityConstraint) = .empty;
        var child = self.document.node(id).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const child_node = self.document.node(child);
            if (child_node.kind != .element or !isXsd(child_node, null)) {
                continue;
            }
            var kind: ?IdentityKind = null;
            if (std.mem.eql(u8, child_node.local, "key")) {
                kind = .key;
            } else if (std.mem.eql(u8, child_node.local, "keyref")) {
                kind = .keyref;
            } else if (std.mem.eql(u8, child_node.local, "unique")) {
                kind = .unique;
            }
            if (kind == null) continue;
            const constraint = try self.parseIdentityConstraint(child, kind.?);
            if (self.findIdentityConstraint(.{
                .namespace_uri = constraint.namespace_uri,
                .local = constraint.name,
            }) != null) {
                return error.InvalidSchema;
            }
            try self.identity_constraints.append(self.arena, constraint);
            try constraints.append(self.arena, constraint);
        }
        return constraints.toOwnedSlice(self.arena);
    }

    fn parseIdentityConstraint(
        self: *Compiler,
        id: dom.NodeId,
        kind: IdentityKind,
    ) Error!*const IdentityConstraint {
        const name = self.document.attribute(id, "name") orelse
            return error.InvalidSchema;
        var selector: ?CompiledXPath = null;
        var fields: std.ArrayList(CompiledXPath) = .empty;
        var refer: ?QName = null;
        if (kind == .keyref) {
            const refer_value = self.document.attribute(id, "refer") orelse
                return error.InvalidSchema;
            refer = try self.resolveQName(id, refer_value);
        }
        var child = self.document.node(id).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const child_node = self.document.node(child);
            if (child_node.kind != .element or !isXsd(child_node, null)) {
                continue;
            }
            if (std.mem.eql(u8, child_node.local, "selector")) {
                if (selector != null) return error.InvalidSchema;
                const xpath_value = self.document.attribute(child, "xpath") orelse
                    return error.InvalidSchema;
                const compiled = try self.compileIdentityXPath(child, xpath_value);
                if (!isSelectorXPath(compiled.expr)) {
                    return error.InvalidSchema;
                }
                selector = compiled;
            } else if (std.mem.eql(u8, child_node.local, "field")) {
                const xpath_value = self.document.attribute(child, "xpath") orelse
                    return error.InvalidSchema;
                try fields.append(
                    self.arena,
                    try self.compileIdentityXPath(child, xpath_value),
                );
            }
        }
        if (selector == null or fields.items.len == 0) {
            return error.InvalidSchema;
        }
        const constraint = try self.arena.create(IdentityConstraint);
        constraint.* = .{
            .kind = kind,
            .name = name,
            .namespace_uri = self.target_namespace,
            .selector = selector.?,
            .fields = try fields.toOwnedSlice(self.arena),
            .refer = refer,
            .node = id,
        };
        return constraint;
    }

    fn compileIdentityXPath(
        self: *Compiler,
        id: dom.NodeId,
        text: []const u8,
    ) Error!CompiledXPath {
        var parser = xpath_parser.Parser.init(self.arena, text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidSchema,
        };
        const expr = parser.parse() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidSchema,
        };
        return .{
            .expr = expr,
            .namespaces = try self.document.inScopeNamespaces(self.arena, id),
        };
    }

    fn findIdentityConstraint(
        self: *Compiler,
        qname: QName,
    ) ?*const IdentityConstraint {
        for (self.identity_constraints.items) |constraint| {
            if (std.mem.eql(
                u8,
                constraint.namespace_uri,
                qname.namespace_uri,
            ) and std.mem.eql(u8, constraint.name, qname.local)) {
                return constraint;
            }
        }
        return null;
    }

    fn resolveIdentityReferences(self: *Compiler) Error!void {
        for (self.identity_constraints.items) |constraint| {
            const refer = constraint.refer orelse continue;
            const referenced = self.findIdentityConstraint(refer) orelse
                return error.InvalidSchema;
            if (referenced.kind == .keyref) return error.InvalidSchema;
            @constCast(constraint).referenced = referenced;
        }
    }

    fn resolveSubstitutions(self: *Compiler) Error!void {
        for (self.elements.items) |decl| {
            if (decl.substitution_qname) |qname| {
                const head = self.findGlobalElement(qname) orelse
                    return error.InvalidSchema;
                if (head == decl) return error.InvalidSchema;
                @constCast(decl).substitution_group = head;
            }
        }
        for (self.elements.items) |decl| {
            var current = decl.substitution_group;
            var steps: usize = 0;
            while (current) |head| {
                if (head == decl) return error.InvalidSchema;
                steps += 1;
                if (steps > self.elements.items.len + 1) {
                    return error.InvalidSchema;
                }
                current = head.substitution_group;
            }
        }
    }

    fn parseTypeBody(self: *Compiler, decl: *const TypeDecl) Error!void {
        const saved = self.enterSchema(decl.doc orelse
            return error.InvalidSchema);
        defer self.leaveSchema(saved);
        const node = self.document.node(decl.node);
        if (std.mem.eql(u8, node.local, "simpleType")) {
            @constCast(decl).body = .{
                .simple = try self.parseSimpleType(decl.node),
            };
        } else {
            @constCast(decl).body = .{
                .complex = try self.parseComplexType(decl.node),
            };
        }
    }

    fn parseSimpleType(self: *Compiler, id: dom.NodeId) Error!SimpleDecl {
        var child = self.document.node(id).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const child_node = self.document.node(child);
            if (child_node.kind != .element) continue;
            if (!isXsd(child_node, null)) continue;
            if (std.mem.eql(u8, child_node.local, "annotation")) continue;
            if (std.mem.eql(u8, child_node.local, "restriction")) {
                var base: ?TypeUse = null;
                if (self.document.attribute(child, "base")) |value| {
                    base = try self.typeUseFromQName(
                        child,
                        try self.resolveQName(child, value),
                    );
                }
                var facets: datatypes.Facets = .{};
                var inline_type: ?TypeUse = null;
                var facet_child = self.document.node(child).first_child;
                while (facet_child != dom.null_node) : (facet_child = self.document.node(facet_child).next_sibling) {
                    const facet_node = self.document.node(facet_child);
                    if (facet_node.kind != .element) continue;
                    if (!isXsd(facet_node, null)) continue;
                    if (std.mem.eql(u8, facet_node.local, "simpleType")) {
                        if (inline_type != null or base != null) {
                            return error.InvalidSchema;
                        }
                        inline_type = try self.inlineSimpleType(facet_child);
                    } else if (std.mem.eql(u8, facet_node.local, "annotation")) {
                        continue;
                    } else {
                        try self.addFacet(&facets, facet_child);
                    }
                }
                return .{ .restriction = .{
                    .base = base orelse inline_type orelse
                        return error.InvalidSchema,
                    .facets = facets,
                } };
            }
            if (std.mem.eql(u8, child_node.local, "list")) {
                var item: ?TypeUse = null;
                if (self.document.attribute(child, "itemType")) |value| {
                    item = try self.typeUseFromQName(
                        child,
                        try self.resolveQName(child, value),
                    );
                }
                var inline_type: ?TypeUse = null;
                var list_child = self.document.node(child).first_child;
                while (list_child != dom.null_node) : (list_child = self.document.node(list_child).next_sibling) {
                    const list_node = self.document.node(list_child);
                    if (list_node.kind == .element and
                        isXsd(list_node, "simpleType"))
                    {
                        if (inline_type != null or item != null) {
                            return error.InvalidSchema;
                        }
                        inline_type = try self.inlineSimpleType(list_child);
                    }
                }
                return .{ .list = .{
                    .item = item orelse inline_type orelse
                        return error.InvalidSchema,
                } };
            }
            if (std.mem.eql(u8, child_node.local, "union")) {
                var members: std.ArrayList(TypeUse) = .empty;
                if (self.document.attribute(child, "memberTypes")) |value| {
                    var tokens = std.mem.tokenizeAny(u8, value, " \t\r\n");
                    while (tokens.next()) |token| {
                        try members.append(
                            self.arena,
                            try self.typeUseFromQName(
                                child,
                                try self.resolveQName(child, token),
                            ),
                        );
                    }
                }
                var union_child = self.document.node(child).first_child;
                while (union_child != dom.null_node) : (union_child = self.document.node(union_child).next_sibling) {
                    const union_node = self.document.node(union_child);
                    if (union_node.kind == .element and
                        isXsd(union_node, "simpleType"))
                    {
                        try members.append(
                            self.arena,
                            try self.inlineSimpleType(union_child),
                        );
                    }
                }
                if (members.items.len == 0) return error.InvalidSchema;
                return .{ .union_ = .{
                    .members = try members.toOwnedSlice(self.arena),
                } };
            }
        }
        return error.InvalidSchema;
    }

    fn inlineSimpleType(self: *Compiler, id: dom.NodeId) Error!TypeUse {
        const decl = try self.arena.create(TypeDecl);
        decl.* = .{
            .node = id,
            .doc = self.current_schema,
            .final = try self.derivationSet(id, "final", false, true),
            .body = .{ .simple = try self.parseSimpleType(id) },
        };
        try self.types.append(self.arena, decl);
        return .{ .anonymous = decl };
    }

    fn inlineComplexType(self: *Compiler, id: dom.NodeId) Error!TypeUse {
        const decl = try self.arena.create(TypeDecl);
        decl.* = .{
            .node = id,
            .doc = self.current_schema,
            .abstract = try self.booleanAttribute(id, "abstract"),
            .block = try self.derivationSet(id, "block", false, false),
            .final = try self.derivationSet(id, "final", false, false),
            .body = .{ .complex = try self.parseComplexType(id) },
        };
        try self.types.append(self.arena, decl);
        return .{ .anonymous = decl };
    }

    fn addFacet(
        self: *Compiler,
        facets: *datatypes.Facets,
        id: dom.NodeId,
    ) Error!void {
        const node = self.document.node(id);
        const value = self.document.attribute(id, "value") orelse
            return error.InvalidSchema;
        if (std.mem.eql(u8, node.local, "enumeration")) {
            var list: std.ArrayList([]const u8) = .empty;
            if (facets.enumeration.len != 0) {
                try list.appendSlice(self.arena, facets.enumeration);
            }
            try list.append(self.arena, value);
            facets.enumeration = try list.toOwnedSlice(self.arena);
        } else if (std.mem.eql(u8, node.local, "pattern")) {
            const compiled = regex.compile(self.arena, value) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidRegex,
            };
            const pointer = try self.arena.create(regex.Regex);
            pointer.* = compiled;
            var list: std.ArrayList(*const regex.Regex) = .empty;
            if (facets.patterns.len != 0) {
                try list.appendSlice(self.arena, facets.patterns);
            }
            try list.append(self.arena, pointer);
            facets.patterns = try list.toOwnedSlice(self.arena);
        } else if (std.mem.eql(u8, node.local, "length")) {
            facets.length = try parseUnsigned(value);
        } else if (std.mem.eql(u8, node.local, "minLength")) {
            facets.min_length = try parseUnsigned(value);
        } else if (std.mem.eql(u8, node.local, "maxLength")) {
            facets.max_length = try parseUnsigned(value);
        } else if (std.mem.eql(u8, node.local, "minInclusive")) {
            facets.min_inclusive = value;
        } else if (std.mem.eql(u8, node.local, "maxInclusive")) {
            facets.max_inclusive = value;
        } else if (std.mem.eql(u8, node.local, "minExclusive")) {
            facets.min_exclusive = value;
        } else if (std.mem.eql(u8, node.local, "maxExclusive")) {
            facets.max_exclusive = value;
        } else if (std.mem.eql(u8, node.local, "totalDigits")) {
            facets.total_digits = try parseUnsigned(value);
        } else if (std.mem.eql(u8, node.local, "fractionDigits")) {
            facets.fraction_digits = try parseUnsigned(value);
        } else if (std.mem.eql(u8, node.local, "whiteSpace")) {
            if (std.mem.eql(u8, value, "preserve")) {
                facets.white_space = .preserve;
            } else if (std.mem.eql(u8, value, "replace")) {
                facets.white_space = .replace;
            } else if (std.mem.eql(u8, value, "collapse")) {
                facets.white_space = .collapse;
            } else {
                return error.InvalidSchema;
            }
        } else {
            return error.InvalidSchema;
        }
    }

    fn parseComplexType(self: *Compiler, id: dom.NodeId) Error!ComplexDecl {
        var decl: ComplexDecl = .{
            .mixed = try self.booleanAttribute(id, "mixed"),
        };
        var child = self.document.node(id).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const child_node = self.document.node(child);
            if (child_node.kind != .element) continue;
            if (!isXsd(child_node, null)) continue;
            if (std.mem.eql(u8, child_node.local, "annotation")) continue;
            if (std.mem.eql(u8, child_node.local, "sequence") or
                std.mem.eql(u8, child_node.local, "choice") or
                std.mem.eql(u8, child_node.local, "all") or
                std.mem.eql(u8, child_node.local, "group"))
            {
                if (decl.content != .empty) return error.InvalidSchema;
                decl.content = .{ .particle = try self.parseParticle(child) };
            } else if (std.mem.eql(u8, child_node.local, "attribute") or
                std.mem.eql(u8, child_node.local, "attributeGroup") or
                std.mem.eql(u8, child_node.local, "anyAttribute"))
            {
                try self.parseAttributeContent(
                    child,
                    &decl.attributes,
                    &decl.any_attribute,
                );
            } else if (std.mem.eql(u8, child_node.local, "simpleContent")) {
                if (decl.content != .empty) return error.InvalidSchema;
                decl.content = try self.parseSimpleContent(child, &decl);
            } else if (std.mem.eql(u8, child_node.local, "complexContent")) {
                if (decl.content != .empty) return error.InvalidSchema;
                decl.content = try self.parseComplexContent(child, &decl);
            }
        }
        return decl;
    }

    fn parseSimpleContent(
        self: *Compiler,
        id: dom.NodeId,
        decl: *ComplexDecl,
    ) Error!ContentDecl {
        var child = self.document.node(id).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const child_node = self.document.node(child);
            if (child_node.kind != .element or !isXsd(child_node, null)) continue;
            if (std.mem.eql(u8, child_node.local, "annotation")) continue;
            const restriction = std.mem.eql(u8, child_node.local, "restriction");
            if (!restriction and !std.mem.eql(u8, child_node.local, "extension")) {
                return error.InvalidSchema;
            }
            var base: ?TypeUse = null;
            if (self.document.attribute(child, "base")) |base_value| {
                base = try self.typeUseFromQName(
                    child,
                    try self.resolveQName(child, base_value),
                );
            }
            var facets: datatypes.Facets = .{};
            var facet_child = self.document.node(child).first_child;
            while (facet_child != dom.null_node) : (facet_child = self.document.node(facet_child).next_sibling) {
                const facet_node = self.document.node(facet_child);
                if (facet_node.kind != .element or !isXsd(facet_node, null)) {
                    continue;
                }
                if (std.mem.eql(u8, facet_node.local, "annotation")) continue;
                if (std.mem.eql(u8, facet_node.local, "attribute") or
                    std.mem.eql(u8, facet_node.local, "attributeGroup") or
                    std.mem.eql(u8, facet_node.local, "anyAttribute"))
                {
                    try self.parseAttributeContent(
                        facet_child,
                        &decl.attributes,
                        &decl.any_attribute,
                    );
                    continue;
                }
                if (std.mem.eql(u8, facet_node.local, "simpleType")) {
                    if (base != null) return error.InvalidSchema;
                    base = try self.inlineSimpleType(facet_child);
                    continue;
                }
                if (restriction) try self.addFacet(&facets, facet_child);
            }
            return .{ .simple_content = .{
                .base = base orelse return error.InvalidSchema,
                .facets = facets,
                .restriction = restriction,
            } };
        }
        return error.InvalidSchema;
    }

    fn parseComplexContent(
        self: *Compiler,
        id: dom.NodeId,
        decl: *ComplexDecl,
    ) Error!ContentDecl {
        var child = self.document.node(id).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const child_node = self.document.node(child);
            if (child_node.kind != .element or !isXsd(child_node, null)) continue;
            if (std.mem.eql(u8, child_node.local, "annotation")) continue;
            const restriction = std.mem.eql(u8, child_node.local, "restriction");
            if (!restriction and !std.mem.eql(u8, child_node.local, "extension")) {
                return error.InvalidSchema;
            }
            const base_value = self.document.attribute(child, "base") orelse
                return error.InvalidSchema;
            const base = try self.typeUseFromQName(
                child,
                try self.resolveQName(child, base_value),
            );
            var particle: ?*const Particle = null;
            var content_child = self.document.node(child).first_child;
            while (content_child != dom.null_node) : (content_child = self.document.node(content_child).next_sibling) {
                const content_node = self.document.node(content_child);
                if (content_node.kind != .element or
                    !isXsd(content_node, null))
                {
                    continue;
                }
                if (std.mem.eql(u8, content_node.local, "attribute") or
                    std.mem.eql(u8, content_node.local, "attributeGroup") or
                    std.mem.eql(u8, content_node.local, "anyAttribute"))
                {
                    try self.parseAttributeContent(
                        content_child,
                        &decl.attributes,
                        &decl.any_attribute,
                    );
                    continue;
                }
                if (std.mem.eql(u8, content_node.local, "sequence") or
                    std.mem.eql(u8, content_node.local, "choice") or
                    std.mem.eql(u8, content_node.local, "all"))
                {
                    if (particle != null) return error.InvalidSchema;
                    particle = try self.parseParticle(content_child);
                }
            }
            return .{ .complex_content = .{
                .base = base,
                .particle = particle,
                .restriction = restriction,
            } };
        }
        return error.InvalidSchema;
    }

    fn parseAttributeContent(
        self: *Compiler,
        id: dom.NodeId,
        attributes: *[]const AttributeUse,
        any_attribute: *?Wildcard,
    ) Error!void {
        const node = self.document.node(id);
        if (std.mem.eql(u8, node.local, "attribute")) {
            try self.parseAttributeUse(id, attributes);
        } else if (std.mem.eql(u8, node.local, "anyAttribute")) {
            if (any_attribute.* != null) return error.InvalidSchema;
            any_attribute.* = try self.parseAnyAttribute(id);
        } else if (std.mem.eql(u8, node.local, "attributeGroup")) {
            const ref = self.document.attribute(id, "ref") orelse
                return error.InvalidSchema;
            const qname = try self.resolveQName(id, ref);
            const group = self.findGlobalAttributeGroup(qname) orelse
                return error.InvalidSchema;
            try self.parseAttributeGroupBody(group);
            for (group.attributes) |candidate| {
                for (attributes.*) |existing| {
                    if (std.mem.eql(
                        u8,
                        existing.decl.namespace_uri,
                        candidate.decl.namespace_uri,
                    ) and std.mem.eql(
                        u8,
                        existing.decl.name,
                        candidate.decl.name,
                    )) {
                        return error.InvalidSchema;
                    }
                }
            }
            var list: std.ArrayList(AttributeUse) = .empty;
            try list.appendSlice(self.arena, attributes.*);
            try list.appendSlice(self.arena, group.attributes);
            attributes.* = try list.toOwnedSlice(self.arena);
            if (group.any_attribute) |wildcard| {
                if (any_attribute.* != null) return error.InvalidSchema;
                any_attribute.* = wildcard;
            }
        }
    }

    fn parseAttributeUse(
        self: *Compiler,
        id: dom.NodeId,
        uses: *[]const AttributeUse,
    ) Error!void {
        var use: Use = .optional;
        if (self.document.attribute(id, "use")) |value| {
            if (std.mem.eql(u8, value, "optional")) {
                use = .optional;
            } else if (std.mem.eql(u8, value, "required")) {
                use = .required;
            } else if (std.mem.eql(u8, value, "prohibited")) {
                use = .prohibited;
            } else {
                return error.InvalidSchema;
            }
        }
        var decl: *const AttributeDecl = undefined;
        if (self.document.attribute(id, "ref")) |value| {
            if (self.document.attribute(id, "name") != null or
                self.document.attribute(id, "type") != null or
                self.document.attribute(id, "form") != null or
                self.document.attribute(id, "default") != null or
                self.document.attribute(id, "fixed") != null or
                self.hasInlineTypeChild(id))
            {
                return error.InvalidSchema;
            }
            const qname = try self.resolveQName(id, value);
            decl = self.findGlobalAttribute(qname) orelse
                return error.InvalidSchema;
        } else {
            const name = self.document.attribute(id, "name") orelse
                return error.InvalidSchema;
            const default_value = self.document.attribute(id, "default");
            const fixed_value = self.document.attribute(id, "fixed");
            if (default_value != null and fixed_value != null) {
                return error.InvalidSchema;
            }
            if (use != .optional and (default_value != null or fixed_value != null)) {
                return error.InvalidSchema;
            }
            const qualified = try self.localForm(id, true);
            const attribute = try self.arena.create(AttributeDecl);
            attribute.* = .{
                .name = name,
                .namespace_uri = if (qualified) self.target_namespace else "",
                .node = id,
                .default_value = default_value,
                .fixed_value = fixed_value,
                .doc = self.current_schema,
            };
            attribute.type_use = try self.attributeTypeUse(id);
            try self.local_attributes.append(self.arena, attribute);
            decl = attribute;
        }
        for (uses.*) |existing| {
            if (std.mem.eql(
                u8,
                existing.decl.namespace_uri,
                decl.namespace_uri,
            ) and std.mem.eql(u8, existing.decl.name, decl.name)) {
                return error.InvalidSchema;
            }
        }
        var list: std.ArrayList(AttributeUse) = .empty;
        try list.appendSlice(self.arena, uses.*);
        try list.append(self.arena, .{ .decl = decl, .use = use });
        uses.* = try list.toOwnedSlice(self.arena);
    }

    fn applyWildcardNamespace(
        self: *Compiler,
        wildcard: *Wildcard,
        value: []const u8,
    ) Error!void {
        var tokens = std.mem.tokenizeAny(u8, value, " \t\r\n");
        var uris: std.ArrayList([]const u8) = .empty;
        var count: usize = 0;
        while (tokens.next()) |token| {
            if (std.mem.startsWith(u8, token, "##")) {
                if (count != 0) return error.InvalidSchema;
                wildcard.namespace_rule = try parseNamespaceRule(token);
                if (tokens.next() != null) return error.InvalidSchema;
                return;
            }
            try uris.append(self.arena, try self.arena.dupe(u8, token));
            count += 1;
        }
        if (uris.items.len == 0) return error.InvalidSchema;
        wildcard.namespaces = try uris.toOwnedSlice(self.arena);
    }

    fn parseAnyAttribute(self: *Compiler, id: dom.NodeId) Error!Wildcard {
        var wildcard: Wildcard = .{
            .target_namespace = self.target_namespace,
        };
        if (self.document.attribute(id, "namespace")) |value| {
            try self.applyWildcardNamespace(&wildcard, value);
        }
        if (self.document.attribute(id, "processContents")) |value| {
            if (std.mem.eql(u8, value, "skip")) {
                wildcard.process = .skip;
            } else if (std.mem.eql(u8, value, "lax")) {
                wildcard.process = .lax;
            } else if (std.mem.eql(u8, value, "strict")) {
                wildcard.process = .strict;
            } else {
                return error.InvalidSchema;
            }
        }
        return wildcard;
    }

    fn parseParticle(self: *Compiler, id: dom.NodeId) Error!*const Particle {
        const node = self.document.node(id);
        const occurs = try self.parseOccurs(id);
        if (std.mem.eql(u8, node.local, "element")) {
            const decl = try self.localElement(id);
            const particle = try self.arena.create(Particle);
            particle.* = .{ .element = .{
                .decl = decl,
                .min = occurs.min,
                .max = occurs.max,
            } };
            return particle;
        }
        if (std.mem.eql(u8, node.local, "any")) {
            var wildcard: Wildcard = .{
                .target_namespace = self.target_namespace,
            };
            if (self.document.attribute(id, "namespace")) |value| {
                try self.applyWildcardNamespace(&wildcard, value);
            }
            if (self.document.attribute(id, "processContents")) |value| {
                if (std.mem.eql(u8, value, "skip")) {
                    wildcard.process = .skip;
                } else if (std.mem.eql(u8, value, "lax")) {
                    wildcard.process = .lax;
                } else if (std.mem.eql(u8, value, "strict")) {
                    wildcard.process = .strict;
                } else {
                    return error.InvalidSchema;
                }
            }
            const particle = try self.arena.create(Particle);
            particle.* = .{ .any = .{
                .wildcard = wildcard,
                .min = occurs.min,
                .max = occurs.max,
            } };
            return particle;
        }
        if (std.mem.eql(u8, node.local, "group")) {
            const ref = self.document.attribute(id, "ref") orelse
                return error.InvalidSchema;
            const qname = try self.resolveQName(id, ref);
            const group = self.findGlobalGroup(qname) orelse
                return error.InvalidSchema;
            const particle = try self.arena.create(Particle);
            particle.* = .{ .group = .{
                .decl = group,
                .min = occurs.min,
                .max = occurs.max,
            } };
            return particle;
        }
        if (std.mem.eql(u8, node.local, "sequence") or
            std.mem.eql(u8, node.local, "choice") or
            std.mem.eql(u8, node.local, "all"))
        {
            var items: std.ArrayList(*const Particle) = .empty;
            var child = node.first_child;
            while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
                const child_node = self.document.node(child);
                if (child_node.kind != .element) continue;
                if (!isXsd(child_node, null)) continue;
                if (std.mem.eql(u8, child_node.local, "annotation")) continue;
                if (std.mem.eql(u8, child_node.local, "element") or
                    std.mem.eql(u8, child_node.local, "sequence") or
                    std.mem.eql(u8, child_node.local, "choice") or
                    std.mem.eql(u8, child_node.local, "all") or
                    std.mem.eql(u8, child_node.local, "any") or
                    std.mem.eql(u8, child_node.local, "group"))
                {
                    try items.append(self.arena, try self.parseParticle(child));
                } else {
                    return error.InvalidSchema;
                }
            }
            const particle = try self.arena.create(Particle);
            if (std.mem.eql(u8, node.local, "all")) {
                for (items.items) |item| {
                    if (item.* != .element) return error.InvalidSchema;
                    const element = item.element;
                    if (element.min > 1) return error.InvalidSchema;
                    const maximum = element.max orelse
                        return error.InvalidSchema;
                    if (maximum > 1) return error.InvalidSchema;
                }
            }
            if (std.mem.eql(u8, node.local, "sequence")) {
                particle.* = .{ .sequence = .{
                    .items = try items.toOwnedSlice(self.arena),
                    .min = occurs.min,
                    .max = occurs.max,
                } };
            } else if (std.mem.eql(u8, node.local, "choice")) {
                particle.* = .{ .choice = .{
                    .items = try items.toOwnedSlice(self.arena),
                    .min = occurs.min,
                    .max = occurs.max,
                } };
            } else {
                if (occurs.min > 1 or (occurs.max orelse 1) > 1) {
                    return error.InvalidSchema;
                }
                particle.* = .{ .all = .{
                    .items = try items.toOwnedSlice(self.arena),
                    .min = occurs.min,
                    .max = occurs.max,
                } };
            }
            return particle;
        }
        return error.InvalidSchema;
    }

    fn localElement(self: *Compiler, id: dom.NodeId) Error!*const ElementDecl {
        if (self.document.attribute(id, "ref")) |value| {
            if (self.document.attribute(id, "name") != null or
                self.document.attribute(id, "type") != null or
                self.document.attribute(id, "form") != null or
                self.document.attribute(id, "default") != null or
                self.document.attribute(id, "fixed") != null or
                self.document.attribute(id, "nillable") != null or
                self.document.attribute(id, "block") != null or
                self.document.attribute(id, "final") != null)
            {
                return error.InvalidSchema;
            }
            var child = self.document.node(id).first_child;
            while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
                const child_node = self.document.node(child);
                if (child_node.kind == .element and
                    std.mem.eql(u8, child_node.ns, xsd_namespace) and
                    (std.mem.eql(u8, child_node.local, "simpleType") or
                        std.mem.eql(u8, child_node.local, "complexType")))
                {
                    return error.InvalidSchema;
                }
            }
            const qname = try self.resolveQName(id, value);
            return self.findGlobalElement(qname) orelse
                return error.InvalidSchema;
        }
        if (self.document.attribute(id, "default") != null and
            self.document.attribute(id, "fixed") != null)
        {
            return error.InvalidSchema;
        }
        const name = self.document.attribute(id, "name") orelse
            return error.InvalidSchema;
        const qualified = try self.localForm(id, false);
        const decl = try self.arena.create(ElementDecl);
        decl.* = .{
            .name = name,
            .namespace_uri = if (qualified) self.target_namespace else "",
            .node = id,
            .nillable = try self.booleanAttribute(id, "nillable"),
            .block = try self.derivationSet(id, "block", true, false),
            .final = try self.derivationSet(id, "final", false, false),
            .default_value = self.document.attribute(id, "default"),
            .fixed_value = self.document.attribute(id, "fixed"),
            .doc = self.current_schema,
        };
        decl.type_use = try self.elementTypeUse(id, null);
        decl.identity = try self.parseIdentityConstraints(id);
        try self.local_elements.append(self.arena, decl);
        return decl;
    }

    fn localForm(
        self: *Compiler,
        id: dom.NodeId,
        attribute_declaration: bool,
    ) Error!bool {
        const value = self.document.attribute(id, "form") orelse
            return if (attribute_declaration)
                self.attribute_form_qualified
            else
                self.element_form_qualified;
        if (std.mem.eql(u8, value, "qualified")) return true;
        if (std.mem.eql(u8, value, "unqualified")) return false;
        return error.InvalidSchema;
    }

    const Occurs = struct { min: usize, max: ?usize };

    fn parseOccurs(self: *Compiler, id: dom.NodeId) Error!Occurs {
        var minimum: usize = 1;
        if (self.document.attribute(id, "minOccurs")) |value| {
            minimum = try parseUnsigned(value);
        }
        var maximum: ?usize = 1;
        if (self.document.attribute(id, "maxOccurs")) |value| {
            if (std.mem.eql(u8, value, "unbounded")) {
                maximum = null;
            } else {
                maximum = try parseUnsigned(value);
            }
        }
        if (maximum) |max| {
            if (max < minimum) return error.InvalidSchema;
        }
        return .{ .min = minimum, .max = maximum };
    }

    fn elementTypeUse(
        self: *Compiler,
        id: dom.NodeId,
        fallback: ?TypeUse,
    ) Error!TypeUse {
        if (self.document.attribute(id, "type")) |value| {
            if (self.hasInlineTypeChild(id)) return error.InvalidSchema;
            return self.typeUseFromQName(
                id,
                try self.resolveQName(id, value),
            );
        }
        var child = self.document.node(id).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const child_node = self.document.node(child);
            if (child_node.kind != .element) continue;
            if (std.mem.eql(u8, child_node.local, "simpleType")) {
                return self.inlineSimpleType(child);
            }
            if (std.mem.eql(u8, child_node.local, "complexType")) {
                return self.inlineComplexType(child);
            }
        }
        return fallback orelse .any_type;
    }

    fn attributeTypeUse(self: *Compiler, id: dom.NodeId) Error!TypeUse {
        if (self.document.attribute(id, "type")) |value| {
            if (self.hasInlineTypeChild(id)) return error.InvalidSchema;
            return self.typeUseFromQName(
                id,
                try self.resolveQName(id, value),
            );
        }
        var child = self.document.node(id).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const child_node = self.document.node(child);
            if (child_node.kind == .element and
                std.mem.eql(u8, child_node.local, "simpleType"))
            {
                return self.inlineSimpleType(child);
            }
        }
        return .any_simple;
    }

    fn hasInlineTypeChild(self: *Compiler, id: dom.NodeId) bool {
        var child = self.document.node(id).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const child_node = self.document.node(child);
            if (child_node.kind == .element and
                std.mem.eql(u8, child_node.ns, xsd_namespace) and
                (std.mem.eql(u8, child_node.local, "simpleType") or
                    std.mem.eql(u8, child_node.local, "complexType")))
            {
                return true;
            }
        }
        return false;
    }

    fn typeUseFromQName(self: *Compiler, id: dom.NodeId, qname: QName) Error!TypeUse {
        _ = self;
        _ = id;
        if (std.mem.eql(u8, qname.namespace_uri, xsd_namespace)) {
            if (std.mem.eql(u8, qname.local, "anyType")) return .any_type;
            if (std.mem.eql(u8, qname.local, "anySimpleType")) {
                return .any_simple;
            }
            if (datatypes.builtin(qname.local)) |builtin| {
                return .{ .builtin = builtin.kind };
            }
            return error.InvalidSchema;
        }
        return .{ .qname = qname };
    }

    fn resolveQName(
        self: *Compiler,
        id: dom.NodeId,
        raw: []const u8,
    ) Error!QName {
        const bindings = try self.document.inScopeNamespaces(self.arena, id);
        if (std.mem.indexOfScalar(u8, raw, ':')) |colon| {
            const prefix = raw[0..colon];
            const local = raw[colon + 1 ..];
            if (prefix.len == 0 or local.len == 0) return error.InvalidSchema;
            for (bindings) |binding| {
                if (std.mem.eql(u8, binding.prefix, prefix)) {
                    return .{ .namespace_uri = binding.uri, .local = local };
                }
            }
            return error.InvalidSchema;
        }
        var namespace_uri: []const u8 = "";
        var has_default = false;
        for (bindings) |binding| {
            if (binding.prefix.len == 0) {
                namespace_uri = binding.uri;
                has_default = true;
                break;
            }
        }
        if (!has_default and self.current_schema.chameleon) {
            namespace_uri = self.target_namespace;
        }
        return .{ .namespace_uri = namespace_uri, .local = raw };
    }

    fn findGlobalElement(
        self: *Compiler,
        qname: QName,
    ) ?*const ElementDecl {
        for (self.elements.items) |decl| {
            if (std.mem.eql(u8, decl.namespace_uri, qname.namespace_uri) and
                std.mem.eql(u8, decl.name, qname.local))
            {
                return decl;
            }
        }
        return null;
    }

    fn findGlobalAttribute(
        self: *Compiler,
        qname: QName,
    ) ?*const AttributeDecl {
        for (self.attributes.items) |decl| {
            if (std.mem.eql(u8, decl.namespace_uri, qname.namespace_uri) and
                std.mem.eql(u8, decl.name, qname.local))
            {
                return decl;
            }
        }
        return null;
    }

    fn findGlobalGroup(self: *Compiler, qname: QName) ?*const GroupDecl {
        if (self.redefining_group) |redefining| {
            if (std.mem.eql(u8, redefining.namespace_uri, qname.namespace_uri) and
                std.mem.eql(u8, redefining.name, qname.local))
            {
                return redefining.original;
            }
        }
        var index = self.groups.items.len;
        while (index > 0) {
            index -= 1;
            const decl = self.groups.items[index];
            if (std.mem.eql(u8, decl.namespace_uri, qname.namespace_uri) and
                std.mem.eql(u8, decl.name, qname.local))
            {
                return decl;
            }
        }
        return null;
    }

    fn findGlobalAttributeGroup(
        self: *Compiler,
        qname: QName,
    ) ?*const AttributeGroupDecl {
        if (self.redefining_attribute_group) |redefining| {
            if (std.mem.eql(u8, redefining.namespace_uri, qname.namespace_uri) and
                std.mem.eql(u8, redefining.name, qname.local))
            {
                return redefining.original;
            }
        }
        var index = self.attribute_groups.items.len;
        while (index > 0) {
            index -= 1;
            const decl = self.attribute_groups.items[index];
            if (std.mem.eql(u8, decl.namespace_uri, qname.namespace_uri) and
                std.mem.eql(u8, decl.name, qname.local))
            {
                return decl;
            }
        }
        return null;
    }

    fn findGlobalType(self: *Compiler, qname: QName) ?*const TypeDecl {
        if (self.redefining_type) |redefining| {
            if (std.mem.eql(u8, redefining.namespace_uri, qname.namespace_uri) and
                std.mem.eql(u8, redefining.name, qname.local))
            {
                return redefining.original;
            }
        }
        var index = self.types.items.len;
        while (index > 0) {
            index -= 1;
            const decl = self.types.items[index];
            if (decl.global and
                std.mem.eql(u8, decl.namespace_uri, qname.namespace_uri) and
                std.mem.eql(u8, decl.name, qname.local))
            {
                return decl;
            }
        }
        return null;
    }

    fn booleanAttribute(
        self: *Compiler,
        id: dom.NodeId,
        name: []const u8,
    ) Error!bool {
        const value = self.document.attribute(id, name) orelse return false;
        if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1")) {
            return true;
        }
        if (std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "0")) {
            return false;
        }
        return error.InvalidSchema;
    }

    fn derivationSet(
        self: *Compiler,
        id: dom.NodeId,
        attribute: []const u8,
        allow_substitution: bool,
        allow_list_union: bool,
    ) Error!DerivationSet {
        const value = self.document.attribute(id, attribute) orelse return .{};
        var out: DerivationSet = .{};
        var tokens = std.mem.tokenizeAny(u8, value, " \t\r\n");
        var any = false;
        while (tokens.next()) |token| {
            any = true;
            if (std.mem.eql(u8, token, "#all")) {
                out = .{
                    .extension = true,
                    .restriction = true,
                    .substitution = allow_substitution,
                };
                continue;
            }
            if (std.mem.eql(u8, token, "extension")) {
                out.extension = true;
                continue;
            }
            if (std.mem.eql(u8, token, "restriction")) {
                out.restriction = true;
                continue;
            }
            if (allow_substitution and
                std.mem.eql(u8, token, "substitution"))
            {
                out.substitution = true;
                continue;
            }
            if (allow_list_union and
                (std.mem.eql(u8, token, "list") or
                    std.mem.eql(u8, token, "union")))
            {
                continue;
            }
            return error.InvalidSchema;
        }
        if (!any) return error.InvalidSchema;
        return out;
    }

    fn resolveAllTypes(self: *Compiler) Error!void {
        for (self.types.items) |decl| {
            _ = try self.resolveTypeDecl(decl);
        }
    }

    fn resolveTypeDecl(self: *Compiler, decl: *const TypeDecl) Error!TypeInfo {
        if (decl.info) |info| return info;
        if (decl.resolving) return error.InvalidSchema;
        const mutable = @constCast(decl);
        mutable.resolving = true;
        defer mutable.resolving = false;
        const saved_redefinition = self.redefining_type;
        self.redefining_type = if (decl.original != null) decl else null;
        defer self.redefining_type = saved_redefinition;
        const info: TypeInfo = switch (decl.body) {
            .simple => |simple| .{
                .simple = try self.resolveSimpleDecl(simple),
            },
            .complex => |complex| .{
                .complex = try self.resolveComplexDecl(complex),
            },
            .unresolved => return error.InvalidSchema,
        };
        switch (info) {
            .simple => |simple| @constCast(simple).decl = decl,
            .complex => |complex| {
                @constCast(complex).decl = decl;
                @constCast(complex).abstract = decl.abstract;
            },
            else => {},
        }
        mutable.info = info;
        return info;
    }

    fn resolveSimpleDecl(
        self: *Compiler,
        decl: SimpleDecl,
    ) Error!*const SimpleInfo {
        switch (decl) {
            .restriction => |restriction| {
                const base = try self.resolveTypeUseToSimple(restriction.base);
                if (typeFinal(.{ .simple = base }).restriction) {
                    return error.InvalidSchema;
                }
                try self.checkRestrictionFacets(base, restriction.facets);
                const info = try self.arena.create(SimpleInfo);
                info.* = base.*;
                info.base = .{ .simple = base };
                info.facets = mergeFacets(base.facets, restriction.facets);
                return info;
            },
            .list => |list| {
                const item = try self.resolveTypeUseToSimple(list.item);
                if (item.variety != .atomic) return error.InvalidSchema;
                const info = try self.arena.create(SimpleInfo);
                info.* = .{ .variety = .list, .item = item };
                return info;
            },
            .union_ => |union_| {
                const members = try self.arena.alloc(
                    *const SimpleInfo,
                    union_.members.len,
                );
                for (union_.members, 0..) |member, index| {
                    members[index] = try self.resolveTypeUseToSimple(member);
                }
                const info = try self.arena.create(SimpleInfo);
                info.* = .{ .variety = .union_, .members = members };
                return info;
            },
        }
    }

    fn resolveTypeUseToSimple(
        self: *Compiler,
        use: TypeUse,
    ) Error!*const SimpleInfo {
        const info = try self.resolveTypeUse(use);
        return switch (info) {
            .simple => |simple| simple,
            .any_simple => try self.builtinInfo(.string),
            else => error.InvalidSchema,
        };
    }

    fn resolveTypeUse(self: *Compiler, use: TypeUse) Error!TypeInfo {
        return switch (use) {
            .any_type => .any_type,
            .any_simple => .any_simple,
            .builtin => |kind| .{ .simple = try self.builtinInfo(kind) },
            .anonymous => |decl| try self.resolveTypeDecl(decl),
            .qname => |qname| blk: {
                const decl = self.findGlobalType(qname) orelse
                    return error.InvalidSchema;
                break :blk try self.resolveTypeDecl(decl);
            },
        };
    }

    fn builtinInfo(
        self: *Compiler,
        kind: datatypes.Kind,
    ) Error!*const SimpleInfo {
        const info = try self.arena.create(SimpleInfo);
        info.* = .{ .kind = kind };
        return info;
    }

    fn resolveComplexDecl(
        self: *Compiler,
        decl: ComplexDecl,
    ) Error!*const ComplexInfo {
        const info = try self.arena.create(ComplexInfo);
        info.* = .{
            .mixed = decl.mixed,
            .attributes = decl.attributes,
            .any_attribute = decl.any_attribute,
        };
        switch (decl.content) {
            .empty => {},
            .particle => |particle| info.particle = particle,
            .simple_content => |content| {
                const base_info = try self.resolveTypeUse(content.base);
                const method: DerivationSet = if (content.restriction)
                    .{ .restriction = true }
                else
                    .{ .extension = true };
                const prohibited = typeFinal(base_info);
                if (method.has(.restriction) and prohibited.restriction or
                    method.has(.extension) and prohibited.extension)
                {
                    return error.InvalidSchema;
                }
                var base_simple: *const SimpleInfo = undefined;
                var base_attributes: []const AttributeUse = &.{};
                var base_any_attribute: ?Wildcard = null;
                switch (base_info) {
                    .simple => |simple| {
                        if (content.restriction) return error.InvalidSchema;
                        base_simple = simple;
                    },
                    .any_simple => {
                        if (content.restriction) return error.InvalidSchema;
                        base_simple = try self.builtinInfo(.string);
                    },
                    .complex => |complex| {
                        base_simple = complex.simple orelse
                            return error.InvalidSchema;
                        base_attributes = complex.attributes;
                        base_any_attribute = complex.any_attribute;
                    },
                    else => return error.InvalidSchema,
                }
                try self.checkRestrictionFacets(base_simple, content.facets);
                const merged = try self.arena.create(SimpleInfo);
                merged.* = base_simple.*;
                merged.base = .{ .simple = base_simple };
                merged.facets = mergeFacets(
                    base_simple.facets,
                    content.facets,
                );
                info.simple = merged;
                info.attributes = try self.mergeAttributes(
                    base_attributes,
                    decl.attributes,
                );
                info.any_attribute = decl.any_attribute orelse
                    base_any_attribute;
                info.base = base_info;
                info.derivation = if (content.restriction)
                    .restriction
                else
                    .extension;
            },
            .complex_content => |content| {
                const base_info = try self.resolveTypeUse(content.base);
                const method: DerivationSet = if (content.restriction)
                    .{ .restriction = true }
                else
                    .{ .extension = true };
                const prohibited = typeFinal(base_info);
                if (method.has(.restriction) and prohibited.restriction or
                    method.has(.extension) and prohibited.extension)
                {
                    return error.InvalidSchema;
                }
                const base_complex = switch (base_info) {
                    .complex => |complex| complex,
                    .any_type => blk: {
                        const empty = try self.arena.create(ComplexInfo);
                        empty.* = .{};
                        break :blk empty;
                    },
                    else => return error.InvalidSchema,
                };
                info.mixed = if (content.restriction)
                    decl.mixed
                else
                    base_complex.mixed or decl.mixed;
                info.attributes = try self.mergeAttributes(
                    base_complex.attributes,
                    decl.attributes,
                );
                info.any_attribute = decl.any_attribute orelse
                    base_complex.any_attribute;
                if (content.particle) |particle| {
                    if (content.restriction) {
                        info.particle = particle;
                    } else if (base_complex.particle) |base_particle| {
                        info.particle = try self.sequenceOf(
                            base_particle,
                            particle,
                        );
                    } else {
                        info.particle = particle;
                    }
                } else {
                    info.particle = if (content.restriction)
                        null
                    else
                        base_complex.particle;
                }
                info.base = base_info;
                info.derivation = if (content.restriction)
                    .restriction
                else
                    .extension;
            },
        }
        return info;
    }

    fn resolveTypeUseToSimpleContent(
        self: *Compiler,
        use: TypeUse,
    ) Error!*const SimpleInfo {
        const info = try self.resolveTypeUse(use);
        return switch (info) {
            .simple => |simple| simple,
            .any_simple => try self.builtinInfo(.string),
            .complex => |complex| complex.simple orelse error.InvalidSchema,
            else => error.InvalidSchema,
        };
    }

    fn resolveTypeUseToComplex(
        self: *Compiler,
        use: TypeUse,
    ) Error!*const ComplexInfo {
        const info = try self.resolveTypeUse(use);
        return switch (info) {
            .complex => |complex| complex,
            .any_type => blk: {
                const empty = try self.arena.create(ComplexInfo);
                empty.* = .{};
                break :blk empty;
            },
            else => error.InvalidSchema,
        };
    }

    fn sequenceOf(
        self: *Compiler,
        first: *const Particle,
        second: *const Particle,
    ) Error!*const Particle {
        const items = try self.arena.alloc(*const Particle, 2);
        items[0] = first;
        items[1] = second;
        const particle = try self.arena.create(Particle);
        particle.* = .{ .sequence = .{ .items = items } };
        return particle;
    }

    fn mergeAttributes(
        self: *Compiler,
        base: []const AttributeUse,
        derived: []const AttributeUse,
    ) Error![]const AttributeUse {
        var out: std.ArrayList(AttributeUse) = .empty;
        try out.appendSlice(self.arena, base);
        for (derived) |use| {
            var replaced = false;
            for (out.items, 0..) |existing, index| {
                if (std.mem.eql(
                    u8,
                    existing.decl.namespace_uri,
                    use.decl.namespace_uri,
                ) and std.mem.eql(u8, existing.decl.name, use.decl.name)) {
                    out.items[index] = use;
                    replaced = true;
                    break;
                }
            }
            if (!replaced) try out.append(self.arena, use);
        }
        return out.toOwnedSlice(self.arena);
    }

    fn resolveAllDeclarations(self: *Compiler) Error!void {
        for (self.elements.items) |decl| {
            @constCast(decl).type_info = try self.resolveTypeUse(decl.type_use);
            try self.checkElementValues(decl);
        }
        for (self.local_elements.items) |decl| {
            @constCast(decl).type_info = try self.resolveTypeUse(decl.type_use);
            try self.checkElementValues(decl);
        }
        for (self.attributes.items) |decl| {
            @constCast(decl).type_info = try self.resolveTypeUse(decl.type_use);
            try self.checkAttributeValues(decl);
        }
        for (self.local_attributes.items) |decl| {
            @constCast(decl).type_info = try self.resolveTypeUse(decl.type_use);
            try self.checkAttributeValues(decl);
        }
    }

    /// Reject facets that do not apply to the base type's variety, require
    /// totalDigits to be positive, and check that facet values are valid
    /// values of the base type.
    fn checkRestrictionFacets(
        self: *Compiler,
        base: *const SimpleInfo,
        facets: datatypes.Facets,
    ) Error!void {
        const has_length = facets.length != null or
            facets.min_length != null or
            facets.max_length != null;
        const has_bounds = facets.min_inclusive != null or
            facets.max_inclusive != null or
            facets.min_exclusive != null or
            facets.max_exclusive != null;
        const has_digits = facets.total_digits != null or
            facets.fraction_digits != null;
        switch (base.variety) {
            .list => if (has_bounds or has_digits) {
                return error.InvalidSchema;
            },
            .union_ => if (has_length or has_bounds or has_digits) {
                return error.InvalidSchema;
            },
            .atomic => {
                if (has_length and !lengthFacetApplies(base.kind)) {
                    return error.InvalidSchema;
                }
                if (has_bounds and !orderedFacetApplies(base.kind)) {
                    return error.InvalidSchema;
                }
                if (has_digits and !digitsFacetApplies(base.kind)) {
                    return error.InvalidSchema;
                }
            },
        }
        if (facets.total_digits) |value| {
            if (value == 0) return error.InvalidSchema;
        }
        if (facets.min_inclusive) |value| {
            if (!try self.valueValidFor(base, value)) {
                return error.InvalidSchema;
            }
        }
        if (facets.max_inclusive) |value| {
            if (!try self.valueValidFor(base, value)) {
                return error.InvalidSchema;
            }
        }
        if (facets.min_exclusive) |value| {
            if (!try self.valueValidFor(base, value)) {
                return error.InvalidSchema;
            }
        }
        if (facets.max_exclusive) |value| {
            if (!try self.valueValidFor(base, value)) {
                return error.InvalidSchema;
            }
        }
        for (facets.enumeration) |value| {
            if (!try self.valueValidFor(base, value)) {
                return error.InvalidSchema;
            }
        }
    }

    fn valueValidFor(
        self: *Compiler,
        base: *const SimpleInfo,
        value: []const u8,
    ) Error!bool {
        return switch (base.variety) {
            .atomic => datatypes.validate(
                self.arena,
                base.kind,
                base.facets,
                value,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidPattern => false,
            },
            .list => blk: {
                const item = base.item orelse break :blk false;
                var tokens = std.mem.tokenizeAny(u8, value, " \t\r\n");
                while (tokens.next()) |token| {
                    if (!try self.valueValidFor(item, token)) break :blk false;
                }
                break :blk true;
            },
            .union_ => blk: {
                for (base.members) |member| {
                    if (try self.valueValidFor(member, value)) break :blk true;
                }
                break :blk false;
            },
        };
    }

    fn checkElementValues(
        self: *Compiler,
        decl: *const ElementDecl,
    ) Error!void {
        const value = decl.default_value orelse
            decl.fixed_value orelse return;
        const simple = switch (decl.type_info) {
            .simple => |simple| simple,
            // anySimpleType and anyType accept every lexical value.
            .any_simple, .any_type => return,
            .complex => |complex| blk: {
                if (complex.simple) |simple| break :blk simple;
                if (!complex.mixed) return error.InvalidSchema;
                if (complex.particle) |particle| {
                    if (!particleEmptiable(particle, 0)) {
                        return error.InvalidSchema;
                    }
                }
                return;
            },
        };
        if (!try self.valueValidFor(simple, value)) {
            return error.InvalidSchema;
        }
    }

    fn checkAttributeValues(
        self: *Compiler,
        decl: *const AttributeDecl,
    ) Error!void {
        const simple = switch (decl.type_info) {
            .simple => |simple| simple,
            .any_simple => return,
            else => return error.InvalidSchema,
        };
        const value = decl.default_value orelse
            decl.fixed_value orelse return;
        if (!try self.valueValidFor(simple, value)) {
            return error.InvalidSchema;
        }
    }

    /// Validate substitution group affiliations once all type information has
    /// been resolved. Members must have types validly derived from the head,
    /// and the head's `final` exclusions must not prohibit that derivation.
    fn checkSubstitutionTypes(self: *Compiler) Error!void {
        for (self.elements.items) |decl| {
            const head = decl.substitution_group orelse continue;
            if (!isDerivedFrom(decl.type_info, head.type_info)) {
                return error.InvalidSchema;
            }
            const methods = derivationMethods(decl.type_info, head.type_info);
            if (methods.extension and head.final.extension or
                methods.restriction and head.final.restriction)
            {
                return error.InvalidSchema;
            }
        }
    }
};

fn mergeFacets(
    base: datatypes.Facets,
    derived: datatypes.Facets,
) datatypes.Facets {
    var out = base;
    if (derived.enumeration.len != 0) out.enumeration = derived.enumeration;
    if (derived.patterns.len != 0) out.patterns = derived.patterns;
    if (derived.length != null) out.length = derived.length;
    if (derived.min_length != null) out.min_length = derived.min_length;
    if (derived.max_length != null) out.max_length = derived.max_length;
    if (derived.min_inclusive != null) out.min_inclusive = derived.min_inclusive;
    if (derived.max_inclusive != null) out.max_inclusive = derived.max_inclusive;
    if (derived.min_exclusive != null) out.min_exclusive = derived.min_exclusive;
    if (derived.max_exclusive != null) out.max_exclusive = derived.max_exclusive;
    if (derived.total_digits != null) out.total_digits = derived.total_digits;
    if (derived.fraction_digits != null) {
        out.fraction_digits = derived.fraction_digits;
    }
    if (derived.white_space != null) out.white_space = derived.white_space;
    return out;
}

fn parseNamespaceRule(value: []const u8) Error!NamespaceRule {
    if (std.mem.eql(u8, value, "##any")) return .any;
    if (std.mem.eql(u8, value, "##other")) return .other;
    if (std.mem.eql(u8, value, "##targetNamespace")) return .target_namespace;
    if (std.mem.eql(u8, value, "##local")) return .local;
    return error.InvalidSchema;
}

fn formDefaultFor(
    document: *const dom.Document,
    root: dom.NodeId,
    attribute_name: []const u8,
) Error!bool {
    const value = document.attribute(root, attribute_name) orelse
        return false;
    if (std.mem.eql(u8, value, "qualified")) return true;
    if (std.mem.eql(u8, value, "unqualified")) return false;
    return error.InvalidSchema;
}

/// A particle is emptiable when it can match without consuming any element.
fn particleEmptiable(particle: *const Particle, depth: usize) bool {
    if (depth > 256) return false;
    return switch (particle.*) {
        .element => |value| value.min == 0,
        .any => |value| value.min == 0,
        .group => |value| if (value.decl.particle) |inner|
            particleEmptiable(inner, depth + 1)
        else
            false,
        .sequence => |value| blk: {
            for (value.items) |item| {
                if (!particleEmptiable(item, depth + 1)) break :blk false;
            }
            break :blk true;
        },
        .choice => |value| blk: {
            for (value.items) |item| {
                if (particleEmptiable(item, depth + 1)) break :blk true;
            }
            break :blk false;
        },
        .all => |value| blk: {
            for (value.items) |item| {
                if (!particleEmptiable(item, depth + 1)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn lengthFacetApplies(kind: datatypes.Kind) bool {
    return switch (kind) {
        .string,
        .normalized_string,
        .token,
        .language,
        .name,
        .ncname,
        .nmtoken,
        .nmtokens,
        .id,
        .idref,
        .idrefs,
        .entity,
        .entities,
        .any_uri,
        .qname,
        .notation,
        .hex_binary,
        .base64_binary,
        => true,
        else => false,
    };
}

fn orderedFacetApplies(kind: datatypes.Kind) bool {
    return switch (kind) {
        .decimal,
        .integer,
        .non_positive_integer,
        .negative_integer,
        .long,
        .int,
        .short,
        .byte,
        .non_negative_integer,
        .unsigned_long,
        .unsigned_int,
        .unsigned_short,
        .unsigned_byte,
        .positive_integer,
        .float,
        .double,
        .duration,
        .date_time,
        .time,
        .date,
        .g_year_month,
        .g_year,
        .g_month_day,
        .g_day,
        .g_month,
        => true,
        else => false,
    };
}

fn digitsFacetApplies(kind: datatypes.Kind) bool {
    return switch (kind) {
        .decimal,
        .integer,
        .non_positive_integer,
        .negative_integer,
        .long,
        .int,
        .short,
        .byte,
        .non_negative_integer,
        .unsigned_long,
        .unsigned_int,
        .unsigned_short,
        .unsigned_byte,
        .positive_integer,
        => true,
        else => false,
    };
}

/// Identity-constraint selectors are restricted XPaths: unions of relative
/// location paths that never select attributes.
fn isSelectorXPath(expression: *const xpath_ast.Expr) bool {
    switch (expression.*) {
        .binary => |binary| {
            if (binary.op != .union_) return false;
            return isSelectorXPath(binary.lhs) and isSelectorXPath(binary.rhs);
        },
        .path => |path| {
            if (path.start != null) return false;
            for (path.steps) |step| {
                if (step.axis == .attribute) return false;
            }
            return true;
        },
        else => return false,
    }
}

fn parseUnsigned(value: []const u8) Error!usize {
    return std.fmt.parseUnsigned(usize, value, 10) catch
        return error.InvalidSchema;
}

fn isXsd(node: *const dom.Node, local: ?[]const u8) bool {
    if (!std.mem.eql(u8, node.ns, xsd_namespace)) return false;
    if (local) |expected| return std.mem.eql(u8, node.local, expected);
    return true;
}
