//! XSLT 1.0 transformation over `dom.Document`.

const std = @import("std");
const dom = @import("../dom.zig");
const compile = @import("compile.zig");
const transform_mod = @import("transform.zig");

pub const Stylesheet = compile.Stylesheet;
pub const Options = compile.Options;
pub const Resolver = compile.Resolver;
pub const Resource = compile.Resource;
pub const Result = transform_mod.Result;
pub const Output = compile.Output;
pub const OutputMethod = compile.OutputMethod;
pub const Error = compile.Error || transform_mod.Error;
pub const xsl_namespace = compile.xsl_namespace;

/// Compile an XSLT stylesheet document without external includes or imports.
pub fn parse(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
) Error!Stylesheet {
    return compile.compile(allocator, document);
}

/// Compile a stylesheet, resolving `xsl:include` and `xsl:import` through the
/// supplied resolver.
pub fn parseWithOptions(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
    options: Options,
) Error!Stylesheet {
    return compile.compileWithOptions(allocator, document, options);
}

/// Apply a compiled stylesheet to a source document.
pub fn apply(
    stylesheet: *const Stylesheet,
    source: *const dom.Document,
    options: Options,
) Error!Result {
    return transform_mod.apply(
        stylesheet.arena.child_allocator,
        stylesheet,
        source,
        options,
    );
}

/// Compile and apply a stylesheet in one call.
pub fn transform(
    allocator: std.mem.Allocator,
    stylesheet_document: *const dom.Document,
    source_document: *const dom.Document,
    options: Options,
) Error!Result {
    var stylesheet = try parseWithOptions(
        allocator,
        stylesheet_document,
        options,
    );
    defer stylesheet.deinit();
    return apply(&stylesheet, source_document, options);
}

const testing = std.testing;

fn parseDocument(source: []const u8) !dom.Document {
    return dom.Document.parse(testing.allocator, source, .{
        .keep_comments = true,
        .keep_pis = true,
    });
}

fn transformToString(
    stylesheet_source: []const u8,
    source: []const u8,
    options: Options,
) ![]u8 {
    var stylesheet_document = try parseDocument(stylesheet_source);
    defer stylesheet_document.deinit();
    var source_document = try parseDocument(source);
    defer source_document.deinit();
    var result = try transform(
        testing.allocator,
        &stylesheet_document,
        &source_document,
        options,
    );
    defer result.deinit();
    return result.toOwnedSlice(testing.allocator);
}

test "XSLT applies templates and value-of" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:template match="/">
        \\    <out><xsl:apply-templates select="root/item"/></out>
        \\  </xsl:template>
        \\  <xsl:template match="item">
        \\    <item id="{@id}"><xsl:value-of select="name"/></item>
        \\  </xsl:template>
        \\</xsl:stylesheet>
    ;
    const source = "<root><item id='a'><name>Apple</name></item><item id='b'><name>Pear</name></item></root>";
    const output = try transformToString(stylesheet, source, .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(
        "<out><item id=\"a\">Apple</item><item id=\"b\">Pear</item></out>",
        output,
    );
}

test "XSLT supports for-each if choose and variables" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:template match="/">
        \\    <xsl:variable name="limit" select="2"/>
        \\    <list><xsl:for-each select="root/n">
        \\      <xsl:sort select="." data-type="number"/>
        \\      <n><xsl:value-of select="."/></n>
        \\      <xsl:if test=". &gt; $limit"><big/></xsl:if>
        \\    </xsl:for-each></list>
        \\  </xsl:template>
        \\</xsl:stylesheet>
    ;
    const source = "<root><n>3</n><n>1</n><n>2</n></root>";
    const output = try transformToString(stylesheet, source, .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(
        "<list><n>1</n><n>2</n><n>3</n><big/></list>",
        output,
    );
}

test "XSLT supports copy-of call-template and parameters" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:template match="/">
        \\    <out><xsl:call-template name="emit">
        \\      <xsl:with-param name="prefix" select="'p-'"/>
        \\    </xsl:call-template></out>
        \\  </xsl:template>
        \\  <xsl:template name="emit">
        \\    <xsl:param name="prefix" select="'x-'"/>
        \\    <xsl:for-each select="root/item">
        \\      <xsl:copy-of select="."/>
        \\      <mark><xsl:value-of select="$prefix"/><xsl:value-of select="@id"/></mark>
        \\    </xsl:for-each>
        \\  </xsl:template>
        \\</xsl:stylesheet>
    ;
    const source = "<root><item id='a'><name>A</name></item></root>";
    const output = try transformToString(stylesheet, source, .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(
        "<out><item id=\"a\"><name>A</name></item><mark>p-a</mark></out>",
        output,
    );
}

test "XSLT text output method" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="text"/>
        \\  <xsl:template match="/"><xsl:value-of select="root/a"/></xsl:template>
        \\</xsl:stylesheet>
    ;
    const source = "<root><a>hello</a></root>";
    const output = try transformToString(stylesheet, source, .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("hello", output);
}

test "XSLT simplified stylesheet" {
    const stylesheet =
        \\<out xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
        \\  xsl:version="1.0"><xsl:value-of select="root/a"/></out>
    ;
    const source = "<root><a>text</a></root>";
    const output = try transformToString(stylesheet, source, .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<out>text</out>",
        output,
    );
}

test "XSLT current function and attribute copying" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:template match="/">
        \\    <out><xsl:for-each select="root/item">
        \\      <i><xsl:value-of select="current()/@id"/></i>
        \\    </xsl:for-each></out>
        \\  </xsl:template>
        \\</xsl:stylesheet>
    ;
    const source = "<root><item id='a'/><item id='b'/></root>";
    const output = try transformToString(stylesheet, source, .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("<out><i>a</i><i>b</i></out>", output);
}

test "XSLT keys index nodes and support lookup" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:key name="byId" match="item" use="@id"/>
        \\  <xsl:template match="/">
        \\    <out>
        \\      <xsl:value-of select="count(key('byId','a'))"/>
        \\      <xsl:for-each select="key('byId','a')">
        \\        <item><xsl:value-of select="@name"/></item>
        \\      </xsl:for-each>
        \\      <xsl:apply-templates select="key('byId','b')"/>
        \\    </out>
        \\  </xsl:template>
        \\  <xsl:template match="item">
        \\    <b><xsl:value-of select="@name"/></b>
        \\  </xsl:template>
        \\</xsl:stylesheet>
    ;
    const source = "<root><item id='a' name='A'/><item id='b' name='B'/></root>";
    const output = try transformToString(stylesheet, source, .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(
        "<out>1<item>A</item><b>B</b></out>",
        output,
    );
}

test "XSLT keys support multiple declarations and node-set values" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:key name="byValue" match="item" use="tag"/>
        \\  <xsl:key name="byValue" match="item" use="@id"/>
        \\  <xsl:template match="/"><out>
        \\    <xsl:value-of select="count(key('byValue','x'))"/>
        \\    <xsl:value-of select="count(key('byValue','y'))"/>
        \\    <xsl:value-of select="count(key('byValue','a'))"/>
        \\    <xsl:value-of select="count(key('byValue','missing'))"/>
        \\  </out></xsl:template>
        \\</xsl:stylesheet>
    ;
    const source =
        "<root><item id='a'><tag>x</tag><tag>y</tag></item>" ++
        "<item id='b'><tag>x</tag></item></root>";
    const output = try transformToString(stylesheet, source, .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("<out>2110</out>", output);
}

test "XSLT keys work in global variables and patterns" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:key name="special" match="item[@kind='x']" use="@id"/>
        \\  <xsl:variable name="found" select="key('special','a')"/>
        \\  <xsl:template match="/"><out>
        \\    <xsl:value-of select="count($found)"/>
        \\    <xsl:value-of select="count(key('special','b'))"/>
        \\  </out></xsl:template>
        \\</xsl:stylesheet>
    ;
    const source =
        "<root><item id='a' kind='x'/><item id='b' kind='y'/></root>";
    const output = try transformToString(stylesheet, source, .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("<out>10</out>", output);
}

const StylesheetResource = struct {
    href: []const u8,
    uri: []const u8,
    data: []const u8,
};

const StylesheetMapResolver = struct {
    resources: []const StylesheetResource,
};

fn loadStylesheet(
    context: ?*anyopaque,
    href: []const u8,
    base: []const u8,
) ?Resource {
    _ = base;
    const resolver: *const StylesheetMapResolver = @ptrCast(@alignCast(context.?));
    for (resolver.resources) |resource| {
        if (std.mem.eql(u8, resource.href, href)) {
            return .{ .uri = resource.uri, .data = resource.data };
        }
    }
    return null;
}

fn transformWithResolver(
    stylesheet_source: []const u8,
    resources: []const StylesheetResource,
    source: []const u8,
    options: Options,
) ![]u8 {
    var resolver: StylesheetMapResolver = .{ .resources = resources };
    var stylesheet_document = try parseDocument(stylesheet_source);
    defer stylesheet_document.deinit();
    var compiled = try parseWithOptions(
        testing.allocator,
        &stylesheet_document,
        .{
            .parameters = options.parameters,
            .resolver = .{
                .context = &resolver,
                .load = loadStylesheet,
            },
            .base = "main.xsl",
        },
    );
    defer compiled.deinit();
    var source_document = try parseDocument(source);
    defer source_document.deinit();
    var result = try apply(&compiled, &source_document, options);
    defer result.deinit();
    return result.toOwnedSlice(testing.allocator);
}

test "XSLT includes named and match templates" {
    const resources = [_]StylesheetResource{
        .{
            .href = "inc.xsl",
            .uri = "inc.xsl",
            .data = "<xsl:stylesheet version='1.0' " ++
                "xmlns:xsl='http://www.w3.org/1999/XSL/Transform'>" ++
                "<xsl:template name='emit'><inc>" ++
                "<xsl:value-of select='.'/></inc></xsl:template>" ++
                "<xsl:template match='item'><match>" ++
                "<xsl:value-of select='@id'/></match></xsl:template>" ++
                "</xsl:stylesheet>",
        },
    };
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:include href="inc.xsl"/>
        \\  <xsl:template match="/"><out>
        \\    <xsl:for-each select="root/a">
        \\      <xsl:call-template name="emit"/>
        \\    </xsl:for-each>
        \\    <xsl:apply-templates select="root/item"/>
        \\  </out></xsl:template>
        \\</xsl:stylesheet>
    ;
    const source = "<root><a>x</a><item id='i'/></root>";
    const output = try transformWithResolver(stylesheet, &resources, source, .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("<out><inc>x</inc><match>i</match></out>", output);
}

test "XSLT import precedence and apply-imports" {
    const resources = [_]StylesheetResource{
        .{
            .href = "base.xsl",
            .uri = "base.xsl",
            .data = "<xsl:stylesheet version='1.0' " ++
                "xmlns:xsl='http://www.w3.org/1999/XSL/Transform'>" ++
                "<xsl:variable name='v' select=\"'imported'\"/>" ++
                "<xsl:template match='item'><xsl:param name='p'/><base>" ++
                "<xsl:value-of select='@id'/>" ++
                "<xsl:value-of select='$p'/>" ++
                "</base></xsl:template>" ++
                "</xsl:stylesheet>",
        },
    };
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:import href="base.xsl"/>
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:template match="/"><out><xsl:value-of select="$v"/>
        \\    <xsl:apply-templates select="root/item"/></out></xsl:template>
        \\  <xsl:template match="item"><main><xsl:value-of select="@id"/>
        \\    <xsl:apply-imports>
        \\      <xsl:with-param name="p" select="'P'"/>
        \\    </xsl:apply-imports></main></xsl:template>
        \\</xsl:stylesheet>
    ;
    const source = "<root><item id='a'/><item id='b'/></root>";
    const output = try transformWithResolver(stylesheet, &resources, source, .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(
        "<out>imported<main>a<base>aP</base></main>" ++
            "<main>b<base>bP</base></main></out>",
        output,
    );
}

test "XSLT nested imports and duplicate includes" {
    const resources = [_]StylesheetResource{
        .{
            .href = "mid.xsl",
            .uri = "mid.xsl",
            .data = "<xsl:stylesheet version='1.0' " ++
                "xmlns:xsl='http://www.w3.org/1999/XSL/Transform'>" ++
                "<xsl:import href='base.xsl'/>" ++
                "</xsl:stylesheet>",
        },
        .{
            .href = "base.xsl",
            .uri = "base.xsl",
            .data = "<xsl:stylesheet version='1.0' " ++
                "xmlns:xsl='http://www.w3.org/1999/XSL/Transform'>" ++
                "<xsl:template match='item'><base/></xsl:template>" ++
                "</xsl:stylesheet>",
        },
        .{
            .href = "shared.xsl",
            .uri = "shared.xsl",
            .data = "<xsl:stylesheet version='1.0' " ++
                "xmlns:xsl='http://www.w3.org/1999/XSL/Transform'>" ++
                "<xsl:template name='shared'><shared/></xsl:template>" ++
                "</xsl:stylesheet>",
        },
    };
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:import href="mid.xsl"/>
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:include href="shared.xsl"/>
        \\  <xsl:template match="/"><out>
        \\    <xsl:call-template name="shared"/>
        \\    <xsl:apply-templates select="root/item"/>
        \\  </out></xsl:template>
        \\</xsl:stylesheet>
    ;
    const source = "<root><item/></root>";
    const output = try transformWithResolver(stylesheet, &resources, source, .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("<out><shared/><base/></out>", output);

    const duplicate =
        "<xsl:stylesheet version='1.0' " ++
        "xmlns:xsl='http://www.w3.org/1999/XSL/Transform'>" ++
        "<xsl:include href='shared.xsl'/>" ++
        "<xsl:include href='shared.xsl'/>" ++
        "</xsl:stylesheet>";
    var duplicate_resolver: StylesheetMapResolver = .{ .resources = &resources };
    var duplicate_document = try parseDocument(duplicate);
    defer duplicate_document.deinit();
    try testing.expectError(
        error.InvalidStylesheet,
        parseWithOptions(testing.allocator, &duplicate_document, .{
            .resolver = .{
                .context = &duplicate_resolver,
                .load = loadStylesheet,
            },
            .base = "main.xsl",
        }),
    );
}

test "XSLT rejects circular and misplaced imports" {
    const circular = [_]StylesheetResource{
        .{
            .href = "a.xsl",
            .uri = "a.xsl",
            .data = "<xsl:stylesheet version='1.0' " ++
                "xmlns:xsl='http://www.w3.org/1999/XSL/Transform'>" ++
                "<xsl:include href='main.xsl'/>" ++
                "</xsl:stylesheet>",
        },
    };
    const stylesheet =
        "<xsl:stylesheet version='1.0' " ++
        "xmlns:xsl='http://www.w3.org/1999/XSL/Transform'>" ++
        "<xsl:include href='a.xsl'/></xsl:stylesheet>";
    var resolver: StylesheetMapResolver = .{ .resources = &circular };
    var document = try parseDocument(stylesheet);
    defer document.deinit();
    try testing.expectError(
        error.InvalidStylesheet,
        parseWithOptions(testing.allocator, &document, .{
            .resolver = .{
                .context = &resolver,
                .load = loadStylesheet,
            },
            .base = "main.xsl",
        }),
    );

    const misplaced =
        "<xsl:stylesheet version='1.0' " ++
        "xmlns:xsl='http://www.w3.org/1999/XSL/Transform'>" ++
        "<xsl:template match='/'/>" ++
        "<xsl:import href='base.xsl'/></xsl:stylesheet>";
    var misplaced_document = try parseDocument(misplaced);
    defer misplaced_document.deinit();
    var base_resolver: StylesheetMapResolver = .{ .resources = &.{} };
    try testing.expectError(
        error.InvalidStylesheet,
        parseWithOptions(testing.allocator, &misplaced_document, .{
            .resolver = .{
                .context = &base_resolver,
                .load = loadStylesheet,
            },
            .base = "main.xsl",
        }),
    );
}

test "XSLT HTML output method" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="html"/>
        \\  <xsl:template match="/"><html><head><title>T</title></head><body>
        \\    <br/><img src="x"/><div/><input checked="checked"/>
        \\    <p>a &amp; b &lt; c</p>
        \\  </body></html></xsl:template>
        \\</xsl:stylesheet>
    ;
    const output = try transformToString(stylesheet, "<root/>", .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(
        "<html><head><title>T</title></head><body>" ++
            "<br><img src=\"x\"><div></div><input checked>" ++
            "<p>a &amp; b &lt; c</p></body></html>",
        output,
    );
}

test "XSLT HTML output keeps script and style raw" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="html"/>
        \\  <xsl:template match="/"><html><body>
        \\    <script>if (a &lt; b) x();</script>
        \\    <style>a &gt; b {}</style>
        \\    <textarea>a &lt; b</textarea>
        \\  </body></html></xsl:template>
        \\</xsl:stylesheet>
    ;
    const output = try transformToString(stylesheet, "<root/>", .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(
        "<html><body><script>if (a < b) x();</script>" ++
            "<style>a > b {}</style><textarea>a &lt; b</textarea>" ++
            "</body></html>",
        output,
    );
}

test "XSLT HTML output minimizes boolean attributes" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="html"/>
        \\  <xsl:template match="/"><html><body>
        \\    <input checked="false" disabled="no" selected=""/>
        \\    <p/>
        \\  </body></html></xsl:template>
        \\</xsl:stylesheet>
    ;
    const output = try transformToString(stylesheet, "<root/>", .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(
        "<html><body><input checked disabled selected><p></p></body></html>",
        output,
    );
}

test "XSLT attribute sets apply to literal and dynamic elements" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:attribute-set name="base">
        \\    <xsl:attribute name="a">1</xsl:attribute>
        \\  </xsl:attribute-set>
        \\  <xsl:attribute-set name="derived" use-attribute-sets="base">
        \\    <xsl:attribute name="b">2</xsl:attribute>
        \\  </xsl:attribute-set>
        \\  <xsl:template match="/"><out>
        \\    <literal xsl:use-attribute-sets="derived"/>
        \\    <xsl:element name="dynamic" use-attribute-sets="base"/>
        \\    <override xsl:use-attribute-sets="base" a="literal"/>
        \\  </out></xsl:template>
        \\</xsl:stylesheet>
    ;
    const output = try transformToString(stylesheet, "<root/>", .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(
        "<out><literal a=\"1\" b=\"2\"/><dynamic a=\"1\"/>" ++
            "<override a=\"literal\"/></out>",
        output,
    );
}

test "XSLT attribute sets support AVTs and multiple sets" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:attribute-set name="first">
        \\    <xsl:attribute name="a">first</xsl:attribute>
        \\    <xsl:attribute name="id"><xsl:value-of select="@id"/></xsl:attribute>
        \\  </xsl:attribute-set>
        \\  <xsl:attribute-set name="second">
        \\    <xsl:attribute name="a">second</xsl:attribute>
        \\  </xsl:attribute-set>
        \\  <xsl:template match="/"><out><xsl:for-each select="root/item">
        \\    <item xsl:use-attribute-sets="first second"/>
        \\  </xsl:for-each></out></xsl:template>
        \\</xsl:stylesheet>
    ;
    const source = "<root><item id='x'/><item id='y'/></root>";
    const output = try transformToString(stylesheet, source, .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(
        "<out><item a=\"second\" id=\"x\"/><item a=\"second\" id=\"y\"/></out>",
        output,
    );
}

test "XSLT rejects circular and invalid attribute sets" {
    const circular =
        "<xsl:stylesheet version='1.0' " ++
        "xmlns:xsl='http://www.w3.org/1999/XSL/Transform'>" ++
        "<xsl:attribute-set name='a' use-attribute-sets='b'/>" ++
        "<xsl:attribute-set name='b' use-attribute-sets='a'/>" ++
        "</xsl:stylesheet>";
    var circular_document = try parseDocument(circular);
    defer circular_document.deinit();
    try testing.expectError(
        error.InvalidStylesheet,
        parse(testing.allocator, &circular_document),
    );

    const invalid =
        "<xsl:stylesheet version='1.0' " ++
        "xmlns:xsl='http://www.w3.org/1999/XSL/Transform'>" ++
        "<xsl:attribute-set name='a'><xsl:text>x</xsl:text>" ++
        "</xsl:attribute-set></xsl:stylesheet>";
    var invalid_document = try parseDocument(invalid);
    defer invalid_document.deinit();
    try testing.expectError(
        error.InvalidStylesheet,
        parse(testing.allocator, &invalid_document),
    );
}

test "XSLT strip-space removes whitespace-only text nodes" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:strip-space elements="*"/>
        \\  <xsl:template match="/"><out>
        \\    <xsl:value-of select="count(//text())"/>
        \\  </out></xsl:template>
        \\</xsl:stylesheet>
    ;
    const output = try transformToString(
        stylesheet,
        "<root> <item> <a>x</a> </item> </root>",
        .{},
    );
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("<out>1</out>", output);
}

test "XSLT strip-space honors element tests and preserve-space" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:strip-space elements="*"/>
        \\  <xsl:preserve-space elements="pre"/>
        \\  <xsl:template match="/"><out>
        \\    <xsl:value-of select="count(//text())"/>
        \\  </out></xsl:template>
        \\</xsl:stylesheet>
    ;
    const output = try transformToString(
        stylesheet,
        "<root> <pre> <a/> </pre> <other> <b/> </other> </root>",
        .{},
    );
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("<out>2</out>", output);

    const specific =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:strip-space elements="item"/>
        \\  <xsl:template match="/"><out>
        \\    <xsl:value-of select="count(//text())"/>
        \\  </out></xsl:template>
        \\</xsl:stylesheet>
    ;
    const specific_output = try transformToString(
        specific,
        "<root> <item> <a>x</a> </item> </root>",
        .{},
    );
    defer testing.allocator.free(specific_output);
    try testing.expectEqualStrings("<out>3</out>", specific_output);
}

test "XSLT strip-space honors namespaces" {
    const namespaced =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
        \\  xmlns:p="urn:p">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:strip-space elements="p:item"/>
        \\  <xsl:template match="/"><out>
        \\    <xsl:value-of select="count(//text())"/>
        \\  </out></xsl:template>
        \\</xsl:stylesheet>
    ;
    const namespaced_output = try transformToString(
        namespaced,
        "<root xmlns:p='urn:p'> <p:item> <a/> </p:item> </root>",
        .{},
    );
    defer testing.allocator.free(namespaced_output);
    try testing.expectEqualStrings(
        "<out xmlns:p=\"urn:p\">2</out>",
        namespaced_output,
    );

    const preserved =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:strip-space elements="*"/>
        \\  <xsl:template match="/"><out>
        \\    <xsl:value-of select="count(//text())"/>
        \\  </out></xsl:template>
        \\</xsl:stylesheet>
    ;
    const preserved_output = try transformToString(
        preserved,
        "<root> <pre xml:space='preserve'> <a/> </pre> </root>",
        .{},
    );
    defer testing.allocator.free(preserved_output);
    try testing.expectEqualStrings("<out>0</out>", preserved_output);
}

test "XSLT strip-space affects copy-of output" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:strip-space elements="*"/>
        \\  <xsl:template match="/"><out>
        \\    <xsl:copy-of select="root"/>
        \\  </out></xsl:template>
        \\</xsl:stylesheet>
    ;
    const output = try transformToString(
        stylesheet,
        "<root> <a> x </a> </root>",
        .{},
    );
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(
        "<out><root><a> x </a></root></out>",
        output,
    );
}
