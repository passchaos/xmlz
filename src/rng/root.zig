//! RELAX NG validation over `dom.Document`.

const std = @import("std");
const dom = @import("../dom.zig");

pub const schema = @import("schema.zig");
pub const validate_mod = @import("validate.zig");

pub const Schema = schema.Schema;
pub const Options = schema.Options;
pub const Resolver = schema.Resolver;
pub const Resource = schema.Resource;
pub const Error = schema.Error;
pub const ValidationError = validate_mod.ValidationError;
pub const ValidationResult = validate_mod.Result;
pub const structure_namespace = schema.structure_namespace;

/// Compile a RELAX NG schema document.
pub fn parse(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
) Error!Schema {
    return schema.parse(allocator, document);
}

/// Compile a schema with include/externalRef resolution.
pub fn parseWithOptions(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
    options: Options,
) Error!Schema {
    return schema.parseWithOptions(allocator, document, options);
}

/// Validate an instance document against a compiled schema.
pub fn validate(
    compiled: *const Schema,
    allocator: std.mem.Allocator,
    document: *const dom.Document,
) validate_mod.Error!ValidationResult {
    return validate_mod.validate(compiled, allocator, document);
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

fn expectValid(schema_source: []const u8, instance: []const u8) !void {
    var schema_document = try parseDocument(schema_source);
    defer schema_document.deinit();
    var compiled = try parse(testing.allocator, &schema_document);
    defer compiled.deinit();
    var instance_document = try parseDocument(instance);
    defer instance_document.deinit();
    var result = try validate(&compiled, testing.allocator, &instance_document);
    defer result.deinit();
    try testing.expect(result.isValid());
}

fn expectInvalid(schema_source: []const u8, instance: []const u8) !void {
    var schema_document = try parseDocument(schema_source);
    defer schema_document.deinit();
    var compiled = try parse(testing.allocator, &schema_document);
    defer compiled.deinit();
    var instance_document = try parseDocument(instance);
    defer instance_document.deinit();
    var result = try validate(&compiled, testing.allocator, &instance_document);
    defer result.deinit();
    try testing.expect(!result.isValid());
}

const rng_namespace = "http://relaxng.org/ns/structure/1.0";

fn elementSchema(body: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        testing.allocator,
        "<element xmlns='{s}' datatypeLibrary='http://www.w3.org/2001/XMLSchema-datatypes' name='root'>{s}</element>",
        .{ rng_namespace, body },
    );
}

test "RELAX NG validates element sequences" {
    const schema_source = try elementSchema(
        "<group>" ++
            "<element name='item'><text/></element>" ++
            "<element name='item'><text/></element>" ++
            "</group>",
    );
    defer testing.allocator.free(schema_source);
    try expectValid(schema_source, "<root><item>a</item><item>b</item></root>");
    try expectInvalid(schema_source, "<root><item>a</item></root>");
    try expectInvalid(
        schema_source,
        "<root><item>a</item><other>b</other></root>",
    );
}

test "RELAX NG validates attributes in any order" {
    const schema_source = try elementSchema(
        "<group>" ++
            "<attribute name='a'><text/></attribute>" ++
            "<attribute name='b'><text/></attribute>" ++
            "</group>",
    );
    defer testing.allocator.free(schema_source);
    try expectValid(schema_source, "<root a='1' b='2'/>");
    try expectValid(schema_source, "<root b='2' a='1'/>");
    try expectInvalid(schema_source, "<root a='1'/>");
    try expectInvalid(schema_source, "<root a='1' b='2' c='3'/>");
}

test "RELAX NG validates choice, optional, and repetition" {
    const schema_source = try elementSchema(
        "<group><oneOrMore><choice>" ++
            "<element name='a'><text/></element>" ++
            "<element name='b'><empty/></element>" ++
            "</choice></oneOrMore>" ++
            "<optional><attribute name='id'><text/></attribute></optional></group>",
    );
    defer testing.allocator.free(schema_source);
    try expectValid(schema_source, "<root><a>x</a><b/><a>y</a></root>");
    try expectValid(schema_source, "<root id='1'><b/></root>");
    try expectInvalid(schema_source, "<root/>");
    try expectInvalid(schema_source, "<root><c/></root>");
}

test "RELAX NG validates data, value, and list patterns" {
    const schema_source = try elementSchema(
        "<group><element name='n'><data type='integer'/></element>" ++
            "<group><element name='tag'><value>fixed</value></element>" ++
            "<element name='ids'><list><oneOrMore><data type='integer'/></oneOrMore></list></element>" ++
            "</group></group>",
    );
    defer testing.allocator.free(schema_source);
    try expectValid(
        schema_source,
        "<root><n>42</n><tag>fixed</tag><ids>1 2 3</ids></root>",
    );
    try expectInvalid(
        schema_source,
        "<root><n>x</n><tag>fixed</tag><ids>1 2</ids></root>",
    );
    try expectInvalid(
        schema_source,
        "<root><n>1</n><tag>other</tag><ids>1</ids></root>",
    );
    try expectInvalid(
        schema_source,
        "<root><n>1</n><tag>fixed</tag><ids>1 x</ids></root>",
    );
}

test "RELAX NG validates recursive defines" {
    const schema_source =
        \\<grammar xmlns="http://relaxng.org/ns/structure/1.0">
        \\  <start>
        \\    <element name="tree">
        \\      <group>
        \\        <attribute name="name"><text/></attribute>
        \\        <zeroOrMore><ref name="child"/></zeroOrMore>
        \\      </group>
        \\    </element>
        \\  </start>
        \\  <define name="child">
        \\    <element name="tree">
        \\      <group>
        \\        <attribute name="name"><text/></attribute>
        \\        <zeroOrMore><ref name="child"/></zeroOrMore>
        \\      </group>
        \\    </element>
        \\  </define>
        \\</grammar>
    ;
    try expectValid(
        schema_source,
        "<tree name='a'><tree name='b'/><tree name='c'/></tree>",
    );
    try expectInvalid(schema_source, "<tree><tree name='b'/></tree>");
}

test "RELAX NG validates mixed content and name classes" {
    const schema_source =
        \\<element xmlns="http://relaxng.org/ns/structure/1.0" name="p">
        \\  <mixed>
        \\    <zeroOrMore>
        \\      <element>
        \\        <choice>
        \\          <name>b</name>
        \\          <name>i</name>
        \\        </choice>
        \\        <text/>
        \\      </element>
        \\    </zeroOrMore>
        \\  </mixed>
        \\</element>
    ;
    try expectValid(schema_source, "<p>hello <b>bold</b> and <i>it</i></p>");
    try expectValid(schema_source, "<p/>");
    try expectInvalid(schema_source, "<p><u>x</u></p>");
}

test "RELAX NG validates namespaces and anyName except" {
    const schema_source =
        \\<element xmlns="http://relaxng.org/ns/structure/1.0" name="root">
        \\  <zeroOrMore>
        \\    <element>
        \\      <anyName>
        \\        <except><name>skip</name></except>
        \\      </anyName>
        \\      <empty/>
        \\    </element>
        \\  </zeroOrMore>
        \\</element>
    ;
    try expectValid(schema_source, "<root><a/><ns:b xmlns:ns='urn:x'/></root>");
    try expectInvalid(schema_source, "<root><skip/></root>");
}
