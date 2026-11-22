//! Optional DTD validity checking over a parsed `dom.Document`.
//!
//! Well-formedness is enforced by the parser. This module adds the DTD
//! validity constraints: element content models, attribute types and
//! defaults, required/fixed attributes, ID uniqueness, IDREF resolution,
//! entity/notation references, and the root element type.

const std = @import("std");
const dom = @import("dom.zig");
const parser_mod = @import("parser.zig");
const chars = @import("chars.zig");
const entities = @import("entities.zig");

pub const IssueKind = enum {
    root_element_mismatch,
    undeclared_element,
    invalid_content,
    undeclared_attribute,
    missing_required_attribute,
    invalid_attribute_value,
    duplicate_id,
    unresolved_idref,
    undeclared_entity,
    undeclared_notation,
    fixed_attribute_mismatch,
    invalid_attribute_default,
    duplicate_element_declaration,
    duplicate_attribute_declaration,
    duplicate_notation_declaration,
    duplicate_enumeration_name,
    duplicate_mixed_content_name,
    multiple_id_attributes,
    standalone_external_declaration,
    standalone_external_default,
    standalone_external_element_content,
    pe_nesting,
};

pub const Issue = struct {
    kind: IssueKind,
    node: dom.NodeId = dom.null_node,
    attribute: []const u8 = "",
    name: []const u8 = "",
};

pub const Options = struct {
    /// Reject any character data, including whitespace, in element-only
    /// content. XML's Element Valid constraint is strict here; libxml2 and
    /// many parsers are lenient about indentation.
    strict_element_content: bool = false,
};

pub fn validate(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
    dtd: parser_mod.Dtd,
) ![]Issue {
    return validateWithOptions(allocator, document, dtd, .{});
}

pub fn validateWithOptions(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
    dtd: parser_mod.Dtd,
    options: Options,
) ![]Issue {
    if (dtd.doctype_name.len == 0 and
        dtd.elements.len == 0 and
        dtd.attributes.len == 0)
    {
        return &.{};
    }

    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const temp = scratch.allocator();

    var issues: std.ArrayList(Issue) = .empty;
    errdefer issues.deinit(allocator);

    const root = document.root();
    if (root == dom.null_node) return issues.toOwnedSlice(allocator);
    if (dtd.doctype_name.len != 0 and
        !std.mem.eql(u8, document.node(root).name, dtd.doctype_name))
    {
        try issues.append(allocator, .{
            .kind = .root_element_mismatch,
            .node = root,
            .name = document.node(root).name,
        });
    }

    var ids = std.StringHashMap(void).init(temp);
    var idrefs: std.ArrayList([]const u8) = .empty;

    for (document.nodes, 0..) |node, index| {
        if (node.kind != .element) continue;
        const id: dom.NodeId = @intCast(index);
        const decl = findElementDecl(dtd, node.name) orelse {
            try issues.append(allocator, .{
                .kind = .undeclared_element,
                .node = id,
                .name = node.name,
            });
            continue;
        };
        try validateContent(
            temp,
            document,
            id,
            decl.model,
            options,
            &issues,
            allocator,
        );
        try validateAttributes(
            temp,
            document,
            dtd,
            id,
            &ids,
            &idrefs,
            &issues,
            allocator,
        );
    }

    try validateDeclarations(
        temp,
        document,
        dtd,
        &idrefs,
        &issues,
        allocator,
    );
    try validateStandaloneElements(document, dtd, &issues, allocator);
    for (dtd.pe_issues) |_| {
        try issues.append(allocator, .{ .kind = .pe_nesting });
    }
    var seen_undeclared = std.StringHashMap(void).init(temp);
    for (dtd.undeclared_refs) |name| {
        if (seen_undeclared.contains(name)) continue;
        try seen_undeclared.put(name, {});
        try issues.append(allocator, .{
            .kind = .undeclared_entity,
            .name = name,
        });
    }

    for (idrefs.items) |ref| {
        if (!ids.contains(ref)) {
            try issues.append(allocator, .{
                .kind = .unresolved_idref,
                .name = ref,
            });
        }
    }

    for (dtd.entities.entries[0..dtd.entities.count]) |entity| {
        if (entity.unparsed and entity.notation.len != 0 and
            !notationDeclared(dtd, entity.notation))
        {
            try issues.append(allocator, .{
                .kind = .undeclared_notation,
                .name = entity.notation,
            });
        }
    }

    return issues.toOwnedSlice(allocator);
}

fn findElementDecl(dtd: parser_mod.Dtd, name: []const u8) ?*const parser_mod.ElementDecl {
    for (dtd.elements) |*decl| {
        if (std.mem.eql(u8, decl.name, name)) return decl;
    }
    return null;
}

fn findAttributeDecl(
    dtd: parser_mod.Dtd,
    element: []const u8,
    name: []const u8,
) ?*const parser_mod.AttributeDecl {
    for (dtd.attributes) |*decl| {
        if (std.mem.eql(u8, decl.element, element) and
            std.mem.eql(u8, decl.name, name))
        {
            return decl;
        }
    }
    return null;
}

fn notationDeclared(dtd: parser_mod.Dtd, name: []const u8) bool {
    for (dtd.notations) |decl| {
        if (std.mem.eql(u8, decl.name, name)) return true;
    }
    return false;
}

fn validateContent(
    temp: std.mem.Allocator,
    document: *const dom.Document,
    id: dom.NodeId,
    model: parser_mod.ContentModel,
    options: Options,
    issues: *std.ArrayList(Issue),
    issue_allocator: std.mem.Allocator,
) !void {
    var child_names: std.ArrayList([]const u8) = .empty;
    var has_any_text = false;
    var has_non_whitespace_text = false;
    var has_markup_child = false;

    var child = document.node(id).first_child;
    while (child != dom.null_node) : (child = document.node(child).next_sibling) {
        const node = document.node(child);
        switch (node.kind) {
            .element => try child_names.append(temp, node.name),
            .text => {
                has_any_text = true;
                if (!isWhitespaceOnly(node.value)) {
                    has_non_whitespace_text = true;
                }
            },
            else => has_markup_child = true,
        }
    }

    switch (model) {
        .empty => {
            if (has_any_text or has_markup_child or child_names.items.len != 0) {
                try issues.append(issue_allocator, .{
                    .kind = .invalid_content,
                    .node = id,
                });
            }
        },
        .any => {},
        .mixed => |allowed| {
            for (child_names.items) |name| {
                if (!containsName(allowed, name)) {
                    try issues.append(issue_allocator, .{
                        .kind = .invalid_content,
                        .node = id,
                        .name = name,
                    });
                }
            }
        },
        .children => |content| {
            const node = document.node(id);
            if (has_non_whitespace_text or
                (options.strict_element_content and has_any_text) or
                node.has_whitespace_char_ref_text or
                node.has_nel_ls_text or
                node.has_cdata_text or
                !try matchesContent(temp, content, child_names.items))
            {
                try issues.append(issue_allocator, .{
                    .kind = .invalid_content,
                    .node = id,
                });
            }
        },
    }
}

fn containsName(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

fn matchesContent(
    temp: std.mem.Allocator,
    model: *const parser_mod.ContentNode,
    names: []const []const u8,
) !bool {
    const positions = try matchNode(temp, model, names, &.{0});
    for (positions) |position| {
        if (position == names.len) return true;
    }
    return false;
}

fn matchNode(
    temp: std.mem.Allocator,
    node: *const parser_mod.ContentNode,
    names: []const []const u8,
    positions: []const usize,
) ![]const usize {
    switch (node.*) {
        .name => |name| {
            var out: std.ArrayList(usize) = .empty;
            for (positions) |position| {
                if (position < names.len and
                    std.mem.eql(u8, names[position], name))
                {
                    try out.append(temp, position + 1);
                }
            }
            return dedupPositions(temp, names.len, out.items);
        },
        .sequence => |children| {
            var current = positions;
            for (children) |child| {
                current = try matchNode(temp, child, names, current);
                if (current.len == 0) break;
            }
            return current;
        },
        .choice => |children| {
            var out: std.ArrayList(usize) = .empty;
            for (children) |child| {
                const matched = try matchNode(temp, child, names, positions);
                try out.appendSlice(temp, matched);
            }
            return dedupPositions(temp, names.len, out.items);
        },
        .quantifier => |quantifier| {
            var out: std.ArrayList(usize) = .empty;
            var frontier = positions;
            if (quantifier.min == 0) try out.appendSlice(temp, frontier);
            var count: usize = 0;
            while (count <= names.len) : (count += 1) {
                const next = try matchNode(temp, quantifier.node, names, frontier);
                if (next.len == 0) break;
                if (count + 1 >= quantifier.min) {
                    try out.appendSlice(temp, next);
                }
                frontier = next;
                if (quantifier.max) |max| {
                    if (count + 1 >= max) break;
                }
            }
            return dedupPositions(temp, names.len, out.items);
        },
    }
}

fn dedupPositions(
    temp: std.mem.Allocator,
    names_len: usize,
    items: []const usize,
) ![]const usize {
    const seen = try temp.alloc(bool, names_len + 1);
    @memset(seen, false);
    var out: std.ArrayList(usize) = .empty;
    for (items) |position| {
        if (position <= names_len and !seen[position]) {
            seen[position] = true;
            try out.append(temp, position);
        }
    }
    return out.toOwnedSlice(temp);
}

fn validateAttributes(
    temp: std.mem.Allocator,
    document: *const dom.Document,
    dtd: parser_mod.Dtd,
    id: dom.NodeId,
    ids: *std.StringHashMap(void),
    idrefs: *std.ArrayList([]const u8),
    issues: *std.ArrayList(Issue),
    issue_allocator: std.mem.Allocator,
) !void {
    const element = document.node(id);
    const attributes = document.attributesOf(id);

    for (dtd.attributes) |*decl| {
        if (!std.mem.eql(u8, decl.element, element.name)) continue;
        const attribute = findAttribute(attributes, decl.name) orelse {
            if (decl.default_kind == .required) {
                try issues.append(issue_allocator, .{
                    .kind = .missing_required_attribute,
                    .node = id,
                    .attribute = decl.name,
                });
            }
            continue;
        };
        try validateAttributeValue(
            temp,
            dtd,
            id,
            decl,
            attribute,
            ids,
            idrefs,
            issues,
            issue_allocator,
        );
    }

    for (attributes) |attribute| {
        if (findAttributeDecl(dtd, element.name, attribute.name) == null) {
            try issues.append(issue_allocator, .{
                .kind = .undeclared_attribute,
                .node = id,
                .attribute = attribute.name,
            });
        }
    }

    if (dtd.standalone == true) {
        for (dtd.attributes) |*decl| {
            if (!std.mem.eql(u8, decl.element, element.name) or
                !decl.from_external)
            {
                continue;
            }
            const present = findAttribute(attributes, decl.name);
            if (present) |attribute| {
                if (decl.attr_type != .cdata and
                    attribute.normalization_changed)
                {
                    try issues.append(issue_allocator, .{
                        .kind = .standalone_external_declaration,
                        .node = id,
                        .attribute = decl.name,
                    });
                }
            }
            if (present == null and
                (decl.default_kind == .value or decl.default_kind == .fixed))
            {
                try issues.append(issue_allocator, .{
                    .kind = .standalone_external_default,
                    .node = id,
                    .attribute = decl.name,
                });
            }
        }
    }
}

fn isIdName(dtd: parser_mod.Dtd, value: []const u8) bool {
    return if (dtd.namespaces) chars.isNCName(value) else chars.isName(value);
}

fn validateDeclarations(
    temp: std.mem.Allocator,
    document: *const dom.Document,
    dtd: parser_mod.Dtd,
    idrefs: *std.ArrayList([]const u8),
    issues: *std.ArrayList(Issue),
    issue_allocator: std.mem.Allocator,
) !void {
    for (dtd.duplicate_elements) |name| {
        try issues.append(issue_allocator, .{
            .kind = .duplicate_element_declaration,
            .name = name,
        });
    }
    for (dtd.duplicate_notations) |name| {
        try issues.append(issue_allocator, .{
            .kind = .duplicate_notation_declaration,
            .name = name,
        });
    }

    for (dtd.elements) |element_decl| {
        var id_count: usize = 0;
        for (dtd.attributes) |decl| {
            if (std.mem.eql(u8, decl.element, element_decl.name) and
                decl.attr_type == .id)
            {
                id_count += 1;
            }
        }
        if (id_count > 1) {
            try issues.append(issue_allocator, .{
                .kind = .multiple_id_attributes,
                .name = element_decl.name,
            });
        }
        if (element_decl.model == .mixed) {
            const names = element_decl.model.mixed;
            if (hasDuplicateNames(names)) {
                try issues.append(issue_allocator, .{
                    .kind = .duplicate_mixed_content_name,
                    .name = element_decl.name,
                });
            }
        }
    }

    for (dtd.attributes) |*decl| {
        if (decl.attr_type == .id and
            decl.default_kind != .implied and
            decl.default_kind != .required)
        {
            try issues.append(issue_allocator, .{
                .kind = .invalid_attribute_default,
                .attribute = decl.name,
            });
        }
        switch (decl.attr_type) {
            .notation => |names| {
                if (hasDuplicateNames(names)) {
                    try issues.append(issue_allocator, .{
                        .kind = .duplicate_enumeration_name,
                        .attribute = decl.name,
                    });
                }
                for (names) |name| {
                    if (!notationDeclared(dtd, name)) {
                        try issues.append(issue_allocator, .{
                            .kind = .undeclared_notation,
                            .attribute = decl.name,
                            .name = name,
                        });
                    }
                }
            },
            .enumeration => |names| {
                if (hasDuplicateNames(names)) {
                    try issues.append(issue_allocator, .{
                        .kind = .duplicate_enumeration_name,
                        .attribute = decl.name,
                    });
                }
            },
            else => {},
        }
        if (decl.default_kind == .value or decl.default_kind == .fixed) {
            const value = try normalizeDefault(temp, dtd, decl);
            try validateDefaultLexical(
                dtd,
                decl,
                value,
                issues,
                issue_allocator,
            );
            if (defaultUsed(document, decl)) {
                try validateDefaultReferential(
                    temp,
                    dtd,
                    decl,
                    value,
                    idrefs,
                    issues,
                    issue_allocator,
                );
            }
        }
    }
}

fn hasDuplicateNames(names: []const []const u8) bool {
    for (names, 0..) |name, index| {
        for (names[0..index]) |previous| {
            if (std.mem.eql(u8, previous, name)) return true;
        }
    }
    return false;
}

fn validateStandaloneElements(
    document: *const dom.Document,
    dtd: parser_mod.Dtd,
    issues: *std.ArrayList(Issue),
    issue_allocator: std.mem.Allocator,
) !void {
    if (dtd.standalone != true) return;
    for (document.nodes, 0..) |node, index| {
        if (node.kind != .element) continue;
        var external_element_content = false;
        for (dtd.elements) |decl| {
            if (!decl.from_external or
                !std.mem.eql(u8, decl.name, node.name))
            {
                continue;
            }
            if (decl.model == .children) {
                external_element_content = true;
                break;
            }
        }
        if (!external_element_content) continue;
        const id: dom.NodeId = @intCast(index);
        var child = node.first_child;
        while (child != dom.null_node) : (child = document.node(child).next_sibling) {
            const child_node = document.node(child);
            if (child_node.kind == .text and isWhitespaceOnly(child_node.value)) {
                try issues.append(issue_allocator, .{
                    .kind = .standalone_external_element_content,
                    .node = id,
                    .name = node.name,
                });
                break;
            }
        }
    }
}

fn findAttribute(
    attributes: []const dom.Attribute,
    name: []const u8,
) ?dom.Attribute {
    for (attributes) |attribute| {
        if (std.mem.eql(u8, attribute.name, name)) return attribute;
    }
    return null;
}

fn defaultUsed(
    document: *const dom.Document,
    decl: *const parser_mod.AttributeDecl,
) bool {
    for (document.nodes, 0..) |node, index| {
        if (node.kind != .element or
            !std.mem.eql(u8, node.name, decl.element))
        {
            continue;
        }
        const id: dom.NodeId = @intCast(index);
        if (findAttribute(document.attributesOf(id), decl.name) == null) {
            return true;
        }
    }
    return false;
}

fn validateDefaultLexical(
    dtd: parser_mod.Dtd,
    decl: *const parser_mod.AttributeDecl,
    value: []const u8,
    issues: *std.ArrayList(Issue),
    issue_allocator: std.mem.Allocator,
) !void {
    switch (decl.attr_type) {
        .cdata, .id => {},
        .idref => {
            if (!isIdName(dtd, value)) {
                try addDefaultIssue(issues, issue_allocator, decl.name);
            }
        },
        .idrefs => {
            var tokens = std.mem.tokenizeAny(u8, value, " \t\r\n");
            var token_count: usize = 0;
            while (tokens.next()) |token| {
                token_count += 1;
                if (!isIdName(dtd, token)) {
                    try addDefaultIssue(issues, issue_allocator, decl.name);
                    break;
                }
            }
            if (token_count == 0) {
                try addDefaultIssue(issues, issue_allocator, decl.name);
            }
        },
        .entity => {
            if (!chars.isName(value)) {
                try addDefaultIssue(issues, issue_allocator, decl.name);
            }
        },
        .entities => {
            var tokens = std.mem.tokenizeAny(u8, value, " \t\r\n");
            var token_count: usize = 0;
            while (tokens.next()) |token| {
                token_count += 1;
                if (!chars.isName(token)) {
                    try addDefaultIssue(issues, issue_allocator, decl.name);
                    break;
                }
            }
            if (token_count == 0) {
                try addDefaultIssue(issues, issue_allocator, decl.name);
            }
        },
        .nmtoken => {
            if (!chars.isNmtoken(value)) {
                try addDefaultIssue(issues, issue_allocator, decl.name);
            }
        },
        .nmtokens => {
            var tokens = std.mem.tokenizeAny(u8, value, " \t\r\n");
            var token_count: usize = 0;
            while (tokens.next()) |token| {
                token_count += 1;
                if (!chars.isNmtoken(token)) {
                    try addDefaultIssue(issues, issue_allocator, decl.name);
                    break;
                }
            }
            if (token_count == 0) {
                try addDefaultIssue(issues, issue_allocator, decl.name);
            }
        },
        .notation => |allowed| {
            if (!containsName(allowed, value)) {
                try addDefaultIssue(issues, issue_allocator, decl.name);
            }
        },
        .enumeration => |allowed| {
            if (!containsName(allowed, value)) {
                try addDefaultIssue(issues, issue_allocator, decl.name);
            }
        },
    }
}

fn validateDefaultReferential(
    temp: std.mem.Allocator,
    dtd: parser_mod.Dtd,
    decl: *const parser_mod.AttributeDecl,
    value: []const u8,
    idrefs: *std.ArrayList([]const u8),
    issues: *std.ArrayList(Issue),
    issue_allocator: std.mem.Allocator,
) !void {
    switch (decl.attr_type) {
        .entity => {
            if (!isUnparsedEntity(dtd, value)) {
                try addDefaultIssue(issues, issue_allocator, decl.name);
            }
        },
        .entities => {
            var tokens = std.mem.tokenizeAny(u8, value, " \t\r\n");
            while (tokens.next()) |token| {
                if (!isUnparsedEntity(dtd, token)) {
                    try addDefaultIssue(issues, issue_allocator, decl.name);
                    break;
                }
            }
        },
        .notation => {
            if (!notationDeclared(dtd, value)) {
                try addDefaultIssue(issues, issue_allocator, decl.name);
            }
        },
        .idref => try idrefs.append(temp, value),
        .idrefs => {
            var tokens = std.mem.tokenizeAny(u8, value, " \t\r\n");
            while (tokens.next()) |token| {
                try idrefs.append(temp, token);
            }
        },
        else => {},
    }
}

fn addDefaultIssue(
    issues: *std.ArrayList(Issue),
    allocator: std.mem.Allocator,
    attribute: []const u8,
) !void {
    try issues.append(allocator, .{
        .kind = .invalid_attribute_default,
        .attribute = attribute,
    });
}

fn validateAttributeValue(
    temp: std.mem.Allocator,
    dtd: parser_mod.Dtd,
    id: dom.NodeId,
    decl: *const parser_mod.AttributeDecl,
    attribute: dom.Attribute,
    ids: *std.StringHashMap(void),
    idrefs: *std.ArrayList([]const u8),
    issues: *std.ArrayList(Issue),
    issue_allocator: std.mem.Allocator,
) !void {
    const value = attribute.value;
    switch (decl.attr_type) {
        .cdata => {},
        .id => {
            if (!isIdName(dtd, value)) {
                try invalidValue(issues, issue_allocator, id, decl.name);
            } else if (ids.contains(value)) {
                try issues.append(issue_allocator, .{
                    .kind = .duplicate_id,
                    .node = id,
                    .attribute = decl.name,
                    .name = value,
                });
            } else {
                try ids.put(value, {});
            }
        },
        .idref => {
            if (!isIdName(dtd, value)) {
                try invalidValue(issues, issue_allocator, id, decl.name);
            } else {
                try idrefs.append(temp, value);
            }
        },
        .idrefs => {
            var tokens = std.mem.tokenizeAny(u8, value, " \t\r\n");
            var token_count: usize = 0;
            while (tokens.next()) |token| {
                token_count += 1;
                if (!isIdName(dtd, token)) {
                    try invalidValue(issues, issue_allocator, id, decl.name);
                    break;
                }
                try idrefs.append(temp, token);
            }
            if (token_count == 0) {
                try invalidValue(issues, issue_allocator, id, decl.name);
            }
        },
        .entity => {
            if (!isUnparsedEntity(dtd, value)) {
                try issues.append(issue_allocator, .{
                    .kind = .undeclared_entity,
                    .node = id,
                    .attribute = decl.name,
                    .name = value,
                });
            }
        },
        .entities => {
            var tokens = std.mem.tokenizeAny(u8, value, " \t\r\n");
            var token_count: usize = 0;
            while (tokens.next()) |token| {
                token_count += 1;
                if (!isUnparsedEntity(dtd, token)) {
                    try issues.append(issue_allocator, .{
                        .kind = .undeclared_entity,
                        .node = id,
                        .attribute = decl.name,
                        .name = token,
                    });
                }
            }
            if (token_count == 0) {
                try invalidValue(issues, issue_allocator, id, decl.name);
            }
        },
        .nmtoken => {
            if (!chars.isNmtoken(value)) {
                try invalidValue(issues, issue_allocator, id, decl.name);
            }
        },
        .nmtokens => {
            if (attribute.whitespace_char_ref) {
                try invalidValue(issues, issue_allocator, id, decl.name);
            }
            var tokens = std.mem.tokenizeAny(u8, value, " \t\r\n");
            var token_count: usize = 0;
            while (tokens.next()) |token| {
                token_count += 1;
                if (!chars.isNmtoken(token)) {
                    try invalidValue(issues, issue_allocator, id, decl.name);
                    break;
                }
            }
            if (token_count == 0) {
                try invalidValue(issues, issue_allocator, id, decl.name);
            }
        },
        .notation => |allowed| {
            if (!containsName(allowed, value) or !notationDeclared(dtd, value)) {
                try issues.append(issue_allocator, .{
                    .kind = .undeclared_notation,
                    .node = id,
                    .attribute = decl.name,
                    .name = value,
                });
            }
        },
        .enumeration => |allowed| {
            if (!containsName(allowed, value)) {
                try invalidValue(issues, issue_allocator, id, decl.name);
            }
        },
    }

    if (decl.default_kind == .fixed) {
        const normalized = try normalizeDefault(temp, dtd, decl);
        if (!std.mem.eql(u8, value, normalized)) {
            try issues.append(issue_allocator, .{
                .kind = .fixed_attribute_mismatch,
                .node = id,
                .attribute = decl.name,
            });
        }
    }
}

fn invalidValue(
    issues: *std.ArrayList(Issue),
    allocator: std.mem.Allocator,
    node: dom.NodeId,
    attribute: []const u8,
) !void {
    try issues.append(allocator, .{
        .kind = .invalid_attribute_value,
        .node = node,
        .attribute = attribute,
    });
}

fn isUnparsedEntity(dtd: parser_mod.Dtd, name: []const u8) bool {
    const entity = dtd.entities.find(name) orelse return false;
    return entity.external and entity.unparsed;
}

fn normalizeDefault(
    temp: std.mem.Allocator,
    dtd: parser_mod.Dtd,
    decl: *const parser_mod.AttributeDecl,
) ![]const u8 {
    var value = decl.default_value;
    if (std.mem.indexOfScalar(u8, value, '&') != null) {
        value = entities.decodeAttributeAlloc(
            temp,
            value,
            dtd.entities,
            .{},
            .{
                .preserve_undeclared = true,
                .preserve_external = true,
            },
        ) catch decl.default_value;
    }
    if (decl.tokenized()) {
        return normalizeTokenized(temp, value);
    }
    return value;
}

fn normalizeTokenized(
    temp: std.mem.Allocator,
    value: []const u8,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var pending_space = false;
    var started = false;
    for (value) |byte| {
        if (byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n') {
            if (started) pending_space = true;
            continue;
        }
        if (pending_space) {
            try out.append(temp, ' ');
            pending_space = false;
        }
        try out.append(temp, byte);
        started = true;
    }
    return out.toOwnedSlice(temp);
}

fn isWhitespaceOnly(value: []const u8) bool {
    for (value) |byte| {
        if (!chars.isWhitespace(byte)) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const Validated = struct {
    document: dom.Document,
    issues: []Issue,

    fn deinit(self: *Validated) void {
        testing.allocator.free(self.issues);
        self.document.deinit();
    }
};

fn validateSource(source: []const u8) !Validated {
    var document = try dom.Document.parse(testing.allocator, source, .{});
    errdefer document.deinit();
    const dtd = document.dtd orelse return error.TestUnexpectedResult;
    const issues = try validate(testing.allocator, &document, dtd);
    return .{ .document = document, .issues = issues };
}

fn expectIssueCount(source: []const u8, expected: usize) !void {
    var result = try validateSource(source);
    defer result.deinit();
    if (result.issues.len != expected) {
        std.debug.print("validation issues for {s}:\n", .{source});
        for (result.issues) |issue| {
            std.debug.print("  {s} node={d} attr={s} name={s}\n", .{
                @tagName(issue.kind),
                issue.node,
                issue.attribute,
                issue.name,
            });
        }
    }
    try testing.expectEqual(expected, result.issues.len);
}

test "DTD validation accepts a valid document" {
    try expectIssueCount(
        "<!DOCTYPE doc [" ++
            "<!ELEMENT doc (item+, note?)>" ++
            "<!ELEMENT item (#PCDATA)>" ++
            "<!ATTLIST item id ID #REQUIRED price CDATA #IMPLIED>" ++
            "<!ELEMENT note (#PCDATA)>" ++
            "]>" ++
            "<doc><item id='a' price='5'>Apple</item>" ++
            "<item id='b'>Banana</item><note>n</note></doc>",
        0,
    );
}

test "DTD validation reports content model violations" {
    try expectIssueCount(
        "<!DOCTYPE doc [<!ELEMENT doc (item+)><!ELEMENT item EMPTY>]>" ++
            "<doc><item/><bogus/></doc>",
        2,
    );
    try expectIssueCount(
        "<!DOCTYPE doc [<!ELEMENT doc (item+)><!ELEMENT item EMPTY>]>" ++
            "<doc>text<item/></doc>",
        1,
    );
    try expectIssueCount(
        "<!DOCTYPE e [<!ELEMENT e EMPTY>]><e> </e>",
        1,
    );
    try expectIssueCount(
        "<!DOCTYPE doc [<!ELEMENT doc (#PCDATA|b)*><!ELEMENT b EMPTY>]>" ++
            "<doc>text<b/>more</doc>",
        0,
    );
    try expectIssueCount(
        "<!DOCTYPE doc [<!ELEMENT doc (#PCDATA|b)*><!ELEMENT b EMPTY>" ++
            "<!ELEMENT c EMPTY>]><doc><c/></doc>",
        1,
    );
    try expectIssueCount(
        "<!DOCTYPE doc [<!ELEMENT doc ANY>]><doc><anything/></doc>",
        1,
    );
}

test "DTD validation reports attribute constraints" {
    try expectIssueCount(
        "<!DOCTYPE doc [<!ELEMENT doc EMPTY>" ++
            "<!ATTLIST doc id ID #REQUIRED>]><doc/>",
        1,
    );
    try expectIssueCount(
        "<!DOCTYPE doc [<!ELEMENT doc EMPTY>" ++
            "<!ATTLIST doc id ID #REQUIRED>]><doc id='a' bogus='x'/>",
        1,
    );
    try expectIssueCount(
        "<!DOCTYPE doc [<!ELEMENT doc EMPTY>" ++
            "<!ATTLIST doc a ID #IMPLIED>]>" ++
            "<doc a='x'/>",
        0,
    );
}

test "DTD validation reports duplicate IDs and unresolved IDREFs" {
    try expectIssueCount(
        "<!DOCTYPE doc [<!ELEMENT doc (item*)><!ELEMENT item EMPTY>" ++
            "<!ATTLIST item id ID #REQUIRED>]>" ++
            "<doc><item id='a'/><item id='a'/></doc>",
        1,
    );
    try expectIssueCount(
        "<!DOCTYPE doc [<!ELEMENT doc (item*)><!ELEMENT item EMPTY>" ++
            "<!ATTLIST item ref IDREF #IMPLIED>]>" ++
            "<doc><item ref='missing'/></doc>",
        1,
    );
    try expectIssueCount(
        "<!DOCTYPE doc [<!ELEMENT doc (item*)><!ELEMENT item EMPTY>" ++
            "<!ATTLIST item id ID #IMPLIED ref IDREF #IMPLIED>]>" ++
            "<doc><item id='a' ref='a'/></doc>",
        0,
    );
}

test "DTD validation checks enumerations notations entities and fixed values" {
    try expectIssueCount(
        "<!DOCTYPE doc [<!ELEMENT doc EMPTY>" ++
            "<!ATTLIST doc kind (a|b) #REQUIRED>]><doc kind='c'/>",
        1,
    );
    try expectIssueCount(
        "<!DOCTYPE doc [<!ELEMENT doc EMPTY>" ++
            "<!ATTLIST doc kind (a|b) #REQUIRED>]><doc kind='a'/>",
        0,
    );
    try expectIssueCount(
        "<!DOCTYPE doc [<!ELEMENT doc EMPTY>" ++
            "<!NOTATION png SYSTEM 'png'>" ++
            "<!ATTLIST doc src NOTATION (png) #REQUIRED>]><doc src='png'/>",
        0,
    );
    try expectIssueCount(
        "<!DOCTYPE doc [<!ELEMENT doc EMPTY>" ++
            "<!NOTATION png SYSTEM 'png'>" ++
            "<!ATTLIST doc src NOTATION (png) #REQUIRED>]><doc src='jpg'/>",
        1,
    );
    try expectIssueCount(
        "<!DOCTYPE doc [<!ELEMENT doc EMPTY>" ++
            "<!NOTATION png SYSTEM 'png'>" ++
            "<!ENTITY pic SYSTEM 'x.png' NDATA png>" ++
            "<!ATTLIST doc src ENTITY #REQUIRED>]><doc src='pic'/>",
        0,
    );
    try expectIssueCount(
        "<!DOCTYPE doc [<!ELEMENT doc EMPTY>" ++
            "<!NOTATION png SYSTEM 'png'>" ++
            "<!ENTITY pic SYSTEM 'x.png' NDATA png>" ++
            "<!ATTLIST doc src ENTITY #REQUIRED>]><doc src='missing'/>",
        1,
    );
    try expectIssueCount(
        "<!DOCTYPE doc [<!ELEMENT doc EMPTY>" ++
            "<!ATTLIST doc version CDATA #FIXED '1'>]><doc version='2'/>",
        1,
    );
    try expectIssueCount(
        "<!DOCTYPE doc [<!ELEMENT doc EMPTY>" ++
            "<!ATTLIST doc version CDATA #FIXED '1'>]><doc version='1'/>",
        0,
    );
}

test "DTD validation checks the root element type" {
    try expectIssueCount(
        "<!DOCTYPE a [<!ELEMENT a EMPTY><!ELEMENT b EMPTY>]><b/>",
        1,
    );
}
