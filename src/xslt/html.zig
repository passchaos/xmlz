//! HTML serialization for the `html` output method, including the
//! libxslt-compatible formatting rules.

const std = @import("std");
const dom = @import("../dom.zig");

pub fn writeHtmlNode(
    out: *std.Io.Writer,
    document: *const dom.Document,
    id: dom.NodeId,
    raw_text: bool,
    charset: []const u8,
    format: bool,
    compat: bool,
    default_ns: []const u8,
) std.Io.Writer.Error!void {
    const node_value = document.node(id);
    switch (node_value.kind) {
        .document => {
            var child = node_value.first_child;
            while (child != dom.null_node) : (child = document.node(child).next_sibling) {
                try writeHtmlNode(
                    out,
                    document,
                    child,
                    false,
                    charset,
                    format,
                    compat,
                    "",
                );
            }
            if (compat) try out.writeByte('\n');
        },
        .element => try writeHtmlElement(
            out,
            document,
            id,
            charset,
            format,
            compat,
            default_ns,
        ),
        .text => {
            if (raw_text or node_value.isRawText()) {
                try out.writeAll(node_value.value);
            } else {
                try writeHtmlText(out, node_value.value);
            }
        },
        .comment => {
            try out.writeAll("<!--");
            try out.writeAll(node_value.value);
            try out.writeAll("-->");
        },
        .processing_instruction => {
            try out.writeAll("<?");
            try out.writeAll(node_value.name);
            if (node_value.value.len != 0) {
                try out.writeByte(' ');
                try out.writeAll(node_value.value);
            }
            try out.writeByte('>');
        },
    }
}

fn writeHtmlElement(
    out: *std.Io.Writer,
    document: *const dom.Document,
    id: dom.NodeId,
    charset: []const u8,
    format: bool,
    compat: bool,
    default_ns: []const u8,
) std.Io.Writer.Error!void {
    const node_value = document.node(id);
    const info = if (document.ns(node_value.ns).len == 0)
        htmlTagInfo(node_value.localName())
    else
        null;
    const is_p = node_value.localName().len != 0 and node_value.localName()[0] == 'p';
    const prefixed = std.mem.indexOfScalar(u8, node_value.name, ':') != null;
    var declared_default: ?[]const u8 = null;
    for (document.attributesOf(id)) |attr| {
        if (std.mem.eql(u8, attr.name(), "xmlns")) {
            declared_default = attr.value();
        }
    }
    var child_default = default_ns;
    var synthesize_default = false;
    if (!prefixed) {
        if (declared_default) |value| {
            child_default = value;
        } else if (!std.mem.eql(u8, document.ns(node_value.ns), default_ns)) {
            synthesize_default = true;
            child_default = document.ns(node_value.ns);
        }
    }
    try out.writeByte('<');
    try out.writeAll(node_value.name);
    if (synthesize_default) {
        try out.writeAll(" xmlns=\"");
        try writeHtmlAttribute(out, document.ns(node_value.ns));
        try out.writeByte('"');
    }
    for (document.attributesOf(id)) |attr| {
        try out.writeByte(' ');
        const name = attr.name();
        try out.writeAll(name);
        if (document.ns(attr.ns).len == 0 and isHtmlBooleanAttribute(name)) {
            continue;
        }
        try out.writeAll("=\"");
        if (isHtmlUriAttribute(name)) {
            try writeHtmlUriAttribute(out, attr.value());
        } else {
            try writeHtmlAttribute(out, attr.value());
        }
        try out.writeByte('"');
    }
    if (info) |tag| {
        if (tag.empty) {
            try out.writeByte('>');
            return;
        }
    }
    if (node_value.first_child == dom.null_node and
        !(compat and isHtmlHeadWithMeta(document, id)))
    {
        if (info != null and info.?.save_end and !is_p and
            !std.ascii.eqlIgnoreCase(node_value.localName(), "html") and
            !std.ascii.eqlIgnoreCase(node_value.localName(), "body"))
        {
            try out.writeByte('>');
        } else {
            try out.writeAll("></");
            try out.writeAll(node_value.name);
            try out.writeByte('>');
        }
    } else {
        try out.writeByte('>');
        const insert_meta = compat and isHtmlHeadWithMeta(document, id);
        const first = if (node_value.first_child != dom.null_node)
            document.node(node_value.first_child)
        else
            null;
        const last = if (node_value.last_child != dom.null_node)
            document.node(node_value.last_child)
        else
            null;
        var child_count: usize = if (insert_meta) 1 else 0;
        var real_count: usize = 0;
        var child = node_value.first_child;
        while (child != dom.null_node) : (child = document.node(child).next_sibling) {
            real_count += 1;
            child_count += 1;
        }
        const first_is_text = if (insert_meta)
            false
        else if (first) |value|
            value.kind == .text
        else
            false;
        if (format and info != null and !info.?.is_inline and
            !first_is_text and child_count > 1 and !is_p)
        {
            try out.writeByte('\n');
        }
        if (insert_meta) {
            const prefix = node_value.name[0 .. node_value.name.len - node_value.localName().len];
            try out.writeByte('<');
            try out.writeAll(prefix);
            try out.writeAll("meta charset=\"");
            try writeHtmlAttribute(out, charset);
            try out.writeAll("\">");
            if (format and info != null and !info.?.is_inline and
                real_count != 0 and child_count > 1 and !is_p)
            {
                if (first) |value| {
                    if (value.kind != .text) try out.writeByte('\n');
                }
            }
        }
        const raw_text = document.ns(node_value.ns).len == 0 and
            (std.ascii.eqlIgnoreCase(node_value.localName(), "script") or
                std.ascii.eqlIgnoreCase(node_value.localName(), "style"));
        child = node_value.first_child;
        while (child != dom.null_node) : (child = document.node(child).next_sibling) {
            try writeHtmlNode(
                out,
                document,
                child,
                raw_text,
                charset,
                format,
                compat,
                child_default,
            );
        }
        const last_is_text = if (last) |value| value.kind == .text else false;
        if (format and info != null and !info.?.is_inline and
            !last_is_text and child_count > 1 and !is_p)
        {
            try out.writeByte('\n');
        }
        try out.writeAll("</");
        try out.writeAll(node_value.name);
        try out.writeByte('>');
    }
    if (format and info != null and !info.?.is_inline and
        node_value.next_sibling != dom.null_node)
    {
        const next = document.node(node_value.next_sibling);
        if (next.kind != .text and node_value.parent != dom.null_node) {
            const parent = document.node(node_value.parent);
            if (parent.kind == .element and
                (parent.localName().len == 0 or parent.localName()[0] != 'p'))
            {
                try out.writeByte('\n');
            }
        }
    }
}

fn isHtmlHeadWithMeta(document: *const dom.Document, id: dom.NodeId) bool {
    const node_value = document.node(id);
    if (!std.ascii.eqlIgnoreCase(node_value.localName(), "head")) return false;
    return !hasHtmlCharsetMeta(document, id);
}

fn hasHtmlCharsetMeta(document: *const dom.Document, id: dom.NodeId) bool {
    var child = document.node(id).first_child;
    while (child != dom.null_node) : (child = document.node(child).next_sibling) {
        const node_value = document.node(child);
        if (node_value.kind != .element) continue;
        if (!std.ascii.eqlIgnoreCase(node_value.localName(), "meta")) continue;
        if (document.attribute(child, "charset") != null or
            document.attribute(child, "http-equiv") != null)
        {
            return true;
        }
    }
    return false;
}

const HtmlTagInfo = struct {
    name: []const u8,
    empty: bool = false,
    save_end: bool = false,
    is_inline: bool = false,
};

const html_tag_table = [_]HtmlTagInfo{
    .{ .name = "a", .is_inline = true },
    .{ .name = "abbr", .is_inline = true },
    .{ .name = "acronym", .is_inline = true },
    .{ .name = "address" },
    .{ .name = "applet" },
    .{ .name = "area", .empty = true },
    .{ .name = "b", .is_inline = true },
    .{ .name = "base", .empty = true },
    .{ .name = "basefont", .empty = true, .is_inline = true },
    .{ .name = "bdo", .is_inline = true },
    .{ .name = "big", .is_inline = true },
    .{ .name = "blockquote" },
    .{ .name = "body" },
    .{ .name = "br", .empty = true, .is_inline = true },
    .{ .name = "button" },
    .{ .name = "caption" },
    .{ .name = "center" },
    .{ .name = "cite", .is_inline = true },
    .{ .name = "code", .is_inline = true },
    .{ .name = "col", .empty = true },
    .{ .name = "colgroup" },
    .{ .name = "dd" },
    .{ .name = "del" },
    .{ .name = "dfn", .is_inline = true },
    .{ .name = "dir" },
    .{ .name = "div" },
    .{ .name = "dl" },
    .{ .name = "dt" },
    .{ .name = "em", .is_inline = true },
    .{ .name = "embed", .is_inline = true },
    .{ .name = "fieldset" },
    .{ .name = "font", .is_inline = true },
    .{ .name = "form" },
    .{ .name = "frame", .empty = true },
    .{ .name = "frameset" },
    .{ .name = "h1" },
    .{ .name = "h2" },
    .{ .name = "h3" },
    .{ .name = "h4" },
    .{ .name = "h5" },
    .{ .name = "h6" },
    .{ .name = "head" },
    .{ .name = "hr", .empty = true },
    .{ .name = "html" },
    .{ .name = "i", .is_inline = true },
    .{ .name = "iframe" },
    .{ .name = "img", .empty = true, .is_inline = true },
    .{ .name = "input", .empty = true, .is_inline = true },
    .{ .name = "ins" },
    .{ .name = "isindex", .empty = true },
    .{ .name = "kbd", .is_inline = true },
    .{ .name = "label", .is_inline = true },
    .{ .name = "legend" },
    .{ .name = "li", .save_end = true },
    .{ .name = "link", .empty = true },
    .{ .name = "map" },
    .{ .name = "menu" },
    .{ .name = "meta", .empty = true },
    .{ .name = "noframes" },
    .{ .name = "noscript" },
    .{ .name = "object" },
    .{ .name = "ol" },
    .{ .name = "optgroup" },
    .{ .name = "option" },
    .{ .name = "p" },
    .{ .name = "param", .empty = true },
    .{ .name = "pre" },
    .{ .name = "q", .is_inline = true },
    .{ .name = "s", .is_inline = true },
    .{ .name = "samp", .is_inline = true },
    .{ .name = "script" },
    .{ .name = "select", .is_inline = true },
    .{ .name = "small", .is_inline = true },
    .{ .name = "span", .is_inline = true },
    .{ .name = "strike", .is_inline = true },
    .{ .name = "strong", .is_inline = true },
    .{ .name = "style" },
    .{ .name = "sub", .is_inline = true },
    .{ .name = "sup", .is_inline = true },
    .{ .name = "table" },
    .{ .name = "tbody" },
    .{ .name = "td" },
    .{ .name = "textarea", .is_inline = true },
    .{ .name = "tfoot" },
    .{ .name = "th" },
    .{ .name = "thead" },
    .{ .name = "title" },
    .{ .name = "tr" },
    .{ .name = "tt", .is_inline = true },
    .{ .name = "u", .is_inline = true },
    .{ .name = "ul" },
    .{ .name = "var", .is_inline = true },
};

const html_tag_map = std.StaticStringMap(HtmlTagInfo).initComptime(blk: {
    var entries: [html_tag_table.len]struct {
        []const u8,
        HtmlTagInfo,
    } = undefined;
    for (html_tag_table, 0..) |info, index| {
        entries[index] = .{ info.name, info };
    }
    break :blk entries;
});

const html_uri_attributes = std.StaticStringMap(void).initComptime(.{
    .{ "href", {} },
    .{ "src", {} },
    .{ "action", {} },
    .{ "name", {} },
    .{ "cite", {} },
    .{ "longdesc", {} },
    .{ "usemap", {} },
    .{ "background", {} },
    .{ "profile", {} },
    .{ "classid", {} },
    .{ "codebase", {} },
    .{ "data", {} },
    .{ "formaction", {} },
    .{ "icon", {} },
    .{ "manifest", {} },
    .{ "poster", {} },
});

const html_boolean_attributes = std.StaticStringMap(void).initComptime(.{
    .{ "checked", {} },
    .{ "compact", {} },
    .{ "declare", {} },
    .{ "defer", {} },
    .{ "disabled", {} },
    .{ "ismap", {} },
    .{ "multiple", {} },
    .{ "nohref", {} },
    .{ "noresize", {} },
    .{ "noshade", {} },
    .{ "nowrap", {} },
    .{ "readonly", {} },
    .{ "selected", {} },
});

/// HTML element and attribute names are ASCII; lowercase into a stack buffer
/// before the table lookup so lookups stay case-insensitive.
fn htmlNameLower(name: []const u8, buffer: []u8) ?[]const u8 {
    if (name.len > buffer.len) return null;
    return std.ascii.lowerString(buffer, name);
}

fn htmlTagInfo(name: []const u8) ?HtmlTagInfo {
    var buffer: [64]u8 = undefined;
    const lower = htmlNameLower(name, &buffer) orelse return null;
    return html_tag_map.get(lower);
}

fn isHtmlUriAttribute(name: []const u8) bool {
    var buffer: [64]u8 = undefined;
    const lower = htmlNameLower(name, &buffer) orelse return false;
    return html_uri_attributes.has(lower);
}

fn writeHtmlUriAttribute(
    out: *std.Io.Writer,
    value: []const u8,
) std.Io.Writer.Error!void {
    const hex = "0123456789ABCDEF";
    // libxml2 drops leading whitespace from URI attribute values and
    // escapes interior/trailing whitespace.
    var start: usize = 0;
    while (start < value.len and std.ascii.isWhitespace(value[start])) {
        start += 1;
    }
    for (value[start..]) |byte| {
        switch (byte) {
            '&' => try out.writeAll("&amp;"),
            '<' => try out.writeAll("&lt;"),
            '>' => try out.writeAll("&gt;"),
            '"' => try out.writeAll("&quot;"),
            else => {
                if (byte >= 0x80 or byte == ' ') {
                    try out.writeByte('%');
                    try out.writeByte(hex[byte >> 4]);
                    try out.writeByte(hex[byte & 0x0F]);
                } else {
                    try out.writeByte(byte);
                }
            },
        }
    }
}

fn findHtmlTextSpecial(text: []const u8, start: usize) usize {
    const Vec = @Vector(32, u8);
    const amp: Vec = @splat('&');
    const lt: Vec = @splat('<');
    const gt: Vec = @splat('>');
    var index = start;
    while (index + 32 <= text.len) : (index += 32) {
        const chunk: Vec = text[index..][0..32].*;
        const mask: u32 = @bitCast((chunk == amp) | (chunk == lt) | (chunk == gt));
        if (mask != 0) return index + @ctz(mask);
    }
    while (index < text.len) : (index += 1) {
        switch (text[index]) {
            '&', '<', '>' => return index,
            else => {},
        }
    }
    return text.len;
}

fn findHtmlAttributeSpecial(value: []const u8, start: usize) usize {
    const Vec = @Vector(32, u8);
    const amp: Vec = @splat('&');
    const lt: Vec = @splat('<');
    const gt: Vec = @splat('>');
    const quote: Vec = @splat('"');
    var index = start;
    while (index + 32 <= value.len) : (index += 32) {
        const chunk: Vec = value[index..][0..32].*;
        const mask: u32 = @bitCast(
            (chunk == amp) | (chunk == lt) | (chunk == gt) | (chunk == quote),
        );
        if (mask != 0) return index + @ctz(mask);
    }
    while (index < value.len) : (index += 1) {
        switch (value[index]) {
            '&', '<', '>', '"' => return index,
            else => {},
        }
    }
    return value.len;
}

fn writeHtmlText(
    out: *std.Io.Writer,
    text: []const u8,
) std.Io.Writer.Error!void {
    var pos: usize = 0;
    while (pos < text.len) {
        const special = findHtmlTextSpecial(text, pos);
        if (special > pos) {
            try out.writeAll(text[pos..special]);
            pos = special;
            if (pos >= text.len) break;
        }
        switch (text[pos]) {
            '&' => try out.writeAll("&amp;"),
            '<' => try out.writeAll("&lt;"),
            '>' => try out.writeAll("&gt;"),
            else => unreachable,
        }
        pos += 1;
    }
}

fn writeHtmlAttribute(
    out: *std.Io.Writer,
    value: []const u8,
) std.Io.Writer.Error!void {
    var pos: usize = 0;
    while (pos < value.len) {
        const special = findHtmlAttributeSpecial(value, pos);
        if (special > pos) {
            try out.writeAll(value[pos..special]);
            pos = special;
            if (pos >= value.len) break;
        }
        switch (value[pos]) {
            '&' => try out.writeAll("&amp;"),
            '<' => try out.writeAll("&lt;"),
            '>' => try out.writeAll("&gt;"),
            '"' => try out.writeAll("&quot;"),
            else => unreachable,
        }
        pos += 1;
    }
}

fn isHtmlBooleanAttribute(name: []const u8) bool {
    var buffer: [64]u8 = undefined;
    const lower = htmlNameLower(name, &buffer) orelse return false;
    return html_boolean_attributes.has(lower);
}

pub fn writeTextNode(
    out: *std.Io.Writer,
    document: *const dom.Document,
    id: dom.NodeId,
) !void {
    const node_value = document.node(id);
    if (node_value.kind == .text) {
        try out.writeAll(node_value.value);
        return;
    }
    if (node_value.kind != .document and node_value.kind != .element) return;
    var child = node_value.first_child;
    while (child != dom.null_node) : (child = document.node(child).next_sibling) {
        try writeTextNode(out, document, child);
    }
}
