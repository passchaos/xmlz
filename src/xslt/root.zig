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

test "XSLT xsl:number supports levels and count patterns" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:template match="/"><out>
        \\    <xsl:for-each select="//item">
        \\      <n><xsl:number level="single" count="*"/></n>
        \\    </xsl:for-each>
        \\    <xsl:for-each select="//item">
        \\      <m><xsl:number level="multiple" count="sec|item" format="1.1"/></m>
        \\    </xsl:for-each>
        \\    <xsl:for-each select="//item">
        \\      <a><xsl:number level="any" count="item"/></a>
        \\    </xsl:for-each>
        \\  </out></xsl:template>
        \\</xsl:stylesheet>
    ;
    const source = "<doc><sec><item/><item/></sec><sec><item/></sec></doc>";
    const output = try transformToString(stylesheet, source, .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(
        "<out><n>1</n><n>2</n><n>1</n>" ++
            "<m>1.1</m><m>1.2</m><m>2.1</m>" ++
            "<a>1</a><a>2</a><a>3</a></out>",
        output,
    );
}

test "XSLT xsl:number numbers matching ancestors and resets at from" {
    const ancestor =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:template match="/"><out>
        \\    <xsl:apply-templates select="//name"/>
        \\  </out></xsl:template>
        \\  <xsl:template match="name">
        \\    <n><xsl:number count="item"/></n>
        \\  </xsl:template>
        \\</xsl:stylesheet>
    ;
    const ancestor_output = try transformToString(
        ancestor,
        "<root><item><name>A</name></item><x/><item><name>B</name></item>" ++
            "<item><name>C</name></item></root>",
        .{},
    );
    defer testing.allocator.free(ancestor_output);
    try testing.expectEqualStrings(
        "<out><n>1</n><n>2</n><n>3</n></out>",
        ancestor_output,
    );

    const resets =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:template match="/"><out>
        \\    <xsl:for-each select="//item">
        \\      <s><xsl:number level="single" count="item" from="sec"/></s>
        \\      <m><xsl:number level="multiple" count="item" from="sec"/></m>
        \\      <a><xsl:number level="any" count="item" from="sec"/></a>
        \\    </xsl:for-each>
        \\  </out></xsl:template>
        \\</xsl:stylesheet>
    ;
    const reset_output = try transformToString(
        resets,
        "<doc><sec><item/><item/></sec><sec><item/></sec></doc>",
        .{},
    );
    defer testing.allocator.free(reset_output);
    try testing.expectEqualStrings(
        "<out><s>1</s><m>1</m><a>1</a>" ++
            "<s>2</s><m>2</m><a>2</a>" ++
            "<s>1</s><m>1</m><a>1</a></out>",
        reset_output,
    );
}

test "XSLT xsl:number formats numbers" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:template match="/"><out>
        \\    <xsl:number value="3" format="1"/>
        \\    <xsl:number value="3" format="01"/>
        \\    <xsl:number value="3" format="a"/>
        \\    <xsl:number value="3" format="A"/>
        \\    <xsl:number value="3" format="i"/>
        \\    <xsl:number value="3" format="I"/>
        \\    <xsl:number value="3" format="1. "/>
        \\    <xsl:number value="3" format="(1)"/>
        \\    <xsl:number value="3" format="1.1"/>
        \\  </out></xsl:template>
        \\</xsl:stylesheet>
    ;
    const output = try transformToString(stylesheet, "<root/>", .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(
        "<out>303cCiiiIII3. (3)3</out>",
        output,
    );
}

test "XSLT xsl:number omits unmatched counts" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:template match="/"><out>
        \\    <xsl:for-each select="root/item">
        \\      <n><xsl:number level="single" count="none"/></n>
        \\    </xsl:for-each>
        \\  </out></xsl:template>
        \\</xsl:stylesheet>
    ;
    const output = try transformToString(
        stylesheet,
        "<root><item/><item/></root>",
        .{},
    );
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("<out><n/><n/></out>", output);
}

test "XSLT disable-output-escaping emits raw text" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:template match="/"><out>
        \\    <xsl:value-of select="root/html" disable-output-escaping="yes"/>
        \\    <xsl:text disable-output-escaping="yes">&lt;raw/&gt;</xsl:text>
        \\    <escaped><xsl:value-of select="root/html"/></escaped>
        \\  </out></xsl:template>
        \\</xsl:stylesheet>
    ;
    const output = try transformToString(
        stylesheet,
        "<root><html>&lt;b&gt;x&lt;/b&gt;</html></root>",
        .{},
    );
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(
        "<out><b>x</b><raw/><escaped>&lt;b&gt;x&lt;/b&gt;</escaped></out>",
        output,
    );
}

test "XSLT disable-output-escaping works in HTML output" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="html"/>
        \\  <xsl:template match="/"><out>
        \\    <xsl:value-of select="root/html" disable-output-escaping="yes"/>
        \\  </out></xsl:template>
        \\</xsl:stylesheet>
    ;
    const output = try transformToString(
        stylesheet,
        "<root><html>&lt;b&gt;x&lt;/b&gt;</html></root>",
        .{},
    );
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("<out><b>x</b></out>", output);
}

test "XSLT format-number formats patterns" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:template match="/"><out>
        \\    <a><xsl:value-of select="format-number(1234.5, '#,##0.00')"/></a>
        \\    <b><xsl:value-of select="format-number(0.5, '0%')"/></b>
        \\    <c><xsl:value-of select="format-number(-1234.5, '#,##0.00')"/></c>
        \\    <d><xsl:value-of select="format-number(-1234.5, '#,##0.00;(#,##0.00)')"/></d>
        \\    <e><xsl:value-of select="format-number(1234.5, '#,##0.##')"/></e>
        \\    <f><xsl:value-of select="format-number(1234.5, '00000.00')"/></f>
        \\    <g><xsl:value-of select="format-number(0.5, '0‰')"/></g>
        \\    <h><xsl:value-of select="format-number(0.125, '0.00')"/></h>
        \\  </out></xsl:template>
        \\</xsl:stylesheet>
    ;
    const output = try transformToString(stylesheet, "<root/>", .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(
        "<out><a>1,234.50</a><b>50%</b><c>-1,234.50</c>" ++
            "<d>(1,234.50)</d><e>1,234.5</e><f>01234.50</f>" ++
            "<g>500‰</g><h>0.13</h></out>",
        output,
    );
}

test "XSLT format-number handles NaN and infinity" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:template match="/"><out>
        \\    <a><xsl:value-of select="format-number(1 div 0, '$#,##0.00')"/></a>
        \\    <b><xsl:value-of select="format-number(-1 div 0, '$#,##0.00')"/></b>
        \\    <c><xsl:value-of select="format-number(0 div 0, '$#,##0.00')"/></c>
        \\  </out></xsl:template>
        \\</xsl:stylesheet>
    ;
    const output = try transformToString(stylesheet, "<root/>", .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(
        "<out><a>Infinity</a><b>-Infinity</b><c>NaN</c></out>",
        output,
    );
}

test "XSLT format-number uses named decimal formats" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:decimal-format name="eu" decimal-separator=","
        \\    grouping-separator="." minus-sign="~"/>
        \\  <xsl:template match="/"><out>
        \\    <a><xsl:value-of select="format-number(-1234.5, '#.##0,00', 'eu')"/></a>
        \\  </out></xsl:template>
        \\</xsl:stylesheet>
    ;
    const output = try transformToString(stylesheet, "<root/>", .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("<out><a>~1.234,50</a></out>", output);
}

test "XSLT format-number rejects unknown decimal formats" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:template match="/"><out>
        \\    <xsl:value-of select="format-number(1, '0', 'missing')"/>
        \\  </out></xsl:template>
        \\</xsl:stylesheet>
    ;
    try testing.expectError(
        error.InvalidArgument,
        transformToString(stylesheet, "<root/>", .{}),
    );
}

test "XSLT result tree fragments support copy-of and string conversion" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:variable name="v">
        \\    <b><xsl:value-of select="root/x"/></b>
        \\  </xsl:variable>
        \\  <xsl:template match="/"><out>
        \\    <xsl:copy-of select="$v"/>
        \\    <s><xsl:value-of select="$v"/></s>
        \\    <t><xsl:value-of select="string($v)"/></t>
        \\    <f><xsl:value-of select="boolean($v)"/></f>
        \\  </out></xsl:template>
        \\</xsl:stylesheet>
    ;
    const output = try transformToString(
        stylesheet,
        "<root><x>text</x></root>",
        .{},
    );
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(
        "<out><b>text</b><s>text</s><t>text</t><f>true</f></out>",
        output,
    );
}

test "XSLT result tree fragments support multiple nodes and globals" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:variable name="global"><g>global</g></xsl:variable>
        \\  <xsl:template match="/"><out>
        \\    <xsl:variable name="local">pre<a/>post</xsl:variable>
        \\    <xsl:copy-of select="$local"/>
        \\    <xsl:copy-of select="$global"/>
        \\    <xsl:for-each select="root/item">
        \\      <xsl:variable name="item"><i><xsl:value-of select="@id"/></i></xsl:variable>
        \\      <xsl:copy-of select="$item"/>
        \\    </xsl:for-each>
        \\  </out></xsl:template>
        \\</xsl:stylesheet>
    ;
    const output = try transformToString(
        stylesheet,
        "<root><item id='a'/><item id='b'/></root>",
        .{},
    );
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(
        "<out>pre<a/>post<g>global</g><i>a</i><i>b</i></out>",
        output,
    );
}

test "XSLT namespace aliases rewrite literal elements and attributes" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
        \\  xmlns:axsl="urn:alias">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:namespace-alias stylesheet-prefix="axsl" result-prefix="xsl"/>
        \\  <xsl:template match="/"><out xsl:exclude-result-prefixes="axsl">
        \\    <axsl:template match="x"><axsl:text>hi</axsl:text></axsl:template>
        \\  </out></xsl:template>
        \\</xsl:stylesheet>
    ;
    const output = try transformToString(stylesheet, "<root/>", .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(
        "<out><xsl:template xmlns:xsl=\"http://www.w3.org/1999/XSL/Transform\" match=\"x\">" ++
            "<xsl:text>hi</xsl:text>" ++
            "</xsl:template></out>",
        output,
    );
}

test "XSLT namespace aliases rewrite attributes and custom namespaces" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
        \\  xmlns:axsl="urn:alias" xmlns:res="urn:result">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:namespace-alias stylesheet-prefix="axsl" result-prefix="res"/>
        \\  <xsl:template match="/"><out xsl:exclude-result-prefixes="axsl res">
        \\    <axsl:item axsl:a="v"/>
        \\  </out></xsl:template>
        \\</xsl:stylesheet>
    ;
    const output = try transformToString(stylesheet, "<root/>", .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(
        "<out><res:item xmlns:res=\"urn:result\" res:a=\"v\"/></out>",
        output,
    );
}

test "XSLT rejects duplicate namespace aliases" {
    const stylesheet =
        "<xsl:stylesheet version='1.0' " ++
        "xmlns:xsl='http://www.w3.org/1999/XSL/Transform' " ++
        "xmlns:a='urn:a' xmlns:b='urn:b'>" ++
        "<xsl:namespace-alias stylesheet-prefix='a' result-prefix='b'/>" ++
        "<xsl:namespace-alias stylesheet-prefix='a' result-prefix='b'/>" ++
        "</xsl:stylesheet>";
    var document = try parseDocument(stylesheet);
    defer document.deinit();
    try testing.expectError(
        error.InvalidStylesheet,
        parse(testing.allocator, &document),
    );
}

test "XSLT generate-id is stable, unique, and empty for empty node-sets" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:template match="/"><out>
        \\    <same><xsl:value-of select="generate-id(/root) = generate-id(/root)"/></same>
        \\    <diff><xsl:value-of select="generate-id(/root) != generate-id(/root/a)"/></diff>
        \\    <empty><xsl:value-of select="generate-id(/missing) = ''"/></empty>
        \\    <attr><xsl:value-of select="generate-id(/root/a/@x) != generate-id(/root/a)"/></attr>
        \\    <unique><xsl:value-of select="count(//*[generate-id() = generate-id(preceding::*)]) = 0"/></unique>
        \\    <name><xsl:value-of select="starts-with(generate-id(/root), 'id')"/></name>
        \\  </out></xsl:template>
        \\</xsl:stylesheet>
    ;
    const output = try transformToString(
        stylesheet,
        "<root><a x='1'/><a x='2'/></root>",
        .{},
    );
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(
        "<out><same>true</same><diff>true</diff><empty>true</empty>" ++
            "<attr>true</attr><unique>true</unique><name>true</name></out>",
        output,
    );
}

test "XSLT system-property reports version and vendor" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
        \\  xmlns:t="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:template match="/"><out>
        \\    <version><xsl:value-of select="system-property('xsl:version')"/></version>
        \\    <prefixed><xsl:value-of select="system-property('t:version')"/></prefixed>
        \\    <vendor><xsl:value-of select="system-property('xsl:vendor')"/></vendor>
        \\    <url><xsl:value-of select="system-property('xsl:vendor-url')"/></url>
        \\    <unknown><xsl:value-of select="system-property('xsl:unknown')"/></unknown>
        \\    <plain><xsl:value-of select="system-property('version')"/></plain>
        \\  </out></xsl:template>
        \\</xsl:stylesheet>
    ;
    const output = try transformToString(stylesheet, "<root/>", .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(
        "<out><version>1.0</version><prefixed>1.0</prefixed>" ++
            "<vendor>xmlz</vendor>" ++
            "<url>https://github.com/passchaos/xmlz</url>" ++
            "<unknown/><plain/></out>",
        output,
    );
}

test "XSLT element-available and function-available" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
        \\  xmlns:exsl="http://exslt.org/common"
        \\  exclude-result-prefixes="exsl">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:template match="/"><out>
        \\    <instruction><xsl:value-of select="element-available('xsl:apply-templates')"/></instruction>
        \\    <subsidiary><xsl:value-of select="element-available('xsl:sort')"/></subsidiary>
        \\    <not-instruction><xsl:value-of select="element-available('xsl:stylesheet')"/></not-instruction>
        \\    <unprefixed-element><xsl:value-of select="element-available('apply-templates')"/></unprefixed-element>
        \\    <core><xsl:value-of select="function-available('count')"/></core>
        \\    <xslt-plain><xsl:value-of select="function-available('generate-id')"/></xslt-plain>
        \\    <xslt-prefixed><xsl:value-of select="function-available('xsl:generate-id')"/></xslt-prefixed>
        \\    <unknown><xsl:value-of select="function-available('unknown')"/></unknown>
        \\    <extension><xsl:value-of select="function-available('exsl:node-set')"/></extension>
        \\  </out></xsl:template>
        \\</xsl:stylesheet>
    ;
    const output = try transformToString(stylesheet, "<root/>", .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(
        "<out><instruction>true</instruction><subsidiary>true</subsidiary>" ++
            "<not-instruction>false</not-instruction>" ++
            "<unprefixed-element>false</unprefixed-element>" ++
            "<core>true</core><xslt-plain>true</xslt-plain>" ++
            "<xslt-prefixed>true</xslt-prefixed><unknown>false</unknown>" ++
            "<extension>true</extension></out>",
        output,
    );
}

test "XSLT system-property rejects an unbound prefix" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:template match="/">
        \\    <xsl:value-of select="system-property('missing:version')"/>
        \\  </xsl:template>
        \\</xsl:stylesheet>
    ;
    try testing.expectError(
        error.UndefinedPrefix,
        transformToString(stylesheet, "<root/>", .{}),
    );
}

test "XSLT cdata-section-elements wraps text and splits terminators" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
        \\  xmlns:p="urn:p">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"
        \\    cdata-section-elements="out p:a"/>
        \\  <xsl:template match="/"><out>a]]&gt;b<p:a>x&amp;y</p:a><b>plain</b></out></xsl:template>
        \\</xsl:stylesheet>
    ;
    const output = try transformToString(stylesheet, "<root/>", .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(
        "<out xmlns:p=\"urn:p\"><![CDATA[a]]]]><![CDATA[>b]]>" ++
            "<p:a><![CDATA[x&y]]></p:a><b>plain</b></out>",
        output,
    );
}

test "XSLT emits doctype-system and doctype-public" {
    const system =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"
        \\    doctype-system="urn:dtd"/>
        \\  <xsl:template match="/"><out/></xsl:template>
        \\</xsl:stylesheet>
    ;
    const system_output = try transformToString(system, "<root/>", .{});
    defer testing.allocator.free(system_output);
    try testing.expectEqualStrings(
        "<!DOCTYPE out SYSTEM \"urn:dtd\">\n<out/>",
        system_output,
    );

    const public_system =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"
        \\    doctype-public="-//X//Y" doctype-system="urn:dtd"/>
        \\  <xsl:template match="/"><out/></xsl:template>
        \\</xsl:stylesheet>
    ;
    const public_system_output = try transformToString(
        public_system,
        "<root/>",
        .{},
    );
    defer testing.allocator.free(public_system_output);
    try testing.expectEqualStrings(
        "<!DOCTYPE out PUBLIC \"-//X//Y\" \"urn:dtd\">\n<out/>",
        public_system_output,
    );

    const public_only =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"
        \\    doctype-public="-//X//Y"/>
        \\  <xsl:template match="/"><out/></xsl:template>
        \\</xsl:stylesheet>
    ;
    const public_only_output = try transformToString(
        public_only,
        "<root/>",
        .{},
    );
    defer testing.allocator.free(public_only_output);
    try testing.expectEqualStrings(
        "<!DOCTYPE out PUBLIC \"-//X//Y\">\n<out/>",
        public_only_output,
    );
}

test "XSLT emits an HTML doctype" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="html"
        \\    doctype-public="-//W3C//DTD HTML 4.01//EN"
        \\    doctype-system="http://www.w3.org/TR/html4/strict.dtd"/>
        \\  <xsl:template match="/"><html><body><p>hi</p></body></html></xsl:template>
        \\</xsl:stylesheet>
    ;
    const output = try transformToString(stylesheet, "<root/>", .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(
        "<!DOCTYPE html PUBLIC \"-//W3C//DTD HTML 4.01//EN\" " ++
            "\"http://www.w3.org/TR/html4/strict.dtd\">\n" ++
            "<html><body><p>hi</p></body></html>",
        output,
    );
}

fn loadExtraDocument(
    _: ?*anyopaque,
    href: []const u8,
    base: []const u8,
) ?Resource {
    _ = base;
    if (!std.mem.eql(u8, href, "extra.xml")) return null;
    return .{
        .uri = "extra.xml",
        .data = "<items><item>one</item><item>two</item></items>",
    };
}

test "XSLT document('') returns the stylesheet document" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:template match="/"><out>
        \\    <count><xsl:value-of select="count(document(''))"/></count>
        \\    <name><xsl:value-of select="name(document('')/*)"/></name>
        \\    <same><xsl:value-of select="count(document('')) = count(document(''))"/></same>
        \\  </out></xsl:template>
        \\</xsl:stylesheet>
    ;
    const output = try transformToString(stylesheet, "<root/>", .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(
        "<out><count>1</count><name>xsl:stylesheet</name><same>true</same></out>",
        output,
    );
}

test "XSLT document loads and applies templates to external nodes" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:template match="/"><out>
        \\    <count><xsl:value-of select="count(document('extra.xml')/items/item)"/></count>
        \\    <cached><xsl:value-of select="count(document('extra.xml')) = count(document('extra.xml'))"/></cached>
        \\    <apply><xsl:apply-templates select="document('extra.xml')/items/item"/></apply>
        \\  </out></xsl:template>
        \\  <xsl:template match="item"><i><xsl:value-of select="."/></i></xsl:template>
        \\</xsl:stylesheet>
    ;
    const output = try transformToString(stylesheet, "<root/>", .{
        .resolver = .{ .context = null, .load = loadExtraDocument },
    });
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(
        "<out><count>2</count><cached>true</cached><apply><i>one</i><i>two</i></apply></out>",
        output,
    );
}

test "XSLT document reports load failures" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:template match="/">
        \\    <xsl:value-of select="document('missing.xml')"/>
        \\  </xsl:template>
        \\</xsl:stylesheet>
    ;
    try testing.expectError(
        error.InvalidArgument,
        transformToString(stylesheet, "<root/>", .{
            .resolver = .{ .context = null, .load = loadExtraDocument },
        }),
    );
}

test "XSLT unparsed-entity-uri returns system identifiers" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:template match="/"><out>
        \\    <uri><xsl:value-of select="unparsed-entity-uri('logo')"/></uri>
        \\    <none><xsl:value-of select="unparsed-entity-uri('missing')"/></none>
        \\    <parsed><xsl:value-of select="unparsed-entity-uri('e')"/></parsed>
        \\  </out></xsl:template>
        \\</xsl:stylesheet>
    ;
    const source =
        "<!DOCTYPE root [" ++
        "<!NOTATION gif SYSTEM 'image/gif'>" ++
        "<!ENTITY logo SYSTEM 'logo.gif' NDATA gif>" ++
        "<!ENTITY e 'text'>]><root/>";
    const output = try transformToString(stylesheet, source, .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(
        "<out><uri>logo.gif</uri><none/><parsed/></out>",
        output,
    );
}

test "XSLT encodes ISO-8859-1 output with character references" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" encoding="ISO-8859-1"/>
        \\  <xsl:template match="/"><out>caf&#233; &#x20AC;</out></xsl:template>
        \\</xsl:stylesheet>
    ;
    const output = try transformToString(stylesheet, "<root/>", .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(
        "<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>\n" ++
            "<out>caf\xe9 &#8364;</out>",
        output,
    );
}

test "XSLT encodes UTF-16 output with a byte order mark" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"
        \\    encoding="UTF-16"/>
        \\  <xsl:template match="/"><out>A&#233;</out></xsl:template>
        \\</xsl:stylesheet>
    ;
    const output = try transformToString(stylesheet, "<root/>", .{});
    defer testing.allocator.free(output);
    const expected = [_]u8{
        0xFF, 0xFE, '<',  0, 'o', 0, 'u', 0, 't', 0, '>', 0,
        'A',  0,    0xE9, 0, '<', 0, '/', 0, 'o', 0, 'u', 0,
        't',  0,    '>',  0,
    };
    try testing.expectEqualSlices(u8, &expected, output);
}

test "XSLT encodes Windows-1252 output" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"
        \\    encoding="windows-1252"/>
        \\  <xsl:template match="/"><out>&#x20AC;&#x0152;&#x03A9;</out></xsl:template>
        \\</xsl:stylesheet>
    ;
    const output = try transformToString(stylesheet, "<root/>", .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("<out>\x80\x8C&#937;</out>", output);
}

test "XSLT falls back to UTF-8 for unsupported output encodings" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" encoding="x-unknown"/>
        \\  <xsl:template match="/"><out>caf&#233;</out></xsl:template>
        \\</xsl:stylesheet>
    ;
    const output = try transformToString(stylesheet, "<root/>", .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<out>caf\xC3\xA9</out>",
        output,
    );
}

test "XSLT exsl:node-set exposes result tree fragments" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
        \\  xmlns:exsl="http://exslt.org/common"
        \\  exclude-result-prefixes="exsl">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:template match="/">
        \\    <xsl:variable name="v"><items><item>a</item><item>b</item></items></xsl:variable>
        \\    <out>
        \\      <count><xsl:value-of select="count(exsl:node-set($v))"/></count>
        \\      <children><xsl:value-of select="count(exsl:node-set($v)/*)"/></children>
        \\      <items><xsl:value-of select="count(exsl:node-set($v)/items/item)"/></items>
        \\      <first><xsl:value-of select="string(exsl:node-set($v)/items/item[1])"/></first>
        \\      <identity><xsl:value-of select="count(exsl:node-set(/root))"/></identity>
        \\      <twice><xsl:value-of select="count(exsl:node-set(exsl:node-set($v))/items/item)"/></twice>
        \\      <apply><xsl:apply-templates select="exsl:node-set($v)/items/item"/></apply>
        \\    </out>
        \\  </xsl:template>
        \\  <xsl:template match="item"><i><xsl:value-of select="."/></i></xsl:template>
        \\</xsl:stylesheet>
    ;
    const output = try transformToString(stylesheet, "<root/>", .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(
        "<out><count>1</count><children>1</children><items>2</items>" ++
            "<first>a</first><identity>1</identity><twice>2</twice>" ++
            "<apply><i>a</i><i>b</i></apply></out>",
        output,
    );
}

fn loadKeyDocument(
    _: ?*anyopaque,
    href: []const u8,
    base: []const u8,
) ?Resource {
    _ = base;
    if (!std.mem.eql(u8, href, "extra.xml")) return null;
    return .{
        .uri = "extra.xml",
        .data = "<items><item xml:id='a'>A</item>" ++
            "<item xml:id='b'>B</item></items>",
    };
}

test "XSLT key and id stay scoped to the context document" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:key name="k" match="item" use="@xml:id"/>
        \\  <xsl:template match="/"><out>
        \\    <foreign><xsl:for-each select="document('extra.xml')/items/item">
        \\      <n><xsl:value-of select="count(key('k', @xml:id))"/></n>
        \\      <i><xsl:value-of select="count(id(@xml:id))"/></i>
        \\    </xsl:for-each></foreign>
        \\    <local><xsl:value-of select="count(key('k', 'a'))"/></local>
        \\    <localId><xsl:value-of select="count(id('a'))"/></localId>
        \\  </out></xsl:template>
        \\</xsl:stylesheet>
    ;
    const source = "<root><item xml:id='a'>local</item></root>";
    const output = try transformToString(stylesheet, source, .{
        .resolver = .{ .context = null, .load = loadKeyDocument },
    });
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(
        "<out><foreign><n>1</n><i>1</i><n>1</n><i>1</i></foreign>" ++
            "<local>1</local><localId>1</localId></out>",
        output,
    );
}

test "XSLT EXSLT functions return values and node-sets" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
        \\  xmlns:func="http://exslt.org/functions"
        \\  xmlns:f="urn:f"
        \\  extension-element-prefixes="func">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <func:function name="f:fact">
        \\    <xsl:param name="n"/>
        \\    <xsl:choose>
        \\      <xsl:when test="$n &lt;= 1"><func:result select="1"/></xsl:when>
        \\      <xsl:otherwise>
        \\        <func:result select="$n * f:fact($n - 1)"/>
        \\      </xsl:otherwise>
        \\    </xsl:choose>
        \\  </func:function>
        \\  <func:function name="f:box">
        \\    <func:result><box><value>7</value></box></func:result>
        \\  </func:function>
        \\  <func:function name="f:empty"/>
        \\  <xsl:template match="/">
        \\    <out>
        \\      <fact><xsl:value-of select="f:fact(5)"/></fact>
        \\      <avail><xsl:value-of select="function-available('f:fact')"/></avail>
        \\      <copied><xsl:copy-of select="f:box()"/></copied>
        \\      <empty><xsl:value-of select="f:empty()"/></empty>
        \\      <scoped><xsl:variable name="n" select="99"/>
        \\        <xsl:value-of select="f:fact(3)"/></scoped>
        \\    </out>
        \\  </xsl:template>
        \\</xsl:stylesheet>
    ;
    const output = try transformToString(stylesheet, "<root/>", .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(
        "<out xmlns:f=\"urn:f\"><fact>120</fact><avail>true</avail>" ++
            "<copied><box><value>7</value></box></copied>" ++
            "<empty/><scoped>6</scoped></out>",
        output,
    );
}

test "XSLT result tree fragments keep their type but act as node-sets" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
        \\  xmlns:exsl="http://exslt.org/common"
        \\  exclude-result-prefixes="exsl">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:variable name="tree"><a><b>1</b></a></xsl:variable>
        \\  <xsl:template match="/">
        \\    <out><xsl:value-of select="exsl:object-type($tree)"/>|</out><xsl:value-of select="count(exsl:node-set($tree)/a/b)"/>|<xsl:value-of select="$tree/a/b"/>
        \\  </xsl:template>
        \\</xsl:stylesheet>
    ;
    const output = try transformToString(stylesheet, "<root/>", .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("<out>RTF|</out>1|1", output);
}

test "XSLT element-available reports EXSLT extension instructions" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
        \\  xmlns:func="http://exslt.org/functions"
        \\  xmlns:f="urn:f"
        \\  extension-element-prefixes="func"
        \\  exclude-result-prefixes="func f">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <func:function name="f:noop"/>
        \\  <xsl:template match="/">
        \\    <out><xsl:value-of select="element-available('func:result')"/>|<xsl:value-of select="element-available('func:function')"/></out>
        \\  </xsl:template>
        \\</xsl:stylesheet>
    ;
    const output = try transformToString(stylesheet, "<root/>", .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("<out>true|false</out>", output);
}

test "XSLT parameters pass through built-in template rules" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"/>
        \\  <xsl:template match="/">
        \\    <xsl:apply-templates select="root/wrap">
        \\      <xsl:with-param name="p">passed</xsl:with-param>
        \\    </xsl:apply-templates>
        \\  </xsl:template>
        \\  <xsl:template match="item">
        \\    <xsl:param name="p"/>
        \\    <out><xsl:value-of select="$p"/></out>
        \\  </xsl:template>
        \\</xsl:stylesheet>
    ;
    const output = try transformToString(
        stylesheet,
        "<root><wrap><item/></wrap></root>",
        .{},
    );
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("<out>passed</out>", output);
}

test "XSLT output honors version and standalone" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" version="1.1" standalone="yes"/>
        \\  <xsl:template match="/"><out/></xsl:template>
        \\</xsl:stylesheet>
    ;
    const output = try transformToString(stylesheet, "<root/>", .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(
        "<?xml version=\"1.1\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<out/>",
        output,
    );
}

test "XSLT merges adjacent text into one CDATA section" {
    const stylesheet =
        \\<xsl:stylesheet version="1.0"
        \\  xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
        \\  <xsl:output method="xml" omit-xml-declaration="yes"
        \\    cdata-section-elements="x"/>
        \\  <xsl:template match="/">
        \\    <x><xsl:text>a</xsl:text><xsl:value-of select="'b'"/></x>
        \\  </xsl:template>
        \\</xsl:stylesheet>
    ;
    const output = try transformToString(stylesheet, "<root/>", .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("<x><![CDATA[ab]]></x>", output);
}
