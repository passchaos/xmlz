//! XML serializer for `dom.Document`.
//!
//! The writer emits raw qualified names and namespace declarations preserved
//! by the DOM, so parsed documents round-trip without renaming. Character data
//! and attribute values are re-escaped, and CR is written as `&#13;` so line
//! ending normalization cannot lose it.

const std = @import("std");
const small_bytes = @import("bytes.zig");
const chars = @import("chars.zig");
const dom = @import("dom.zig");

/// Explicit DOCTYPE declaration supplied by a caller such as the XSLT engine.
pub const Doctype = struct {
    name: []const u8,
    public_id: ?[]const u8 = null,
    system_id: ?[]const u8 = null,
};

/// Element expanded name used by `cdata_elements`.
pub const ExpandedName = struct {
    uri: []const u8,
    local: []const u8,
};

pub const Options = struct {
    /// Emit an XML declaration at the start of the document.
    xml_declaration: bool = true,
    /// Emit the original DOCTYPE when one was parsed.
    emit_doctype: bool = false,
    /// Emit an explicit DOCTYPE instead of the parsed one.
    doctype: ?Doctype = null,
    /// Indentation unit. When non-null, elements whose children contain no
    /// text are pretty-printed like libxml2's serializer; mixed-content
    /// subtrees stay inline to preserve text.
    indent: ?[]const u8 = null,
    /// Append a newline after the last top-level node. libxslt's serializer
    /// does this unless `indent="no"` was explicit.
    trailing_newline: bool = false,
    /// Escape `>` as `&gt;` in character data. Escaping is always safe and
    /// avoids accidental `]]>` sequences.
    escape_gt: bool = true,
    /// Elements whose text children are serialized as CDATA sections.
    cdata_elements: []const ExpandedName = &.{},
    /// XML version written into the declaration; null keeps the document's
    /// version (or 1.0).
    version: ?[]const u8 = null,
    /// `standalone` pseudo-attribute; null keeps the document's value.
    standalone: ?bool = null,
    /// Encoding name written into the XML declaration; null omits the
    /// encoding pseudo-attribute (libxslt omits it for default UTF-8 output).
    encoding_label: ?[]const u8 = null,
    /// When set, insert an XHTML Content-Type meta element into <head>.
    html_meta_charset: ?[]const u8 = null,
};

pub const Error = std.Io.Writer.Error || error{
    InvalidCharacter,
    InvalidComment,
    InvalidProcessingInstruction,
    InvalidName,
};

pub fn writeDocument(
    writer: *std.Io.Writer,
    doc: *const dom.Document,
    options: Options,
) Error!void {
    const version = outputVersion(options, doc);
    if (options.xml_declaration) {
        try writer.writeAll("<?xml version=\"");
        if (options.version) |value| {
            try writer.writeAll(value);
        } else if (doc.declaration) |declaration| {
            try writer.writeAll(declaration.version);
        } else {
            try writer.writeAll("1.0");
        }
        try writer.writeByte('"');
        if (options.encoding_label) |label| {
            try writer.writeAll(" encoding=\"");
            try writer.writeAll(label);
            try writer.writeByte('"');
        }
        const standalone: ?bool = options.standalone orelse
            (if (doc.declaration) |declaration| declaration.standalone else null);
        if (standalone) |value| {
            try writer.writeAll(if (value)
                " standalone=\"yes\""
            else
                " standalone=\"no\"");
        }
        try writer.writeAll("?>");
        try writer.writeByte('\n');
    }
    if (options.doctype) |doctype| {
        try writeDoctype(writer, doctype);
        try writer.writeByte('\n');
    } else if (options.emit_doctype) {
        if (doc.doctype) |doctype| {
            try writer.writeAll(doctype.raw);
            try writer.writeByte('\n');
        }
    }
    // Serialize every document child, not just the root element: an XSLT
    // result can consist solely of text, comments, or processing
    // instructions.
    var child = doc.node(doc.documentNode()).first_child;
    while (child != dom.null_node) : (child = doc.node(child).next_sibling) {
        try writeNode(
            writer,
            doc,
            child,
            0,
            options,
            options.indent != null,
            version,
            "",
            0,
            doc.chars_validated,
        );
        // libxslt separates top-level comments that have a following node
        // when indenting; elements are not separated.
        if (options.indent != null and
            doc.node(child).kind == .comment and
            doc.node(child).next_sibling != dom.null_node)
        {
            try writer.writeByte('\n');
        }
    }
    if (options.trailing_newline) try writer.writeByte('\n');
}

fn documentVersion(doc: *const dom.Document) chars.Version {
    if (doc.declaration) |declaration| {
        if (std.mem.eql(u8, declaration.version, "1.1")) return .xml_1_1;
    }
    return .xml_1_0;
}

fn outputVersion(options: Options, doc: *const dom.Document) chars.Version {
    if (options.version) |version| {
        if (std.mem.eql(u8, version, "1.1")) return .xml_1_1;
        return .xml_1_0;
    }
    return documentVersion(doc);
}

/// Write an explicit DOCTYPE declaration.
pub fn writeDoctype(writer: *std.Io.Writer, doctype: Doctype) Error!void {
    try writer.writeAll("<!DOCTYPE ");
    try writer.writeAll(doctype.name);
    if (doctype.public_id) |public_id| {
        try writer.writeAll(" PUBLIC \"");
        try writer.writeAll(public_id);
        try writer.writeByte('"');
        if (doctype.system_id) |system_id| {
            try writer.writeAll(" \"");
            try writer.writeAll(system_id);
            try writer.writeByte('"');
        }
    } else if (doctype.system_id) |system_id| {
        try writer.writeAll(" SYSTEM \"");
        try writer.writeAll(system_id);
        try writer.writeByte('"');
    }
    try writer.writeByte('>');
}

fn isCdataElement(options: Options, doc: *const dom.Document, node: *const dom.Node) bool {
    for (options.cdata_elements) |name| {
        if (std.mem.eql(u8, name.uri, doc.ns(node.ns)) and
            std.mem.eql(u8, name.local, node.localName()))
        {
            return true;
        }
    }
    return false;
}

fn writeCdata(
    writer: *std.Io.Writer,
    text: []const u8,
    version: chars.Version,
    validated: bool,
) Error!void {
    if (!(validated and version == .xml_1_0)) {
        if (chars.findInvalidLiteralCharVersion(text, version)) |_| {
            if (version == .xml_1_0) return error.InvalidCharacter;
            // Restricted characters cannot appear literally inside a CDATA
            // section, so fall back to escaped character data.
            return escapeTextVersion(writer, text, true, version);
        }
    }
    try writer.writeAll("<![CDATA[");
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, text, index, "]]>")) |match| {
        try writer.writeAll(text[index .. match + 2]);
        try writer.writeAll("]]><![CDATA[");
        index = match + 2;
    }
    try writer.writeAll(text[index..]);
    try writer.writeAll("]]>");
}

fn writeNode(
    writer: *std.Io.Writer,
    doc: *const dom.Document,
    id: dom.NodeId,
    depth: usize,
    options: Options,
    pretty: bool,
    version: chars.Version,
    default_ns: []const u8,
    default_ns_id: dom.NamespaceId,
    validated: bool,
) Error!void {
    const node = doc.node(id);
    switch (node.kind) {
        .element => try writeElement(
            writer,
            doc,
            id,
            depth,
            options,
            pretty,
            version,
            default_ns,
            default_ns_id,
            validated,
        ),
        .text => {
            if (node.isRawText() or node.isTextPlain()) {
                const out = writer.unusedCapacitySlice();
                if (out.len >= node.value.len) {
                    copyShort(out[0..node.value.len], node.value);
                    writer.advance(node.value.len);
                } else {
                    try writer.writeAll(node.value);
                }
            } else {
                try escapeTextVersionChecked(
                    writer,
                    node.value,
                    options.escape_gt,
                    version,
                    validated,
                );
            }
        },
        .comment => {
            if (pretty) try writeIndent(writer, depth, options.indent.?);
            try writeComment(writer, node.value, validated);
        },
        .processing_instruction => {
            if (pretty) try writeIndent(writer, depth, options.indent.?);
            try writePi(writer, node.name, node.value, validated);
        },
        .document => unreachable,
    }
}

/// Copy up to sixteen bytes with two overlapping loads and stores. The
/// writer copies millions of short names, values, and raw attribute spans,
/// where the generic memcpy's size dispatch costs more than the copy.
inline fn copyShort(out: []u8, in: []const u8) void {
    small_bytes.copyShort(out, in);
}

inline fn isXmlnsAttribute(name: []const u8) bool {
    if (name.len != 5) return false;
    return std.mem.eql(u8, name, "xmlns");
}

/// Return the prefix of an `xmlns:prefix` attribute name, or null.
inline fn xmlnsPrefix(name: []const u8) ?[]const u8 {
    if (name.len <= 6 or name[5] != ':') return null;
    if (!std.mem.eql(u8, name[0..5], "xmlns")) return null;
    return name[6..];
}

/// Namespace declarations that repeat an inherited binding are dropped so the
/// output does not carry redundant `xmlns` attributes.
/// Pointer-receiver accessors for the writer's hot loops. `dom.Attribute`
/// stores names and values as pointer/length pairs; taking the record by
/// value in the accessor would copy all 32 bytes before extracting a slice.
inline fn attrName(attr: *const dom.Attribute) []const u8 {
    return attr.name_ptr[0..@as(usize, attr.name_len)];
}

inline fn attrValue(attr: *const dom.Attribute) []const u8 {
    return attr.value_ptr[0..@as(usize, attr.value_len)];
}

inline fn shouldSkipAttribute(
    doc: *const dom.Document,
    id: dom.NodeId,
    attr: *const dom.Attribute,
    default_ns: []const u8,
) bool {
    const name = attrName(attr);
    const value = attrValue(attr);
    if (isXmlnsAttribute(name)) {
        return std.mem.eql(u8, value, default_ns);
    }
    const prefix = xmlnsPrefix(name) orelse return false;
    if (std.mem.eql(u8, prefix, "xml") and
        std.mem.eql(u8, value, "http://www.w3.org/XML/1998/namespace"))
    {
        return true;
    }
    return ancestorBindsPrefix(doc, id, prefix, value);
}

/// Write `<name ...>` (or `<name .../>`) into the writer.
///
/// For XML 1.0 the tag is emitted straight into the writer's free buffer, so
/// each name and value is copied exactly once instead of being staged on the
/// stack first. Values that need escaping, or tags that outgrow the free
/// buffer, switch to the generic path for the remainder of the tag.
fn writeStartTag(
    writer: *std.Io.Writer,
    doc: *const dom.Document,
    id: dom.NodeId,
    node: *const dom.Node,
    options: Options,
    version: chars.Version,
    default_ns: []const u8,
    needs_synth_ns: bool,
    empty: bool,
    validated: bool,
) Error!void {
    const attrs = doc.attributesOf(id);
    // Only elements that carry namespace declarations need the redundant
    // binding check; most elements skip it entirely.
    const skip_decls = node.hasNsDecls();
    // XHTML serialization gives a plain <html> root the XHTML namespace
    // declaration (libxml2's xhtmlNodeDumpOutput behavior).
    const xhtml_ns = options.html_meta_charset != null and doc.ns(node.ns).len == 0 and
        std.mem.eql(u8, node.localName(), "html") and
        !hasNamespaceDeclaration(doc, id);

    if (version == .xml_1_0 and !xhtml_ns) {
        var out = writer.unusedCapacitySlice();
        if (out.len >= 1 + node.name.len) {
            var used: usize = 0;
            out[used] = '<';
            used += 1;
            copyShort(out[used..], node.name);
            used += node.name.len;
            var direct = true;
            if (needs_synth_ns) {
                const node_ns = doc.ns(node.ns);
                if ((shortPlainAttribute(node_ns) or
                    (if (validated)
                        try scanAttributeTrusted(node_ns, 0)
                    else
                        try scanAttribute(node_ns, 0)) == node_ns.len) and
                    used + " xmlns=\"".len + node_ns.len + 1 <= out.len)
                {
                    @memcpy(out[used..][0.." xmlns=\"".len], " xmlns=\"");
                    used += " xmlns=\"".len;
                    @memcpy(out[used..][0..node_ns.len], node_ns);
                    used += node_ns.len;
                    out[used] = '"';
                    used += 1;
                } else {
                    direct = false;
                }
            }
            if (direct) {
                var index: usize = 0;
                while (index < attrs.len) : (index += 1) {
                    const attr = &attrs[index];
                    if (skip_decls and
                        shouldSkipAttribute(doc, id, attr, default_ns)) continue;
                    // The raw source span is already `name="value"`; copy it
                    // once instead of assembling the pieces. Keeping this
                    // branch separate keeps the pointer/length fields live
                    // only on the path that needs them.
                    if (attr.isRawAdjacent()) {
                        const raw = attr.name_ptr[0 .. @intFromPtr(attr.value_ptr) +
                            @as(usize, attr.value_len) + 1 - @intFromPtr(attr.name_ptr)];
                        const needed = 1 + raw.len;
                        if (used + needed > out.len) {
                            writer.advance(used);
                            out = writer.unusedCapacitySlice();
                            used = 0;
                            if (out.len < needed) break;
                        }
                        out[used] = ' ';
                        used += 1;
                        copyShort(out[used..], raw);
                        used += raw.len;
                        continue;
                    }
                    const name = attrName(attr);
                    const value = attrValue(attr);
                    if (!attr.isPlain() and !shortPlainAttribute(value) and
                        (if (validated)
                            try scanAttributeTrusted(value, 0)
                        else
                            try scanAttribute(value, 0)) != value.len) break;
                    const needed = 4 + name.len + value.len;
                    if (used + needed > out.len) {
                        writer.advance(used);
                        out = writer.unusedCapacitySlice();
                        used = 0;
                        if (out.len < needed) break;
                    }
                    out[used] = ' ';
                    used += 1;
                    @memcpy(out[used..][0..name.len], name);
                    used += name.len;
                    out[used] = '=';
                    out[used + 1] = '"';
                    used += 2;
                    @memcpy(out[used..][0..value.len], value);
                    used += value.len;
                    out[used] = '"';
                    used += 1;
                }
                if (index == attrs.len) {
                    if (out.len - used < 2) {
                        writer.advance(used);
                        try writer.writeAll(if (empty) "/>" else ">");
                        return;
                    }
                    if (empty) {
                        out[used] = '/';
                        out[used + 1] = '>';
                        used += 2;
                    } else {
                        out[used] = '>';
                        used += 1;
                    }
                    writer.advance(used);
                    return;
                }
                if (used != 0) writer.advance(used);
                // Finish the tag through the generic writer starting at the
                // attribute that could not be written directly.
                while (index < attrs.len) : (index += 1) {
                    const attr = &attrs[index];
                    if (skip_decls and
                        shouldSkipAttribute(doc, id, attr, default_ns)) continue;
                    try writer.writeByte(' ');
                    if (attr.isRawAdjacent()) {
                        try writer.writeAll(
                            attrName(attr).ptr[0 .. @intFromPtr(attrValue(attr).ptr) +
                                attrValue(attr).len + 1 - @intFromPtr(attrName(attr).ptr)],
                        );
                        continue;
                    }
                    try writer.writeAll(attrName(attr));
                    try writer.writeAll("=\"");
                    if (attr.isPlain()) {
                        try writer.writeAll(attrValue(attr));
                    } else {
                        try escapeAttributeVersionChecked(
                            writer,
                            attrValue(attr),
                            version,
                            validated,
                        );
                    }
                    try writer.writeByte('"');
                }
                try writer.writeAll(if (empty) "/>" else ">");
                return;
            }
        }
    }

    try writer.writeByte('<');
    try writer.writeAll(node.name);
    if (needs_synth_ns) {
        try writer.writeAll(" xmlns=\"");
        try escapeAttributeVersionChecked(writer, doc.ns(node.ns), version, validated);
        try writer.writeByte('"');
    }
    if (xhtml_ns) {
        try writer.writeAll(" xmlns=\"http://www.w3.org/1999/xhtml\"");
    }
    for (attrs) |*attr| {
        if (skip_decls and shouldSkipAttribute(doc, id, attr, default_ns)) continue;
        try writer.writeByte(' ');
        try writer.writeAll(attrName(attr));
        try writer.writeAll("=\"");
        try escapeAttributeVersionChecked(writer, attrValue(attr), version, validated);
        try writer.writeByte('"');
    }
    try writer.writeAll(if (empty) "/>" else ">");
}

fn writeElement(
    writer: *std.Io.Writer,
    doc: *const dom.Document,
    id: dom.NodeId,
    depth: usize,
    options: Options,
    pretty: bool,
    version: chars.Version,
    default_ns: []const u8,
    default_ns_id: dom.NamespaceId,
    validated: bool,
) Error!void {
    const node = doc.node(id);
    if (pretty) try writeIndent(writer, depth, options.indent.?);

    const prefixed = node.localName().len != node.name.len;
    var declared_default: ?[]const u8 = null;
    if (node.hasNsDecls()) {
        for (doc.attributesOf(id)) |attr| {
            if (isXmlnsAttribute(attr.name())) declared_default = attr.value();
        }
    }
    // An unprefixed element outside the inherited default namespace needs a
    // binding (or an undeclaration when it is in no namespace). The inherited
    // namespace is tracked by table index, so the common case is an integer
    // compare instead of a table lookup and a string compare.
    const same_default = if (default_ns_id != dom.null_node)
        node.ns == default_ns_id
    else
        std.mem.eql(u8, doc.ns(node.ns), default_ns);
    const needs_synth_ns = !prefixed and declared_default == null and
        !same_default;
    var child_default = default_ns;
    var child_default_id = default_ns_id;
    if (!prefixed) {
        if (declared_default) |value| {
            child_default = value;
            child_default_id = doc.lookupNamespace(value) orelse dom.null_node;
        } else if (needs_synth_ns) {
            child_default = doc.ns(node.ns);
            child_default_id = node.ns;
        }
    }
    const empty = node.first_child == dom.null_node;
    try writeStartTag(
        writer,
        doc,
        id,
        node,
        options,
        version,
        default_ns,
        needs_synth_ns,
        empty,
        validated,
    );
    if (empty) return;

    // XHTML serialization inserts a Content-Type meta element into <head>
    // (libxml2's xmlNodeDumpOutput behavior for XHTML doctypes).
    const meta_charset: ?[]const u8 = blk: {
        const charset = options.html_meta_charset orelse break :blk null;
        if (!std.mem.eql(u8, node.localName(), "head")) break :blk null;
        if (node.parent == dom.null_node) break :blk null;
        const parent = doc.node(node.parent);
        if (parent.kind != .element or
            !std.mem.eql(u8, parent.localName(), "html"))
        {
            break :blk null;
        }
        if (hasContentTypeMeta(doc, id)) break :blk null;
        break :blk charset;
    };
    if (meta_charset) |charset| {
        if (pretty) {
            try writer.writeByte('\n');
            try writeIndent(writer, depth + 1, options.indent.?);
        }
        try writer.writeAll(
            "<meta http-equiv=\"Content-Type\" content=\"text/html; " ++
                "charset=",
        );
        try escapeAttributeVersion(writer, charset, version);
        try writer.writeAll("\" />");
    }

    // Any text child disables formatting for the whole subtree, exactly like
    // libxml2: whitespace is then preserved verbatim instead of re-indented.
    var format = pretty;
    if (format) {
        var scan = node.first_child;
        while (scan != dom.null_node) : (scan = doc.node(scan).next_sibling) {
            if (doc.node(scan).kind == .text) {
                format = false;
                break;
            }
        }
    }
    if (format) try writer.writeByte('\n');

    const cdata = isCdataElement(options, doc, node);
    var child = node.first_child;
    while (child != dom.null_node) : (child = doc.node(child).next_sibling) {
        const child_node = doc.node(child);
        const child_cdata = cdata and child_node.kind == .text and
            !child_node.isRawText();
        if (child_cdata) {
            try writeCdata(writer, child_node.value, version, validated);
        } else {
            try writeNode(
                writer,
                doc,
                child,
                depth + 1,
                options,
                format,
                version,
                child_default,
                child_default_id,
                validated,
            );
        }
        if (format) try writer.writeByte('\n');
    }

    if (format) try writeIndent(writer, depth, options.indent.?);
    try writeEndTag(writer, node.name);
}

/// Write `</name>` into the free buffer when it fits, falling back to the
/// generic writer otherwise.
fn writeEndTag(writer: *std.Io.Writer, name: []const u8) Error!void {
    const out = writer.unusedCapacitySlice();
    if (out.len >= name.len + 3) {
        out[0] = '<';
        out[1] = '/';
        copyShort(out[2..], name);
        out[name.len + 2] = '>';
        writer.advance(name.len + 3);
        return;
    }
    try writer.writeAll("</");
    try writer.writeAll(name);
    try writer.writeByte('>');
}

fn hasNamespaceDeclaration(doc: *const dom.Document, id: dom.NodeId) bool {
    for (doc.attributesOf(id)) |*attr| {
        const name = attrName(attr);
        if (std.mem.eql(u8, name, "xmlns") or
            std.mem.startsWith(u8, name, "xmlns:"))
        {
            return true;
        }
    }
    return false;
}

fn ancestorBindsPrefix(
    doc: *const dom.Document,
    id: dom.NodeId,
    prefix: []const u8,
    uri: []const u8,
) bool {
    var current = doc.node(id).parent;
    while (current != dom.null_node) {
        const node = doc.node(current);
        if (node.kind != .element) break;
        for (doc.attributesOf(current)) |*attr| {
            const name = attrName(attr);
            if (name.len != "xmlns:".len + prefix.len) continue;
            if (!std.mem.startsWith(u8, name, "xmlns:")) continue;
            if (!std.mem.eql(u8, name["xmlns:".len..], prefix)) continue;
            return std.mem.eql(u8, attrValue(attr), uri);
        }
        current = node.parent;
    }
    return false;
}

fn hasContentTypeMeta(doc: *const dom.Document, id: dom.NodeId) bool {
    var child = doc.node(id).first_child;
    while (child != dom.null_node) : (child = doc.node(child).next_sibling) {
        const node = doc.node(child);
        if (node.kind != .element) continue;
        if (!std.mem.eql(u8, node.localName(), "meta")) continue;
        if (doc.attribute(child, "http-equiv")) |value| {
            if (std.ascii.eqlIgnoreCase(value, "Content-Type")) return true;
        }
    }
    return false;
}

fn writeIndent(writer: *std.Io.Writer, depth: usize, unit: []const u8) Error!void {
    for (0..depth) |_| try writer.writeAll(unit);
}

fn writeComment(
    writer: *std.Io.Writer,
    value: []const u8,
    validated: bool,
) Error!void {
    if (!validated and
        (std.mem.indexOf(u8, value, "--") != null or
            (value.len != 0 and value[value.len - 1] == '-')))
    {
        return error.InvalidComment;
    }
    try writer.writeAll("<!--");
    try writer.writeAll(value);
    try writer.writeAll("-->");
}

fn writePi(
    writer: *std.Io.Writer,
    target: []const u8,
    data: []const u8,
    validated: bool,
) Error!void {
    if (!validated) {
        chars.validateName(target) catch return error.InvalidName;
        if (std.ascii.eqlIgnoreCase(target, "xml")) {
            return error.InvalidProcessingInstruction;
        }
        if (std.mem.indexOf(u8, data, "?>") != null) {
            return error.InvalidProcessingInstruction;
        }
    }
    try writer.writeAll("<?");
    try writer.writeAll(target);
    if (data.len != 0) {
        try writer.writeByte(' ');
        try writer.writeAll(data);
    }
    try writer.writeAll("?>");
}

/// ASCII bytes that need an escape or a validation error in character data.
/// `>` is included and filtered by the caller when `escape_gt` is false.
const text_special_table: [256]bool = blk: {
    var table = [_]bool{false} ** 256;
    for ([_]u8{ '&', '<', '>', '\r' }) |byte| table[byte] = true;
    for (0x00..0x20) |value| {
        const byte: u8 = @intCast(value);
        if (byte != '\t' and byte != '\n') table[byte] = true;
    }
    break :blk table;
};

/// ASCII bytes that need an escape or a validation error in attribute values.
const attribute_special_table: [256]bool = blk: {
    var table = [_]bool{false} ** 256;
    for ([_]u8{ '&', '<', '"' }) |byte| table[byte] = true;
    for (0x00..0x20) |value| table[@intCast(value)] = true;
    break :blk table;
};

/// Inline pre-check for the short plain values that dominate real documents;
/// longer or non-ASCII values go through `scanAttribute` instead.
inline fn shortPlainAttribute(value: []const u8) bool {
    if (value.len > 16) return false;
    for (value) |byte| {
        if (byte >= 0x80 or attribute_special_table[byte]) return false;
    }
    return true;
}

/// Inline pre-check for short plain character data.
inline fn shortPlainText(text: []const u8, escape_gt: bool) bool {
    if (text.len > 16) return false;
    for (text) |byte| {
        if (byte >= 0x80) return false;
        if (text_special_table[byte]) {
            if (byte == '>' and !escape_gt) continue;
            return false;
        }
    }
    return true;
}

/// Validate a run of non-ASCII UTF-8 starting at `start` and return the index
/// of the first ASCII byte (or the end of the slice).
fn validateHighRun(text: []const u8, start: usize) Error!usize {
    var index = start;
    while (index < text.len and text[index] >= 0x80) {
        const length = chars.xmlCodepointLength(text, index, .xml_1_0) orelse
            return error.InvalidCharacter;
        index += length;
    }
    return index;
}

/// Find the next XML 1.0 character-data byte that needs escaping or is
/// invalid, validating UTF-8 as it goes. Returns `text.len` when the rest of
/// the text is plain. Bytes below 0x20 and at or above 0x80 compare as signed
/// values below 0x20, so one vector compare catches controls and non-ASCII.
fn scanText(text: []const u8, start: usize, escape_gt: bool) Error!usize {
    const Vec = @Vector(32, u8);
    const IVec = @Vector(32, i8);
    const ctrl: IVec = @splat(0x20);
    const zero: IVec = @splat(0);
    const tab: Vec = @splat('\t');
    const lf: Vec = @splat('\n');
    const amp: Vec = @splat('&');
    const lt: Vec = @splat('<');
    const gt: Vec = @splat('>');
    var index = start;
    vector: while (index + 32 <= text.len) {
        const chunk: Vec = text[index..][0..32].*;
        var mask: u32 = @bitCast(@as(IVec, @bitCast(chunk)) < ctrl);
        mask &= ~@as(u32, @bitCast((chunk == tab) | (chunk == lf)));
        mask |= @bitCast((chunk == amp) | (chunk == lt));
        if (escape_gt) mask |= @bitCast(chunk == gt);
        const high: u32 = @bitCast(@as(IVec, @bitCast(chunk)) < zero);
        if (mask != 0 and (high == 0 or @ctz(mask) < @ctz(high))) {
            return index + @ctz(mask);
        }
        if (high != 0) {
            index = try validateHighRun(text, index + @ctz(high));
            continue :vector;
        }
        index += 32;
    }
    while (index < text.len) {
        const byte = text[index];
        if (byte >= 0x80) {
            index = try validateHighRun(text, index);
            continue;
        }
        if (text_special_table[byte]) {
            if (byte == '>' and !escape_gt) {
                index += 1;
                continue;
            }
            return index;
        }
        index += 1;
    }
    return text.len;
}

/// Find the next XML 1.0 attribute-value byte that needs escaping or is
/// invalid, validating UTF-8 as it goes. Returns `value.len` when the rest of
/// the value is plain.
fn scanAttribute(value: []const u8, start: usize) Error!usize {
    const Vec = @Vector(32, u8);
    const IVec = @Vector(32, i8);
    const ctrl: IVec = @splat(0x20);
    const zero: IVec = @splat(0);
    const amp: Vec = @splat('&');
    const lt: Vec = @splat('<');
    const quote: Vec = @splat('"');
    var index = start;
    vector: while (index + 32 <= value.len) {
        const chunk: Vec = value[index..][0..32].*;
        var mask: u32 = @bitCast(@as(IVec, @bitCast(chunk)) < ctrl);
        mask |= @bitCast((chunk == amp) | (chunk == lt) | (chunk == quote));
        const high: u32 = @bitCast(@as(IVec, @bitCast(chunk)) < zero);
        if (mask != 0 and (high == 0 or @ctz(mask) < @ctz(high))) {
            return index + @ctz(mask);
        }
        if (high != 0) {
            index = try validateHighRun(value, index + @ctz(high));
            continue :vector;
        }
        index += 32;
    }
    while (index < value.len) {
        const byte = value[index];
        if (byte >= 0x80) {
            index = try validateHighRun(value, index);
            continue;
        }
        if (attribute_special_table[byte]) return index;
        index += 1;
    }
    return value.len;
}

/// Character-data scan for trees whose characters were already validated:
/// bytes at or above 0x80 are plain.
fn scanTextTrusted(text: []const u8, start: usize, escape_gt: bool) Error!usize {
    const Vec = @Vector(32, u8);
    const ctrl: Vec = @splat(0x20);
    const tab: Vec = @splat('\t');
    const lf: Vec = @splat('\n');
    const amp: Vec = @splat('&');
    const lt: Vec = @splat('<');
    const gt: Vec = @splat('>');
    var index = start;
    while (index + 32 <= text.len) : (index += 32) {
        const chunk: Vec = text[index..][0..32].*;
        var mask: u32 = @bitCast(chunk < ctrl);
        mask &= ~@as(u32, @bitCast((chunk == tab) | (chunk == lf)));
        mask |= @bitCast((chunk == amp) | (chunk == lt));
        if (escape_gt) mask |= @bitCast(chunk == gt);
        if (mask != 0) return index + @ctz(mask);
    }
    while (index < text.len) : (index += 1) {
        const byte = text[index];
        if (text_special_table[byte]) {
            if (byte == '>' and !escape_gt) continue;
            return index;
        }
    }
    return text.len;
}

/// Attribute-value scan for trees whose characters were already validated.
fn scanAttributeTrusted(value: []const u8, start: usize) Error!usize {
    const Vec = @Vector(32, u8);
    const ctrl: Vec = @splat(0x20);
    const amp: Vec = @splat('&');
    const lt: Vec = @splat('<');
    const quote: Vec = @splat('"');
    var index = start;
    while (index + 32 <= value.len) : (index += 32) {
        const chunk: Vec = value[index..][0..32].*;
        var mask: u32 = @bitCast(chunk < ctrl);
        mask |= @bitCast((chunk == amp) | (chunk == lt) | (chunk == quote));
        if (mask != 0) return index + @ctz(mask);
    }
    if (index + 16 <= value.len) {
        const Half = @Vector(16, u8);
        const chunk: Half = value[index..][0..16].*;
        var mask: u16 = @bitCast(chunk < @as(Half, @splat(0x20)));
        mask |= @bitCast(
            (chunk == @as(Half, @splat('&'))) |
                (chunk == @as(Half, @splat('<'))) |
                (chunk == @as(Half, @splat('"'))),
        );
        if (mask != 0) return index + @ctz(mask);
        index += 16;
    }
    while (index < value.len) : (index += 1) {
        if (attribute_special_table[value[index]]) return index;
    }
    return value.len;
}

/// Escape XML 1.0 character data.
pub fn escapeText(
    writer: *std.Io.Writer,
    text: []const u8,
    escape_gt: bool,
) Error!void {
    return escapeTextVersion(writer, text, escape_gt, .xml_1_0);
}

/// Escape character data for the given XML version.
pub fn escapeTextVersion(
    writer: *std.Io.Writer,
    text: []const u8,
    escape_gt: bool,
    version: chars.Version,
) Error!void {
    return escapeTextVersionChecked(writer, text, escape_gt, version, false);
}

/// Escape character data. When `validated` is set the caller guarantees that
/// every byte was already checked against the XML character rules, so
/// non-ASCII runs are copied instead of validated.
fn escapeTextVersionChecked(
    writer: *std.Io.Writer,
    text: []const u8,
    escape_gt: bool,
    version: chars.Version,
    validated: bool,
) Error!void {
    if (version == .xml_1_0) {
        if (shortPlainText(text, escape_gt)) {
            try writer.writeAll(text);
            return;
        }
        // Entity expansion often leaves a one-byte text node (the decoded
        // `&`), which would otherwise run the full scan loop.
        if (text.len == 1) {
            switch (text[0]) {
                '&' => try writer.writeAll("&amp;"),
                '<' => try writer.writeAll("&lt;"),
                '>' => try writer.writeAll(if (escape_gt) "&gt;" else ">"),
                '\r' => try writer.writeAll("&#13;"),
                else => try writer.writeAll(text),
            }
            return;
        }
        var fast: usize = 0;
        while (fast < text.len) {
            const special = if (validated)
                try scanTextTrusted(text, fast, escape_gt)
            else
                try scanText(text, fast, escape_gt);
            if (special > fast) try writer.writeAll(text[fast..special]);
            if (special >= text.len) break;
            switch (text[special]) {
                '&' => try writer.writeAll("&amp;"),
                '<' => try writer.writeAll("&lt;"),
                '>' => try writer.writeAll(if (escape_gt) "&gt;" else ">"),
                '\r' => try writer.writeAll("&#13;"),
                else => return error.InvalidCharacter,
            }
            fast = special + 1;
        }
        return;
    }
    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        switch (byte) {
            '&' => {
                try writer.writeAll("&amp;");
                index += 1;
            },
            '<' => {
                try writer.writeAll("&lt;");
                index += 1;
            },
            '>' => {
                try writer.writeAll(if (escape_gt) "&gt;" else ">");
                index += 1;
            },
            '\r' => {
                try writer.writeAll("&#13;");
                index += 1;
            },
            '\n', '\t' => {
                try writer.writeByte(byte);
                index += 1;
            },
            else => {
                if (byte < 0x80) {
                    if (version == .xml_1_1 and chars.isRestrictedChar11(byte)) {
                        try writer.print("&#x{X};", .{byte});
                    } else {
                        try writer.writeByte(byte);
                    }
                    index += 1;
                    continue;
                }
                const length = std.unicode.utf8ByteSequenceLength(byte) catch
                    return error.InvalidCharacter;
                if (index + length > text.len) return error.InvalidCharacter;
                const codepoint = std.unicode.utf8Decode(text[index..][0..length]) catch
                    return error.InvalidCharacter;
                if (!chars.isXmlCharVersion(codepoint, version)) {
                    return error.InvalidCharacter;
                }
                if (version == .xml_1_1 and
                    (chars.isRestrictedChar11(codepoint) or
                        codepoint == 0x85 or codepoint == 0x2028))
                {
                    try writer.print("&#x{X};", .{codepoint});
                } else {
                    try writer.writeAll(text[index..][0..length]);
                }
                index += length;
            },
        }
    }
}

/// Escape an XML 1.0 attribute value using double quotes.
pub fn escapeAttribute(
    writer: *std.Io.Writer,
    value: []const u8,
) Error!void {
    return escapeAttributeVersion(writer, value, .xml_1_0);
}

/// Escape an attribute value for the given XML version.
pub fn escapeAttributeVersion(
    writer: *std.Io.Writer,
    value: []const u8,
    version: chars.Version,
) Error!void {
    return escapeAttributeVersionChecked(writer, value, version, false);
}

/// Escape an attribute value. When `validated` is set the caller guarantees
/// that every byte was already checked against the XML character rules.
fn escapeAttributeVersionChecked(
    writer: *std.Io.Writer,
    value: []const u8,
    version: chars.Version,
    validated: bool,
) Error!void {
    if (version == .xml_1_0) {
        if (shortPlainAttribute(value)) {
            try writer.writeAll(value);
            return;
        }
        var fast: usize = 0;
        while (fast < value.len) {
            const special = if (validated)
                try scanAttributeTrusted(value, fast)
            else
                try scanAttribute(value, fast);
            if (special > fast) try writer.writeAll(value[fast..special]);
            if (special >= value.len) break;
            switch (value[special]) {
                '&' => try writer.writeAll("&amp;"),
                '<' => try writer.writeAll("&lt;"),
                '"' => try writer.writeAll("&quot;"),
                '\t' => try writer.writeAll("&#9;"),
                '\n' => try writer.writeAll("&#10;"),
                '\r' => try writer.writeAll("&#13;"),
                else => return error.InvalidCharacter,
            }
            fast = special + 1;
        }
        return;
    }
    var index: usize = 0;
    while (index < value.len) {
        const byte = value[index];
        switch (byte) {
            '&' => {
                try writer.writeAll("&amp;");
                index += 1;
            },
            '<' => {
                try writer.writeAll("&lt;");
                index += 1;
            },
            '"' => {
                try writer.writeAll("&quot;");
                index += 1;
            },
            '\t' => {
                try writer.writeAll("&#9;");
                index += 1;
            },
            '\n' => {
                try writer.writeAll("&#10;");
                index += 1;
            },
            '\r' => {
                try writer.writeAll("&#13;");
                index += 1;
            },
            else => {
                if (byte < 0x80) {
                    if (version == .xml_1_1 and chars.isRestrictedChar11(byte)) {
                        try writer.print("&#x{X};", .{byte});
                    } else {
                        try writer.writeByte(byte);
                    }
                    index += 1;
                    continue;
                }
                const length = std.unicode.utf8ByteSequenceLength(byte) catch
                    return error.InvalidCharacter;
                if (index + length > value.len) return error.InvalidCharacter;
                const codepoint = std.unicode.utf8Decode(value[index..][0..length]) catch
                    return error.InvalidCharacter;
                if (!chars.isXmlCharVersion(codepoint, version)) {
                    return error.InvalidCharacter;
                }
                if (version == .xml_1_1 and
                    (chars.isRestrictedChar11(codepoint) or
                        codepoint == 0x85 or codepoint == 0x2028))
                {
                    try writer.print("&#x{X};", .{codepoint});
                } else {
                    try writer.writeAll(value[index..][0..length]);
                }
                index += length;
            },
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn render(doc: *const dom.Document, options: Options) ![]u8 {
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    try writeDocument(&allocating.writer, doc, options);
    return allocating.toOwnedSlice();
}

test "writer round-trips a namespace-aware document" {
    const input =
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\">" ++
        "<g id=\"layer\"><rect x=\"1\"/></g>hello &amp; goodbye</svg>";
    var doc = try dom.Document.parse(testing.allocator, input, .{});
    defer doc.deinit();

    const output = try render(&doc, .{ .xml_declaration = false });
    defer testing.allocator.free(output);

    var reparsed = try dom.Document.parse(testing.allocator, output, .{});
    defer reparsed.deinit();
    try testing.expectEqualStrings(
        doc.node(doc.root()).name,
        reparsed.node(reparsed.root()).name,
    );
    const original_text = try doc.textContentAlloc(testing.allocator, doc.root());
    defer testing.allocator.free(original_text);
    const reparsed_text = try reparsed.textContentAlloc(
        testing.allocator,
        reparsed.root(),
    );
    defer testing.allocator.free(reparsed_text);
    try testing.expectEqualStrings(original_text, reparsed_text);
}

test "writer escapes text and attribute values" {
    const input = "<doc a=\"x &amp; y &#10; z\">a &lt; b &amp; c &#13;</doc>";
    var doc = try dom.Document.parse(testing.allocator, input, .{});
    defer doc.deinit();

    const output = try render(&doc, .{ .xml_declaration = false });
    defer testing.allocator.free(output);

    try testing.expect(std.mem.indexOf(u8, output, "a=\"x &amp; y &#10; z\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "a &lt; b &amp; c &#13;") != null);
    try testing.expect(std.mem.indexOf(u8, output, "&#13;") != null);
}

test "parsed values record serializer plainness" {
    const input =
        "<doc plain=\"abc\" amp=\"a&amp;b\" quote='say &quot;hi&quot;'>" ++
        "text > tail &lt; &amp; &#13;</doc>";
    var doc = try dom.Document.parse(testing.allocator, input, .{});
    defer doc.deinit();

    const root = doc.root();
    const attrs = doc.attributesOf(root);
    try testing.expect(attrs[0].isPlain());
    // A decoded reference can introduce '&', so the value is not plain.
    try testing.expect(!attrs[1].isPlain());
    try testing.expect(!attrs[2].isPlain());

    var saw_gt_text = false;
    var child = doc.node(root).first_child;
    while (child != dom.null_node) : (child = doc.node(child).next_sibling) {
        const node = doc.node(child);
        if (node.kind == .text and
            std.mem.indexOfScalar(u8, node.value, '>') != null)
        {
            saw_gt_text = true;
            try testing.expect(!node.isTextPlain());
        }
    }
    try testing.expect(saw_gt_text);

    const output = try render(&doc, .{ .xml_declaration = false });
    defer testing.allocator.free(output);
    try testing.expect(std.mem.indexOf(u8, output, "plain=\"abc\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "amp=\"a&amp;b\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "text &gt; tail") != null);
}

test "writer pretty prints block elements and preserves mixed content" {
    const input = "<root><a><b/></a><p>text <i>x</i> tail</p></root>";
    var doc = try dom.Document.parse(testing.allocator, input, .{});
    defer doc.deinit();

    const output = try render(&doc, .{
        .xml_declaration = false,
        .indent = "  ",
    });
    defer testing.allocator.free(output);

    try testing.expect(std.mem.indexOf(u8, output, "<root>\n  <a>\n    <b/>\n  </a>\n") != null);
    try testing.expect(std.mem.indexOf(u8, output, "<p>text <i>x</i> tail</p>") != null);
}

test "writer emits comments and processing instructions" {
    const input = "<doc><!-- note --><?pi data?></doc>";
    var doc = try dom.Document.parse(testing.allocator, input, .{
        .keep_comments = true,
        .keep_pis = true,
    });
    defer doc.deinit();

    const output = try render(&doc, .{ .xml_declaration = false });
    defer testing.allocator.free(output);
    try testing.expect(std.mem.indexOf(u8, output, "<!-- note -->") != null);
    try testing.expect(std.mem.indexOf(u8, output, "<?pi data?>") != null);
}

test "writer rejects invalid comment and PI payloads" {
    var allocating: std.Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    try testing.expectError(
        error.InvalidComment,
        writeComment(&allocating.writer, "bad -- comment", false),
    );
    try testing.expectError(
        error.InvalidProcessingInstruction,
        writePi(&allocating.writer, "pi", "bad ?> data", false),
    );
    try testing.expectError(
        error.InvalidProcessingInstruction,
        writePi(&allocating.writer, "xml", "data", false),
    );
}

test "writer preserves XML 1.1 restricted characters as references" {
    const input = "<?xml version=\"1.1\"?><doc>&#x1;&#x85;</doc>";
    var doc = try dom.Document.parse(testing.allocator, input, .{});
    defer doc.deinit();

    const output = try render(&doc, .{});
    defer testing.allocator.free(output);
    try testing.expect(std.mem.indexOf(u8, output, "version=\"1.1\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "&#x1;") != null);
    try testing.expect(std.mem.indexOf(u8, output, "&#x85;") != null);

    var reparsed = try dom.Document.parse(testing.allocator, output, .{});
    defer reparsed.deinit();
    const original = try doc.textContentAlloc(testing.allocator, doc.root());
    defer testing.allocator.free(original);
    const round_tripped = try reparsed.textContentAlloc(
        testing.allocator,
        reparsed.root(),
    );
    defer testing.allocator.free(round_tripped);
    try testing.expectEqualStrings(original, round_tripped);
    try testing.expectEqual(@as(u8, 1), round_tripped[0]);
    try testing.expectEqual(@as(u8, 0x85), round_tripped[round_tripped.len - 1]);
}
