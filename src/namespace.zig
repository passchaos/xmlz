//! Namespaces in XML 1.0 (Third Edition) resolution.
//!
//! The resolver is a small binding stack. Push an element's attributes before
//! resolving its name; pop it after the matching end tag. Namespace
//! declarations on the same element are visible to that element and its
//! descendants, as required by the specification.

const std = @import("std");
const chars = @import("chars.zig");

pub const xml_uri = "http://www.w3.org/XML/1998/namespace";
pub const xmlns_uri = "http://www.w3.org/2000/xmlns/";
pub const xsl_uri = "http://www.w3.org/1999/XSL/Transform";
pub const exslt_uri = "http://exslt.org/common";

pub const max_depth = 512;
pub const max_bindings = 256;

pub const Error = error{
    InvalidQualifiedName,
    UndeclaredPrefix,
    InvalidNamespaceDeclaration,
    ReservedPrefix,
    DuplicateExpandedAttribute,
    NamespaceLimitExceeded,
};

pub const QName = struct {
    prefix: []const u8,
    local: []const u8,
    raw: []const u8,
};

pub fn splitQName(raw: []const u8) Error!QName {
    if (raw.len == 0) return error.InvalidQualifiedName;
    if (std.mem.indexOfScalar(u8, raw, ':')) |colon| {
        if (colon == 0 or colon + 1 == raw.len) {
            return error.InvalidQualifiedName;
        }
        if (std.mem.indexOfScalarPos(u8, raw, colon + 1, ':') != null) {
            return error.InvalidQualifiedName;
        }
        const prefix = raw[0..colon];
        const local = raw[colon + 1 ..];
        chars.validateNCName(prefix) catch return error.InvalidQualifiedName;
        chars.validateNCName(local) catch return error.InvalidQualifiedName;
        return .{ .prefix = prefix, .local = local, .raw = raw };
    }
    chars.validateNCName(raw) catch return error.InvalidQualifiedName;
    return .{ .prefix = "", .local = raw, .raw = raw };
}

/// Split a QName whose bytes have already been validated as an XML `Name`.
/// Only the namespace-specific constraints are checked: at most one colon,
/// non-empty parts, and a NameStartChar at the beginning of the local part.
pub fn splitQNameValidated(raw: []const u8) Error!QName {
    if (raw.len == 0) return error.InvalidQualifiedName;
    if (std.mem.indexOfScalar(u8, raw, ':')) |colon| {
        if (colon == 0 or colon + 1 == raw.len) {
            return error.InvalidQualifiedName;
        }
        if (std.mem.indexOfScalarPos(u8, raw, colon + 1, ':') != null) {
            return error.InvalidQualifiedName;
        }
        const local = raw[colon + 1 ..];
        if (local[0] < 0x80) {
            if (!chars.isAsciiNameStartChar(local[0])) {
                return error.InvalidQualifiedName;
            }
        } else {
            const length = std.unicode.utf8ByteSequenceLength(local[0]) catch
                return error.InvalidQualifiedName;
            if (length > local.len) return error.InvalidQualifiedName;
            const codepoint = std.unicode.utf8Decode(local[0..length]) catch
                return error.InvalidQualifiedName;
            if (!chars.isNCNameStartChar(codepoint)) {
                return error.InvalidQualifiedName;
            }
        }
        return .{ .prefix = raw[0..colon], .local = local, .raw = raw };
    }
    return .{ .prefix = "", .local = raw, .raw = raw };
}

pub const ResolvedName = struct {
    raw: []const u8,
    prefix: []const u8,
    local: []const u8,
    /// Empty when the name is in no namespace.
    uri: []const u8,
};

pub const Binding = struct {
    prefix: []const u8,
    uri: []const u8,
};

/// Order bindings lexicographically by prefix. XPath namespace nodes and
/// canonical XML namespace declarations both use this order, which places the
/// default namespace (empty prefix) first.
pub fn bindingLessThan(_: void, a: Binding, b: Binding) bool {
    return std.mem.order(u8, a.prefix, b.prefix) == .lt;
}

pub const Resolver = struct {
    bindings: [max_bindings]Binding = undefined,
    count: usize = 0,
    marks: [max_depth]usize = undefined,
    default_marks: [max_depth][]const u8 = undefined,
    default_ns: []const u8 = "",
    /// Namespaces 1.1 permits prefix undeclaration with an empty URI.
    allow_undeclaration: bool = false,
    depth: usize = 0,

    pub fn reset(self: *Resolver) void {
        self.count = 0;
        self.depth = 0;
        self.default_ns = "";
    }

    /// Enter an element scope without declaring namespaces.
    pub fn enter(self: *Resolver) Error!void {
        if (self.depth == max_depth) return error.NamespaceLimitExceeded;
        self.marks[self.depth] = self.count;
        self.default_marks[self.depth] = self.default_ns;
        self.depth += 1;
    }

    /// Enter an element and process its namespace declarations. `attrs` may be
    /// any slice of structs with `name` and `value` fields.
    pub fn push(self: *Resolver, attrs: anytype) Error!void {
        try self.enter();

        for (attrs) |attr| {
            if (std.mem.eql(u8, attr.name, "xmlns")) {
                const uri = attr.value;
                if (std.mem.eql(u8, uri, xml_uri) or
                    std.mem.eql(u8, uri, xmlns_uri))
                {
                    return error.InvalidNamespaceDeclaration;
                }
                try self.addBinding("", uri);
            } else if (std.mem.startsWith(u8, attr.name, "xmlns:")) {
                const prefix = attr.name["xmlns:".len..];
                chars.validateNCName(prefix) catch {
                    return error.InvalidNamespaceDeclaration;
                };
                if (std.mem.eql(u8, prefix, "xmlns")) return error.ReservedPrefix;
                const uri = attr.value;
                if (std.mem.eql(u8, prefix, "xml")) {
                    if (!std.mem.eql(u8, uri, xml_uri)) return error.ReservedPrefix;
                    try self.addBinding(prefix, uri);
                    continue;
                }
                if (uri.len == 0) {
                    if (!self.allow_undeclaration) {
                        return error.InvalidNamespaceDeclaration;
                    }
                    try self.addBinding(prefix, "");
                    continue;
                }
                if (std.mem.eql(u8, uri, xml_uri) or
                    std.mem.eql(u8, uri, xmlns_uri))
                {
                    return error.ReservedPrefix;
                }
                try self.addBinding(prefix, uri);
            }
        }
    }

    pub fn pop(self: *Resolver) void {
        std.debug.assert(self.depth != 0);
        self.depth -= 1;
        self.count = self.marks[self.depth];
        self.default_ns = self.default_marks[self.depth];
    }

    pub fn resolve(self: *const Resolver, prefix: []const u8) ?[]const u8 {
        if (prefix.len == 0) return self.default_ns;
        if (std.mem.eql(u8, prefix, "xml")) return xml_uri;
        var index = self.count;
        while (index > 0) {
            index -= 1;
            if (std.mem.eql(u8, self.bindings[index].prefix, prefix)) {
                // Namespaces 1.1 prefix undeclaration leaves the prefix
                // unbound rather than bound to the empty string.
                if (self.bindings[index].uri.len == 0) return null;
                return self.bindings[index].uri;
            }
        }
        return null;
    }

    pub fn splitQNameUnchecked(raw: []const u8) QName {
        if (std.mem.indexOfScalar(u8, raw, ':')) |colon| {
            return .{
                .prefix = raw[0..colon],
                .local = raw[colon + 1 ..],
                .raw = raw,
            };
        }
        return .{ .prefix = "", .local = raw, .raw = raw };
    }

    /// Trusted-input variant of `push`: records declarations without checking
    /// reserved prefixes or URI constraints.
    pub fn pushUnchecked(self: *Resolver, attrs: anytype) Error!void {
        try self.enter();
        for (attrs) |attr| {
            if (std.mem.eql(u8, attr.name, "xmlns")) {
                try self.addBinding("", attr.value);
            } else if (std.mem.startsWith(u8, attr.name, "xmlns:")) {
                try self.addBinding(attr.name["xmlns:".len..], attr.value);
            }
        }
    }

    pub fn resolveElementNameUncheckedColon(
        self: *const Resolver,
        raw: []const u8,
        colon: u16,
    ) ResolvedName {
        if (colon == 0xFFFF) {
            return .{
                .raw = raw,
                .prefix = "",
                .local = raw,
                .uri = self.default_ns,
            };
        }
        const prefix = raw[0..colon];
        return .{
            .raw = raw,
            .prefix = prefix,
            .local = raw[colon + 1 ..],
            .uri = self.resolve(prefix) orelse "",
        };
    }

    pub fn resolveAttributeNameUncheckedColon(
        self: *const Resolver,
        raw: []const u8,
        colon: u16,
    ) ResolvedName {
        if (colon == 0xFFFF) {
            return .{ .raw = raw, .prefix = "", .local = raw, .uri = "" };
        }
        const prefix = raw[0..colon];
        return .{
            .raw = raw,
            .prefix = prefix,
            .local = raw[colon + 1 ..],
            .uri = self.resolve(prefix) orelse "",
        };
    }

    pub fn resolveElementNameUnchecked(
        self: *const Resolver,
        raw: []const u8,
    ) ResolvedName {
        const qname = splitQNameUnchecked(raw);
        if (qname.prefix.len == 0) {
            return .{
                .raw = raw,
                .prefix = "",
                .local = qname.local,
                .uri = self.default_ns,
            };
        }
        return .{
            .raw = raw,
            .prefix = qname.prefix,
            .local = qname.local,
            .uri = self.resolve(qname.prefix) orelse "",
        };
    }

    pub fn resolveAttributeNameUnchecked(
        self: *const Resolver,
        raw: []const u8,
    ) ResolvedName {
        const qname = splitQNameUnchecked(raw);
        if (qname.prefix.len == 0) {
            return .{
                .raw = raw,
                .prefix = "",
                .local = qname.local,
                .uri = "",
            };
        }
        return .{
            .raw = raw,
            .prefix = qname.prefix,
            .local = qname.local,
            .uri = self.resolve(qname.prefix) orelse "",
        };
    }

    pub fn resolveElementName(
        self: *const Resolver,
        raw: []const u8,
    ) Error!ResolvedName {
        return self.resolveElementQName(try splitQName(raw));
    }

    /// Fast path for names already validated by the XML parser.
    pub fn resolveElementNameValidated(
        self: *const Resolver,
        raw: []const u8,
    ) Error!ResolvedName {
        if (std.mem.indexOfScalar(u8, raw, ':') != null) {
            return self.resolveElementQName(try splitQNameValidated(raw));
        }
        return .{
            .raw = raw,
            .prefix = "",
            .local = raw,
            .uri = self.resolve("") orelse "",
        };
    }

    fn resolveElementQName(
        self: *const Resolver,
        qname: QName,
    ) Error!ResolvedName {
        const raw = qname.raw;
        if (std.mem.eql(u8, qname.prefix, "xmlns")) return error.ReservedPrefix;
        if (qname.prefix.len == 0) {
            const uri = self.resolve("") orelse "";
            return .{
                .raw = raw,
                .prefix = "",
                .local = qname.local,
                .uri = uri,
            };
        }
        const uri = self.resolve(qname.prefix) orelse return error.UndeclaredPrefix;
        return .{
            .raw = raw,
            .prefix = qname.prefix,
            .local = qname.local,
            .uri = uri,
        };
    }

    pub fn resolveAttributeName(
        self: *const Resolver,
        raw: []const u8,
    ) Error!ResolvedName {
        return self.resolveAttributeQName(try splitQName(raw));
    }

    /// Fast path for names already validated by the XML parser.
    pub fn resolveAttributeNameValidated(
        self: *const Resolver,
        raw: []const u8,
    ) Error!ResolvedName {
        if (std.mem.indexOfScalar(u8, raw, ':') != null) {
            return self.resolveAttributeQName(try splitQNameValidated(raw));
        }
        return .{ .raw = raw, .prefix = "", .local = raw, .uri = "" };
    }

    fn resolveAttributeQName(
        self: *const Resolver,
        qname: QName,
    ) Error!ResolvedName {
        const raw = qname.raw;
        if (qname.prefix.len == 0) {
            return .{
                .raw = raw,
                .prefix = "",
                .local = qname.local,
                .uri = "",
            };
        }
        if (std.mem.eql(u8, qname.prefix, "xmlns")) return error.ReservedPrefix;
        const uri = self.resolve(qname.prefix) orelse return error.UndeclaredPrefix;
        return .{
            .raw = raw,
            .prefix = qname.prefix,
            .local = qname.local,
            .uri = uri,
        };
    }

    pub inline fn isNamespaceDeclaration(name: []const u8) bool {
        if (name.len < 5) return false;
        if (name[0] != 'x' or name[1] != 'm' or name[2] != 'l' or
            name[3] != 'n' or name[4] != 's')
        {
            return false;
        }
        return name.len == 5 or name[5] == ':';
    }

    fn addBinding(self: *Resolver, prefix: []const u8, uri: []const u8) Error!void {
        if (self.count == self.bindings.len) return error.NamespaceLimitExceeded;
        self.bindings[self.count] = .{ .prefix = prefix, .uri = uri };
        self.count += 1;
        if (prefix.len == 0) self.default_ns = uri;
    }
};

test "namespace bindings resolve defaults prefixes and reserved names" {
    var resolver: Resolver = .{};
    const attrs = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "xmlns", .value = "urn:default" },
        .{ .name = "xmlns:p", .value = "urn:p" },
        .{ .name = "xmlns:xml", .value = xml_uri },
    };
    try resolver.push(&attrs);

    try std.testing.expectEqualStrings("urn:default", (try resolver.resolveElementName("root")).uri);
    try std.testing.expectEqualStrings("urn:p", (try resolver.resolveElementName("p:item")).uri);
    try std.testing.expectEqualStrings("", (try resolver.resolveAttributeName("plain")).uri);
    try std.testing.expectEqualStrings("urn:p", (try resolver.resolveAttributeName("p:attr")).uri);
    try std.testing.expectEqualStrings(xml_uri, (try resolver.resolveAttributeName("xml:lang")).uri);
    try std.testing.expectError(error.UndeclaredPrefix, resolver.resolveElementName("q:item"));
    try std.testing.expectError(error.InvalidQualifiedName, resolver.resolveElementName("a:b:c"));

    resolver.pop();
    try std.testing.expectEqualStrings("", (try resolver.resolveElementName("root")).uri);
}

test "namespace declarations enforce reserved prefix rules" {
    var resolver: Resolver = .{};
    const bad_default = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "xmlns", .value = xmlns_uri },
    };
    try std.testing.expectError(error.InvalidNamespaceDeclaration, resolver.push(&bad_default));

    const bad_xml = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "xmlns:xml", .value = "urn:wrong" },
    };
    try std.testing.expectError(error.ReservedPrefix, resolver.push(&bad_xml));

    const bad_prefix = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "xmlns:p", .value = "" },
    };
    try std.testing.expectError(error.InvalidNamespaceDeclaration, resolver.push(&bad_prefix));

    const bad_xmlns = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "xmlns:xmlns", .value = "urn:x" },
    };
    try std.testing.expectError(error.ReservedPrefix, resolver.push(&bad_xmlns));
}

test "default namespace can be undeclared" {
    var resolver: Resolver = .{};
    const outer = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "xmlns", .value = "urn:a" },
    };
    try resolver.push(&outer);
    try std.testing.expectEqualStrings("urn:a", (try resolver.resolveElementName("x")).uri);
    const inner = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "xmlns", .value = "" },
    };
    try resolver.push(&inner);
    try std.testing.expectEqualStrings("", (try resolver.resolveElementName("x")).uri);
    resolver.pop();
    resolver.pop();
}
