//! RELAX NG validation.
//!
//! Matching uses pattern derivatives over attributes, child elements, and text
//! runs. Attribute order is irrelevant: each attribute is consumed by a
//! derivative, and the residual pattern is then matched against the children.
//! Recursive `define` references are guarded so nullable and derivative
//! computations terminate.

const std = @import("std");
const dom = @import("../dom.zig");
const namespace = @import("../namespace.zig");
const datatypes = @import("../xsd/datatypes.zig");
const schema = @import("schema.zig");

pub const Error = error{OutOfMemory};

pub const ValidationError = struct {
    node: dom.NodeId,
    message: []const u8,
};

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    errors: []const ValidationError,

    pub fn isValid(self: *const Result) bool {
        return self.errors.len == 0;
    }

    pub fn deinit(self: *Result) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn validate(
    compiled: *const schema.Schema,
    allocator: std.mem.Allocator,
    document: *const dom.Document,
) Error!Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var matcher: Matcher = .{
        .allocator = arena.allocator(),
        .document = document,
        .errors = .empty,
        .nullable_visiting = std.AutoHashMap(
            *const schema.Pattern,
            void,
        ).init(arena.allocator()),
    };
    const root = document.root();
    if (root == dom.null_node) {
        try matcher.addError(
            document.documentNode(),
            "document has no root element",
        );
    } else if (!try matcher.matchElement(compiled.start, root)) {
        try matcher.addError(
            root,
            "element does not match the RELAX NG schema",
        );
    }
    const errors = try arena.allocator().dupe(
        ValidationError,
        matcher.errors.items,
    );
    return .{ .arena = arena, .errors = errors };
}

const Event = union(enum) {
    element: dom.NodeId,
    text: []const u8,
};

const Matcher = struct {
    allocator: std.mem.Allocator,
    document: *const dom.Document,
    errors: std.ArrayList(ValidationError) = .empty,
    nullable_visiting: std.AutoHashMap(*const schema.Pattern, void),
    depth: usize = 0,

    fn addError(
        self: *Matcher,
        node: dom.NodeId,
        message: []const u8,
    ) Error!void {
        try self.errors.append(self.allocator, .{
            .node = node,
            .message = message,
        });
    }

    fn make(self: *Matcher, value: schema.Pattern) Error!*const schema.Pattern {
        const ptr = try self.allocator.create(schema.Pattern);
        ptr.* = value;
        return ptr;
    }

    fn group(
        self: *Matcher,
        left: *const schema.Pattern,
        right: *const schema.Pattern,
    ) Error!*const schema.Pattern {
        if (isTag(left, .empty)) return right;
        if (isTag(right, .empty)) return left;
        if (isTag(left, .not_allowed) or isTag(right, .not_allowed)) {
            return self.make(.not_allowed);
        }
        return self.make(.{ .group = .{ .left = left, .right = right } });
    }

    fn interleave(
        self: *Matcher,
        left: *const schema.Pattern,
        right: *const schema.Pattern,
    ) Error!*const schema.Pattern {
        if (isTag(left, .empty)) return right;
        if (isTag(right, .empty)) return left;
        if (isTag(left, .not_allowed) or isTag(right, .not_allowed)) {
            return self.make(.not_allowed);
        }
        return self.make(.{ .interleave = .{
            .left = left,
            .right = right,
        } });
    }

    fn choice(
        self: *Matcher,
        left: *const schema.Pattern,
        right: *const schema.Pattern,
    ) Error!*const schema.Pattern {
        if (isTag(left, .not_allowed)) return right;
        if (isTag(right, .not_allowed)) return left;
        return self.make(.{ .choice = .{ .left = left, .right = right } });
    }

    fn resolve(
        self: *Matcher,
        pattern: *const schema.Pattern,
    ) Error!?*const schema.Pattern {
        _ = self;
        return switch (pattern.*) {
            .ref => |define| define.pattern,
            .parent_ref => |define| define.pattern,
            else => pattern,
        };
    }

    fn matchElement(
        self: *Matcher,
        pattern: *const schema.Pattern,
        id: dom.NodeId,
    ) Error!bool {
        const resolved = (try self.resolve(pattern)) orelse return false;
        switch (resolved.*) {
            .choice => |pair| {
                if (try self.matchElement(pair.left, id)) return true;
                return self.matchElement(pair.right, id);
            },
            .element => |element| {
                const node = self.document.node(id);
                if (!nameClassMatches(element.name_class, self.document.ns(node.ns), node.local)) {
                    return false;
                }
                return self.matchElementContent(element.content, id);
            },
            else => return false,
        }
    }

    fn matchElementContent(
        self: *Matcher,
        pattern: *const schema.Pattern,
        id: dom.NodeId,
    ) Error!bool {
        var attributes: std.ArrayList(dom.Attribute) = .empty;
        for (self.document.attributesOf(id)) |attr| {
            if (namespace.Resolver.isNamespaceDeclaration(attr.name)) continue;
            try attributes.append(self.allocator, attr);
        }
        var residuals: std.ArrayList(*const schema.Pattern) = .empty;
        try residuals.append(self.allocator, pattern);
        for (attributes.items, 0..) |attr, index| {
            var next: std.ArrayList(*const schema.Pattern) = .empty;
            for (residuals.items) |residual| {
                const derived = try self.attributeDerivative(
                    residual,
                    id,
                    attr,
                    index,
                );
                for (derived) |candidate| {
                    try appendUnique(&next, self.allocator, candidate);
                }
            }
            if (next.items.len == 0) return false;
            residuals = next;
        }
        const events = try self.collectEvents(id);
        for (residuals.items) |residual| {
            if (try self.matchEvents(residual, id, events)) return true;
        }
        return false;
    }

    fn collectEvents(self: *Matcher, id: dom.NodeId) Error![]const Event {
        var events: std.ArrayList(Event) = .empty;
        var text: std.ArrayList(u8) = .empty;
        var child = self.document.node(id).first_child;
        while (child != dom.null_node) : (child = self.document.node(child).next_sibling) {
            const node = self.document.node(child);
            switch (node.kind) {
                .text => try text.appendSlice(self.allocator, node.value),
                .element => {
                    if (!isWhitespaceOnly(text.items)) {
                        try events.append(self.allocator, .{
                            .text = try text.toOwnedSlice(self.allocator),
                        });
                    }
                    text = .empty;
                    try events.append(self.allocator, .{ .element = child });
                },
                .comment, .processing_instruction, .document => {},
            }
        }
        if (!isWhitespaceOnly(text.items)) {
            try events.append(self.allocator, .{
                .text = try text.toOwnedSlice(self.allocator),
            });
        }
        return events.items;
    }

    fn matchEvents(
        self: *Matcher,
        pattern: *const schema.Pattern,
        element_id: dom.NodeId,
        events: []const Event,
    ) Error!bool {
        var residuals: std.ArrayList(*const schema.Pattern) = .empty;
        try residuals.append(self.allocator, pattern);
        for (events) |event| {
            var next: std.ArrayList(*const schema.Pattern) = .empty;
            for (residuals.items) |residual| {
                const derived = switch (event) {
                    .element => |child| try self.elementDerivative(
                        residual,
                        child,
                    ),
                    .text => |value| try self.textDerivative(
                        residual,
                        element_id,
                        value,
                    ),
                };
                for (derived) |candidate| {
                    try appendUnique(&next, self.allocator, candidate);
                }
            }
            if (next.items.len == 0) return false;
            residuals = next;
        }
        for (residuals.items) |residual| {
            if (try self.nullable(residual)) return true;
        }
        return false;
    }

    fn attributeDerivative(
        self: *Matcher,
        pattern: *const schema.Pattern,
        element_id: dom.NodeId,
        attr: dom.Attribute,
        index: usize,
    ) Error![]const *const schema.Pattern {
        if (self.enter()) return &.{};
        defer self.leave();
        const resolved = (try self.resolve(pattern)) orelse return &.{};
        switch (resolved.*) {
            .attribute => |attribute| {
                if (!nameClassMatches(
                    attribute.name_class,
                    self.document.ns(attr.ns),
                    attr.localName(),
                )) {
                    return &.{};
                }
                if (!try self.valuePatternMatches(
                    attribute.content,
                    element_id,
                    attr.value,
                )) {
                    return &.{};
                }
                const empty = try self.make(.empty);
                return self.singleton(empty);
            },
            .group => |pair| {
                var out: std.ArrayList(*const schema.Pattern) = .empty;
                for (try self.attributeDerivative(
                    pair.left,
                    element_id,
                    attr,
                    index,
                )) |left| {
                    try appendUnique(
                        &out,
                        self.allocator,
                        try self.group(left, pair.right),
                    );
                }
                for (try self.attributeDerivative(
                    pair.right,
                    element_id,
                    attr,
                    index,
                )) |right| {
                    try appendUnique(
                        &out,
                        self.allocator,
                        try self.group(pair.left, right),
                    );
                }
                return out.items;
            },
            .interleave => |pair| {
                var out: std.ArrayList(*const schema.Pattern) = .empty;
                for (try self.attributeDerivative(
                    pair.left,
                    element_id,
                    attr,
                    index,
                )) |left| {
                    try appendUnique(
                        &out,
                        self.allocator,
                        try self.interleave(left, pair.right),
                    );
                }
                for (try self.attributeDerivative(
                    pair.right,
                    element_id,
                    attr,
                    index,
                )) |right| {
                    try appendUnique(
                        &out,
                        self.allocator,
                        try self.interleave(pair.left, right),
                    );
                }
                return out.items;
            },
            .choice => |pair| {
                var out: std.ArrayList(*const schema.Pattern) = .empty;
                for (try self.attributeDerivative(
                    pair.left,
                    element_id,
                    attr,
                    index,
                )) |left| {
                    try appendUnique(&out, self.allocator, left);
                }
                for (try self.attributeDerivative(
                    pair.right,
                    element_id,
                    attr,
                    index,
                )) |right| {
                    try appendUnique(&out, self.allocator, right);
                }
                return out.items;
            },
            .optional => |inner| {
                return self.attributeDerivative(
                    inner,
                    element_id,
                    attr,
                    index,
                );
            },
            .zero_or_more => |inner| {
                return self.repeatDerivative(
                    inner,
                    element_id,
                    attr,
                    index,
                    true,
                );
            },
            .one_or_more => |inner| {
                return self.repeatDerivative(
                    inner,
                    element_id,
                    attr,
                    index,
                    true,
                );
            },
            .mixed => |inner| {
                var out: std.ArrayList(*const schema.Pattern) = .empty;
                for (try self.attributeDerivative(
                    inner,
                    element_id,
                    attr,
                    index,
                )) |residual| {
                    try appendUnique(
                        &out,
                        self.allocator,
                        try self.make(.{ .mixed = residual }),
                    );
                }
                return out.items;
            },
            else => return &.{},
        }
    }

    fn repeatDerivative(
        self: *Matcher,
        inner: *const schema.Pattern,
        element_id: dom.NodeId,
        attr: dom.Attribute,
        index: usize,
        _: bool,
    ) Error![]const *const schema.Pattern {
        var out: std.ArrayList(*const schema.Pattern) = .empty;
        for (try self.attributeDerivative(
            inner,
            element_id,
            attr,
            index,
        )) |residual| {
            const repeated = try self.make(.{ .zero_or_more = inner });
            try appendUnique(
                &out,
                self.allocator,
                try self.group(residual, repeated),
            );
        }
        return out.items;
    }

    fn elementDerivative(
        self: *Matcher,
        pattern: *const schema.Pattern,
        child: dom.NodeId,
    ) Error![]const *const schema.Pattern {
        if (self.enter()) return &.{};
        defer self.leave();
        const resolved = (try self.resolve(pattern)) orelse return &.{};
        switch (resolved.*) {
            .element => |element| {
                const node = self.document.node(child);
                if (!nameClassMatches(element.name_class, self.document.ns(node.ns), node.local)) {
                    return &.{};
                }
                if (!try self.matchElementContent(element.content, child)) {
                    return &.{};
                }
                return self.singleton(try self.make(.empty));
            },
            .group => |pair| {
                var out: std.ArrayList(*const schema.Pattern) = .empty;
                for (try self.elementDerivative(pair.left, child)) |left| {
                    try appendUnique(
                        &out,
                        self.allocator,
                        try self.group(left, pair.right),
                    );
                }
                if (try self.nullable(pair.left)) {
                    for (try self.elementDerivative(pair.right, child)) |right| {
                        try appendUnique(
                            &out,
                            self.allocator,
                            try self.group(pair.left, right),
                        );
                    }
                }
                return out.items;
            },
            .interleave => |pair| {
                var out: std.ArrayList(*const schema.Pattern) = .empty;
                for (try self.elementDerivative(pair.left, child)) |left| {
                    try appendUnique(
                        &out,
                        self.allocator,
                        try self.interleave(left, pair.right),
                    );
                }
                for (try self.elementDerivative(pair.right, child)) |right| {
                    try appendUnique(
                        &out,
                        self.allocator,
                        try self.interleave(pair.left, right),
                    );
                }
                return out.items;
            },
            .choice => |pair| {
                var out: std.ArrayList(*const schema.Pattern) = .empty;
                for (try self.elementDerivative(pair.left, child)) |left| {
                    try appendUnique(&out, self.allocator, left);
                }
                for (try self.elementDerivative(pair.right, child)) |right| {
                    try appendUnique(&out, self.allocator, right);
                }
                return out.items;
            },
            .optional => |inner| {
                return self.elementDerivative(inner, child);
            },
            .zero_or_more => |inner| {
                return self.repeatElementDerivative(inner, child);
            },
            .one_or_more => |inner| {
                return self.repeatElementDerivative(inner, child);
            },
            .mixed => |inner| {
                var out: std.ArrayList(*const schema.Pattern) = .empty;
                for (try self.elementDerivative(inner, child)) |residual| {
                    try appendUnique(
                        &out,
                        self.allocator,
                        try self.make(.{ .mixed = residual }),
                    );
                }
                return out.items;
            },
            else => return &.{},
        }
    }

    fn repeatElementDerivative(
        self: *Matcher,
        inner: *const schema.Pattern,
        child: dom.NodeId,
    ) Error![]const *const schema.Pattern {
        var out: std.ArrayList(*const schema.Pattern) = .empty;
        for (try self.elementDerivative(inner, child)) |residual| {
            const repeated = try self.make(.{ .zero_or_more = inner });
            try appendUnique(
                &out,
                self.allocator,
                try self.group(residual, repeated),
            );
        }
        return out.items;
    }

    fn textDerivative(
        self: *Matcher,
        pattern: *const schema.Pattern,
        element_id: dom.NodeId,
        text: []const u8,
    ) Error![]const *const schema.Pattern {
        if (self.enter()) return &.{};
        defer self.leave();
        const resolved = (try self.resolve(pattern)) orelse return &.{};
        switch (resolved.*) {
            .text => return self.singleton(try self.make(.empty)),
            .data => |data| {
                if (!try self.dataMatches(data, element_id, text)) {
                    return &.{};
                }
                return self.singleton(try self.make(.empty));
            },
            .value => |value| {
                if (!try self.valueMatches(value, element_id, text)) {
                    return &.{};
                }
                return self.singleton(try self.make(.empty));
            },
            .list => |item| {
                if (!try self.matchTokens(item, text)) return &.{};
                return self.singleton(try self.make(.empty));
            },
            .group => |pair| {
                var out: std.ArrayList(*const schema.Pattern) = .empty;
                for (try self.textDerivative(
                    pair.left,
                    element_id,
                    text,
                )) |left| {
                    try appendUnique(
                        &out,
                        self.allocator,
                        try self.group(left, pair.right),
                    );
                }
                if (try self.nullable(pair.left)) {
                    for (try self.textDerivative(
                        pair.right,
                        element_id,
                        text,
                    )) |right| {
                        try appendUnique(
                            &out,
                            self.allocator,
                            try self.group(pair.left, right),
                        );
                    }
                }
                return out.items;
            },
            .interleave => |pair| {
                var out: std.ArrayList(*const schema.Pattern) = .empty;
                for (try self.textDerivative(
                    pair.left,
                    element_id,
                    text,
                )) |left| {
                    try appendUnique(
                        &out,
                        self.allocator,
                        try self.interleave(left, pair.right),
                    );
                }
                for (try self.textDerivative(
                    pair.right,
                    element_id,
                    text,
                )) |right| {
                    try appendUnique(
                        &out,
                        self.allocator,
                        try self.interleave(pair.left, right),
                    );
                }
                return out.items;
            },
            .choice => |pair| {
                var out: std.ArrayList(*const schema.Pattern) = .empty;
                for (try self.textDerivative(
                    pair.left,
                    element_id,
                    text,
                )) |left| {
                    try appendUnique(&out, self.allocator, left);
                }
                for (try self.textDerivative(
                    pair.right,
                    element_id,
                    text,
                )) |right| {
                    try appendUnique(&out, self.allocator, right);
                }
                return out.items;
            },
            .optional => |inner| {
                return self.textDerivative(inner, element_id, text);
            },
            .zero_or_more => |inner| {
                return self.repeatTextDerivative(inner, element_id, text);
            },
            .one_or_more => |inner| {
                return self.repeatTextDerivative(inner, element_id, text);
            },
            .mixed => |inner| {
                var out: std.ArrayList(*const schema.Pattern) = .empty;
                try appendUnique(
                    &out,
                    self.allocator,
                    try self.make(.{ .mixed = inner }),
                );
                for (try self.textDerivative(
                    inner,
                    element_id,
                    text,
                )) |residual| {
                    try appendUnique(
                        &out,
                        self.allocator,
                        try self.make(.{ .mixed = residual }),
                    );
                }
                return out.items;
            },
            else => return &.{},
        }
    }

    fn repeatTextDerivative(
        self: *Matcher,
        inner: *const schema.Pattern,
        element_id: dom.NodeId,
        text: []const u8,
    ) Error![]const *const schema.Pattern {
        var out: std.ArrayList(*const schema.Pattern) = .empty;
        for (try self.textDerivative(inner, element_id, text)) |residual| {
            const repeated = try self.make(.{ .zero_or_more = inner });
            try appendUnique(
                &out,
                self.allocator,
                try self.group(residual, repeated),
            );
        }
        return out.items;
    }

    fn matchTokens(
        self: *Matcher,
        item: *const schema.Pattern,
        text: []const u8,
    ) Error!bool {
        var residuals: std.ArrayList(*const schema.Pattern) = .empty;
        try residuals.append(self.allocator, item);
        var tokens = std.mem.tokenizeAny(u8, text, " \t\r\n");
        while (tokens.next()) |token| {
            var next: std.ArrayList(*const schema.Pattern) = .empty;
            for (residuals.items) |residual| {
                for (try self.tokenDerivative(residual, token)) |candidate| {
                    try appendUnique(&next, self.allocator, candidate);
                }
            }
            if (next.items.len == 0) return false;
            residuals = next;
        }
        for (residuals.items) |residual| {
            if (try self.nullable(residual)) return true;
        }
        return false;
    }

    fn tokenDerivative(
        self: *Matcher,
        pattern: *const schema.Pattern,
        token: []const u8,
    ) Error![]const *const schema.Pattern {
        if (self.enter()) return &.{};
        defer self.leave();
        const resolved = (try self.resolve(pattern)) orelse return &.{};
        switch (resolved.*) {
            .data => |data| {
                if (!try self.dataMatches(data, dom.null_node, token)) {
                    return &.{};
                }
                return self.singleton(try self.make(.empty));
            },
            .value => |value| {
                if (!try self.valueMatches(value, dom.null_node, token)) {
                    return &.{};
                }
                return self.singleton(try self.make(.empty));
            },
            .group => |pair| {
                var out: std.ArrayList(*const schema.Pattern) = .empty;
                for (try self.tokenDerivative(pair.left, token)) |left| {
                    try appendUnique(
                        &out,
                        self.allocator,
                        try self.group(left, pair.right),
                    );
                }
                if (try self.nullable(pair.left)) {
                    for (try self.tokenDerivative(pair.right, token)) |right| {
                        try appendUnique(
                            &out,
                            self.allocator,
                            try self.group(pair.left, right),
                        );
                    }
                }
                return out.items;
            },
            .interleave => |pair| {
                var out: std.ArrayList(*const schema.Pattern) = .empty;
                for (try self.tokenDerivative(pair.left, token)) |left| {
                    try appendUnique(
                        &out,
                        self.allocator,
                        try self.interleave(left, pair.right),
                    );
                }
                for (try self.tokenDerivative(pair.right, token)) |right| {
                    try appendUnique(
                        &out,
                        self.allocator,
                        try self.interleave(pair.left, right),
                    );
                }
                return out.items;
            },
            .choice => |pair| {
                var out: std.ArrayList(*const schema.Pattern) = .empty;
                for (try self.tokenDerivative(pair.left, token)) |left| {
                    try appendUnique(&out, self.allocator, left);
                }
                for (try self.tokenDerivative(pair.right, token)) |right| {
                    try appendUnique(&out, self.allocator, right);
                }
                return out.items;
            },
            .optional => |inner| {
                return self.tokenDerivative(inner, token);
            },
            .zero_or_more => |inner| {
                return self.repeatTokenDerivative(inner, token);
            },
            .one_or_more => |inner| {
                return self.repeatTokenDerivative(inner, token);
            },
            else => return &.{},
        }
    }

    fn repeatTokenDerivative(
        self: *Matcher,
        inner: *const schema.Pattern,
        token: []const u8,
    ) Error![]const *const schema.Pattern {
        var out: std.ArrayList(*const schema.Pattern) = .empty;
        for (try self.tokenDerivative(inner, token)) |residual| {
            const repeated = try self.make(.{ .zero_or_more = inner });
            try appendUnique(
                &out,
                self.allocator,
                try self.group(residual, repeated),
            );
        }
        return out.items;
    }

    fn valuePatternMatches(
        self: *Matcher,
        pattern: *const schema.Pattern,
        element_id: dom.NodeId,
        text: []const u8,
    ) Error!bool {
        const resolved = (try self.resolve(pattern)) orelse return false;
        switch (resolved.*) {
            .text => return true,
            .data => |data| return self.dataMatches(data, element_id, text),
            .value => |value| return self.valueMatches(value, element_id, text),
            .list => |item| return self.matchTokens(item, text),
            .choice => |pair| {
                if (try self.valuePatternMatches(pair.left, element_id, text)) {
                    return true;
                }
                return self.valuePatternMatches(pair.right, element_id, text);
            },
            .group => |pair| {
                return (try self.valuePatternMatches(
                    pair.left,
                    element_id,
                    text,
                )) and (try self.valuePatternMatches(
                    pair.right,
                    element_id,
                    text,
                ));
            },
            .interleave => |pair| {
                return (try self.valuePatternMatches(
                    pair.left,
                    element_id,
                    text,
                )) and (try self.valuePatternMatches(
                    pair.right,
                    element_id,
                    text,
                ));
            },
            .optional => return true,
            .zero_or_more => return true,
            .one_or_more => |inner| {
                return self.valuePatternMatches(inner, element_id, text);
            },
            .empty => return text.len == 0,
            .not_allowed => return false,
            else => return false,
        }
    }

    fn dataMatches(
        self: *Matcher,
        data: schema.Data,
        element_id: dom.NodeId,
        text: []const u8,
    ) Error!bool {
        if (!self.validateData(data, text)) return false;
        if (data.except) |except| {
            if (try self.valuePatternMatches(except, element_id, text)) {
                return false;
            }
        }
        return true;
    }

    fn validateData(
        self: *Matcher,
        data: schema.Data,
        text: []const u8,
    ) bool {
        return datatypes.validate(
            self.allocator,
            data.kind,
            data.facets,
            text,
        ) catch false;
    }

    fn valueMatches(
        self: *Matcher,
        value: schema.Value,
        element_id: dom.NodeId,
        text: []const u8,
    ) Error!bool {
        if (!(datatypes.validate(
            self.allocator,
            value.kind,
            .{},
            text,
        ) catch return false)) {
            return false;
        }
        const whitespace = datatypes.builtinWhitespace(value.kind);
        const actual = try datatypes.normalize(self.allocator, whitespace, text);
        const expected = try datatypes.normalize(
            self.allocator,
            whitespace,
            value.text,
        );
        switch (value.kind) {
            .boolean => {
                const a = booleanValue(actual) orelse return false;
                const b = booleanValue(expected) orelse return false;
                return a == b;
            },
            .decimal, .integer, .float, .double => {
                const a = std.fmt.parseFloat(f64, actual) catch return false;
                const b = std.fmt.parseFloat(f64, expected) catch return false;
                return a == b;
            },
            .qname => {
                const a = (try self.resolveQNameValue(element_id, actual)) orelse
                    return false;
                if (std.mem.indexOfScalar(u8, expected, ':')) |_| {
                    const b = (try self.resolveQNameValue(
                        element_id,
                        expected,
                    )) orelse return false;
                    return std.mem.eql(u8, a.ns, b.ns) and
                        std.mem.eql(u8, a.local, b.local);
                }
                return std.mem.eql(u8, a.ns, value.ns) and
                    std.mem.eql(u8, a.local, expected);
            },
            else => return std.mem.eql(u8, actual, expected),
        }
    }

    fn resolveQNameValue(
        self: *Matcher,
        element_id: dom.NodeId,
        raw: []const u8,
    ) Error!?schema.Name {
        if (std.mem.indexOfScalar(u8, raw, ':')) |colon| {
            const prefix = raw[0..colon];
            const local = raw[colon + 1 ..];
            if (prefix.len == 0 or local.len == 0) return null;
            if (element_id == dom.null_node) return null;
            const bindings = try self.document.inScopeNamespaces(
                self.allocator,
                element_id,
            );
            for (bindings) |binding| {
                if (std.mem.eql(u8, binding.prefix, prefix)) {
                    return .{ .ns = binding.uri, .local = local };
                }
            }
            return null;
        }
        if (raw.len == 0) return null;
        return .{ .ns = "", .local = raw };
    }

    fn nullable(self: *Matcher, pattern: *const schema.Pattern) Error!bool {
        if (self.nullable_visiting.contains(pattern)) return false;
        try self.nullable_visiting.put(pattern, {});
        defer _ = self.nullable_visiting.remove(pattern);
        const resolved = (try self.resolve(pattern)) orelse return false;
        return switch (resolved.*) {
            .empty => true,
            .not_allowed => false,
            .text => true,
            .element, .attribute => false,
            .group => |pair| (try self.nullable(pair.left)) and
                (try self.nullable(pair.right)),
            .interleave => |pair| (try self.nullable(pair.left)) and
                (try self.nullable(pair.right)),
            .choice => |pair| (try self.nullable(pair.left)) or
                (try self.nullable(pair.right)),
            .optional => true,
            .zero_or_more => true,
            .one_or_more => |inner| self.nullable(inner),
            .mixed => true,
            .data => |data| try self.dataMatches(data, dom.null_node, ""),
            .value => |value| self.valueMatches(value, dom.null_node, ""),
            .list => |item| self.matchTokens(item, ""),
            .ref, .parent_ref => unreachable,
        };
    }

    fn singleton(
        self: *Matcher,
        pattern: *const schema.Pattern,
    ) Error![]const *const schema.Pattern {
        const out = try self.allocator.alloc(*const schema.Pattern, 1);
        out[0] = pattern;
        return out;
    }

    fn enter(self: *Matcher) bool {
        if (self.depth >= 512) return true;
        self.depth += 1;
        return false;
    }

    fn leave(self: *Matcher) void {
        if (self.depth != 0) self.depth -= 1;
    }
};

fn isTag(
    pattern: *const schema.Pattern,
    tag: std.meta.Tag(schema.Pattern),
) bool {
    return std.meta.activeTag(pattern.*) == tag;
}

fn appendUnique(
    list: *std.ArrayList(*const schema.Pattern),
    allocator: std.mem.Allocator,
    pattern: *const schema.Pattern,
) Error!void {
    if (list.items.len >= 1024) return;
    for (list.items) |existing| {
        if (existing == pattern) return;
    }
    try list.append(allocator, pattern);
}

fn nameClassMatches(
    name_class: *const schema.NameClass,
    ns: []const u8,
    local: []const u8,
) bool {
    return switch (name_class.*) {
        .name => |name| std.mem.eql(u8, name.ns, ns) and
            std.mem.eql(u8, name.local, local),
        .any_name => |any| if (any.except) |except|
            !nameClassMatches(except, ns, local)
        else
            true,
        .ns_name => |name| std.mem.eql(u8, name.ns, ns) and
            (if (name.except) |except|
                !nameClassMatches(except, ns, local)
            else
                true),
        .choice => |pair| nameClassMatches(pair.left, ns, local) or
            nameClassMatches(pair.right, ns, local),
    };
}

fn isWhitespaceOnly(text: []const u8) bool {
    for (text) |byte| {
        if (byte != ' ' and byte != '\t' and byte != '\r' and byte != '\n') {
            return false;
        }
    }
    return true;
}

fn booleanValue(text: []const u8) ?bool {
    if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "1")) {
        return true;
    }
    if (std.mem.eql(u8, text, "false") or std.mem.eql(u8, text, "0")) {
        return false;
    }
    return null;
}
