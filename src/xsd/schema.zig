//! XML Schema 1.0 structure compiler.
//!
//! Supported: global/local elements and attributes, simple types with
//! restriction/list/union and facets, complex types with sequence/choice/all
//! particles, groups, attribute groups, wildcards, substitution groups,
//! attribute uses, and simple/complex content extension and restriction.
//! Includes/imports, identity constraints, and abstract-type enforcement are
//! not implemented.

const std = @import("std");
const dom = @import("../dom.zig");
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
};

pub const ComplexInfo = struct {
    mixed: bool = false,
    simple: ?*const SimpleInfo = null,
    particle: ?*const Particle = null,
    attributes: []const AttributeUse = &.{},
    any_attribute: ?Wildcard = null,
};

pub const NamespaceRule = enum { any, other, target_namespace, local };

pub const Wildcard = struct {
    namespace_rule: NamespaceRule = .any,
    process: enum { skip, lax, strict } = .strict,
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
    node: dom.NodeId = dom.null_node,
};

pub const AttributeGroupDecl = struct {
    name: []const u8 = "",
    namespace_uri: []const u8 = "",
    attributes: []const AttributeUse = &.{},
    any_attribute: ?Wildcard = null,
    parsed: bool = false,
    resolving: bool = false,
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
    node: dom.NodeId = dom.null_node,
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
    body: union(enum) {
        simple: SimpleDecl,
        complex: ComplexDecl,
        unresolved,
    } = .unresolved,
    info: ?TypeInfo = null,
    resolving: bool = false,
    node: dom.NodeId = dom.null_node,
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

    pub fn deinit(self: *Schema) void {
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
        for (self.types) |decl| {
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
        for (self.groups) |decl| {
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
        for (self.attribute_groups) |decl| {
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

/// Compile an XML Schema document.
pub fn parse(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
) Error!Schema {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var compiler: Compiler = .{
        .arena = arena.allocator(),
        .document = document,
    };
    try compiler.run();
    return .{
        .arena = arena,
        .target_namespace = compiler.target_namespace,
        .element_form_qualified = compiler.element_form_qualified,
        .attribute_form_qualified = compiler.attribute_form_qualified,
        .elements = try compiler.elements.toOwnedSlice(compiler.arena),
        .attributes = try compiler.attributes.toOwnedSlice(compiler.arena),
        .types = try compiler.types.toOwnedSlice(compiler.arena),
        .groups = try compiler.groups.toOwnedSlice(compiler.arena),
        .attribute_groups = try compiler.attribute_groups.toOwnedSlice(
            compiler.arena,
        ),
    };
}

const Compiler = struct {
    arena: std.mem.Allocator,
    document: *const dom.Document,
    target_namespace: []const u8 = "",
    element_form_qualified: bool = false,
    attribute_form_qualified: bool = false,
    elements: std.ArrayList(*const ElementDecl) = .empty,
    attributes: std.ArrayList(*const AttributeDecl) = .empty,
    types: std.ArrayList(*const TypeDecl) = .empty,
    groups: std.ArrayList(*const GroupDecl) = .empty,
    attribute_groups: std.ArrayList(*const AttributeGroupDecl) = .empty,
    local_elements: std.ArrayList(*const ElementDecl) = .empty,
    local_attributes: std.ArrayList(*const AttributeDecl) = .empty,
    root: dom.NodeId = dom.null_node,

    fn run(self: *Compiler) Error!void {
        const root = self.document.root();
        if (root == dom.null_node) return error.InvalidSchema;
        const root_node = self.document.node(root);
        if (!isXsd(root_node, "schema")) return error.InvalidSchema;
        self.root = root;

        if (self.document.attribute(root, "targetNamespace")) |value| {
            self.target_namespace = value;
        }
        self.element_form_qualified = try self.formDefault(
            root,
            "elementFormDefault",
        );
        self.attribute_form_qualified = try self.formDefault(
            root,
            "attributeFormDefault",
        );

        try self.collectGlobals();
        try self.parseGlobalBodies();
        try self.resolveSubstitutions();
        try self.resolveAllTypes();
        try self.resolveAllDeclarations();
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

    fn collectGlobals(self: *Compiler) Error!void {
        var child = self.document.node(self.root).first_child;
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
            } else if (std.mem.eql(u8, child_node.local, "include") or
                std.mem.eql(u8, child_node.local, "import") or
                std.mem.eql(u8, child_node.local, "redefine") or
                std.mem.eql(u8, child_node.local, "notation"))
            {
                return error.InvalidSchema;
            }
        }
    }

    fn globalElement(self: *Compiler, id: dom.NodeId) Error!*const ElementDecl {
        if (self.document.attribute(id, "ref") != null) {
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
            .default_value = self.document.attribute(id, "default"),
            .fixed_value = self.document.attribute(id, "fixed"),
            .substitution_qname = substitution_qname,
        };
        return decl;
    }

    fn globalAttribute(
        self: *Compiler,
        id: dom.NodeId,
    ) Error!*const AttributeDecl {
        if (self.document.attribute(id, "ref") != null) {
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
        };
        return decl;
    }

    fn globalType(self: *Compiler, id: dom.NodeId) Error!*const TypeDecl {
        const name = self.document.attribute(id, "name") orelse
            return error.InvalidSchema;
        const decl = try self.arena.create(TypeDecl);
        decl.* = .{
            .name = name,
            .namespace_uri = self.target_namespace,
            .global = true,
            .node = id,
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
            @constCast(decl).type_use = try self.elementTypeUse(
                decl.node,
                null,
            );
        }
        for (self.attributes.items) |decl| {
            @constCast(decl).type_use = try self.attributeTypeUse(decl.node);
        }
    }

    fn parseGroupBody(self: *Compiler, decl: *const GroupDecl) Error!void {
        if (decl.parsed) return;
        if (decl.resolving) return error.InvalidSchema;
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
            .body = .{ .simple = try self.parseSimpleType(id) },
        };
        try self.types.append(self.arena, decl);
        return .{ .anonymous = decl };
    }

    fn inlineComplexType(self: *Compiler, id: dom.NodeId) Error!TypeUse {
        const decl = try self.arena.create(TypeDecl);
        decl.* = .{
            .node = id,
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
            if (self.document.attribute(id, "name") != null) {
                return error.InvalidSchema;
            }
            const qname = try self.resolveQName(id, value);
            decl = self.findGlobalAttribute(qname) orelse
                return error.InvalidSchema;
        } else {
            const name = self.document.attribute(id, "name") orelse
                return error.InvalidSchema;
            const qualified = try self.localForm(id, true);
            const attribute = try self.arena.create(AttributeDecl);
            attribute.* = .{
                .name = name,
                .namespace_uri = if (qualified) self.target_namespace else "",
                .node = id,
                .default_value = self.document.attribute(id, "default"),
                .fixed_value = self.document.attribute(id, "fixed"),
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

    fn parseAnyAttribute(self: *Compiler, id: dom.NodeId) Error!Wildcard {
        var wildcard: Wildcard = .{};
        if (self.document.attribute(id, "namespace")) |value| {
            wildcard.namespace_rule = try parseNamespaceRule(value);
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
            var wildcard: Wildcard = .{};
            if (self.document.attribute(id, "namespace")) |value| {
                wildcard.namespace_rule = try parseNamespaceRule(value);
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
            if (self.document.attribute(id, "name") != null) {
                return error.InvalidSchema;
            }
            const qname = try self.resolveQName(id, value);
            return self.findGlobalElement(qname) orelse
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
            .default_value = self.document.attribute(id, "default"),
            .fixed_value = self.document.attribute(id, "fixed"),
        };
        decl.type_use = try self.elementTypeUse(id, null);
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
        for (bindings) |binding| {
            if (binding.prefix.len == 0) {
                namespace_uri = binding.uri;
                break;
            }
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
        for (self.groups.items) |decl| {
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
        for (self.attribute_groups.items) |decl| {
            if (std.mem.eql(u8, decl.namespace_uri, qname.namespace_uri) and
                std.mem.eql(u8, decl.name, qname.local))
            {
                return decl;
            }
        }
        return null;
    }

    fn findGlobalType(self: *Compiler, qname: QName) ?*const TypeDecl {
        for (self.types.items) |decl| {
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
        const info: TypeInfo = switch (decl.body) {
            .simple => |simple| .{
                .simple = try self.resolveSimpleDecl(simple),
            },
            .complex => |complex| .{
                .complex = try self.resolveComplexDecl(complex),
            },
            .unresolved => return error.InvalidSchema,
        };
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
                const info = try self.arena.create(SimpleInfo);
                info.* = base.*;
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
                const merged = try self.arena.create(SimpleInfo);
                merged.* = base_simple.*;
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
            },
            .complex_content => |content| {
                const base_info = try self.resolveTypeUseToComplex(content.base);
                info.mixed = if (content.restriction)
                    decl.mixed
                else
                    base_info.mixed or decl.mixed;
                info.attributes = try self.mergeAttributes(
                    base_info.attributes,
                    decl.attributes,
                );
                info.any_attribute = decl.any_attribute orelse
                    base_info.any_attribute;
                if (content.particle) |particle| {
                    if (content.restriction) {
                        info.particle = particle;
                    } else if (base_info.particle) |base_particle| {
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
                        base_info.particle;
                }
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
        }
        for (self.local_elements.items) |decl| {
            @constCast(decl).type_info = try self.resolveTypeUse(decl.type_use);
        }
        for (self.attributes.items) |decl| {
            @constCast(decl).type_info = try self.resolveTypeUse(decl.type_use);
        }
        for (self.local_attributes.items) |decl| {
            @constCast(decl).type_info = try self.resolveTypeUse(decl.type_use);
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

fn parseUnsigned(value: []const u8) Error!usize {
    return std.fmt.parseUnsigned(usize, value, 10) catch
        return error.InvalidSchema;
}

fn isXsd(node: *const dom.Node, local: ?[]const u8) bool {
    if (!std.mem.eql(u8, node.ns, xsd_namespace)) return false;
    if (local) |expected| return std.mem.eql(u8, node.local, expected);
    return true;
}
