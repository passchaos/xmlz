//! XPath 1.0 parser and evaluator.

const std = @import("std");
const ast = @import("ast.zig");
const parser_mod = @import("parser.zig");
const eval_mod = @import("eval.zig");

pub const lexer = @import("lexer.zig");
pub const value = @import("value.zig");

pub const Context = value.Context;
pub const Value = value.Value;
pub const Variable = value.Variable;
pub const NodeRef = value.NodeRef;
pub const AttributeRef = value.AttributeRef;
pub const NamespaceRef = value.NamespaceRef;
pub const Result = value.Result;
pub const parseNumber = value.parseNumber;
pub const formatNumber = value.formatNumber;

pub const Error = parser_mod.Error || eval_mod.Error;

pub const Expression = struct {
    arena: std.heap.ArenaAllocator,
    root: *ast.Expr,

    pub fn parse(allocator: std.mem.Allocator, source: []const u8) Error!Expression {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        var parser = try parser_mod.Parser.init(arena.allocator(), source);
        const root = try parser.parse();
        return .{ .arena = arena, .root = root };
    }

    pub fn deinit(self: *Expression) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn evaluate(
        self: *const Expression,
        allocator: std.mem.Allocator,
        context: *const Context,
    ) Error!Result {
        return eval_mod.evaluate(allocator, self.root, context);
    }
};

test {
    std.testing.refAllDecls(@This());
    _ = lexer;
    _ = value;
}

const testing = std.testing;
const dom = @import("../dom.zig");
const namespace = @import("../namespace.zig");

const TestDocument =
    \\<root xmlns="urn:def" xmlns:p="urn:p">
    \\  <item id="a" price="5"><name>Apple</name></item>
    \\  <item id="b" price="15"><name>Banana</name></item>
    \\  <p:item id="c" price="10"><p:name>Cherry</p:name></p:item>
    \\  <note> hello   world </note>
    \\  <!-- comment -->
    \\  <?pi data?>
    \\</root>
;

const test_namespaces = [_]namespace.Binding{
    .{ .prefix = "d", .uri = "urn:def" },
    .{ .prefix = "p", .uri = "urn:p" },
};

fn testContext(document: *const dom.Document) Context {
    return .{
        .document = document,
        .node = .{ .node = 0 },
        .namespaces = &test_namespaces,
    };
}

fn countOf(document: *const dom.Document, expression: []const u8) !usize {
    var parsed = try Expression.parse(testing.allocator, expression);
    defer parsed.deinit();
    var context = testContext(document);
    var result = try parsed.evaluate(testing.allocator, &context);
    defer result.deinit();
    return switch (result.value) {
        .node_set => |nodes| nodes.len,
        else => error.TestUnexpectedResult,
    };
}

fn stringOf(
    document: *const dom.Document,
    expression: []const u8,
    allocator: std.mem.Allocator,
) ![]const u8 {
    var parsed = try Expression.parse(testing.allocator, expression);
    defer parsed.deinit();
    var context = testContext(document);
    var result = try parsed.evaluate(testing.allocator, &context);
    defer result.deinit();
    return switch (result.value) {
        .string => |text| try allocator.dupe(u8, text),
        else => error.TestUnexpectedResult,
    };
}

fn numberOf(document: *const dom.Document, expression: []const u8) !f64 {
    var parsed = try Expression.parse(testing.allocator, expression);
    defer parsed.deinit();
    var context = testContext(document);
    var result = try parsed.evaluate(testing.allocator, &context);
    defer result.deinit();
    return switch (result.value) {
        .number => |number| number,
        else => error.TestUnexpectedResult,
    };
}

fn boolOf(document: *const dom.Document, expression: []const u8) !bool {
    var parsed = try Expression.parse(testing.allocator, expression);
    defer parsed.deinit();
    var context = testContext(document);
    var result = try parsed.evaluate(testing.allocator, &context);
    defer result.deinit();
    return switch (result.value) {
        .boolean => |boolean| boolean,
        else => error.TestUnexpectedResult,
    };
}

test "XPath location paths axes and predicates" {
    var document = try dom.Document.parse(testing.allocator, TestDocument, .{
        .keep_comments = true,
        .keep_pis = true,
    });
    defer document.deinit();

    try testing.expectEqual(@as(usize, 2), try countOf(&document, "//d:item"));
    try testing.expectEqual(@as(usize, 2), try countOf(&document, "//d:name"));
    try testing.expectEqual(@as(usize, 1), try countOf(&document, "//p:name"));
    try testing.expectEqual(@as(usize, 2), try countOf(&document, "//d:item/@id"));
    try testing.expectEqual(@as(usize, 1), try countOf(&document, "//d:item[@id='b']"));
    try testing.expectEqual(@as(usize, 1), try countOf(&document, "//d:item[@price > 7]"));
    try testing.expectEqual(@as(usize, 1), try countOf(&document, "//p:item[@price = 10]"));
    try testing.expectEqual(@as(usize, 1), try countOf(&document, "//d:item[2]"));
    try testing.expectEqual(@as(usize, 1), try countOf(&document, "//d:item[position() mod 2 = 1]"));
    try testing.expectEqual(@as(usize, 1), try countOf(&document, "//d:item[1]/following-sibling::d:item"));
    try testing.expectEqual(@as(usize, 1), try countOf(&document, "//p:item[@id='c']/ancestor::d:root"));
    try testing.expectEqual(@as(usize, 2), try countOf(&document, "//d:name/parent::d:item"));
    try testing.expectEqual(@as(usize, 4), try countOf(&document, "//d:item | //d:name"));
    try testing.expectEqual(@as(usize, 1), try countOf(&document, "//comment()"));
    try testing.expectEqual(@as(usize, 1), try countOf(&document, "//processing-instruction('pi')"));
    try testing.expectEqual(@as(usize, 3), try countOf(&document, "/d:root/d:item | /d:root/p:item"));
}

test "XPath string number and boolean functions" {
    var document = try dom.Document.parse(testing.allocator, TestDocument, .{
        .keep_comments = true,
        .keep_pis = true,
    });
    defer document.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectEqualStrings(
        "Apple",
        try stringOf(&document, "string(//d:item[@id='a']/d:name)", allocator),
    );
    try testing.expectEqualStrings(
        " hello   world ",
        try stringOf(&document, "string(//d:note)", allocator),
    );
    try testing.expectEqualStrings(
        "hello world",
        try stringOf(&document, "normalize-space(//d:note)", allocator),
    );
    try testing.expectEqualStrings(
        "234",
        try stringOf(&document, "substring('12345', 2, 3)", allocator),
    );
    try testing.expectEqualStrings(
        "BAr",
        try stringOf(&document, "translate('bar', 'abc', 'ABC')", allocator),
    );
    try testing.expectEqualStrings(
        "Banana",
        try stringOf(&document, "string(//d:item[contains(d:name, 'an')]/d:name)", allocator),
    );
    try testing.expectEqualStrings(
        "b",
        try stringOf(&document, "string(//d:item[last()]/@id)", allocator),
    );
    try testing.expectEqualStrings(
        "0.5",
        try stringOf(&document, "string(1 div 2)", allocator),
    );

    try testing.expectEqual(@as(f64, 2), try numberOf(&document, "count(//d:item)"));
    try testing.expectEqual(@as(f64, 20), try numberOf(&document, "sum(//d:item/@price)"));
    try testing.expectEqual(@as(f64, 7), try numberOf(&document, "1 + 2 * 3"));
    try testing.expectEqual(@as(f64, 12.5), try numberOf(&document, "number('  12.5 ')"));
    try testing.expect(std.math.isInf(try numberOf(&document, "1 div 0")));

    try testing.expect(try boolOf(&document, "boolean(//d:item)"));
    try testing.expect(!try boolOf(&document, "boolean(//missing)"));
    try testing.expect(try boolOf(&document, "true()"));
    try testing.expect(!try boolOf(&document, "false()"));
    try testing.expect(try boolOf(&document, "//d:item[@id='a'] = 'Apple' or true()"));
}

test "XPath variables and namespace errors" {
    var document = try dom.Document.parse(testing.allocator, TestDocument, .{
        .keep_comments = true,
        .keep_pis = true,
    });
    defer document.deinit();

    const variables = [_]Variable{
        .{ .name = "x", .value = .{ .number = 41 } },
    };
    var context = testContext(&document);
    context.variables = &variables;

    var parsed = try Expression.parse(testing.allocator, "$x + 1");
    defer parsed.deinit();
    var result = try parsed.evaluate(testing.allocator, &context);
    defer result.deinit();
    try testing.expectEqual(@as(f64, 42), result.value.number);

    var missing = try Expression.parse(testing.allocator, "$missing");
    defer missing.deinit();
    try testing.expectError(
        error.UndefinedVariable,
        missing.evaluate(testing.allocator, &context),
    );

    var unresolved = try Expression.parse(testing.allocator, "//q:item");
    defer unresolved.deinit();
    try testing.expectError(
        error.UndefinedPrefix,
        unresolved.evaluate(testing.allocator, &context),
    );
}

test "XPath axes filters and comparisons" {
    var document = try dom.Document.parse(testing.allocator, TestDocument, .{
        .keep_comments = true,
        .keep_pis = true,
    });
    defer document.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectEqual(@as(usize, 4), try countOf(&document, "//d:item/@*"));
    try testing.expectEqual(@as(usize, 1), try countOf(&document, "//d:item[2]/preceding-sibling::d:item"));
    try testing.expectEqual(@as(usize, 2), try countOf(&document, "//d:item[2]/ancestor-or-self::*"));
    try testing.expectEqual(@as(usize, 2), try countOf(&document, "//d:item[2]/descendant-or-self::*"));
    try testing.expectEqual(@as(usize, 2), try countOf(&document, "//d:item[2]/attribute::*"));
    try testing.expectEqual(@as(usize, 1), try countOf(&document, "//d:item[2]/@id/parent::*"));
    try testing.expectEqual(@as(usize, 1), try countOf(&document, "//d:item[2]/@id/self::node()"));
    try testing.expectEqual(@as(usize, 1), try countOf(&document, "//d:note/text()"));
    try testing.expectEqual(@as(usize, 1), try countOf(&document, "//d:note/node()"));
    try testing.expectEqual(@as(usize, 2), try countOf(&document, "//d:item/*"));
    try testing.expectEqual(@as(usize, 1), try countOf(&document, "(//d:item)[1]"));
    try testing.expectEqual(@as(usize, 1), try countOf(&document, "(//d:item)[last()]"));
    try testing.expectEqual(@as(usize, 3), try countOf(&document, "//d:item | //p:item"));
    try testing.expectEqual(@as(usize, 2), try countOf(&document, "//p:*"));
    try testing.expectEqual(@as(usize, 3), try countOf(&document, "//*[local-name() = 'item']"));
    try testing.expectEqual(@as(usize, 2), try countOf(&document, "//*[namespace-uri() = 'urn:p']"));
    try testing.expectEqual(@as(usize, 2), try countOf(&document, "//d:item[not(@missing)]"));
    try testing.expectEqual(@as(usize, 2), try countOf(&document, "//d:item[@price][@id]"));
    try testing.expectEqual(@as(usize, 2), try countOf(&document, "//d:item[@id='a' or @id='b']"));
    try testing.expectEqual(@as(usize, 1), try countOf(&document, "//d:item[@id='a' and @price=5]"));

    try testing.expectEqual(@as(usize, 1), try countOf(&document, "//d:item[2]/preceding::d:name"));
    try testing.expectEqual(@as(usize, 1), try countOf(&document, "//d:item[1]/following::d:name"));
    try testing.expectEqual(@as(usize, 1), try countOf(&document, "//d:item[2]/@id/following::d:name"));
    try testing.expectEqual(@as(usize, 1), try countOf(&document, "//d:item[2]/@id/preceding::d:name"));
    try testing.expect(try boolOf(&document, "//d:item[@id='a'] = 'Apple'"));
    try testing.expect(try boolOf(&document, "//d:item/@price > 7"));
    try testing.expect(try boolOf(&document, "//d:item/@price = 5"));
    try testing.expect(try boolOf(&document, "//d:item/@id != 'a'"));
    try testing.expect(try boolOf(&document, "//d:item/@id = //d:item/@id"));
    try testing.expect(try boolOf(&document, "true() = 1"));
    try testing.expect(try boolOf(&document, "0 = false()"));
    try testing.expect(try boolOf(&document, "//missing = false()"));
    try testing.expect(!try boolOf(&document, "'a' < 'b'"));

    try testing.expectEqualStrings(
        "a",
        try stringOf(&document, "string((//d:item)[1]/@id)", allocator),
    );
    try testing.expectEqualStrings(
        "b",
        try stringOf(&document, "string((//d:item)[last()]/@id)", allocator),
    );
    try testing.expectEqualStrings(
        "item",
        try stringOf(&document, "local-name(//d:item[1])", allocator),
    );
    try testing.expectEqualStrings(
        "p:item",
        try stringOf(&document, "name(//p:item[1])", allocator),
    );
    try testing.expectEqualStrings(
        "urn:p",
        try stringOf(&document, "namespace-uri(//p:item[1])", allocator),
    );
}

test "XPath core function library edge cases" {
    var document = try dom.Document.parse(testing.allocator, TestDocument, .{});
    defer document.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectEqualStrings(
        "234",
        try stringOf(&document, "substring('12345', 1.5, 2.6)", allocator),
    );
    try testing.expectEqualStrings(
        "12",
        try stringOf(&document, "substring('12345', 0, 3)", allocator),
    );
    try testing.expectEqualStrings(
        "12345",
        try stringOf(&document, "substring('12345', -42, 1 div 0)", allocator),
    );
    try testing.expectEqualStrings(
        "a b",
        try stringOf(&document, "normalize-space('  a  b  ')", allocator),
    );
    try testing.expectEqualStrings(
        "ABAB",
        try stringOf(&document, "translate('abcabc', 'abc', 'AB')", allocator),
    );
    try testing.expectEqualStrings(
        "1999",
        try stringOf(&document, "substring-before('1999/04/01', '/')", allocator),
    );
    try testing.expectEqualStrings(
        "04/01",
        try stringOf(&document, "substring-after('1999/04/01', '/')", allocator),
    );
    try testing.expectEqualStrings(
        "abc",
        try stringOf(&document, "concat('a', 'b', 'c')", allocator),
    );
    try testing.expectEqualStrings(
        "true",
        try stringOf(&document, "string(true())", allocator),
    );
    try testing.expectEqualStrings(
        "NaN",
        try stringOf(&document, "string(0 div 0)", allocator),
    );
    try testing.expectEqualStrings(
        "-Infinity",
        try stringOf(&document, "string(-1 div 0)", allocator),
    );

    try testing.expectEqual(@as(f64, 2), try numberOf(&document, "string-length('é😀')"));
    try testing.expectEqualStrings(
        "",
        try stringOf(&document, "substring('abc', 0 div 0)", allocator),
    );
    try testing.expectEqualStrings(
        "ae",
        try stringOf(&document, "translate('aé', 'é', 'e')", allocator),
    );
    try testing.expectEqualStrings(
        "0.0000001",
        try stringOf(&document, "string(1 div 10000000)", allocator),
    );
    try testing.expectEqual(@as(f64, 1), try numberOf(&document, "floor(1.5)"));
    try testing.expectEqual(@as(f64, 2), try numberOf(&document, "ceiling(1.2)"));
    try testing.expectEqual(@as(f64, 2), try numberOf(&document, "round(1.5)"));
    try testing.expectEqual(@as(f64, -1), try numberOf(&document, "round(-1.5)"));
    try testing.expect(std.math.isNan(try numberOf(&document, "number('1e3')")));

    try testing.expect(try boolOf(&document, "starts-with('abc', 'ab')"));
    try testing.expect(try boolOf(&document, "contains('abc', 'b')"));
    try testing.expect(try boolOf(&document, "boolean('false')"));
}

test "XPath lang and id functions" {
    const source =
        \\<root xml:lang="en-US">
        \\  <item id="alpha" xml:lang="fr">un</item>
        \\  <item id="beta">deux</item>
        \\</root>
    ;
    var document = try dom.Document.parse(testing.allocator, source, .{});
    defer document.deinit();
    const namespaces = [_]namespace.Binding{};
    var context: Context = .{
        .document = &document,
        .node = .{ .node = 0 },
        .namespaces = &namespaces,
    };

    var lang_en = try Expression.parse(testing.allocator, "//item[lang('en')]");
    defer lang_en.deinit();
    var result = try lang_en.evaluate(testing.allocator, &context);
    try testing.expectEqual(@as(usize, 1), result.value.node_set.len);
    result.deinit();

    var lang_fr = try Expression.parse(testing.allocator, "//item[lang('fr')]");
    defer lang_fr.deinit();
    result = try lang_fr.evaluate(testing.allocator, &context);
    try testing.expectEqual(@as(usize, 1), result.value.node_set.len);
    result.deinit();

    var id_expr = try Expression.parse(testing.allocator, "id('beta')");
    defer id_expr.deinit();
    result = try id_expr.evaluate(testing.allocator, &context);
    try testing.expectEqual(@as(usize, 1), result.value.node_set.len);
    try testing.expectEqualStrings(
        "item",
        document.node(result.value.node_set[0].node).name,
    );
    result.deinit();
}

test "XPath namespace axis" {
    var document = try dom.Document.parse(testing.allocator, TestDocument, .{});
    defer document.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectEqual(@as(usize, 3), try countOf(&document, "/d:root/namespace::*"));
    try testing.expectEqual(@as(usize, 3), try countOf(&document, "/d:root/namespace::node()"));
    try testing.expectEqual(@as(usize, 1), try countOf(&document, "/d:root/namespace::p"));
    try testing.expectEqual(@as(usize, 1), try countOf(&document, "/d:root/namespace::xml"));
    try testing.expectEqual(@as(usize, 0), try countOf(&document, "/d:root/namespace::q"));
    try testing.expectEqual(@as(usize, 1), try countOf(&document, "//d:item[1]/namespace::p"));
    try testing.expectEqual(@as(usize, 1), try countOf(&document, "/d:root/namespace::p/parent::d:root"));

    try testing.expectEqualStrings(
        "urn:def",
        try stringOf(&document, "string(/d:root/namespace::*)", allocator),
    );
    try testing.expectEqualStrings(
        "urn:p",
        try stringOf(&document, "string(/d:root/namespace::p)", allocator),
    );
    try testing.expectEqualStrings(
        "p",
        try stringOf(&document, "name(/d:root/namespace::p)", allocator),
    );
    try testing.expectEqualStrings(
        "p",
        try stringOf(&document, "local-name(/d:root/namespace::p)", allocator),
    );
    try testing.expectEqualStrings(
        "",
        try stringOf(&document, "namespace-uri(/d:root/namespace::p)", allocator),
    );
    try testing.expectEqualStrings(
        namespace.xml_uri,
        try stringOf(&document, "string(/d:root/namespace::xml)", allocator),
    );
    try testing.expectEqualStrings(
        "",
        try stringOf(&document, "name(/d:root/namespace::*)", allocator),
    );

    // Nearest declaration wins over an ancestor binding.
    var shadow = try dom.Document.parse(
        testing.allocator,
        "<a xmlns='urn:a' xmlns:p='urn:one'><b xmlns:p='urn:two'><c/></b></a>",
        .{},
    );
    defer shadow.deinit();
    try testing.expectEqual(@as(usize, 3), try countOf(&shadow, "/*/namespace::*"));
    try testing.expectEqual(@as(usize, 3), try countOf(&shadow, "/*/*/namespace::*"));
    try testing.expectEqualStrings(
        "urn:one",
        try stringOf(&shadow, "string(/*/namespace::p)", allocator),
    );
    try testing.expectEqualStrings(
        "urn:two",
        try stringOf(&shadow, "string(/*/*/namespace::p)", allocator),
    );
    try testing.expectEqualStrings(
        "urn:two",
        try stringOf(&shadow, "string(/*/*/*/namespace::p)", allocator),
    );

    // XML 1.1 prefix undeclaration shadows an outer binding without
    // producing a namespace node.
    var undeclared = try dom.Document.parse(
        testing.allocator,
        "<?xml version='1.1'?><a xmlns:p='urn:p'><b xmlns:p=''><c/></b></a>",
        .{},
    );
    defer undeclared.deinit();
    try testing.expectEqual(@as(usize, 2), try countOf(&undeclared, "/*/namespace::*"));
    try testing.expectEqual(@as(usize, 1), try countOf(&undeclared, "/*/*/namespace::*"));
    try testing.expectEqual(@as(usize, 0), try countOf(&undeclared, "/*/*/namespace::p"));
    try testing.expectEqualStrings(
        namespace.xml_uri,
        try stringOf(&undeclared, "string(/*/*/*/namespace::*)", allocator),
    );

    // Namespace nodes have no children, attributes, or siblings.
    try testing.expectEqual(@as(usize, 0), try countOf(&document, "/d:root/namespace::p/child::node()"));
    try testing.expectEqual(@as(usize, 0), try countOf(&document, "/d:root/namespace::p/attribute::*"));
    try testing.expectEqual(@as(usize, 0), try countOf(&document, "/d:root/namespace::p/following-sibling::*"));
    try testing.expectEqual(@as(usize, 0), try countOf(&document, "/d:root/namespace::p/preceding-sibling::*"));
    try testing.expectEqual(@as(usize, 0), try countOf(&document, "//d:item[1]/@id/namespace::*"));
}

test "XPath parser rejects malformed expressions" {
    const invalid = [_][]const u8{
        "",
        "//",
        "1 +",
        "$",
        "a[",
        "a::",
        "a/",
        "1 2",
        "a[@x=]",
    };
    for (invalid) |source| {
        try testing.expectError(
            error.InvalidExpression,
            Expression.parse(testing.allocator, source),
        );
    }

    var document = try dom.Document.parse(testing.allocator, "<a/>", .{});
    defer document.deinit();
    var context: Context = .{ .document = &document, .node = .{ .node = 0 } };
    var parsed = try Expression.parse(testing.allocator, "unknown-function()");
    defer parsed.deinit();
    try testing.expectError(
        error.UnknownFunction,
        parsed.evaluate(testing.allocator, &context),
    );
}
