//! ISO Schematron validation over `dom.Document`.

const std = @import("std");
const dom = @import("../dom.zig");

pub const schema = @import("schema.zig");
pub const validate_mod = @import("validate.zig");

pub const Schema = schema.Schema;
pub const Error = schema.Error;
pub const Options = validate_mod.Options;
pub const Failure = validate_mod.Failure;
pub const Reference = validate_mod.Reference;
pub const ValidationResult = validate_mod.Result;
pub const namespace_uri = schema.namespace_uri;

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
        if (std.mem.eql(u8, node.ns, namespace_uri) and
            std.mem.eql(u8, node.local, "pattern"))
        {
            if (ancestor == null or inside_ancestor) {
                try out.append(allocator, child);
            }
            continue;
        }
        const is_ancestor = if (ancestor) |value|
            std.mem.eql(u8, node.ns, value.namespace) and
                std.mem.eql(u8, node.local, value.local)
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
    std.testing.refAllDecls(@This());
    _ = schema;
    _ = validate_mod;
}

const testing = std.testing;

fn parseDocument(source: []const u8) !dom.Document {
    return dom.Document.parse(testing.allocator, source, .{});
}

const sch = "http://purl.oclc.org/dsdl/schematron";

test "Schematron asserts and reports" {
    const schema_source =
        "<schema xmlns='" ++ sch ++ "'>" ++
        "<pattern id='p'><rule context='item'>" ++
        "<assert test='@id'>item needs id</assert>" ++
        "<report test=\"@id='bad'\">bad id</report>" ++
        "</rule></pattern></schema>";
    var schema_document = try parseDocument(schema_source);
    defer schema_document.deinit();
    var compiled = try parse(testing.allocator, &schema_document);
    defer compiled.deinit();

    var valid_document = try parseDocument("<root><item id='a'/></root>");
    defer valid_document.deinit();
    var valid = try validate(
        &compiled,
        testing.allocator,
        &valid_document,
        .{},
    );
    defer valid.deinit();
    try testing.expect(valid.isValid());

    var invalid_document = try parseDocument("<root><item/></root>");
    defer invalid_document.deinit();
    var invalid = try validate(
        &compiled,
        testing.allocator,
        &invalid_document,
        .{},
    );
    defer invalid.deinit();
    try testing.expect(!invalid.isValid());
    try testing.expectEqualStrings("item needs id", invalid.failures[0].message);

    var report_document = try parseDocument("<root><item id='bad'/></root>");
    defer report_document.deinit();
    var report = try validate(
        &compiled,
        testing.allocator,
        &report_document,
        .{},
    );
    defer report.deinit();
    try testing.expect(report.isValid());
    try testing.expectEqual(1, report.failures.len);
    try testing.expect(report.failures[0].kind == .report);
    try testing.expectEqualStrings("bad id", report.failures[0].message);
}

test "Schematron namespace declarations, lets, and messages" {
    const schema_source =
        "<schema xmlns='" ++ sch ++ "' xmlns:q='urn:q'>" ++
        "<ns prefix='p' uri='urn:q'/>" ++
        "<let name='limit' value='2'/>" ++
        "<pattern id='p'><let name='label' value=\"'items'\"/>" ++
        "<rule context='p:item'>" ++
        "<assert test='count(../p:item) &lt;= $limit'>" ++
        "too many <name/>: <value-of select='$label'/> " ++
        "<value-of select='@id'/></assert>" ++
        "</rule></pattern></schema>";
    var schema_document = try parseDocument(schema_source);
    defer schema_document.deinit();
    var compiled = try parse(testing.allocator, &schema_document);
    defer compiled.deinit();

    var valid_document = try parseDocument(
        "<root xmlns:q='urn:q'><q:item id='a'/><q:item id='b'/></root>",
    );
    defer valid_document.deinit();
    var valid = try validate(
        &compiled,
        testing.allocator,
        &valid_document,
        .{},
    );
    defer valid.deinit();
    try testing.expect(valid.isValid());

    var invalid_document = try parseDocument(
        "<root xmlns:q='urn:q'><q:item id='a'/><q:item id='b'/>" ++
            "<q:item id='c'/></root>",
    );
    defer invalid_document.deinit();
    var invalid = try validate(
        &compiled,
        testing.allocator,
        &invalid_document,
        .{},
    );
    defer invalid.deinit();
    try testing.expect(!invalid.isValid());
    try testing.expect(std.mem.indexOf(
        u8,
        invalid.failures[0].message,
        "items",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        invalid.failures[0].message,
        "q:item",
    ) != null);
}

test "Schematron phases select patterns" {
    const schema_source =
        "<schema xmlns='" ++ sch ++ "' defaultPhase='p2'>" ++
        "<phase id='p1'><active pattern='a'/></phase>" ++
        "<phase id='p2'><active pattern='b'/></phase>" ++
        "<pattern id='a'><rule context='item'>" ++
        "<assert test='@a'>needs a</assert></rule></pattern>" ++
        "<pattern id='b'><rule context='item'>" ++
        "<assert test='@b'>needs b</assert></rule></pattern>" ++
        "</schema>";
    var schema_document = try parseDocument(schema_source);
    defer schema_document.deinit();
    var compiled = try parse(testing.allocator, &schema_document);
    defer compiled.deinit();

    var document = try parseDocument("<root><item a='1'/></root>");
    defer document.deinit();
    var default_phase = try validate(
        &compiled,
        testing.allocator,
        &document,
        .{},
    );
    defer default_phase.deinit();
    try testing.expect(!default_phase.isValid());

    var first_phase = try validate(
        &compiled,
        testing.allocator,
        &document,
        .{ .phase = "p1" },
    );
    defer first_phase.deinit();
    try testing.expect(first_phase.isValid());
}

test "Schematron abstract rules and extends" {
    const schema_source =
        "<schema xmlns='" ++ sch ++ "'>" ++
        "<pattern id='p'>" ++
        "<rule abstract='true' id='base'>" ++
        "<assert test='@id'>id required</assert></rule>" ++
        "<rule context='item'><extends rule='base'/>" ++
        "<assert test='@kind'>kind required</assert></rule>" ++
        "</pattern></schema>";
    var schema_document = try parseDocument(schema_source);
    defer schema_document.deinit();
    var compiled = try parse(testing.allocator, &schema_document);
    defer compiled.deinit();

    var valid_document = try parseDocument(
        "<root><item id='1' kind='a'/></root>",
    );
    defer valid_document.deinit();
    var valid = try validate(&compiled, testing.allocator, &valid_document, .{});
    defer valid.deinit();
    try testing.expect(valid.isValid());

    var missing_id = try parseDocument("<root><item kind='a'/></root>");
    defer missing_id.deinit();
    var no_id = try validate(&compiled, testing.allocator, &missing_id, .{});
    defer no_id.deinit();
    try testing.expect(!no_id.isValid());

    var missing_kind = try parseDocument("<root><item id='1'/></root>");
    defer missing_kind.deinit();
    var no_kind = try validate(
        &compiled,
        testing.allocator,
        &missing_kind,
        .{},
    );
    defer no_kind.deinit();
    try testing.expect(!no_kind.isValid());
}

test "Schematron abstract patterns substitute parameters" {
    const schema_source =
        "<schema xmlns='" ++ sch ++ "'>" ++
        "<ns prefix='h' uri='urn:h'/>" ++
        "<pattern abstract='true' id='table'>" ++
        "<rule context='$row'><assert test='@$attr'>attribute required</assert></rule>" ++
        "</pattern>" ++
        "<pattern is-a='table' id='htmlTable'>" ++
        "<param name='row' value='h:row'/>" ++
        "<param name='attr' value='id'/>" ++
        "</pattern></schema>";
    var schema_document = try parseDocument(schema_source);
    defer schema_document.deinit();
    var compiled = try parse(testing.allocator, &schema_document);
    defer compiled.deinit();

    var valid_document = try parseDocument(
        "<root xmlns:h='urn:h'><h:row id='1'/></root>",
    );
    defer valid_document.deinit();
    var valid = try validate(&compiled, testing.allocator, &valid_document, .{});
    defer valid.deinit();
    try testing.expect(valid.isValid());

    var invalid_document = try parseDocument(
        "<root xmlns:h='urn:h'><h:row/></root>",
    );
    defer invalid_document.deinit();
    var invalid = try validate(
        &compiled,
        testing.allocator,
        &invalid_document,
        .{},
    );
    defer invalid.deinit();
    try testing.expect(!invalid.isValid());
}

test "Schematron rejects circular extends" {
    const schema_source =
        "<schema xmlns='" ++ sch ++ "'>" ++
        "<pattern id='p'>" ++
        "<rule abstract='true' id='a'><extends rule='a'/></rule>" ++
        "<rule context='item'><extends rule='a'/></rule>" ++
        "</pattern></schema>";
    var schema_document = try parseDocument(schema_source);
    defer schema_document.deinit();
    try testing.expectError(
        error.InvalidSchema,
        parse(testing.allocator, &schema_document),
    );
}

test "Schematron diagnostics and properties render in context" {
    const schema_source =
        "<schema xmlns='" ++ sch ++ "'>" ++
        "<pattern id='p'><rule context='item'>" ++
        "<assert test='@id' diagnostics='missing d1 d2' properties='p1'>" ++
        "item needs id</assert>" ++
        "</rule></pattern>" ++
        "<diagnostics>" ++
        "<diagnostic id='d1'>missing id</diagnostic>" ++
        "<diagnostic id='d2'>kind is <value-of select='@kind'/></diagnostic>" ++
        "</diagnostics>" ++
        "<properties>" ++
        "<property id='p1' scheme='urn:s' role='error'>" ++
        "bad <value-of select='name()'/></property>" ++
        "</properties></schema>";
    var schema_document = try parseDocument(schema_source);
    defer schema_document.deinit();
    var compiled = try parse(testing.allocator, &schema_document);
    defer compiled.deinit();

    var document = try parseDocument("<root><item kind='k'/></root>");
    defer document.deinit();
    var result = try validate(&compiled, testing.allocator, &document, .{});
    defer result.deinit();
    try testing.expect(!result.isValid());
    try testing.expectEqual(1, result.failures.len);
    const failure = result.failures[0];
    try testing.expectEqual(2, failure.diagnostics.len);
    try testing.expectEqualStrings("d1", failure.diagnostics[0].id);
    try testing.expectEqualStrings("missing id", failure.diagnostics[0].message);
    try testing.expectEqualStrings("d2", failure.diagnostics[1].id);
    try testing.expectEqualStrings("kind is k", failure.diagnostics[1].message);
    try testing.expectEqual(1, failure.properties.len);
    try testing.expectEqualStrings("p1", failure.properties[0].id);
    try testing.expectEqualStrings("urn:s", failure.properties[0].scheme);
    try testing.expectEqualStrings("error", failure.properties[0].role);
    try testing.expectEqualStrings("bad item", failure.properties[0].message);
}

test "Schematron compiles patterns embedded in a host schema" {
    const host_source =
        "<grammar xmlns='http://relaxng.org/ns/structure/1.0' " ++
        "xmlns:sch='" ++ sch ++ "' xmlns:q='urn:q'>" ++
        "<sch:pattern id='p'><sch:rule context='q:item'>" ++
        "<sch:assert test='@id'>id required</sch:assert>" ++
        "</sch:rule></sch:pattern></grammar>";
    var host_document = try parseDocument(host_source);
    defer host_document.deinit();
    const patterns = try findEmbeddedPatterns(
        testing.allocator,
        &host_document,
        null,
    );
    defer testing.allocator.free(patterns);
    try testing.expectEqual(1, patterns.len);

    var compiled = try parsePatterns(
        testing.allocator,
        &host_document,
        patterns,
    );
    defer compiled.deinit();

    var invalid_document = try parseDocument(
        "<root xmlns:q='urn:q'><q:item/></root>",
    );
    defer invalid_document.deinit();
    var invalid = try validate(
        &compiled,
        testing.allocator,
        &invalid_document,
        .{},
    );
    defer invalid.deinit();
    try testing.expect(!invalid.isValid());
    try testing.expectEqualStrings("id required", invalid.failures[0].message);

    var valid_document = try parseDocument(
        "<root xmlns:q='urn:q'><q:item id='1'/></root>",
    );
    defer valid_document.deinit();
    var valid = try validate(&compiled, testing.allocator, &valid_document, .{});
    defer valid.deinit();
    try testing.expect(valid.isValid());
}

test "Schematron embedded pattern discovery can require an ancestor" {
    const host_source =
        "<schema xmlns='urn:host' xmlns:sch='" ++ sch ++ "'>" ++
        "<sch:pattern id='outside'/>" ++
        "<appinfo><sch:pattern id='inside'/></appinfo>" ++
        "</schema>";
    var document = try parseDocument(host_source);
    defer document.deinit();
    const all = try findEmbeddedPatterns(
        testing.allocator,
        &document,
        null,
    );
    defer testing.allocator.free(all);
    try testing.expectEqual(2, all.len);
    const inside = try findEmbeddedPatterns(
        testing.allocator,
        &document,
        .{ .namespace = "urn:host", .local = "appinfo" },
    );
    defer testing.allocator.free(inside);
    try testing.expectEqual(1, inside.len);
    try testing.expectEqualStrings(
        "inside",
        document.attribute(inside[0], "id").?,
    );
}
