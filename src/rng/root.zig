//! RELAX NG validation over `dom.Document`.

const std = @import("std");
const dom = @import("../dom.zig");

pub const schema = @import("schema.zig");
pub const compact = @import("compact.zig");
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

/// Compile a schema written in the RELAX NG compact syntax.
pub fn parseCompact(
    allocator: std.mem.Allocator,
    source: []const u8,
) Error!Schema {
    return compact.parse(allocator, source);
}

/// Compile a compact syntax schema with include/external resolution.
pub fn parseCompactWithOptions(
    allocator: std.mem.Allocator,
    source: []const u8,
    options: Options,
) Error!Schema {
    return compact.parseWithOptions(allocator, source, options);
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
    _ = compact;
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

test "RELAX NG nested grammars and parentRef" {
    const schema_source =
        \\<grammar xmlns="http://relaxng.org/ns/structure/1.0">
        \\  <start><ref name="chain"/></start>
        \\  <define name="chain">
        \\    <grammar>
        \\      <start>
        \\        <element name="a">
        \\          <optional><parentRef name="chain"/></optional>
        \\        </element>
        \\      </start>
        \\    </grammar>
        \\  </define>
        \\</grammar>
    ;
    try expectValid(schema_source, "<a/>");
    try expectValid(schema_source, "<a><a><a/></a></a>");
    try expectInvalid(schema_source, "<a><b/></a>");
}

fn expectCompactValid(compact_source: []const u8, instance: []const u8) !void {
    var compiled = try parseCompact(testing.allocator, compact_source);
    defer compiled.deinit();
    var instance_document = try parseDocument(instance);
    defer instance_document.deinit();
    var result = try validate(&compiled, testing.allocator, &instance_document);
    defer result.deinit();
    try testing.expect(result.isValid());
}

fn expectCompactInvalid(compact_source: []const u8, instance: []const u8) !void {
    var compiled = try parseCompact(testing.allocator, compact_source);
    defer compiled.deinit();
    var instance_document = try parseDocument(instance);
    defer instance_document.deinit();
    var result = try validate(&compiled, testing.allocator, &instance_document);
    defer result.deinit();
    try testing.expect(!result.isValid());
}

test "RELAX NG compact syntax validates sequences and attributes" {
    const compact_source =
        \\element root {
        \\  attribute id { text },
        \\  element item { text },
        \\  element item { text }
        \\}
    ;
    try expectCompactValid(
        compact_source,
        "<root id='1'><item>a</item><item>b</item></root>",
    );
    try expectCompactInvalid(
        compact_source,
        "<root><item>a</item><item>b</item></root>",
    );
    try expectCompactInvalid(
        compact_source,
        "<root id='1'><item>a</item></root>",
    );
}

test "RELAX NG compact syntax validates choices and repetition" {
    const compact_source =
        \\element root {
        \\  (element a { text } | element b { empty })+,
        \\  attribute id { text }?
        \\}
    ;
    try expectCompactValid(compact_source, "<root><a>x</a><b/><a>y</a></root>");
    try expectCompactValid(compact_source, "<root id='1'><b/></root>");
    try expectCompactInvalid(compact_source, "<root/>");
    try expectCompactInvalid(compact_source, "<root><c/></root>");
}

test "RELAX NG compact syntax validates namespaces and name classes" {
    const compact_source =
        \\default namespace = "urn:t"
        \\namespace t = "urn:t"
        \\element root {
        \\  element * - t:skip { empty }*
        \\}
    ;
    try expectCompactValid(
        compact_source,
        "<root xmlns='urn:t'><a/><b/></root>",
    );
    try expectCompactInvalid(
        compact_source,
        "<root xmlns='urn:t'><skip/></root>",
    );
    try expectCompactValid(
        compact_source,
        "<root xmlns='urn:t'><skip xmlns=''/></root>",
    );
}

test "RELAX NG compact syntax validates data, values, and lists" {
    const compact_source =
        \\element root {
        \\  element n { xsd:integer { minInclusive = "10" } },
        \\  element tag { "fixed" },
        \\  element ids { list { xsd:integer+ } },
        \\  element nonZero { xsd:integer - "0" }
        \\}
    ;
    try expectCompactValid(
        compact_source,
        "<root><n>10</n><tag>fixed</tag><ids>1 2 3</ids><nonZero>5</nonZero></root>",
    );
    try expectCompactInvalid(
        compact_source,
        "<root><n>5</n><tag>fixed</tag><ids>1</ids><nonZero>5</nonZero></root>",
    );
    try expectCompactInvalid(
        compact_source,
        "<root><n>10</n><tag>other</tag><ids>1</ids><nonZero>5</nonZero></root>",
    );
    try expectCompactInvalid(
        compact_source,
        "<root><n>10</n><tag>fixed</tag><ids>1</ids><nonZero>0</nonZero></root>",
    );
}

test "RELAX NG compact syntax validates grammars and parent references" {
    const compact_source =
        \\grammar {
        \\  start = chain
        \\  chain = grammar {
        \\    start = element a { parent chain? }
        \\  }
        \\}
    ;
    try expectCompactValid(compact_source, "<a/>");
    try expectCompactValid(compact_source, "<a><a><a/></a></a>");
    try expectCompactInvalid(compact_source, "<a><b/></a>");
}

test "RELAX NG compact syntax supports escapes and quoted keywords" {
    const compact_source =
        \\element \x{72}oot {
        \\  \text = element item { empty }
        \\  text
        \\}
    ;
    // The quoted define name is only meaningful inside a grammar; using it as
    // a pattern atom is an error, so keep this schema invalid.
    const compiled = parseCompact(testing.allocator, compact_source);
    if (compiled) |value| {
        var schema_value = value;
        schema_value.deinit();
        return error.TestUnexpectedResult;
    } else |err| {
        try testing.expect(
            err == error.InvalidPattern or err == error.InvalidSchema,
        );
    }

    const valid_source =
        \\element \x{72}oot { element item { empty } }
    ;
    try expectCompactValid(valid_source, "<root><item/></root>");
    try expectCompactInvalid(valid_source, "<root><other/></root>");
}

test "RELAX NG compact syntax rejects mixed operators without parentheses" {
    const compiled = parseCompact(
        testing.allocator,
        "element root { element a { empty } | element b { empty }, element c { empty } }",
    );
    if (compiled) |value| {
        var schema_value = value;
        schema_value.deinit();
        return error.TestUnexpectedResult;
    } else |err| {
        try testing.expect(err == error.InvalidPattern);
    }
}

test "RELAX NG compact syntax skips comments and annotations" {
    const compact_source =
        \\# leading comment
        \\element root {
        \\  ## documentation
        \\  [ doc="yes" ] element item { empty } >> note
        \\}
    ;
    try expectCompactValid(compact_source, "<root><item/></root>");
}

const CompactResource = struct {
    href: []const u8,
    uri: []const u8,
    data: []const u8,
};

const CompactResolver = struct {
    resources: []const CompactResource,
};

fn loadCompactResource(
    context: ?*anyopaque,
    href: []const u8,
    base: []const u8,
) ?Resource {
    _ = base;
    const resolver: *const CompactResolver = @ptrCast(@alignCast(context.?));
    for (resolver.resources) |resource| {
        if (std.mem.eql(u8, resource.href, href)) {
            return .{ .uri = resource.uri, .data = resource.data };
        }
    }
    return null;
}

test "RELAX NG compact syntax includes definitions" {
    const resources = [_]CompactResource{
        .{
            .href = "base.rnc",
            .uri = "base.rnc",
            .data = "item = element item { text }",
        },
    };
    var resolver: CompactResolver = .{ .resources = &resources };
    const source =
        \\grammar {
        \\  include "base.rnc"
        \\  start = element root { item+ }
        \\}
    ;
    var compiled = try parseCompactWithOptions(testing.allocator, source, .{
        .resolver = .{ .context = &resolver, .load = loadCompactResource },
        .base = "main.rnc",
    });
    defer compiled.deinit();
    var instance_document = try parseDocument(
        "<root><item>a</item><item>b</item></root>",
    );
    defer instance_document.deinit();
    var result = try validate(&compiled, testing.allocator, &instance_document);
    defer result.deinit();
    try testing.expect(result.isValid());
}

test "RELAX NG compact syntax include overrides definitions" {
    const resources = [_]CompactResource{
        .{
            .href = "base.rnc",
            .uri = "base.rnc",
            .data = "item = element a { text }",
        },
    };
    var resolver: CompactResolver = .{ .resources = &resources };
    const source =
        \\grammar {
        \\  include "base.rnc" {
        \\    item = element b { text }
        \\  }
        \\  start = element root { item }
        \\}
    ;
    var compiled = try parseCompactWithOptions(testing.allocator, source, .{
        .resolver = .{ .context = &resolver, .load = loadCompactResource },
        .base = "main.rnc",
    });
    defer compiled.deinit();
    var valid_document = try parseDocument("<root><b>x</b></root>");
    defer valid_document.deinit();
    var valid_result = try validate(
        &compiled,
        testing.allocator,
        &valid_document,
    );
    defer valid_result.deinit();
    try testing.expect(valid_result.isValid());

    var invalid_document = try parseDocument("<root><a>x</a></root>");
    defer invalid_document.deinit();
    var invalid_result = try validate(
        &compiled,
        testing.allocator,
        &invalid_document,
    );
    defer invalid_result.deinit();
    try testing.expect(!invalid_result.isValid());
}

test "RELAX NG compact syntax external references and namespace inheritance" {
    const resources = [_]CompactResource{
        .{
            .href = "item.rnc",
            .uri = "item.rnc",
            .data = "element item { empty }",
        },
    };
    var resolver: CompactResolver = .{ .resources = &resources };
    const source =
        \\default namespace = "urn:t"
        \\element root { external "item.rnc" }
    ;
    var compiled = try parseCompactWithOptions(testing.allocator, source, .{
        .resolver = .{ .context = &resolver, .load = loadCompactResource },
        .base = "main.rnc",
    });
    defer compiled.deinit();
    var instance_document = try parseDocument(
        "<root xmlns='urn:t'><item/></root>",
    );
    defer instance_document.deinit();
    var result = try validate(&compiled, testing.allocator, &instance_document);
    defer result.deinit();
    try testing.expect(result.isValid());

    var wrong_document = try parseDocument(
        "<root xmlns='urn:t'><item xmlns=''/></root>",
    );
    defer wrong_document.deinit();
    var wrong_result = try validate(
        &compiled,
        testing.allocator,
        &wrong_document,
    );
    defer wrong_result.deinit();
    try testing.expect(!wrong_result.isValid());
}
