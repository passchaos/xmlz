//! XPath 1.0 values, node references, and evaluation context.

const std = @import("std");
const dom = @import("../dom.zig");
const namespace = @import("../namespace.zig");

pub const AttributeRef = struct {
    element: dom.NodeId,
    index: u32,
};

pub const NamespaceRef = struct {
    element: dom.NodeId,
    prefix: []const u8,
    uri: []const u8,
    /// Deterministic order among the element's namespace nodes.
    order: u32,
};

pub const NodeRef = union(enum) {
    node: dom.NodeId,
    attribute: AttributeRef,
    namespace_node: NamespaceRef,

    pub fn eql(a: NodeRef, b: NodeRef) bool {
        return switch (a) {
            .node => |a_id| switch (b) {
                .node => |b_id| a_id == b_id,
                else => false,
            },
            .attribute => |a_attr| switch (b) {
                .attribute => |b_attr| a_attr.element == b_attr.element and
                    a_attr.index == b_attr.index,
                else => false,
            },
            .namespace_node => |a_ns| switch (b) {
                .namespace_node => |b_ns| a_ns.element == b_ns.element and
                    std.mem.eql(u8, a_ns.prefix, b_ns.prefix),
                else => false,
            },
        };
    }

    pub fn orderKey(self: NodeRef) OrderKey {
        return switch (self) {
            .node => |id| .{ .primary = id, .phase = 0, .index = 0 },
            .namespace_node => |ns| .{
                .primary = ns.element,
                .phase = 1,
                .index = ns.order,
            },
            .attribute => |attr| .{
                .primary = attr.element,
                .phase = 2,
                .index = attr.index,
            },
        };
    }
};

pub const OrderKey = struct {
    primary: u32,
    phase: u8,
    index: u32,
};

pub fn orderKeyLessThan(a: OrderKey, b: OrderKey) bool {
    if (a.primary != b.primary) return a.primary < b.primary;
    if (a.phase != b.phase) return a.phase < b.phase;
    return a.index < b.index;
}

pub fn orderLessThan(_: void, a: NodeRef, b: NodeRef) bool {
    return orderKeyLessThan(a.orderKey(), b.orderKey());
}

pub const Variable = struct {
    name: []const u8,
    value: Value,
};

pub const KeyError = error{OutOfMemory};

pub const NumberFormatError = error{ OutOfMemory, InvalidFormat };

/// XSLT `format-number()` formatter hook.
pub const NumberFormatter = struct {
    context: ?*anyopaque = null,
    format: *const fn (
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        number: f64,
        pattern: []const u8,
        format_name: ?[]const u8,
    ) NumberFormatError![]const u8,
};

/// XSLT `key()` lookup hook.
pub const KeyResolver = struct {
    context: ?*anyopaque = null,
    lookup: *const fn (
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        name: []const u8,
        value: []const u8,
        node: NodeRef,
    ) KeyError![]const NodeRef,
};

/// Contiguous node-id range occupied by one document in a merged view.
pub const NodeRange = struct {
    start: usize,
    end: usize,
};

/// XSLT `generate-id()` hook. The returned string must be unique for the
/// node within a transformation and stable across calls.
pub const NodeIdGenerator = struct {
    context: ?*anyopaque = null,
    generate: *const fn (
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        document: *const dom.Document,
        node: NodeRef,
    ) error{OutOfMemory}![]const u8,
};

pub const DocumentError = error{ OutOfMemory, LoadFailed };

/// EXSLT `node-set()` hook: materialize a result tree fragment as a node in
/// the shared document view.
pub const TreeConverter = struct {
    context: ?*anyopaque = null,
    convert: *const fn (
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        tree: *const TreeFragment,
    ) error{OutOfMemory}!?NodeRef,
};

/// XSLT `document()` hook. Returns the document nodes for `href`, resolved
/// against `base`.
pub const DocumentResolver = struct {
    context: ?*anyopaque = null,
    resolve: *const fn (
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        href: []const u8,
        base: []const u8,
    ) DocumentError![]const NodeRef,
};

/// Extension function hooks used by XSLT implementations that define their
/// own functions (for example EXSLT `func:function`).
pub const ExtensionFunctionHooks = struct {
    context: *anyopaque,
    available: *const fn (
        context: *anyopaque,
        uri: []const u8,
        local: []const u8,
    ) bool,
    call: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        uri: []const u8,
        local: []const u8,
        args: []const Value,
        xpath_context: *const Context,
    ) anyerror!Value,
};

pub const Context = struct {
    document: *const dom.Document,
    node: NodeRef,
    /// XSLT current node returned by `current()`. Defaults to `node`.
    current: ?NodeRef = null,
    /// XSLT `key()` resolver.
    key_resolver: ?KeyResolver = null,
    /// XSLT `format-number()` formatter.
    number_formatter: ?NumberFormatter = null,
    /// XSLT `generate-id()` generator.
    node_id_generator: ?NodeIdGenerator = null,
    /// XSLT `document()` resolver.
    document_resolver: ?DocumentResolver = null,
    /// Document range containing the context node, when documents have been
    /// merged into one view. Used by `key()` and `id()` to stay per-document.
    document_range: ?NodeRange = null,
    /// EXSLT `node-set()` converter.
    tree_converter: ?TreeConverter = null,
    /// User-defined extension functions.
    extension_functions: ?ExtensionFunctionHooks = null,
    /// Base URI used by `document()` when no second argument is given.
    document_base: []const u8 = "",
    /// Enables XSLT-specific functions such as `generate-id()`,
    /// `system-property()`, `element-available()`, and
    /// `function-available()`.
    xslt_functions: bool = false,
    position: usize = 1,
    size: usize = 1,
    /// Prefix bindings for name tests. XPath 1.0 does not use the document's
    /// default namespace for unprefixed name tests.
    namespaces: []const namespace.Binding = &.{},
    variables: []const Variable = &.{},

    pub fn resolvePrefix(self: *const Context, prefix: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, prefix, "xml")) return namespace.xml_uri;
        for (self.namespaces) |binding| {
            if (std.mem.eql(u8, binding.prefix, prefix)) return binding.uri;
        }
        return null;
    }

    pub fn variable(self: *const Context, name: []const u8) ?Value {
        // Later bindings shadow earlier ones, matching XSLT variable scope.
        var index = self.variables.len;
        while (index > 0) {
            index -= 1;
            const entry = self.variables[index];
            if (std.mem.eql(u8, entry.name, name)) return entry.value;
        }
        return null;
    }

    pub fn withNode(
        self: *const Context,
        node: NodeRef,
        position: usize,
        size: usize,
    ) Context {
        return .{
            .document = self.document,
            .node = node,
            .current = self.current,
            .key_resolver = self.key_resolver,
            .number_formatter = self.number_formatter,
            .node_id_generator = self.node_id_generator,
            .document_resolver = self.document_resolver,
            .document_range = self.document_range,
            .tree_converter = self.tree_converter,
            .extension_functions = self.extension_functions,
            .document_base = self.document_base,
            .xslt_functions = self.xslt_functions,
            .position = position,
            .size = size,
            .namespaces = self.namespaces,
            .variables = self.variables,
        };
    }
};

pub const TreeFragment = struct {
    document: *const dom.Document,
    /// Node id of the fragment's document node after it has been merged into
    /// the transformation's shared document view by `exsl:node-set`.
    merged_root: ?dom.NodeId = null,
};

pub const Value = union(enum) {
    node_set: []const NodeRef,
    boolean: bool,
    number: f64,
    string: []const u8,
    /// XSLT result tree fragment.
    tree: *const TreeFragment,

    pub fn toBoolean(self: Value) bool {
        return switch (self) {
            .node_set => |nodes| nodes.len != 0,
            .boolean => |value| value,
            .number => |value| value != 0 and !std.math.isNan(value),
            .string => |value| value.len != 0,
            .tree => true,
        };
    }
};

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    value: Value,

    pub fn deinit(self: *Result) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Parse an XPath number. Returns NaN for malformed strings, matching the
/// XPath 1.0 `number()` conversion rules.
pub fn parseNumber(text: []const u8) f64 {
    var value = std.mem.trim(u8, text, " \t\r\n");
    if (value.len == 0) return std.math.nan(f64);
    var negative = false;
    if (value[0] == '-') {
        negative = true;
        value = value[1..];
    }
    if (value.len == 0) return std.math.nan(f64);
    var index: usize = 0;
    var digits: usize = 0;
    while (index < value.len and std.ascii.isDigit(value[index])) : (index += 1) {
        digits += 1;
    }
    if (index < value.len and value[index] == '.') {
        index += 1;
        while (index < value.len and std.ascii.isDigit(value[index])) : (index += 1) {
            digits += 1;
        }
    }
    if (digits == 0 or index != value.len) return std.math.nan(f64);
    const parsed = std.fmt.parseFloat(f64, value) catch return std.math.nan(f64);
    return if (negative) -parsed else parsed;
}

/// Format a number using the XPath 1.0 string conversion rules as
/// implemented by libxml2: integers print without a decimal point, other
/// values use 15 significant digits, and magnitudes outside [1e-5, 1e9]
/// switch to scientific notation.
pub fn formatNumber(allocator: std.mem.Allocator, number: f64) ![]const u8 {
    if (std.math.isNan(number)) return "NaN";
    if (std.math.isInf(number)) {
        return if (number < 0) "-Infinity" else "Infinity";
    }
    if (number == 0) return "0";
    const magnitude = @abs(number);
    if (number == @trunc(number) and
        number > -2147483648.0 and number < 2147483647.0)
    {
        var integer_buffer: [32]u8 = undefined;
        const text = std.fmt.bufPrint(
            &integer_buffer,
            "{d}",
            .{@as(i64, @intFromFloat(number))},
        ) catch return error.OutOfMemory;
        return allocator.dupe(u8, text);
    }
    var buffer: [400]u8 = undefined;
    if (magnitude > 1e9 or magnitude < 1e-5) {
        const scientific = std.fmt.float.render(
            &buffer,
            number,
            .{ .mode = .scientific, .precision = 14 },
        ) catch return error.OutOfMemory;
        const exponent_at = std.mem.indexOfScalar(u8, scientific, 'e') orelse
            return allocator.dupe(u8, scientific);
        const mantissa = trimFractionZeros(scientific[0..exponent_at]);
        const exponent = std.fmt.parseInt(
            i32,
            scientific[exponent_at + 1 ..],
            10,
        ) catch 0;
        var out: [400]u8 = undefined;
        const sign: u8 = if (exponent < 0) '-' else '+';
        const digits: u32 = @intCast(@abs(exponent));
        const text = std.fmt.bufPrint(
            &out,
            "{s}e{c}{d:0>2}",
            .{ mantissa, sign, digits },
        ) catch return error.OutOfMemory;
        return allocator.dupe(u8, text);
    }
    const integer_place: i32 = @intFromFloat(@trunc(std.math.log10(magnitude)));
    const fraction_places: usize = if (integer_place > 0)
        @intCast(15 - integer_place - 1)
    else
        @intCast(15 - integer_place);
    const fixed = std.fmt.float.render(
        &buffer,
        number,
        .{ .mode = .decimal, .precision = fraction_places },
    ) catch return error.OutOfMemory;
    return allocator.dupe(u8, trimFractionZeros(fixed));
}

fn trimFractionZeros(text: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, text, '.') == null) return text;
    var end = text.len;
    while (end > 0 and text[end - 1] == '0') end -= 1;
    if (end > 0 and text[end - 1] == '.') end -= 1;
    return text[0..end];
}

test "XPath number formatting matches libxml2 conventions" {
    const testing = std.testing;
    const Case = struct { expected: []const u8, number: f64 };
    const cases = [_]Case{
        .{ .expected = "0", .number = 0 },
        .{ .expected = "0.64", .number = 3.14 - 2 - 0.5 },
        .{ .expected = "0.3", .number = 0.1 + 0.2 },
        .{ .expected = "0.333333333333333", .number = 1.0 / 3.0 },
        .{ .expected = "123456789.123457", .number = 123456789.123456789 },
        .{ .expected = "1e-06", .number = 0.000001 },
        .{ .expected = "1.0000000005e+09", .number = 1000000000.5 },
        .{ .expected = "3e+09", .number = 3000000000.0 },
        .{ .expected = "2147483646", .number = 2147483646.0 },
        .{ .expected = "2.147483647e+09", .number = 2147483647.0 },
        .{ .expected = "-0.5", .number = -0.5 },
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for (cases) |case| {
        const text = try formatNumber(arena.allocator(), case.number);
        try testing.expectEqualStrings(case.expected, text);
    }
}
