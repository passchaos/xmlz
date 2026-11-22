//! XML Schema validation.

const std = @import("std");
const dom = @import("../dom.zig");

pub const regex = @import("regex.zig");
pub const datatypes = @import("datatypes.zig");
pub const schema = @import("schema.zig");
pub const validate_mod = @import("validate.zig");

pub const Schema = schema.Schema;
pub const SchemaDocument = schema.SchemaDocument;
pub const Options = schema.Options;
pub const Resolver = schema.Resolver;
pub const Resource = schema.Resource;
pub const Error = schema.Error;
pub const ValidationError = validate_mod.ValidationError;
pub const ValidationResult = validate_mod.Result;

/// Compile an XML Schema document.
pub fn parse(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
) Error!Schema {
    return schema.parse(allocator, document);
}

/// Compile a schema document with include/import resolution.
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
    _ = regex;
    _ = datatypes;
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

const basic_schema =
    \\<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema">
    \\  <xs:element name="root">
    \\    <xs:complexType>
    \\      <xs:sequence>
    \\        <xs:element name="item" type="xs:string"
    \\          minOccurs="1" maxOccurs="unbounded"/>
    \\      </xs:sequence>
    \\      <xs:attribute name="id" type="xs:integer" use="required"/>
    \\    </xs:complexType>
    \\  </xs:element>
    \\</xs:schema>
;

test "XSD validates sequence and required attribute" {
    try expectValid(
        basic_schema,
        "<root id='1'><item>a</item><item>b</item></root>",
    );
    try expectInvalid(basic_schema, "<root><item>a</item></root>");
    try expectInvalid(basic_schema, "<root id='x'><item>a</item></root>");
    try expectInvalid(basic_schema, "<root id='1'/>");
    try expectInvalid(
        basic_schema,
        "<root id='1'><item>a</item><extra/></root>",
    );
}

test "XSD validates simple type restrictions" {
    const schema_source =
        \\<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema">
        \\  <xs:simpleType name="color">
        \\    <xs:restriction base="xs:string">
        \\      <xs:enumeration value="red"/>
        \\      <xs:enumeration value="blue"/>
        \\    </xs:restriction>
        \\  </xs:simpleType>
        \\  <xs:element name="color" type="color"/>
        \\</xs:schema>
    ;
    try expectValid(schema_source, "<color>red</color>");
    try expectInvalid(schema_source, "<color>green</color>");
}

test "XSD validates namespaces and qualified local elements" {
    const schema_source =
        \\<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema"
        \\  targetNamespace="urn:t" xmlns:t="urn:t"
        \\  elementFormDefault="qualified">
        \\  <xs:element name="root" type="t:Root"/>
        \\  <xs:complexType name="Root">
        \\    <xs:sequence>
        \\      <xs:element name="child" type="xs:string"/>
        \\    </xs:sequence>
        \\  </xs:complexType>
        \\</xs:schema>
    ;
    try expectValid(
        schema_source,
        "<root xmlns='urn:t'><child>x</child></root>",
    );
    try expectInvalid(
        schema_source,
        "<root xmlns='urn:t'><child xmlns=''>x</child></root>",
    );
    try expectInvalid(schema_source, "<root><child>x</child></root>");
}

test "XSD validates complex content extension" {
    const schema_source =
        \\<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema"
        \\  targetNamespace="urn:t" xmlns:t="urn:t"
        \\  elementFormDefault="qualified">
        \\  <xs:element name="root" type="t:Derived"/>
        \\  <xs:complexType name="Base">
        \\    <xs:sequence>
        \\      <xs:element name="a" type="xs:string"/>
        \\    </xs:sequence>
        \\  </xs:complexType>
        \\  <xs:complexType name="Derived">
        \\    <xs:complexContent>
        \\      <xs:extension base="t:Base">
        \\        <xs:sequence>
        \\          <xs:element name="b" type="xs:string"/>
        \\        </xs:sequence>
        \\      </xs:extension>
        \\    </xs:complexContent>
        \\  </xs:complexType>
        \\</xs:schema>
    ;
    try expectValid(
        schema_source,
        "<root xmlns='urn:t'><a>1</a><b>2</b></root>",
    );
    try expectInvalid(
        schema_source,
        "<root xmlns='urn:t'><b>2</b><a>1</a></root>",
    );
}

test "XSD validates choice and all particles" {
    const choice_schema =
        \\<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema">
        \\  <xs:element name="root">
        \\    <xs:complexType>
        \\      <xs:choice>
        \\        <xs:element name="a" type="xs:string"/>
        \\        <xs:element name="b" type="xs:string"/>
        \\      </xs:choice>
        \\    </xs:complexType>
        \\  </xs:element>
        \\</xs:schema>
    ;
    try expectValid(choice_schema, "<root><a>x</a></root>");
    try expectValid(choice_schema, "<root><b>x</b></root>");
    try expectInvalid(choice_schema, "<root><a>x</a><b>y</b></root>");
    try expectInvalid(choice_schema, "<root/>");

    const all_schema =
        \\<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema">
        \\  <xs:element name="root">
        \\    <xs:complexType>
        \\      <xs:all>
        \\        <xs:element name="a" type="xs:string"/>
        \\        <xs:element name="b" type="xs:string"/>
        \\      </xs:all>
        \\    </xs:complexType>
        \\  </xs:element>
        \\</xs:schema>
    ;
    try expectValid(all_schema, "<root><a>x</a><b>y</b></root>");
    try expectValid(all_schema, "<root><b>y</b><a>x</a></root>");
    try expectInvalid(all_schema, "<root><a>x</a></root>");
}

test "XSD validates list and union simple types" {
    const list_schema =
        \\<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema">
        \\  <xs:simpleType name="ints">
        \\    <xs:list itemType="xs:integer"/>
        \\  </xs:simpleType>
        \\  <xs:element name="numbers" type="ints"/>
        \\</xs:schema>
    ;
    try expectValid(list_schema, "<numbers>1 2 3</numbers>");
    try expectInvalid(list_schema, "<numbers>1 x 3</numbers>");

    const union_schema =
        \\<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema">
        \\  <xs:simpleType name="value">
        \\    <xs:union memberTypes="xs:integer xs:boolean"/>
        \\  </xs:simpleType>
        \\  <xs:element name="value" type="value"/>
        \\</xs:schema>
    ;
    try expectValid(union_schema, "<value>42</value>");
    try expectValid(union_schema, "<value>true</value>");
    try expectInvalid(union_schema, "<value>hello</value>");
}

test "XSD validates optional and prohibited attributes" {
    const schema_source =
        \\<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema">
        \\  <xs:element name="root">
        \\    <xs:complexType>
        \\      <xs:attribute name="a" type="xs:string"/>
        \\      <xs:attribute name="b" type="xs:string" use="required"/>
        \\      <xs:attribute name="c" type="xs:string" use="prohibited"/>
        \\    </xs:complexType>
        \\  </xs:element>
        \\</xs:schema>
    ;
    try expectValid(schema_source, "<root b='x'/>");
    try expectInvalid(schema_source, "<root a='x'/>");
    try expectInvalid(schema_source, "<root b='x' c='y'/>");
    try expectInvalid(schema_source, "<root b='x' d='y'/>");
}

fn expectSchemaError(source: []const u8) !void {
    var document = try parseDocument(source);
    defer document.deinit();
    if (parse(testing.allocator, &document)) |compiled_value| {
        var compiled = compiled_value;
        compiled.deinit();
        return error.TestUnexpectedResult;
    } else |err| {
        try testing.expect(
            err == error.InvalidSchema or
                err == error.InvalidRegex or
                err == error.OutOfMemory,
        );
    }
}

test "XSD rejects malformed and unsupported schemas" {
    try expectSchemaError(
        "<xs:schema xmlns:xs='http://www.w3.org/2001/XMLSchema'>" ++
            "<xs:element name='a' type='xs:missing'/></xs:schema>",
    );
    try expectSchemaError(
        "<xs:schema xmlns:xs='http://www.w3.org/2001/XMLSchema'>" ++
            "<xs:include schemaLocation='x'/></xs:schema>",
    );
    try expectSchemaError(
        "<xs:schema xmlns:xs='http://www.w3.org/2001/XMLSchema'>" ++
            "<xs:group name='g'/></xs:schema>",
    );
    try expectSchemaError(
        "<xs:schema xmlns:xs='http://www.w3.org/2001/XMLSchema'>" ++
            "<xs:element name='root'><xs:complexType><xs:all>" ++
            "<xs:sequence/></xs:all></xs:complexType></xs:element>" ++
            "</xs:schema>",
    );
    try expectSchemaError(
        "<xs:schema xmlns:xs='http://www.w3.org/2001/XMLSchema'>" ++
            "<xs:element name='root'><xs:complexType><xs:simpleContent>" ++
            "<xs:restriction base='xs:string'/></xs:simpleContent>" ++
            "</xs:complexType></xs:element></xs:schema>",
    );
    try expectSchemaError(
        "<xs:schema xmlns:xs='http://www.w3.org/2001/XMLSchema'>" ++
            "<xs:simpleType name='t'><xs:restriction base='xs:string'>" ++
            "<xs:pattern value='['/></xs:restriction></xs:simpleType>" ++
            "</xs:schema>",
    );
    try expectSchemaError(
        "<xs:schema xmlns:xs='http://www.w3.org/2001/XMLSchema'>" ++
            "<xs:element name='a' type='xs:string'/>" ++
            "<xs:element name='a' type='xs:string'/></xs:schema>",
    );
    try expectSchemaError(
        "<xs:schema xmlns:xs='http://www.w3.org/2001/XMLSchema'>" ++
            "<xs:element ref='missing'/></xs:schema>",
    );
}

test "XSD validates group references" {
    const schema_source =
        \\<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema">
        \\  <xs:group name="pair">
        \\    <xs:sequence>
        \\      <xs:element name="a" type="xs:string"/>
        \\      <xs:element name="b" type="xs:string"/>
        \\    </xs:sequence>
        \\  </xs:group>
        \\  <xs:element name="root">
        \\    <xs:complexType>
        \\      <xs:sequence>
        \\        <xs:group ref="pair" minOccurs="1" maxOccurs="2"/>
        \\      </xs:sequence>
        \\    </xs:complexType>
        \\  </xs:element>
        \\</xs:schema>
    ;
    try expectValid(
        schema_source,
        "<root><a>1</a><b>2</b><a>3</a><b>4</b></root>",
    );
    try expectValid(schema_source, "<root><a>1</a><b>2</b></root>");
    try expectInvalid(schema_source, "<root><a>1</a></root>");
    try expectInvalid(
        schema_source,
        "<root><a>1</a><b>2</b><a>3</a><b>4</b><a>5</a><b>6</b></root>",
    );
}

test "XSD validates attribute group references" {
    const schema_source =
        \\<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema">
        \\  <xs:attributeGroup name="base">
        \\    <xs:attribute name="id" type="xs:integer" use="required"/>
        \\  </xs:attributeGroup>
        \\  <xs:attributeGroup name="common">
        \\    <xs:attributeGroup ref="base"/>
        \\    <xs:attribute name="name" type="xs:string"/>
        \\    <xs:anyAttribute namespace="##any" processContents="skip"/>
        \\  </xs:attributeGroup>
        \\  <xs:element name="root">
        \\    <xs:complexType>
        \\      <xs:attributeGroup ref="common"/>
        \\    </xs:complexType>
        \\  </xs:element>
        \\</xs:schema>
    ;
    try expectValid(schema_source, "<root id='1' name='x' other='y'/>");
    try expectValid(schema_source, "<root id='1'/>");
    try expectInvalid(schema_source, "<root name='x'/>");
    try expectInvalid(schema_source, "<root id='x'/>");
}

test "XSD validates substitution groups and abstract elements" {
    const schema_source =
        \\<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema"
        \\  targetNamespace="urn:t" xmlns:t="urn:t"
        \\  elementFormDefault="qualified">
        \\  <xs:element name="head" abstract="true" type="xs:string"/>
        \\  <xs:element name="member" substitutionGroup="t:head" type="xs:string"/>
        \\  <xs:element name="root">
        \\    <xs:complexType>
        \\      <xs:sequence>
        \\        <xs:element ref="t:head" maxOccurs="unbounded"/>
        \\      </xs:sequence>
        \\    </xs:complexType>
        \\  </xs:element>
        \\</xs:schema>
    ;
    try expectValid(
        schema_source,
        "<root xmlns='urn:t'><member>x</member></root>",
    );
    try expectValid(
        schema_source,
        "<root xmlns='urn:t'><member>x</member><member>y</member></root>",
    );
    try expectInvalid(
        schema_source,
        "<root xmlns='urn:t'><head>x</head></root>",
    );
    try expectInvalid(
        schema_source,
        "<root xmlns='urn:t'><other>x</other></root>",
    );
}

test "XSD validates non-abstract substitution heads" {
    const schema_source =
        \\<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema"
        \\  targetNamespace="urn:t" xmlns:t="urn:t"
        \\  elementFormDefault="qualified">
        \\  <xs:element name="head" type="xs:string"/>
        \\  <xs:element name="member" substitutionGroup="t:head" type="xs:string"/>
        \\  <xs:element name="root">
        \\    <xs:complexType>
        \\      <xs:sequence>
        \\        <xs:element ref="t:head"/>
        \\      </xs:sequence>
        \\    </xs:complexType>
        \\  </xs:element>
        \\</xs:schema>
    ;
    try expectValid(schema_source, "<root xmlns='urn:t'><head>x</head></root>");
    try expectValid(
        schema_source,
        "<root xmlns='urn:t'><member>x</member></root>",
    );
    try expectInvalid(
        schema_source,
        "<root xmlns='urn:t'><other>x</other></root>",
    );
}

test "XSD rejects circular group references" {
    try expectSchemaError(
        "<xs:schema xmlns:xs='http://www.w3.org/2001/XMLSchema'>" ++
            "<xs:group name='items'><xs:sequence>" ++
            "<xs:element name='item' type='xs:string'/>" ++
            "<xs:group ref='items' minOccurs='0'/>" ++
            "</xs:sequence></xs:group>" ++
            "<xs:element name='root'><xs:complexType>" ++
            "<xs:group ref='items'/></xs:complexType></xs:element>" ++
            "</xs:schema>",
    );
}

const key_schema =
    \\<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema">
    \\  <xs:element name="root">
    \\    <xs:complexType>
    \\      <xs:sequence>
    \\        <xs:element name="item" maxOccurs="unbounded">
    \\          <xs:complexType>
    \\            <xs:attribute name="id" type="xs:string" use="required"/>
    \\          </xs:complexType>
    \\        </xs:element>
    \\      </xs:sequence>
    \\    </xs:complexType>
    \\    <xs:key name="itemKey">
    \\      <xs:selector xpath="item"/>
    \\      <xs:field xpath="@id"/>
    \\    </xs:key>
    \\  </xs:element>
    \\</xs:schema>
;

test "XSD validates key uniqueness and presence" {
    try expectValid(key_schema, "<root><item id='a'/><item id='b'/></root>");
    try expectInvalid(key_schema, "<root><item id='a'/><item id='a'/></root>");
    try expectInvalid(key_schema, "<root><item id='a'/><item/></root>");
}

test "XSD validates unique constraints" {
    const schema_source =
        \\<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema">
        \\  <xs:element name="root">
        \\    <xs:complexType>
        \\      <xs:sequence>
        \\        <xs:element name="item" maxOccurs="unbounded">
        \\          <xs:complexType>
        \\            <xs:attribute name="id" type="xs:string"/>
        \\          </xs:complexType>
        \\        </xs:element>
        \\      </xs:sequence>
        \\    </xs:complexType>
        \\    <xs:unique name="itemUnique">
        \\      <xs:selector xpath="item"/>
        \\      <xs:field xpath="@id"/>
        \\    </xs:unique>
        \\  </xs:element>
        \\</xs:schema>
    ;
    try expectValid(
        schema_source,
        "<root><item id='a'/><item/><item id='b'/></root>",
    );
    try expectInvalid(
        schema_source,
        "<root><item id='a'/><item id='a'/></root>",
    );
}

test "XSD validates keyref constraints" {
    const schema_source =
        \\<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema">
        \\  <xs:element name="root">
        \\    <xs:complexType>
        \\      <xs:sequence>
        \\        <xs:element name="item" maxOccurs="unbounded">
        \\          <xs:complexType>
        \\            <xs:attribute name="id" type="xs:string" use="required"/>
        \\          </xs:complexType>
        \\        </xs:element>
        \\        <xs:element name="ref" maxOccurs="unbounded">
        \\          <xs:complexType>
        \\            <xs:attribute name="item" type="xs:string" use="required"/>
        \\          </xs:complexType>
        \\        </xs:element>
        \\      </xs:sequence>
        \\    </xs:complexType>
        \\    <xs:key name="itemKey">
        \\      <xs:selector xpath="item"/>
        \\      <xs:field xpath="@id"/>
        \\    </xs:key>
        \\    <xs:keyref name="itemRef" refer="itemKey">
        \\      <xs:selector xpath="ref"/>
        \\      <xs:field xpath="@item"/>
        \\    </xs:keyref>
        \\  </xs:element>
        \\</xs:schema>
    ;
    try expectValid(
        schema_source,
        "<root><item id='a'/><item id='b'/><ref item='a'/><ref item='b'/></root>",
    );
    try expectInvalid(
        schema_source,
        "<root><item id='a'/><ref item='z'/></root>",
    );
    try expectInvalid(
        schema_source,
        "<root><item id='a'/><ref/></root>",
    );
}

test "XSD validates composite identity constraints" {
    const schema_source =
        \\<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema">
        \\  <xs:element name="root">
        \\    <xs:complexType>
        \\      <xs:sequence>
        \\        <xs:element name="item" maxOccurs="unbounded">
        \\          <xs:complexType>
        \\            <xs:attribute name="a" type="xs:string" use="required"/>
        \\            <xs:attribute name="b" type="xs:string" use="required"/>
        \\          </xs:complexType>
        \\        </xs:element>
        \\      </xs:sequence>
        \\    </xs:complexType>
        \\    <xs:key name="itemKey">
        \\      <xs:selector xpath="item"/>
        \\      <xs:field xpath="@a"/>
        \\      <xs:field xpath="@b"/>
        \\    </xs:key>
        \\  </xs:element>
        \\</xs:schema>
    ;
    try expectValid(
        schema_source,
        "<root><item a='1' b='2'/><item a='1' b='3'/></root>",
    );
    try expectInvalid(
        schema_source,
        "<root><item a='1' b='2'/><item a='1' b='2'/></root>",
    );
}

test "XSD identity constraints select nested nodes" {
    const schema_source =
        \\<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema">
        \\  <xs:element name="root">
        \\    <xs:complexType>
        \\      <xs:sequence>
        \\        <xs:element name="item" maxOccurs="unbounded">
        \\          <xs:complexType>
        \\            <xs:sequence>
        \\              <xs:element name="name" type="xs:string"/>
        \\            </xs:sequence>
        \\          </xs:complexType>
        \\        </xs:element>
        \\      </xs:sequence>
        \\    </xs:complexType>
        \\    <xs:key name="nameKey">
        \\      <xs:selector xpath="item/name"/>
        \\      <xs:field xpath="."/>
        \\    </xs:key>
        \\  </xs:element>
        \\</xs:schema>
    ;
    try expectValid(
        schema_source,
        "<root><item><name>a</name></item><item><name>b</name></item></root>",
    );
    try expectInvalid(
        schema_source,
        "<root><item><name>a</name></item><item><name>a</name></item></root>",
    );
}

const SchemaResource = struct {
    href: []const u8,
    uri: []const u8,
    data: []const u8,
};

const MapResolver = struct {
    resources: []const SchemaResource,
};

fn loadResource(
    context: ?*anyopaque,
    href: []const u8,
    base: []const u8,
) ?Resource {
    _ = base;
    const resolver: *const MapResolver = @ptrCast(@alignCast(context.?));
    for (resolver.resources) |resource| {
        if (std.mem.eql(u8, resource.href, href)) {
            return .{ .uri = resource.uri, .data = resource.data };
        }
    }
    return null;
}

fn expectCompiledValid(compiled: *const Schema, instance: []const u8) !void {
    var document = try parseDocument(instance);
    defer document.deinit();
    var result = try validate(compiled, testing.allocator, &document);
    defer result.deinit();
    try testing.expect(result.isValid());
}

fn expectCompiledInvalid(compiled: *const Schema, instance: []const u8) !void {
    var document = try parseDocument(instance);
    defer document.deinit();
    var result = try validate(compiled, testing.allocator, &document);
    defer result.deinit();
    try testing.expect(!result.isValid());
}

test "XSD includes and imports schema documents" {
    const resources = [_]SchemaResource{
        .{
            .href = "inc.xsd",
            .uri = "inc.xsd",
            .data = "<xs:schema xmlns:xs='http://www.w3.org/2001/XMLSchema'>" ++
                "<xs:complexType name='Root'><xs:sequence>" ++
                "<xs:element name='a' type='xs:string'/>" ++
                "</xs:sequence></xs:complexType></xs:schema>",
        },
        .{
            .href = "other.xsd",
            .uri = "other.xsd",
            .data = "<xs:schema xmlns:xs='http://www.w3.org/2001/XMLSchema' " ++
                "targetNamespace='urn:other'>" ++
                "<xs:complexType name='Other'><xs:sequence>" ++
                "<xs:element name='b' type='xs:string'/>" ++
                "</xs:sequence></xs:complexType></xs:schema>",
        },
    };
    var resolver: MapResolver = .{ .resources = &resources };

    const include_schema =
        \\<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema">
        \\  <xs:include schemaLocation="inc.xsd"/>
        \\  <xs:element name="root" type="Root"/>
        \\</xs:schema>
    ;
    var include_document = try parseDocument(include_schema);
    defer include_document.deinit();
    var included = try parseWithOptions(testing.allocator, &include_document, .{
        .resolver = .{ .context = &resolver, .load = loadResource },
        .base = "main.xsd",
    });
    defer included.deinit();
    try expectCompiledValid(&included, "<root><a>x</a></root>");
    try expectCompiledInvalid(&included, "<root><b>x</b></root>");

    const import_schema =
        \\<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema"
        \\  targetNamespace="urn:t" xmlns:t="urn:t" xmlns:o="urn:other"
        \\  elementFormDefault="qualified">
        \\  <xs:import namespace="urn:other" schemaLocation="other.xsd"/>
        \\  <xs:element name="root" type="o:Other"/>
        \\</xs:schema>
    ;
    var import_document = try parseDocument(import_schema);
    defer import_document.deinit();
    var imported = try parseWithOptions(testing.allocator, &import_document, .{
        .resolver = .{ .context = &resolver, .load = loadResource },
        .base = "main.xsd",
    });
    defer imported.deinit();
    try expectCompiledValid(
        &imported,
        "<root xmlns='urn:t'><b xmlns=''>x</b></root>",
    );
    try expectCompiledInvalid(
        &imported,
        "<root xmlns='urn:t'><a xmlns=''>x</a></root>",
    );
}

test "XSD chameleon include adopts the including namespace" {
    const resources = [_]SchemaResource{
        .{
            .href = "chameleon.xsd",
            .uri = "chameleon.xsd",
            .data = "<xs:schema xmlns:xs='http://www.w3.org/2001/XMLSchema'>" ++
                "<xs:complexType name='Base'><xs:sequence>" ++
                "<xs:element name='a' type='xs:string'/>" ++
                "</xs:sequence></xs:complexType>" ++
                "<xs:complexType name='Derived'><xs:complexContent>" ++
                "<xs:extension base='Base'><xs:sequence>" ++
                "<xs:element name='b' type='xs:string'/>" ++
                "</xs:sequence></xs:extension></xs:complexContent>" ++
                "</xs:complexType></xs:schema>",
        },
    };
    var resolver: MapResolver = .{ .resources = &resources };
    const schema_source =
        \\<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema"
        \\  targetNamespace="urn:t" xmlns:t="urn:t"
        \\  elementFormDefault="qualified">
        \\  <xs:include schemaLocation="chameleon.xsd"/>
        \\  <xs:element name="root" type="t:Derived"/>
        \\</xs:schema>
    ;
    var schema_document = try parseDocument(schema_source);
    defer schema_document.deinit();
    var compiled = try parseWithOptions(testing.allocator, &schema_document, .{
        .resolver = .{ .context = &resolver, .load = loadResource },
        .base = "main.xsd",
    });
    defer compiled.deinit();
    try expectCompiledValid(
        &compiled,
        "<root xmlns='urn:t'><a xmlns=''>x</a><b xmlns=''>y</b></root>",
    );
    try expectCompiledInvalid(
        &compiled,
        "<root xmlns='urn:t'><a xmlns=''>x</a></root>",
    );
}

test "XSD rejects circular and missing schema includes" {
    const resources = [_]SchemaResource{
        .{
            .href = "a.xsd",
            .uri = "a.xsd",
            .data = "<xs:schema xmlns:xs='http://www.w3.org/2001/XMLSchema'>" ++
                "<xs:include schemaLocation='main.xsd'/></xs:schema>",
        },
        .{
            .href = "main.xsd",
            .uri = "main.xsd",
            .data = "<xs:schema xmlns:xs='http://www.w3.org/2001/XMLSchema'>" ++
                "<xs:include schemaLocation='a.xsd'/></xs:schema>",
        },
    };
    var resolver: MapResolver = .{ .resources = &resources };
    const schema_source =
        "<xs:schema xmlns:xs='http://www.w3.org/2001/XMLSchema'>" ++
        "<xs:include schemaLocation='a.xsd'/></xs:schema>";
    var schema_document = try parseDocument(schema_source);
    defer schema_document.deinit();
    try testing.expectError(
        error.InvalidSchema,
        parseWithOptions(testing.allocator, &schema_document, .{
            .resolver = .{ .context = &resolver, .load = loadResource },
            .base = "main.xsd",
        }),
    );

    const missing =
        "<xs:schema xmlns:xs='http://www.w3.org/2001/XMLSchema'>" ++
        "<xs:include schemaLocation='missing.xsd'/></xs:schema>";
    var missing_document = try parseDocument(missing);
    defer missing_document.deinit();
    try testing.expectError(
        error.InvalidSchema,
        parseWithOptions(testing.allocator, &missing_document, .{
            .resolver = .{ .context = &resolver, .load = loadResource },
            .base = "main.xsd",
        }),
    );
}

const abstract_type_schema =
    \\<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema"
    \\  targetNamespace="urn:t" xmlns:t="urn:t"
    \\  elementFormDefault="qualified">
    \\  <xs:complexType name="base" abstract="true">
    \\    <xs:sequence><xs:element name="a" type="xs:string"/></xs:sequence>
    \\  </xs:complexType>
    \\  <xs:complexType name="concrete">
    \\    <xs:complexContent><xs:extension base="t:base">
    \\      <xs:sequence><xs:element name="b" type="xs:string"/></xs:sequence>
    \\    </xs:extension></xs:complexContent>
    \\  </xs:complexType>
    \\  <xs:element name="root" type="t:base"/>
    \\</xs:schema>
;

test "XSD rejects abstract types without substitution" {
    try expectInvalid(
        abstract_type_schema,
        "<root xmlns='urn:t'><a>x</a></root>",
    );
    try expectInvalid(
        abstract_type_schema,
        "<root xmlns='urn:t' xmlns:t='urn:t'" ++
            " xmlns:xsi='http://www.w3.org/2001/XMLSchema-instance'" ++
            " xsi:type='t:base'><a>x</a></root>",
    );
    try expectValid(
        abstract_type_schema,
        "<root xmlns='urn:t' xmlns:t='urn:t'" ++
            " xmlns:xsi='http://www.w3.org/2001/XMLSchema-instance'" ++
            " xsi:type='t:concrete'><a>x</a><b>y</b></root>",
    );
}

test "XSD checks xsi:type derivation validity" {
    const schema_source =
        "<xs:schema xmlns:xs='http://www.w3.org/2001/XMLSchema' " ++
        "targetNamespace='urn:t' xmlns:t='urn:t' " ++
        "elementFormDefault='qualified'>" ++
        "<xs:element name='root' type='xs:string'/>" ++
        "</xs:schema>";
    try expectValid(
        schema_source,
        "<root xmlns='urn:t' xmlns:xs='http://www.w3.org/2001/XMLSchema' " ++
            "xmlns:xsi='http://www.w3.org/2001/XMLSchema-instance' " ++
            "xsi:type='xs:token'>x</root>",
    );
    try expectInvalid(
        schema_source,
        "<root xmlns='urn:t' xmlns:xs='http://www.w3.org/2001/XMLSchema' " ++
            "xmlns:xsi='http://www.w3.org/2001/XMLSchema-instance' " ++
            "xsi:type='xs:int'>1</root>",
    );
}

const block_schema =
    \\<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema"
    \\  targetNamespace="urn:t" xmlns:t="urn:t"
    \\  elementFormDefault="qualified">
    \\  <xs:complexType name="base">
    \\    <xs:sequence><xs:element name="a" type="xs:string"/></xs:sequence>
    \\  </xs:complexType>
    \\  <xs:complexType name="derived">
    \\    <xs:complexContent><xs:extension base="t:base">
    \\      <xs:sequence><xs:element name="b" type="xs:string"/></xs:sequence>
    \\    </xs:extension></xs:complexContent>
    \\  </xs:complexType>
    \\  <xs:element name="root" type="t:base" block="extension"/>
    \\</xs:schema>
;

test "XSD enforces element block on xsi:type" {
    try expectInvalid(
        block_schema,
        "<root xmlns='urn:t' xmlns:t='urn:t'" ++
            " xmlns:xsi='http://www.w3.org/2001/XMLSchema-instance'" ++
            " xsi:type='t:derived'><a>x</a><b>y</b></root>",
    );
    try expectValid(
        block_schema,
        "<root xmlns='urn:t'><a>x</a></root>",
    );
}

test "XSD rejects substitution members with underived types" {
    const schema_source =
        "<xs:schema xmlns:xs='http://www.w3.org/2001/XMLSchema' " ++
        "targetNamespace='urn:t' xmlns:t='urn:t' " ++
        "elementFormDefault='qualified'>" ++
        "<xs:element name='head' type='xs:string'/>" ++
        "<xs:element name='member' substitutionGroup='t:head' " ++
        "type='xs:int'/>" ++
        "<xs:element name='root'><xs:complexType><xs:sequence>" ++
        "<xs:element ref='t:head'/></xs:sequence></xs:complexType>" ++
        "</xs:element></xs:schema>";
    try expectSchemaError(schema_source);
}

test "XSD rejects substitution excluded by final" {
    const schema_source =
        "<xs:schema xmlns:xs='http://www.w3.org/2001/XMLSchema' " ++
        "targetNamespace='urn:t' xmlns:t='urn:t' " ++
        "elementFormDefault='qualified'>" ++
        "<xs:complexType name='base'><xs:sequence>" ++
        "<xs:element name='a' type='xs:string'/>" ++
        "</xs:sequence></xs:complexType>" ++
        "<xs:complexType name='derived'><xs:complexContent>" ++
        "<xs:restriction base='t:base'><xs:sequence>" ++
        "<xs:element name='a' type='xs:string'/>" ++
        "</xs:sequence></xs:restriction></xs:complexContent>" ++
        "</xs:complexType>" ++
        "<xs:element name='head' type='t:base' final='restriction'/>" ++
        "<xs:element name='member' substitutionGroup='t:head' " ++
        "type='t:derived'/>" ++
        "<xs:element name='root'><xs:complexType><xs:sequence>" ++
        "<xs:element ref='t:head'/></xs:sequence></xs:complexType>" ++
        "</xs:element></xs:schema>";
    try expectSchemaError(schema_source);
}

test "XSD rejects derivations from final types" {
    const complex_source =
        "<xs:schema xmlns:xs='http://www.w3.org/2001/XMLSchema' " ++
        "targetNamespace='urn:t' xmlns:t='urn:t'>" ++
        "<xs:complexType name='base' final='extension'/>" ++
        "<xs:complexType name='derived'><xs:complexContent>" ++
        "<xs:extension base='t:base'/></xs:complexContent>" ++
        "</xs:complexType></xs:schema>";
    try expectSchemaError(complex_source);

    const simple_source =
        "<xs:schema xmlns:xs='http://www.w3.org/2001/XMLSchema' " ++
        "targetNamespace='urn:t' xmlns:t='urn:t'>" ++
        "<xs:simpleType name='base' final='restriction'>" ++
        "<xs:restriction base='xs:string'/></xs:simpleType>" ++
        "<xs:simpleType name='derived'>" ++
        "<xs:restriction base='t:base'/></xs:simpleType></xs:schema>";
    try expectSchemaError(simple_source);
}

test "XSD enforces block substitution" {
    const schema_source =
        "<xs:schema xmlns:xs='http://www.w3.org/2001/XMLSchema' " ++
        "targetNamespace='urn:t' xmlns:t='urn:t' " ++
        "elementFormDefault='qualified'>" ++
        "<xs:element name='head' type='xs:string' " ++
        "block='substitution'/>" ++
        "<xs:element name='member' substitutionGroup='t:head' " ++
        "type='xs:string'/>" ++
        "<xs:element name='root'><xs:complexType><xs:sequence>" ++
        "<xs:element ref='t:head'/></xs:sequence></xs:complexType>" ++
        "</xs:element></xs:schema>";
    try expectValid(
        schema_source,
        "<root xmlns='urn:t'><head>x</head></root>",
    );
    try expectInvalid(
        schema_source,
        "<root xmlns='urn:t'><member>x</member></root>",
    );
}

test "XSD wildcard namespace lists" {
    const schema_source =
        "<xs:schema xmlns:xs='http://www.w3.org/2001/XMLSchema'>" ++
        "<xs:element name='root'><xs:complexType><xs:sequence>" ++
        "<xs:any namespace='urn:a urn:b' processContents='lax' " ++
        "minOccurs='0' maxOccurs='unbounded'/>" ++
        "</xs:sequence></xs:complexType></xs:element></xs:schema>";
    try expectValid(
        schema_source,
        "<root><a xmlns='urn:a'/><b xmlns='urn:b'/></root>",
    );
    try expectInvalid(schema_source, "<root><c xmlns='urn:c'/></root>");
    try expectInvalid(schema_source, "<root><c/></root>");

    const attribute_schema =
        "<xs:schema xmlns:xs='http://www.w3.org/2001/XMLSchema'>" ++
        "<xs:element name='root'><xs:complexType>" ++
        "<xs:anyAttribute namespace='urn:a urn:b' " ++
        "processContents='lax'/>" ++
        "</xs:complexType></xs:element></xs:schema>";
    try expectValid(
        attribute_schema,
        "<root xmlns:x='urn:a' x:attr='1'/>",
    );
    try expectInvalid(
        attribute_schema,
        "<root xmlns:x='urn:c' x:attr='1'/>",
    );
    try expectInvalid(attribute_schema, "<root attr='1'/>");
}
