//! ISO Schematron validation over `dom.Document`.

const std = @import("std");
const dom = @import("../dom.zig");

pub const schema = @import("schema.zig");
pub const svrl = @import("svrl.zig");
pub const validate_mod = @import("validate.zig");

pub const Schema = schema.Schema;
pub const Error = schema.Error;
pub const Options = validate_mod.Options;
pub const Failure = validate_mod.Failure;
pub const Reference = validate_mod.Reference;
pub const ValidationResult = validate_mod.Result;
pub const namespace_uri = schema.namespace_uri;

/// Write an SVRL report for a validation result.
pub const writeSvrl = svrl.write;

/// Compile an ISO Schematron schema.
pub fn parse(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
) Error!Schema {
    return schema.parse(allocator, document);
}

/// Compile `sch:pattern` elements embedded in a host schema document.
pub fn parsePatterns(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
    pattern_nodes: []const dom.NodeId,
) Error!Schema {
    return schema.parsePatterns(allocator, document, pattern_nodes);
}

/// Restrict embedded patterns to those inside a host element, such as
/// `xs:appinfo`. A null ancestor collects every `sch:pattern` in the document.
pub const Ancestor = struct {
    namespace: []const u8,
    local: []const u8,
};

/// Collect `sch:pattern` element ids from a host schema document in document
/// order. Patterns nested inside another pattern are not collected.
pub fn findEmbeddedPatterns(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
    ancestor: ?Ancestor,
) ![]const dom.NodeId {
    var out: std.ArrayList(dom.NodeId) = .empty;
    errdefer out.deinit(allocator);
    try collectPatterns(
        allocator,
        document,
        document.documentNode(),
        ancestor,
        false,
        &out,
    );
    return out.toOwnedSlice(allocator);
}

fn collectPatterns(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
    id: dom.NodeId,
    ancestor: ?Ancestor,
    inside_ancestor: bool,
    out: *std.ArrayList(dom.NodeId),
) !void {
    var child = document.node(id).first_child;
    while (child != dom.null_node) : (child = document.node(child).next_sibling) {
        const node = document.node(child);
        if (node.kind != .element) continue;
        if (std.mem.eql(u8, document.ns(node.ns), namespace_uri) and
            std.mem.eql(u8, node.localName(), "pattern"))
        {
            if (ancestor == null or inside_ancestor) {
                try out.append(allocator, child);
            }
            continue;
        }
        const is_ancestor = if (ancestor) |value|
            std.mem.eql(u8, document.ns(node.ns), value.namespace) and
                std.mem.eql(u8, node.localName(), value.local)
        else
            false;
        try collectPatterns(
            allocator,
            document,
            child,
            ancestor,
            inside_ancestor or is_ancestor,
            out,
        );
    }
}

/// Validate an instance document against a compiled schema.
pub fn validate(
    compiled: *const Schema,
    allocator: std.mem.Allocator,
    document: *const dom.Document,
    options: Options,
) validate_mod.Error!ValidationResult {
    return validate_mod.validate(compiled, allocator, document, options);
}

test {
    _ = @import("tests.zig");
}
