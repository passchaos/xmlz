//! XML Schema validation.

const std = @import("std");
const dom = @import("../dom.zig");

pub const regex = @import("regex.zig");
pub const datatypes = @import("datatypes.zig");
pub const schema = @import("schema.zig");
pub const validate_mod = @import("validate.zig");

pub const Schema = schema.Schema;
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
