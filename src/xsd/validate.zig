//! XML Schema instance validation.

const std = @import("std");
const dom = @import("../dom.zig");
const namespace = @import("../namespace.zig");
const datatypes = @import("datatypes.zig");
const schema = @import("schema.zig");
const xpath_value = @import("../xpath/value.zig");
const xpath_eval = @import("../xpath/eval.zig");

pub const Error = error{ OutOfMemory, InvalidSchema };

pub const ValidationError = struct {
    path: []const u8,
    message: []const u8,
};

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    errors: []const ValidationError,

    pub fn isValid(self: *const Result) bool {
        return self.errors.len == 0;
    }

    pub fn deinit(self: *Result) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Validate a document against a compiled schema. All errors are collected in
/// the result; validation does not stop at the first failure.
pub fn validate(
    compiled: *const schema.Schema,
    allocator: std.mem.Allocator,
    document: *const dom.Document,
) Error!Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var validator: Validator = .{
        .allocator = arena.allocator(),
        .schema = compiled,
        .document = document,
    };
    try validator.run();
    return .{
        .arena = arena,
        .errors = try validator.errors.toOwnedSlice(arena.allocator()),
    };
}

const ContentSummary = struct {
    has_elements: bool,
    has_text: bool,
};

const RecordedElement = struct {
    id: dom.NodeId,
    decl: *const schema.ElementDecl,
};

const IdentityTuple = struct {
    values: []const []const u8,
    node: dom.NodeId,
};

const IdentityScope = struct {
    constraint: *const schema.IdentityConstraint,
    element: dom.NodeId,
    tuples: std.ArrayList(IdentityTuple) = .empty,
};

const Assignment = struct {
    child: dom.NodeId,
    decl: ?*const schema.ElementDecl,
    wildcard: ?schema.Wildcard,
};

const Validator = struct {
    allocator: std.mem.Allocator,
    schema: *const schema.Schema,
    document: *const dom.Document,
    errors: std.ArrayList(ValidationError) = .empty,
    recorded: std.ArrayList(RecordedElement) = .empty,

    fn run(self: *Validator) Error!void {
        const root = self.document.root();
        if (root == dom.null_node) {
            try self.addError(self.document.documentNode(), "document has no root element");
            return;
        }
        const node = self.document.node(root);
        const decl = self.schema.findElement(node.ns, node.local) orelse {
            try self.addError(root, "no declaration for root element");
            return;
        };
        try self.validateElement(root, decl);
        try self.checkIdentityConstraints();
    }

    fn validateElement(
        self: *Validator,
        id: dom.NodeId,
        decl: *const schema.ElementDecl,
    ) Error!void {
        if (decl.abstract) {
            try self.addError(id, "abstract element must be substituted");
        }
        try self.recorded.append(self.allocator, .{ .id = id, .decl = decl });
        const effective = try self.effectiveType(id, decl);
        const nil = try self.nilValue(id);
        if (nil) {
            if (!decl.nillable) {
                try self.addError(id, "element is nil but not declared nillable");
            }
            const summary = self.contentSummary(id);
            if (summary.has_elements or summary.has_text) {
                try self.addError(id, "nil element must be empty");
            }
            switch (effective) {
                .complex => |complex| try self.validateAttributes(id, complex),
                .simple, .any_simple => try self.validateSimpleAttributes(id),
                .any_type => {},
            }
            return;
        }

        switch (effective) {
            .any_type => {},
            .any_simple => try self.validateSimpleElement(id, null, decl),
            .simple => |simple| try self.validateSimpleElement(id, simple, decl),
            .complex => |complex| try self.validateComplexElement(id, complex),
        }
    }

    fn validateSimpleElement(
        self: *Validator,
        id: dom.NodeId,
        simple: ?*const schema.SimpleInfo,
        decl: *const schema.ElementDecl,
    ) Error!void {
        try self.validateSimpleAttributes(id);
        const summary = self.contentSummary(id);
        if (summary.has_elements) {
            try self.addError(id, "element content is not allowed for a simple type");
        }
        const text = try self.textContent(id);
        if (simple) |info| {
            if (!try self.validateSimpleValue(info, text)) {
                try self.addError(id, "value does not satisfy the element type");
            }
            if (decl.fixed_value) |fixed| {
                if (!try self.valuesEqual(.{ .simple = info }, text, fixed)) {
                    try self.addError(id, "value does not match the fixed value");
                }
            }
        }
    }

    fn validateComplexElement(
        self: *Validator,
        id: dom.NodeId,
        complex: *const schema.ComplexInfo,
    ) Error!void {
        try self.validateAttributes(id, complex);
        if (complex.simple) |simple| {
            const summary = self.contentSummary(id);
            if (summary.has_elements) {
                try self.addError(id, "element content is not allowed for simple content");
            }
            const text = try self.textContent(id);
            if (!try self.validateSimpleValue(simple, text)) {
                try self.addError(id, "value does not satisfy the simple content type");
            }
            return;
        }
        try self.validateElementContent(id, complex);
    }

    fn validateElementContent(
        self: *Validator,
        id: dom.NodeId,
        complex: *const schema.ComplexInfo,
    ) Error!void {
        const node = self.document.node(id);
        var children: std.ArrayList(dom.NodeId) = .empty;
        var has_text = false;
        var child = node.first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const child_node = self.document.node(child);
            switch (child_node.kind) {
                .element => try children.append(self.allocator, child),
                .text => if (!isWhitespace(child_node.value)) {
                    has_text = true;
                },
                .comment, .processing_instruction => {},
                .document => unreachable,
            }
        }
        if (!complex.mixed and has_text) {
            try self.addError(id, "character data is not allowed in element content");
        }

        const particle = complex.particle orelse {
            if (children.items.len != 0) {
                try self.addError(children.items[0], "element is not allowed here");
            }
            return;
        };
        var matcher: Matcher = .{
            .validator = self,
            .children = children.items,
        };
        const end = matcher.match(particle) orelse {
            try self.addError(id, "element content does not match the declared model");
            return;
        };
        if (end != children.items.len) {
            try self.addError(children.items[end], "unexpected element");
            return;
        }
        for (matcher.assignments.items) |assignment| {
            if (assignment.decl) |decl| {
                try self.validateElement(assignment.child, decl);
            } else if (assignment.wildcard) |wildcard| {
                try self.validateWildcardElement(assignment.child, wildcard);
            }
        }
    }

    fn validateWildcardElement(
        self: *Validator,
        id: dom.NodeId,
        wildcard: schema.Wildcard,
    ) Error!void {
        if (wildcard.process == .skip) return;
        const node = self.document.node(id);
        const decl = self.schema.findElement(node.ns, node.local);
        if (decl) |found| {
            try self.validateElement(id, found);
        } else if (wildcard.process == .strict) {
            try self.addError(id, "no declaration for wildcard element");
        }
    }

    fn validateAttributes(
        self: *Validator,
        id: dom.NodeId,
        complex: *const schema.ComplexInfo,
    ) Error!void {
        const matched = try self.allocator.alloc(bool, complex.attributes.len);
        @memset(matched, false);

        for (self.document.attributesOf(id)) |attr| {
            if (namespace.Resolver.isNamespaceDeclaration(attr.name)) continue;
            if (attr.ns.len != 0 and
                std.mem.eql(u8, attr.ns, schema.xsi_namespace))
            {
                continue;
            }
            const local = attr.localName();
            var found = false;
            for (complex.attributes, 0..) |use, index| {
                if (!std.mem.eql(u8, use.decl.namespace_uri, attr.ns) or
                    !std.mem.eql(u8, use.decl.name, local))
                {
                    continue;
                }
                found = true;
                matched[index] = true;
                if (use.use == .prohibited) {
                    try self.addAttributeError(id, attr.name, "attribute is prohibited");
                    break;
                }
                try self.validateAttributeValue(id, attr, use.decl);
                break;
            }
            if (found) continue;
            if (complex.any_attribute) |wildcard| {
                if (wildcardAllows(wildcard, attr.ns)) {
                    if (wildcard.process != .skip) {
                        if (self.schema.findAttribute(attr.ns, local)) |decl| {
                            try self.validateAttributeValue(id, attr, decl);
                        } else if (wildcard.process == .strict) {
                            try self.addAttributeError(
                                id,
                                attr.name,
                                "no declaration for wildcard attribute",
                            );
                        }
                    }
                    continue;
                }
            }
            try self.addAttributeError(id, attr.name, "attribute is not allowed");
        }

        for (complex.attributes, 0..) |use, index| {
            if (use.use == .required and !matched[index]) {
                try self.addAttributeError(
                    id,
                    use.decl.name,
                    "required attribute is missing",
                );
            }
        }
    }

    fn validateAttributeValue(
        self: *Validator,
        id: dom.NodeId,
        attr: dom.Attribute,
        decl: *const schema.AttributeDecl,
    ) Error!void {
        switch (decl.type_info) {
            .simple => |simple| {
                if (!try self.validateSimpleValue(simple, attr.value)) {
                    try self.addAttributeError(
                        id,
                        attr.name,
                        "attribute value does not satisfy its type",
                    );
                }
            },
            .any_simple, .any_type => {},
            else => try self.addAttributeError(
                id,
                attr.name,
                "attribute type must be simple",
            ),
        }
        if (decl.fixed_value) |fixed| {
            if (!try self.valuesEqual(decl.type_info, attr.value, fixed)) {
                try self.addAttributeError(
                    id,
                    attr.name,
                    "attribute value does not match the fixed value",
                );
            }
        }
    }

    fn validateSimpleAttributes(self: *Validator, id: dom.NodeId) Error!void {
        for (self.document.attributesOf(id)) |attr| {
            if (namespace.Resolver.isNamespaceDeclaration(attr.name)) continue;
            if (attr.ns.len != 0 and
                std.mem.eql(u8, attr.ns, schema.xsi_namespace))
            {
                continue;
            }
            try self.addAttributeError(id, attr.name, "attribute is not allowed");
        }
    }

    fn effectiveType(
        self: *Validator,
        id: dom.NodeId,
        decl: *const schema.ElementDecl,
    ) Error!schema.TypeInfo {
        const declared = decl.type_info;
        const raw = self.document.attributeNs(
            id,
            schema.xsi_namespace,
            "type",
        ) orelse {
            if (schema.typeAbstract(declared)) {
                try self.addError(id, "element uses an abstract type");
            }
            return declared;
        };
        const qname = (try self.resolveInstanceQName(id, raw)) orelse {
            try self.addError(id, "xsi:type is not a valid QName");
            return declared;
        };
        var named: schema.TypeInfo = undefined;
        if (std.mem.eql(u8, qname.namespace_uri, schema.xsd_namespace)) {
            if (std.mem.eql(u8, qname.local, "anyType")) {
                named = .any_type;
            } else if (std.mem.eql(u8, qname.local, "anySimpleType")) {
                named = .any_simple;
            } else if (datatypes.builtin(qname.local)) |builtin| {
                const info = try self.allocator.create(schema.SimpleInfo);
                info.* = .{ .kind = builtin.kind };
                named = .{ .simple = info };
            } else {
                try self.addError(id, "unknown built-in type in xsi:type");
                return declared;
            }
        } else {
            const type_decl = self.schema.findType(
                qname.namespace_uri,
                qname.local,
            ) orelse {
                try self.addError(id, "xsi:type does not name a declared type");
                return declared;
            };
            named = type_decl.info orelse {
                try self.addError(id, "xsi:type names an unresolved type");
                return declared;
            };
        }
        if (schema.typeAbstract(named)) {
            try self.addError(id, "xsi:type names an abstract type");
            return declared;
        }
        if (!schema.isDerivedFrom(named, declared)) {
            try self.addError(
                id,
                "xsi:type is not derived from the declared type",
            );
            return declared;
        }
        const methods = schema.derivationMethods(named, declared);
        const blocked = decl.block.merge(schema.typeBlock(declared));
        if (methods.extension and blocked.extension or
            methods.restriction and blocked.restriction)
        {
            try self.addError(id, "xsi:type uses a blocked derivation");
            return declared;
        }
        return named;
    }

    fn resolveInstanceQName(
        self: *Validator,
        id: dom.NodeId,
        raw: []const u8,
    ) Error!?schema.QName {
        const bindings = try self.document.inScopeNamespaces(self.allocator, id);
        if (std.mem.indexOfScalar(u8, raw, ':')) |colon| {
            const prefix = raw[0..colon];
            const local = raw[colon + 1 ..];
            if (prefix.len == 0 or local.len == 0) return null;
            for (bindings) |binding| {
                if (std.mem.eql(u8, binding.prefix, prefix)) {
                    return .{ .namespace_uri = binding.uri, .local = local };
                }
            }
            return null;
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

    fn checkIdentityConstraints(self: *Validator) Error!void {
        var scopes: std.ArrayList(IdentityScope) = .empty;
        for (self.recorded.items) |record| {
            for (record.decl.identity) |constraint| {
                const scope = try self.identityScope(
                    &scopes,
                    constraint,
                    record.id,
                );
                const selected = try self.evalIdentityNodes(
                    constraint.selector,
                    .{ .node = record.id },
                );
                for (selected) |selected_node| {
                    const selected_id = identityNodeId(selected_node);
                    var values: std.ArrayList([]const u8) = .empty;
                    var missing = false;
                    for (constraint.fields) |field| {
                        const field_nodes = try self.evalIdentityNodes(
                            field,
                            selected_node,
                        );
                        if (field_nodes.len == 0) {
                            missing = true;
                            break;
                        }
                        if (field_nodes.len > 1) {
                            try self.addError(
                                selected_id,
                                "identity field selects more than one node",
                            );
                            missing = true;
                            break;
                        }
                        try values.append(
                            self.allocator,
                            try self.identityString(field_nodes[0]),
                        );
                    }
                    if (missing) {
                        if (constraint.kind != .unique) {
                            try self.addError(
                                selected_id,
                                "identity field is missing",
                            );
                        }
                        continue;
                    }
                    try scope.tuples.append(self.allocator, .{
                        .values = try values.toOwnedSlice(self.allocator),
                        .node = selected_id,
                    });
                }
            }
        }

        for (scopes.items) |scope| {
            if (scope.constraint.kind == .keyref) continue;
            for (scope.tuples.items, 0..) |tuple, index| {
                for (scope.tuples.items[index + 1 ..]) |other| {
                    if (identityTuplesEqual(tuple, other)) {
                        try self.addError(
                            tuple.node,
                            "duplicate identity value",
                        );
                        break;
                    }
                }
            }
        }

        for (scopes.items) |scope| {
            if (scope.constraint.kind != .keyref) continue;
            const referenced = scope.constraint.referenced orelse continue;
            for (scope.tuples.items) |tuple| {
                var found = false;
                for (scopes.items) |candidate| {
                    if (candidate.constraint != referenced) continue;
                    for (candidate.tuples.items) |other| {
                        if (identityTuplesEqual(tuple, other)) {
                            found = true;
                            break;
                        }
                    }
                    if (found) break;
                }
                if (!found) {
                    try self.addError(
                        tuple.node,
                        "keyref value does not match a key",
                    );
                }
            }
        }
    }

    fn identityScope(
        self: *Validator,
        scopes: *std.ArrayList(IdentityScope),
        constraint: *const schema.IdentityConstraint,
        element: dom.NodeId,
    ) Error!*IdentityScope {
        for (scopes.items) |*scope| {
            if (scope.constraint == constraint and scope.element == element) {
                return scope;
            }
        }
        try scopes.append(self.allocator, .{
            .constraint = constraint,
            .element = element,
        });
        return &scopes.items[scopes.items.len - 1];
    }

    fn evalIdentityNodes(
        self: *Validator,
        compiled: schema.CompiledXPath,
        node: xpath_value.NodeRef,
    ) Error![]const xpath_value.NodeRef {
        var context: xpath_value.Context = .{
            .document = self.document,
            .node = node,
            .namespaces = compiled.namespaces,
        };
        var result = xpath_eval.evaluate(
            self.allocator,
            compiled.expr,
            &context,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidSchema,
        };
        defer result.deinit();
        return switch (result.value) {
            .node_set => |nodes| try self.allocator.dupe(
                xpath_value.NodeRef,
                nodes,
            ),
            else => error.InvalidSchema,
        };
    }

    fn identityString(
        self: *Validator,
        node: xpath_value.NodeRef,
    ) Error![]const u8 {
        switch (node) {
            .attribute => |attr| return self.document
                .attributesOf(attr.element)[attr.index].value,
            .namespace_node => |ns| return ns.uri,
            .node => |id| {
                const node_value = self.document.node(id);
                switch (node_value.kind) {
                    .text, .comment, .processing_instruction => {
                        return node_value.value;
                    },
                    .element, .document => {
                        var out: std.ArrayList(u8) = .empty;
                        try self.appendIdentityText(id, &out);
                        return out.toOwnedSlice(self.allocator);
                    },
                }
            },
        }
    }

    fn appendIdentityText(
        self: *Validator,
        id: dom.NodeId,
        out: *std.ArrayList(u8),
    ) Error!void {
        const node = self.document.node(id);
        if (node.kind == .text) {
            try out.appendSlice(self.allocator, node.value);
            return;
        }
        var child = node.first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            try self.appendIdentityText(child, out);
        }
    }

    fn nilValue(self: *Validator, id: dom.NodeId) Error!bool {
        const value = self.document.attributeNs(
            id,
            schema.xsi_namespace,
            "nil",
        ) orelse return false;
        if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1")) {
            return true;
        }
        if (std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "0")) {
            return false;
        }
        try self.addError(id, "invalid xsi:nil value");
        return false;
    }

    fn contentSummary(self: *Validator, id: dom.NodeId) ContentSummary {
        var summary: ContentSummary = .{
            .has_elements = false,
            .has_text = false,
        };
        var child = self.document.node(id).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const child_node = self.document.node(child);
            if (child_node.kind == .element) {
                summary.has_elements = true;
            } else if (child_node.kind == .text and
                !isWhitespace(child_node.value))
            {
                summary.has_text = true;
            }
        }
        return summary;
    }

    fn textContent(self: *Validator, id: dom.NodeId) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var child = self.document.node(id).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const child_node = self.document.node(child);
            if (child_node.kind == .text) {
                try out.appendSlice(self.allocator, child_node.value);
            }
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn validateSimpleValue(
        self: *Validator,
        info: *const schema.SimpleInfo,
        value: []const u8,
    ) Error!bool {
        switch (info.variety) {
            .atomic => return datatypes.validate(
                self.allocator,
                info.kind,
                info.facets,
                value,
            ) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => false,
            },
            .list => {
                const normalized = try datatypes.normalize(
                    self.allocator,
                    .collapse,
                    value,
                );
                var tokens = std.mem.tokenizeAny(u8, normalized, " \t\r\n");
                var count: usize = 0;
                while (tokens.next()) |token| {
                    if (!try self.validateSimpleValue(info.item.?, token)) {
                        return false;
                    }
                    count += 1;
                }
                if (info.facets.length) |expected| {
                    if (count != expected) return false;
                }
                if (info.facets.min_length) |minimum| {
                    if (count < minimum) return false;
                }
                if (info.facets.max_length) |maximum| {
                    if (count > maximum) return false;
                }
                if (!try self.checkStringFacets(info.facets, normalized)) {
                    return false;
                }
                return true;
            },
            .union_ => {
                for (info.members) |member| {
                    if (try self.validateSimpleValue(member, value)) {
                        return self.checkStringFacets(info.facets, value);
                    }
                }
                return false;
            },
        }
    }

    fn checkStringFacets(
        self: *Validator,
        facets: datatypes.Facets,
        value: []const u8,
    ) Error!bool {
        if (facets.patterns.len != 0) {
            var matched = false;
            for (facets.patterns) |pattern| {
                const pattern_matches = pattern.matches(
                    self.allocator,
                    value,
                ) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => false,
                };
                if (pattern_matches) {
                    matched = true;
                    break;
                }
            }
            if (!matched) return false;
        }
        if (facets.enumeration.len != 0) {
            var found = false;
            for (facets.enumeration) |candidate| {
                if (std.mem.eql(u8, candidate, value)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
        return true;
    }

    fn valuesEqual(
        self: *Validator,
        info: schema.TypeInfo,
        actual: []const u8,
        expected: []const u8,
    ) Error!bool {
        switch (info) {
            .simple => |simple| {
                if (simple.variety != .atomic) {
                    return std.mem.eql(u8, actual, expected);
                }
                const whitespace = simple.facets.white_space orelse
                    datatypes.builtinWhitespace(simple.kind);
                const a = try datatypes.normalize(
                    self.allocator,
                    whitespace,
                    actual,
                );
                const b = try datatypes.normalize(
                    self.allocator,
                    whitespace,
                    expected,
                );
                if (datatypes.compareValues(simple.kind, a, b)) |order| {
                    return order == .eq;
                }
                return std.mem.eql(u8, a, b);
            },
            else => return std.mem.eql(u8, actual, expected),
        }
    }

    fn addError(
        self: *Validator,
        id: dom.NodeId,
        message: []const u8,
    ) Error!void {
        const path = try self.nodePath(id);
        try self.errors.append(self.allocator, .{
            .path = path,
            .message = message,
        });
    }

    fn addAttributeError(
        self: *Validator,
        id: dom.NodeId,
        name: []const u8,
        message: []const u8,
    ) Error!void {
        const base = try self.nodePath(id);
        const path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/@{s}",
            .{ base, name },
        );
        try self.errors.append(self.allocator, .{
            .path = path,
            .message = message,
        });
    }

    fn nodePath(self: *Validator, id: dom.NodeId) Error![]const u8 {
        var parts: std.ArrayList([]const u8) = .empty;
        var current = id;
        while (current != dom.null_node) {
            const node = self.document.node(current);
            if (node.kind == .element) {
                var index: usize = 1;
                var sibling = self.document.node(node.parent).first_child;
                while (sibling != dom.null_node and sibling != current) : (sibling = self.document.node(sibling).next_sibling) {
                    const sibling_node = self.document.node(sibling);
                    if (sibling_node.kind == .element and
                        std.mem.eql(u8, sibling_node.name, node.name))
                    {
                        index += 1;
                    }
                }
                const part = try std.fmt.allocPrint(
                    self.allocator,
                    "/{s}[{d}]",
                    .{ node.name, index },
                );
                try parts.append(self.allocator, part);
            }
            current = node.parent;
        }
        var out: std.ArrayList(u8) = .empty;
        var index = parts.items.len;
        while (index > 0) {
            index -= 1;
            try out.appendSlice(self.allocator, parts.items[index]);
        }
        if (out.items.len == 0) return "/";
        return out.toOwnedSlice(self.allocator);
    }
};

const Matcher = struct {
    validator: *Validator,
    children: []const dom.NodeId,
    assignments: std.ArrayList(Assignment) = .empty,
    depth: usize = 0,

    fn match(self: *Matcher, particle: *const schema.Particle) ?usize {
        const occurs = particleOccurs(particle);
        return self.matchWithOccurrences(
            particle,
            0,
            occurs.min,
            occurs.max,
        );
    }

    fn matchWithOccurrences(
        self: *Matcher,
        particle: *const schema.Particle,
        index: usize,
        minimum: usize,
        maximum: ?usize,
    ) ?usize {
        if (maximum) |max| {
            if (max == 0) return if (minimum == 0) index else null;
        }
        const saved = self.assignments.items.len;
        if (self.matchOnce(particle, index)) |next| {
            if (next == index) return index;
            const next_min = if (minimum > 0) minimum - 1 else 0;
            const next_max: ?usize = if (maximum) |max|
                (if (max > 0) max - 1 else 0)
            else
                null;
            if (self.matchWithOccurrences(
                particle,
                next,
                next_min,
                next_max,
            )) |end| {
                return end;
            }
            self.assignments.shrinkRetainingCapacity(saved);
        }
        if (minimum == 0) return index;
        return null;
    }

    fn matchOnce(
        self: *Matcher,
        particle: *const schema.Particle,
        index: usize,
    ) ?usize {
        switch (particle.*) {
            .element => |element| {
                if (index >= self.children.len) return null;
                const child_id = self.children[index];
                const child = self.validator.document.node(child_id);
                var actual = element.decl;
                const direct_match =
                    std.mem.eql(u8, child.local, element.decl.name) and
                    std.mem.eql(u8, child.ns, element.decl.namespace_uri);
                if (!direct_match) {
                    if (!element.decl.global) return null;
                    const blocked = element.decl.block.merge(
                        schema.typeBlock(element.decl.type_info),
                    );
                    if (blocked.substitution) return null;
                    const candidate = self.validator.schema.findElement(
                        child.ns,
                        child.local,
                    ) orelse return null;
                    if (!self.validator.schema.isSubstitutionMember(
                        candidate,
                        element.decl,
                    )) {
                        return null;
                    }
                    if (!schema.isDerivedFrom(
                        candidate.type_info,
                        element.decl.type_info,
                    )) {
                        return null;
                    }
                    const methods = schema.derivationMethods(
                        candidate.type_info,
                        element.decl.type_info,
                    );
                    if (methods.extension and
                        (blocked.extension or element.decl.final.extension) or
                        methods.restriction and
                            (blocked.restriction or element.decl.final.restriction))
                    {
                        return null;
                    }
                    actual = candidate;
                }
                self.assignments.append(self.validator.allocator, .{
                    .child = child_id,
                    .decl = actual,
                    .wildcard = null,
                }) catch return null;
                return index + 1;
            },
            .any => |any| {
                if (index >= self.children.len) return null;
                const child_id = self.children[index];
                const child = self.validator.document.node(child_id);
                if (!wildcardAllows(any.wildcard, child.ns)) {
                    return null;
                }
                self.assignments.append(self.validator.allocator, .{
                    .child = child_id,
                    .decl = null,
                    .wildcard = any.wildcard,
                }) catch return null;
                return index + 1;
            },
            .sequence => |sequence| {
                var position = index;
                for (sequence.items) |item| {
                    const occurs = particleOccurs(item);
                    position = self.matchWithOccurrences(
                        item,
                        position,
                        occurs.min,
                        occurs.max,
                    ) orelse return null;
                }
                return position;
            },
            .choice => |choice| {
                var empty_match: ?usize = null;
                for (choice.items) |item| {
                    const saved = self.assignments.items.len;
                    const occurs = particleOccurs(item);
                    if (self.matchWithOccurrences(
                        item,
                        index,
                        occurs.min,
                        occurs.max,
                    )) |end| {
                        if (end > index) return end;
                        empty_match = end;
                    }
                    self.assignments.shrinkRetainingCapacity(saved);
                }
                return empty_match;
            },
            .all => |all| {
                const flags = self.validator.allocator.alloc(
                    bool,
                    all.items.len,
                ) catch return null;
                @memset(flags, false);
                return self.matchAll(all.items, index, flags);
            },
            .group => |group| {
                if (self.depth >= 256) return null;
                const group_particle = group.decl.particle orelse return null;
                self.depth += 1;
                defer self.depth -= 1;
                const occurs = particleOccurs(group_particle);
                return self.matchWithOccurrences(
                    group_particle,
                    index,
                    occurs.min,
                    occurs.max,
                );
            },
        }
    }

    fn matchAll(
        self: *Matcher,
        items: []const *const schema.Particle,
        index: usize,
        flags: []bool,
    ) ?usize {
        if (index >= self.children.len) {
            for (items, 0..) |item, item_index| {
                if (flags[item_index]) continue;
                const occurs = particleOccurs(item);
                if (occurs.min > 0) return null;
            }
            return index;
        }
        for (items, 0..) |item, item_index| {
            if (flags[item_index]) continue;
            const saved = self.assignments.items.len;
            if (self.matchOnce(item, index)) |next| {
                flags[item_index] = true;
                if (self.matchAll(items, next, flags)) |end| return end;
                flags[item_index] = false;
                self.assignments.shrinkRetainingCapacity(saved);
            }
        }
        return null;
    }
};

fn identityNodeId(node: xpath_value.NodeRef) dom.NodeId {
    return switch (node) {
        .node => |id| id,
        .attribute => |attr| attr.element,
        .namespace_node => |ns| ns.element,
    };
}

fn identityTuplesEqual(a: IdentityTuple, b: IdentityTuple) bool {
    if (a.values.len != b.values.len) return false;
    for (a.values, b.values) |left, right| {
        if (!std.mem.eql(u8, left, right)) return false;
    }
    return true;
}

fn particleOccurs(particle: *const schema.Particle) struct {
    min: usize,
    max: ?usize,
} {
    return switch (particle.*) {
        .element => |element| .{ .min = element.min, .max = element.max },
        .sequence => |sequence| .{ .min = sequence.min, .max = sequence.max },
        .choice => |choice| .{ .min = choice.min, .max = choice.max },
        .all => |all| .{ .min = all.min, .max = all.max },
        .any => |any| .{ .min = any.min, .max = any.max },
        .group => |group| .{ .min = group.min, .max = group.max },
    };
}

fn wildcardAllows(
    wildcard: schema.Wildcard,
    namespace_uri: []const u8,
) bool {
    if (wildcard.namespaces.len != 0) {
        for (wildcard.namespaces) |uri| {
            if (std.mem.eql(u8, uri, namespace_uri)) return true;
        }
        return false;
    }
    return switch (wildcard.namespace_rule) {
        .any => true,
        .other => namespace_uri.len != 0 and
            !std.mem.eql(u8, namespace_uri, wildcard.target_namespace),
        .target_namespace => std.mem.eql(
            u8,
            namespace_uri,
            wildcard.target_namespace,
        ),
        .local => namespace_uri.len == 0,
    };
}

fn isWhitespace(value: []const u8) bool {
    for (value) |byte| {
        if (byte != ' ' and byte != '\t' and byte != '\r' and byte != '\n') {
            return false;
        }
    }
    return true;
}
