//! ISO Schematron validation over `dom.Document`.

const std = @import("std");
const dom = @import("../dom.zig");

pub const schema = @import("schema.zig");
pub const validate_mod = @import("validate.zig");

pub const Schema = schema.Schema;
pub const Error = schema.Error;
pub const Options = validate_mod.Options;
pub const Failure = validate_mod.Failure;
pub const ValidationResult = validate_mod.Result;
pub const namespace_uri = schema.namespace_uri;

/// Compile an ISO Schematron schema.
pub fn parse(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
) Error!Schema {
    return schema.parse(allocator, document);
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
