//! XML Base (Second Edition) and xml:id.
//!
//! `resolve` implements RFC 3986 reference resolution. `elementBase` applies
//! `xml:base` attributes along an element's ancestor chain. `xmlIdEquals`
//! compares an `xml:id` attribute value using the whitespace normalization
//! required by XML ID.

const std = @import("std");
const dom = @import("dom.zig");
const namespace = @import("namespace.zig");

pub const Error = error{OutOfMemory};

const Parts = struct {
    scheme: ?[]const u8 = null,
    authority: ?[]const u8 = null,
    path: []const u8 = "",
    query: ?[]const u8 = null,
    fragment: ?[]const u8 = null,
};

/// Resolve `reference` against `base` following RFC 3986 section 5.2.
pub fn resolve(
    allocator: std.mem.Allocator,
    base: []const u8,
    reference: []const u8,
) Error![]u8 {
    const ref = parse(reference);
    const base_parts = parse(base);

    if (ref.scheme != null) {
        const path = try removeDotSegments(allocator, ref.path);
        defer allocator.free(path);
        return assemble(allocator, .{
            .scheme = ref.scheme,
            .authority = ref.authority,
            .path = path,
            .query = ref.query,
            .fragment = ref.fragment,
        });
    }

    var authority: ?[]const u8 = null;
    var path: []const u8 = "";
    var owned_path: ?[]u8 = null;
    defer {
        if (owned_path) |allocated| allocator.free(allocated);
    }
    var query: ?[]const u8 = null;

    if (ref.authority != null) {
        authority = ref.authority;
        owned_path = try removeDotSegments(allocator, ref.path);
        path = owned_path.?;
        query = ref.query;
    } else if (ref.path.len == 0) {
        authority = base_parts.authority;
        path = base_parts.path;
        query = ref.query orelse base_parts.query;
    } else {
        authority = base_parts.authority;
        if (ref.path[0] == '/') {
            owned_path = try removeDotSegments(allocator, ref.path);
        } else {
            const merged = try mergePaths(allocator, base_parts, ref.path);
            defer allocator.free(merged);
            owned_path = try removeDotSegments(allocator, merged);
        }
        path = owned_path.?;
        query = ref.query;
    }

    return assemble(allocator, .{
        .scheme = base_parts.scheme,
        .authority = authority,
        .path = path,
        .query = query,
        .fragment = ref.fragment,
    });
}

/// Compute the base URI of a node by applying `xml:base` from the root down.
/// Returns null when neither `document_uri` nor any `xml:base` supplies a
/// base. The caller owns the returned slice.
pub fn elementBase(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
    id: dom.NodeId,
    document_uri: []const u8,
) Error!?[]u8 {
    var chain: std.ArrayList(dom.NodeId) = .empty;
    defer chain.deinit(allocator);
    var current: dom.NodeId = id;
    while (true) {
        try chain.append(allocator, current);
        const parent = document.node(current).parent;
        if (parent == dom.null_node) break;
        current = parent;
    }

    var base: ?[]u8 = null;
    errdefer {
        if (base) |allocated| allocator.free(allocated);
    }
    if (document_uri.len != 0) base = try allocator.dupe(u8, document_uri);

    var index = chain.items.len;
    while (index > 0) {
        index -= 1;
        const node_id = chain.items[index];
        if (document.node(node_id).kind != .element) continue;
        const value = document.attributeNs(
            node_id,
            namespace.xml_uri,
            "base",
        ) orelse continue;
        if (base) |current_base| {
            const resolved = try resolve(allocator, current_base, value);
            allocator.free(current_base);
            base = resolved;
        } else {
            base = try resolve(allocator, "", value);
        }
    }
    return base;
}

/// True when an `xml:id` attribute value equals `expected` after XML ID
/// whitespace normalization (trim and collapse runs of #x20/#x9/#xD/#xA).
pub fn xmlIdEquals(raw: []const u8, expected: []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, raw, " \t\r\n");
    const token = tokens.next() orelse return false;
    if (tokens.next() != null) return false;
    return std.mem.eql(u8, token, expected);
}

/// Normalize an `xml:id` value: trim and collapse XML whitespace.
pub fn normalizeId(
    allocator: std.mem.Allocator,
    value: []const u8,
) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var tokens = std.mem.tokenizeAny(u8, value, " \t\r\n");
    var first = true;
    while (tokens.next()) |token| {
        if (!first) try out.append(allocator, ' ');
        try out.appendSlice(allocator, token);
        first = false;
    }
    return out.toOwnedSlice(allocator);
}

fn parse(uri: []const u8) Parts {
    var rest = uri;
    var fragment: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, rest, '#')) |index| {
        fragment = rest[index + 1 ..];
        rest = rest[0..index];
    }
    var query: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, rest, '?')) |index| {
        query = rest[index + 1 ..];
        rest = rest[0..index];
    }
    var scheme: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, rest, ':')) |index| {
        if (isScheme(rest[0..index])) {
            scheme = rest[0..index];
            rest = rest[index + 1 ..];
        }
    }
    var authority: ?[]const u8 = null;
    if (std.mem.startsWith(u8, rest, "//")) {
        const after = rest[2..];
        const end = std.mem.indexOfScalar(u8, after, '/') orelse after.len;
        authority = after[0..end];
        rest = after[end..];
    }
    return .{
        .scheme = scheme,
        .authority = authority,
        .path = rest,
        .query = query,
        .fragment = fragment,
    };
}

fn isScheme(text: []const u8) bool {
    if (text.len == 0) return false;
    if (!std.ascii.isAlphabetic(text[0])) return false;
    for (text[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and
            byte != '+' and byte != '-' and byte != '.')
        {
            return false;
        }
    }
    return true;
}

fn mergePaths(
    allocator: std.mem.Allocator,
    base: Parts,
    reference_path: []const u8,
) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (base.authority != null and base.path.len == 0) {
        try out.append(allocator, '/');
    } else if (std.mem.lastIndexOfScalar(u8, base.path, '/')) |slash| {
        try out.appendSlice(allocator, base.path[0 .. slash + 1]);
    }
    try out.appendSlice(allocator, reference_path);
    return out.toOwnedSlice(allocator);
}

fn removeDotSegments(
    allocator: std.mem.Allocator,
    path: []const u8,
) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var input = path;
    while (input.len != 0) {
        if (std.mem.startsWith(u8, input, "../")) {
            input = input[3..];
        } else if (std.mem.startsWith(u8, input, "./")) {
            input = input[2..];
        } else if (std.mem.startsWith(u8, input, "/./")) {
            input = input[2..];
        } else if (std.mem.eql(u8, input, "/.")) {
            input = "/";
        } else if (std.mem.startsWith(u8, input, "/../")) {
            input = input[3..];
            truncateLastSegment(&out);
        } else if (std.mem.eql(u8, input, "/..")) {
            input = "/";
            truncateLastSegment(&out);
        } else if (std.mem.eql(u8, input, ".") or
            std.mem.eql(u8, input, ".."))
        {
            input = "";
        } else {
            const end = if (input[0] == '/')
                std.mem.indexOfScalarPos(u8, input, 1, '/') orelse input.len
            else
                std.mem.indexOfScalar(u8, input, '/') orelse input.len;
            try out.appendSlice(allocator, input[0..end]);
            input = input[end..];
        }
    }
    return out.toOwnedSlice(allocator);
}

fn truncateLastSegment(out: *std.ArrayList(u8)) void {
    if (std.mem.lastIndexOfScalar(u8, out.items, '/')) |slash| {
        out.shrinkRetainingCapacity(slash);
    } else {
        out.clearRetainingCapacity();
    }
}

fn assemble(allocator: std.mem.Allocator, parts: Parts) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (parts.scheme) |scheme| {
        try out.appendSlice(allocator, scheme);
        try out.append(allocator, ':');
    }
    if (parts.authority) |authority| {
        try out.appendSlice(allocator, "//");
        try out.appendSlice(allocator, authority);
    }
    try out.appendSlice(allocator, parts.path);
    if (parts.query) |query| {
        try out.append(allocator, '?');
        try out.appendSlice(allocator, query);
    }
    if (parts.fragment) |fragment| {
        try out.append(allocator, '#');
        try out.appendSlice(allocator, fragment);
    }
    return out.toOwnedSlice(allocator);
}

const testing = std.testing;

test "resolves RFC 3986 normal references" {
    const base = "http://a/b/c/d;p?q";
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "g:h", "g:h" },
        .{ "g", "http://a/b/c/g" },
        .{ "./g", "http://a/b/c/g" },
        .{ "g/", "http://a/b/c/g/" },
        .{ "/g", "http://a/g" },
        .{ "//g", "http://g" },
        .{ "?y", "http://a/b/c/d;p?y" },
        .{ "g?y", "http://a/b/c/g?y" },
        .{ "#s", "http://a/b/c/d;p?q#s" },
        .{ "g#s", "http://a/b/c/g#s" },
        .{ "g?y#s", "http://a/b/c/g?y#s" },
        .{ ";x", "http://a/b/c/;x" },
        .{ "g;x", "http://a/b/c/g;x" },
        .{ "g;x?y#s", "http://a/b/c/g;x?y#s" },
        .{ "", "http://a/b/c/d;p?q" },
        .{ ".", "http://a/b/c/" },
        .{ "./", "http://a/b/c/" },
        .{ "..", "http://a/b/" },
        .{ "../", "http://a/b/" },
        .{ "../g", "http://a/b/g" },
        .{ "../..", "http://a/" },
        .{ "../../", "http://a/" },
        .{ "../../g", "http://a/g" },
    };
    for (cases) |case| {
        const resolved = try resolve(testing.allocator, base, case[0]);
        defer testing.allocator.free(resolved);
        try testing.expectEqualStrings(case[1], resolved);
    }
}

test "resolves RFC 3986 abnormal references" {
    const base = "http://a/b/c/d;p?q";
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "../../../g", "http://a/g" },
        .{ "../../../../g", "http://a/g" },
        .{ "/./g", "http://a/g" },
        .{ "/../g", "http://a/g" },
        .{ "g.", "http://a/b/c/g." },
        .{ ".g", "http://a/b/c/.g" },
        .{ "g..", "http://a/b/c/g.." },
        .{ "..g", "http://a/b/c/..g" },
        .{ "./../g", "http://a/b/g" },
        .{ "./g/.", "http://a/b/c/g/" },
        .{ "g/./h", "http://a/b/c/g/h" },
        .{ "g/../h", "http://a/b/c/h" },
        .{ "g;x=1/./y", "http://a/b/c/g;x=1/y" },
        .{ "g;x=1/../y", "http://a/b/c/y" },
        .{ "g?y/./x", "http://a/b/c/g?y/./x" },
        .{ "g?y/../x", "http://a/b/c/g?y/../x" },
        .{ "g#s/./x", "http://a/b/c/g#s/./x" },
        .{ "g#s/../x", "http://a/b/c/g#s/../x" },
        .{ "http:g", "http:g" },
    };
    for (cases) |case| {
        const resolved = try resolve(testing.allocator, base, case[0]);
        defer testing.allocator.free(resolved);
        try testing.expectEqualStrings(case[1], resolved);
    }
}

test "computes element base URIs through xml:base" {
    var document = try dom.Document.parse(
        testing.allocator,
        "<a xml:base='http://e/a/'><b xml:base='b/'><c/></b></a>",
        .{},
    );
    defer document.deinit();
    const a = document.root();
    const b = document.findChild(a, "b") orelse return error.TestUnexpectedResult;
    const c = document.findChild(b, "c") orelse return error.TestUnexpectedResult;

    const c_base = (try elementBase(testing.allocator, &document, c, "")) orelse
        return error.TestUnexpectedResult;
    defer testing.allocator.free(c_base);
    try testing.expectEqualStrings("http://e/a/b/", c_base);

    const a_base = (try elementBase(testing.allocator, &document, a, "")) orelse
        return error.TestUnexpectedResult;
    defer testing.allocator.free(a_base);
    try testing.expectEqualStrings("http://e/a/", a_base);

    var relative = try dom.Document.parse(
        testing.allocator,
        "<a><b xml:base='sub/'/></a>",
        .{},
    );
    defer relative.deinit();
    const relative_root = relative.root();
    const relative_b = relative.findChild(relative_root, "b") orelse
        return error.TestUnexpectedResult;
    const relative_base = (try elementBase(
        testing.allocator,
        &relative,
        relative_b,
        "http://e/root.xml",
    )) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(relative_base);
    try testing.expectEqualStrings("http://e/sub/", relative_base);
}

test "normalizes xml:id values" {
    try testing.expect(xmlIdEquals("  a  ", "a"));
    try testing.expect(xmlIdEquals("\t a \n", "a"));
    try testing.expect(!xmlIdEquals("a b", "a"));
    try testing.expect(!xmlIdEquals("", "a"));
    try testing.expect(!xmlIdEquals("a", "b"));

    const normalized = try normalizeId(testing.allocator, "  a \t b  ");
    defer testing.allocator.free(normalized);
    try testing.expectEqualStrings("a b", normalized);
}
