//! XML Schema regular expressions.
//!
//! Implements the XSD pattern-facet syntax: branches, groups, character
//! classes, ranges, `.`, the `\d \s \w \i \c` shorthand classes, `\p{...}`
//! categories, and the `? * + {m,n}` quantifiers. Matching is a Thompson NFA
//! simulation over Unicode code points and requires the whole value to match,
//! as the pattern facet specifies. Unicode category coverage is approximate:
//! common scripts and ranges are recognized rather than the complete Unicode
//! general-category tables.

const std = @import("std");
const chars = @import("../chars.zig");

pub const Error = error{ OutOfMemory, InvalidPattern };

const max_states = 8192;

pub const Regex = struct {
    arena: std.heap.ArenaAllocator,
    states: []const State,
    start: usize,
    accept: usize,

    pub fn deinit(self: *Regex) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// True when `text` matches the pattern in its entirety.
    pub fn matches(
        self: *const Regex,
        allocator: std.mem.Allocator,
        text: []const u8,
    ) Error!bool {
        const state_count = self.states.len;
        const first_buffer = try allocator.alloc(bool, state_count);
        defer allocator.free(first_buffer);
        const second_buffer = try allocator.alloc(bool, state_count);
        defer allocator.free(second_buffer);
        @memset(first_buffer, false);
        @memset(second_buffer, false);
        var current = first_buffer;
        var next = second_buffer;

        var stack: std.ArrayList(usize) = .empty;
        defer stack.deinit(allocator);
        try self.addClosure(self.start, current, &stack, allocator);

        var view = std.unicode.Utf8View.init(text) catch return false;
        var iterator = view.iterator();
        while (iterator.nextCodepoint()) |codepoint| {
            @memset(next, false);
            for (self.states, 0..) |state, index| {
                if (!current[index]) continue;
                for (state.transitions) |transition| {
                    if (predicateMatches(transition.predicate, codepoint)) {
                        try self.addClosure(
                            transition.target,
                            next,
                            &stack,
                            allocator,
                        );
                    }
                }
            }
            const temporary = current;
            current = next;
            next = temporary;
        }
        return current[self.accept];
    }

    fn addClosure(
        self: *const Regex,
        state: usize,
        set: []bool,
        stack: *std.ArrayList(usize),
        allocator: std.mem.Allocator,
    ) Error!void {
        if (set[state]) return;
        set[state] = true;
        try stack.append(allocator, state);
        while (stack.pop()) |current| {
            for (self.states[current].epsilon) |target| {
                if (set[target]) continue;
                set[target] = true;
                try stack.append(allocator, target);
            }
        }
    }
};

const State = struct {
    epsilon: []const usize,
    transitions: []const Transition,
};

const Transition = struct {
    predicate: Predicate,
    target: usize,
};

const Predicate = union(enum) {
    any,
    literal: u21,
    class: *const Class,
};

const Class = struct {
    negated: bool,
    items: []const ClassItem,
};

const ClassItem = struct {
    kind: Kind,
    negated: bool = false,
    lo: u21 = 0,
    hi: u21 = 0,
    category: []const u8 = "",

    const Kind = enum {
        range,
        literal,
        digit,
        space,
        word,
        name_start,
        name_char,
        category,
    };
};

const Repeat = struct {
    child: *const Node,
    min: usize,
    max: ?usize,
};

const Node = union(enum) {
    empty,
    literal: u21,
    any,
    class: *const Class,
    sequence: []const *const Node,
    choice: []const *const Node,
    repeat: Repeat,
};

/// Compile an XSD regular expression. The returned `Regex` owns its arena.
pub fn compile(
    allocator: std.mem.Allocator,
    pattern: []const u8,
) Error!Regex {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    var parser: Parser = .{
        .allocator = arena_allocator,
        .pattern = pattern,
    };
    const root = try parser.parseRegex();
    if (parser.index != pattern.len) return error.InvalidPattern;

    var builder: Builder = .{
        .allocator = arena_allocator,
    };
    defer builder.deinit(arena_allocator);
    const fragment = try builder.compileNode(root);
    const states = try arena_allocator.alloc(State, builder.states.items.len);
    for (builder.states.items, 0..) |state, index| {
        states[index] = .{
            .epsilon = try arena_allocator.dupe(usize, state.epsilon.items),
            .transitions = try arena_allocator.dupe(
                Transition,
                state.transitions.items,
            ),
        };
    }
    return .{
        .arena = arena,
        .states = states,
        .start = fragment.start,
        .accept = fragment.end,
    };
}

const Parser = struct {
    allocator: std.mem.Allocator,
    pattern: []const u8,
    index: usize = 0,

    fn parseRegex(self: *Parser) Error!*const Node {
        var branches: std.ArrayList(*const Node) = .empty;
        try branches.append(self.allocator, try self.parseBranch());
        while (self.index < self.pattern.len and self.pattern[self.index] == '|') {
            self.index += 1;
            try branches.append(self.allocator, try self.parseBranch());
        }
        if (branches.items.len == 1) return branches.items[0];
        const nodes = try self.allocator.dupe(*const Node, branches.items);
        return self.newNode(.{ .choice = nodes });
    }

    fn parseBranch(self: *Parser) Error!*const Node {
        var pieces: std.ArrayList(*const Node) = .empty;
        while (self.index < self.pattern.len) {
            const byte = self.pattern[self.index];
            if (byte == '|' or byte == ')') break;
            try pieces.append(self.allocator, try self.parsePiece());
        }
        if (pieces.items.len == 0) return self.newNode(.empty);
        if (pieces.items.len == 1) return pieces.items[0];
        const nodes = try self.allocator.dupe(*const Node, pieces.items);
        return self.newNode(.{ .sequence = nodes });
    }

    fn parsePiece(self: *Parser) Error!*const Node {
        const atom = try self.parseAtom();
        if (self.index >= self.pattern.len) return atom;
        const byte = self.pattern[self.index];
        var minimum: usize = 1;
        var maximum: ?usize = 1;
        if (byte == '?') {
            minimum = 0;
            maximum = 1;
            self.index += 1;
        } else if (byte == '*') {
            minimum = 0;
            maximum = null;
            self.index += 1;
        } else if (byte == '+') {
            minimum = 1;
            maximum = null;
            self.index += 1;
        } else if (byte == '{') {
            try self.parseBounds(&minimum, &maximum);
        } else {
            return atom;
        }
        if (self.index < self.pattern.len) {
            const next_byte = self.pattern[self.index];
            if (next_byte == '?' or next_byte == '*' or next_byte == '+' or
                next_byte == '{')
            {
                return error.InvalidPattern;
            }
        }
        return self.newNode(.{ .repeat = .{
            .child = atom,
            .min = minimum,
            .max = maximum,
        } });
    }

    fn parseBounds(self: *Parser, minimum: *usize, maximum: *?usize) Error!void {
        self.index += 1; // '{'
        const start = self.index;
        while (self.index < self.pattern.len and
            std.ascii.isDigit(self.pattern[self.index]))
        {
            self.index += 1;
        }
        if (self.index == start) return error.InvalidPattern;
        const min = std.fmt.parseUnsigned(usize, self.pattern[start..self.index], 10) catch
            return error.InvalidPattern;
        if (self.index < self.pattern.len and self.pattern[self.index] == ',') {
            self.index += 1;
            const max_start = self.index;
            while (self.index < self.pattern.len and
                std.ascii.isDigit(self.pattern[self.index]))
            {
                self.index += 1;
            }
            if (self.index == max_start) {
                maximum.* = null;
            } else {
                maximum.* = std.fmt.parseUnsigned(
                    usize,
                    self.pattern[max_start..self.index],
                    10,
                ) catch return error.InvalidPattern;
            }
        } else {
            maximum.* = min;
        }
        if (self.index >= self.pattern.len or self.pattern[self.index] != '}') {
            return error.InvalidPattern;
        }
        self.index += 1;
        minimum.* = min;
        if (maximum.*) |max| {
            if (max < min) return error.InvalidPattern;
        }
        if (min > max_states) return error.InvalidPattern;
    }

    fn parseAtom(self: *Parser) Error!*const Node {
        if (self.index >= self.pattern.len) return error.InvalidPattern;
        const byte = self.pattern[self.index];
        if (byte == '(') {
            self.index += 1;
            const inner = try self.parseRegex();
            if (self.index >= self.pattern.len or self.pattern[self.index] != ')') {
                return error.InvalidPattern;
            }
            self.index += 1;
            return inner;
        }
        if (byte == '[') return self.parseClass();
        if (byte == '.') {
            self.index += 1;
            return self.newNode(.any);
        }
        if (byte == '\\') {
            self.index += 1;
            const item = try self.parseEscape();
            if (item.kind == .literal and !item.negated) {
                return self.newNode(.{ .literal = item.lo });
            }
            const class = try self.allocator.create(Class);
            const items = try self.allocator.alloc(ClassItem, 1);
            items[0] = item;
            class.* = .{ .negated = false, .items = items };
            return self.newNode(.{ .class = class });
        }
        const codepoint = self.nextCodepoint() orelse
            return error.InvalidPattern;
        return self.newNode(.{ .literal = codepoint });
    }

    fn parseClass(self: *Parser) Error!*const Node {
        self.index += 1; // '['
        var negated = false;
        if (self.index < self.pattern.len and self.pattern[self.index] == '^') {
            negated = true;
            self.index += 1;
        }
        var items: std.ArrayList(ClassItem) = .empty;
        while (self.index < self.pattern.len and self.pattern[self.index] != ']') {
            const first = try self.parseClassItem();
            if (first.kind == .range) {
                // A range endpoint must be a single code point.
                try items.append(self.allocator, first);
                continue;
            }
            if (self.index + 1 < self.pattern.len and
                self.pattern[self.index] == '-' and
                self.pattern[self.index + 1] != ']')
            {
                self.index += 1;
                const second = try self.parseClassItem();
                if (second.kind != .literal) return error.InvalidPattern;
                const lo = literalCodepoint(first) orelse
                    return error.InvalidPattern;
                const hi = second.lo;
                if (hi < lo) return error.InvalidPattern;
                try items.append(self.allocator, .{
                    .kind = .range,
                    .lo = lo,
                    .hi = hi,
                });
            } else {
                try items.append(self.allocator, first);
            }
        }
        if (self.index >= self.pattern.len or self.pattern[self.index] != ']') {
            return error.InvalidPattern;
        }
        self.index += 1;
        const class = try self.allocator.create(Class);
        class.* = .{
            .negated = negated,
            .items = try self.allocator.dupe(ClassItem, items.items),
        };
        return self.newNode(.{ .class = class });
    }

    fn parseClassItem(self: *Parser) Error!ClassItem {
        if (self.index >= self.pattern.len) return error.InvalidPattern;
        const byte = self.pattern[self.index];
        if (byte == '\\') {
            self.index += 1;
            return self.parseEscape();
        }
        const codepoint = self.nextCodepoint() orelse
            return error.InvalidPattern;
        return .{ .kind = .literal, .lo = codepoint };
    }

    fn parseEscape(self: *Parser) Error!ClassItem {
        if (self.index >= self.pattern.len) return error.InvalidPattern;
        const byte = self.pattern[self.index];
        self.index += 1;
        return switch (byte) {
            'd' => .{ .kind = .digit },
            'D' => .{ .kind = .digit, .negated = true },
            's' => .{ .kind = .space },
            'S' => .{ .kind = .space, .negated = true },
            'w' => .{ .kind = .word },
            'W' => .{ .kind = .word, .negated = true },
            'i' => .{ .kind = .name_start },
            'I' => .{ .kind = .name_start, .negated = true },
            'c' => .{ .kind = .name_char },
            'C' => .{ .kind = .name_char, .negated = true },
            'p', 'P' => try self.parseCategory(byte == 'P'),
            'n' => .{ .kind = .literal, .lo = '\n' },
            'r' => .{ .kind = .literal, .lo = '\r' },
            't' => .{ .kind = .literal, .lo = '\t' },
            '\\', '|', '.', '-', '^', '?', '*', '+', '{', '}', '(', ')', '[', ']' => .{
                .kind = .literal,
                .lo = byte,
            },
            else => error.InvalidPattern,
        };
    }

    fn parseCategory(self: *Parser, negated: bool) Error!ClassItem {
        if (self.index >= self.pattern.len or self.pattern[self.index] != '{') {
            return error.InvalidPattern;
        }
        self.index += 1;
        const start = self.index;
        while (self.index < self.pattern.len and self.pattern[self.index] != '}') {
            self.index += 1;
        }
        if (self.index >= self.pattern.len) return error.InvalidPattern;
        const name = self.pattern[start..self.index];
        self.index += 1;
        if (name.len == 0) return error.InvalidPattern;
        return .{
            .kind = .category,
            .category = try self.allocator.dupe(u8, name),
            .negated = negated,
        };
    }

    fn nextCodepoint(self: *Parser) ?u21 {
        const length = std.unicode.utf8ByteSequenceLength(
            self.pattern[self.index],
        ) catch return null;
        if (self.index + length > self.pattern.len) return null;
        const codepoint = std.unicode.utf8Decode(
            self.pattern[self.index..][0..length],
        ) catch return null;
        self.index += length;
        return codepoint;
    }

    fn newNode(self: *Parser, node: Node) Error!*const Node {
        const allocated = try self.allocator.create(Node);
        allocated.* = node;
        return allocated;
    }
};

const Fragment = struct {
    start: usize,
    end: usize,
};

const StateBuilder = struct {
    epsilon: std.ArrayList(usize) = .empty,
    transitions: std.ArrayList(Transition) = .empty,
};

const Builder = struct {
    allocator: std.mem.Allocator,
    states: std.ArrayList(StateBuilder) = .empty,

    fn deinit(self: *Builder, allocator: std.mem.Allocator) void {
        for (self.states.items) |*state| {
            state.epsilon.deinit(allocator);
            state.transitions.deinit(allocator);
        }
        self.states.deinit(allocator);
    }

    fn newState(self: *Builder) Error!usize {
        if (self.states.items.len >= max_states) return error.InvalidPattern;
        try self.states.append(self.allocator, .{});
        return self.states.items.len - 1;
    }

    fn addEpsilon(self: *Builder, from: usize, to: usize) Error!void {
        try self.states.items[from].epsilon.append(self.allocator, to);
    }

    fn addTransition(
        self: *Builder,
        from: usize,
        predicate: Predicate,
        to: usize,
    ) Error!void {
        try self.states.items[from].transitions.append(self.allocator, .{
            .predicate = predicate,
            .target = to,
        });
    }

    fn compileNode(self: *Builder, node: *const Node) Error!Fragment {
        return switch (node.*) {
            .empty => blk: {
                const start = try self.newState();
                const end = try self.newState();
                try self.addEpsilon(start, end);
                break :blk .{ .start = start, .end = end };
            },
            .literal => |codepoint| blk: {
                const start = try self.newState();
                const end = try self.newState();
                try self.addTransition(start, .{ .literal = codepoint }, end);
                break :blk .{ .start = start, .end = end };
            },
            .any => blk: {
                const start = try self.newState();
                const end = try self.newState();
                try self.addTransition(start, .any, end);
                break :blk .{ .start = start, .end = end };
            },
            .class => |class| blk: {
                const start = try self.newState();
                const end = try self.newState();
                try self.addTransition(start, .{ .class = class }, end);
                break :blk .{ .start = start, .end = end };
            },
            .sequence => |children| blk: {
                if (children.len == 0) return self.compileNode(&empty_node);
                var fragment = try self.compileNode(children[0]);
                const start = fragment.start;
                for (children[1..]) |child| {
                    const next = try self.compileNode(child);
                    try self.addEpsilon(fragment.end, next.start);
                    fragment.end = next.end;
                }
                break :blk .{ .start = start, .end = fragment.end };
            },
            .choice => |children| blk: {
                const start = try self.newState();
                const end = try self.newState();
                for (children) |child| {
                    const fragment = try self.compileNode(child);
                    try self.addEpsilon(start, fragment.start);
                    try self.addEpsilon(fragment.end, end);
                }
                break :blk .{ .start = start, .end = end };
            },
            .repeat => |repeat| try self.compileRepeat(repeat),
        };
    }

    fn compileRepeat(self: *Builder, repeat: Repeat) Error!Fragment {
        if (repeat.max) |maximum| {
            if (maximum == 0) {
                const start = try self.newState();
                const end = try self.newState();
                try self.addEpsilon(start, end);
                return .{ .start = start, .end = end };
            }
        }
        const start = try self.newState();
        var end = start;
        for (0..repeat.min) |_| {
            const fragment = try self.compileNode(repeat.child);
            try self.addEpsilon(end, fragment.start);
            end = fragment.end;
        }
        if (repeat.max) |maximum| {
            const optional = maximum - repeat.min;
            for (0..optional) |_| {
                const next = try self.newState();
                const fragment = try self.compileNode(repeat.child);
                try self.addEpsilon(end, next);
                try self.addEpsilon(end, fragment.start);
                try self.addEpsilon(fragment.end, next);
                end = next;
            }
            return .{ .start = start, .end = end };
        }
        const loop = try self.newState();
        const fragment = try self.compileNode(repeat.child);
        try self.addEpsilon(end, loop);
        try self.addEpsilon(loop, fragment.start);
        try self.addEpsilon(fragment.end, loop);
        const final = try self.newState();
        try self.addEpsilon(loop, final);
        return .{ .start = start, .end = final };
    }
};

const empty_node: Node = .empty;

fn literalCodepoint(item: ClassItem) ?u21 {
    return if (item.kind == .literal) item.lo else null;
}

fn predicateMatches(predicate: Predicate, codepoint: u21) bool {
    return switch (predicate) {
        .any => true,
        .literal => |literal| codepoint == literal,
        .class => |class| classMatches(class, codepoint),
    };
}

fn classMatches(class: *const Class, codepoint: u21) bool {
    var matched = false;
    for (class.items) |item| {
        if (classItemMatches(item, codepoint)) {
            matched = true;
            break;
        }
    }
    return if (class.negated) !matched else matched;
}

fn classItemMatches(item: ClassItem, codepoint: u21) bool {
    const positive = switch (item.kind) {
        .range => codepoint >= item.lo and codepoint <= item.hi,
        .literal => codepoint == item.lo,
        .digit => isDigit(codepoint),
        .space => isSpace(codepoint),
        .word => isWord(codepoint),
        .name_start => chars.isNCNameStartChar(codepoint),
        .name_char => chars.isNCNameChar(codepoint),
        .category => categoryMatches(item.category, codepoint),
    };
    return if (item.negated) !positive else positive;
}

fn isDigit(codepoint: u21) bool {
    if (codepoint >= '0' and codepoint <= '9') return true;
    return (codepoint >= 0x0660 and codepoint <= 0x0669) or
        (codepoint >= 0x06F0 and codepoint <= 0x06F9) or
        (codepoint >= 0x0966 and codepoint <= 0x096F) or
        (codepoint >= 0xFF10 and codepoint <= 0xFF19);
}

fn isSpace(codepoint: u21) bool {
    return codepoint == 0x09 or codepoint == 0x0A or codepoint == 0x0D or
        codepoint == 0x20 or codepoint == 0x85 or codepoint == 0xA0 or
        codepoint == 0x1680 or
        (codepoint >= 0x2000 and codepoint <= 0x200A) or
        codepoint == 0x2028 or codepoint == 0x2029 or
        codepoint == 0x202F or codepoint == 0x205F or
        codepoint == 0x3000;
}

fn isLetter(codepoint: u21) bool {
    if (codepoint < 0x80) return std.ascii.isAlphabetic(@intCast(codepoint));
    return (codepoint >= 0x00C0 and codepoint <= 0x00FF and
        codepoint != 0x00D7 and codepoint != 0x00F7) or
        (codepoint >= 0x0100 and codepoint <= 0x024F) or
        (codepoint >= 0x0370 and codepoint <= 0x03FF) or
        (codepoint >= 0x0400 and codepoint <= 0x052F) or
        (codepoint >= 0x0590 and codepoint <= 0x05FF) or
        (codepoint >= 0x0600 and codepoint <= 0x06FF) or
        (codepoint >= 0x0900 and codepoint <= 0x097F) or
        (codepoint >= 0x3040 and codepoint <= 0x309F) or
        (codepoint >= 0x30A0 and codepoint <= 0x30FF) or
        (codepoint >= 0x4E00 and codepoint <= 0x9FFF) or
        (codepoint >= 0xAC00 and codepoint <= 0xD7AF) or
        (codepoint >= 0xF900 and codepoint <= 0xFAFF);
}

fn isPunctuation(codepoint: u21) bool {
    if (codepoint < 0x80) {
        return switch (codepoint) {
            '!',
            '"',
            '#',
            '%',
            '&',
            '\'',
            '(',
            ')',
            '*',
            ',',
            '-',
            '.',
            '/',
            ':',
            ';',
            '?',
            '@',
            '[',
            '\\',
            ']',
            '_',
            '{',
            '}',
            => true,
            else => false,
        };
    }
    return (codepoint >= 0x2000 and codepoint <= 0x206F) or
        (codepoint >= 0x3001 and codepoint <= 0x303F) or
        codepoint == 0x00A1 or codepoint == 0x00BF;
}

fn isSymbol(codepoint: u21) bool {
    if (codepoint < 0x80) {
        return switch (codepoint) {
            '$', '+', '<', '=', '>', '^', '`', '|', '~' => true,
            else => false,
        };
    }
    return (codepoint >= 0x20A0 and codepoint <= 0x20CF) or
        (codepoint >= 0x2100 and codepoint <= 0x214F) or
        (codepoint >= 0x2190 and codepoint <= 0x2BFF);
}

fn isControl(codepoint: u21) bool {
    return codepoint < 0x20 or
        (codepoint >= 0x7F and codepoint <= 0x9F) or
        (codepoint >= 0xE000 and codepoint <= 0xF8FF);
}

fn isMark(codepoint: u21) bool {
    return (codepoint >= 0x0300 and codepoint <= 0x036F) or
        (codepoint >= 0x1AB0 and codepoint <= 0x1AFF) or
        (codepoint >= 0x1DC0 and codepoint <= 0x1DFF) or
        (codepoint >= 0x20D0 and codepoint <= 0x20FF) or
        (codepoint >= 0xFE20 and codepoint <= 0xFE2F);
}

fn isWord(codepoint: u21) bool {
    return !isPunctuation(codepoint) and !isSpace(codepoint) and
        !isControl(codepoint);
}

fn categoryMatches(name: []const u8, codepoint: u21) bool {
    if (std.mem.eql(u8, name, "L") or
        std.mem.eql(u8, name, "Lu") or
        std.mem.eql(u8, name, "Ll") or
        std.mem.eql(u8, name, "Lt") or
        std.mem.eql(u8, name, "Lm") or
        std.mem.eql(u8, name, "Lo"))
    {
        return isLetter(codepoint);
    }
    if (std.mem.eql(u8, name, "N") or
        std.mem.eql(u8, name, "Nd") or
        std.mem.eql(u8, name, "Nl") or
        std.mem.eql(u8, name, "No"))
    {
        return isDigit(codepoint);
    }
    if (std.mem.eql(u8, name, "Z") or
        std.mem.eql(u8, name, "Zs") or
        std.mem.eql(u8, name, "Zl") or
        std.mem.eql(u8, name, "Zp"))
    {
        return isSpace(codepoint);
    }
    if (std.mem.eql(u8, name, "P")) return isPunctuation(codepoint);
    if (std.mem.eql(u8, name, "S")) return isSymbol(codepoint);
    if (std.mem.eql(u8, name, "C") or std.mem.eql(u8, name, "Cc")) {
        return isControl(codepoint);
    }
    if (std.mem.eql(u8, name, "M")) return isMark(codepoint);
    return false;
}

const testing = std.testing;

fn expectMatch(pattern: []const u8, text: []const u8, expected: bool) !void {
    var regex = try compile(testing.allocator, pattern);
    defer regex.deinit();
    const actual = try regex.matches(testing.allocator, text);
    try testing.expectEqual(expected, actual);
}

test "XSD regex literals alternation and quantifiers" {
    try expectMatch("abc", "abc", true);
    try expectMatch("abc", "ab", false);
    try expectMatch("abc", "xabc", false);
    try expectMatch("a|b", "a", true);
    try expectMatch("a|b", "b", true);
    try expectMatch("a|b", "ab", false);
    try expectMatch("(ab)+", "abab", true);
    try expectMatch("(ab)+", "aba", false);
    try expectMatch("a?b", "b", true);
    try expectMatch("a*b", "aaab", true);
    try expectMatch("a{2,3}", "aa", true);
    try expectMatch("a{2,3}", "aaa", true);
    try expectMatch("a{2,3}", "a", false);
    try expectMatch("a{2,}", "aaaa", true);
}

test "XSD regex character classes and escapes" {
    try expectMatch("[a-z]+", "hello", true);
    try expectMatch("[a-z]+", "Hello", false);
    try expectMatch("[^0-9]+", "abc", true);
    try expectMatch("[^0-9]+", "a1", false);
    try expectMatch("\\d{3}", "123", true);
    try expectMatch("\\d{3}", "12a", false);
    try expectMatch("\\w+", "a1", true);
    try expectMatch("\\w+", "a_1", false);
    try expectMatch("\\s+", " \t", true);
    try expectMatch("\\i\\c*", "abc-1", true);
    try expectMatch("\\p{L}+", "abc", true);
    try expectMatch("\\p{Nd}+", "123", true);
    try expectMatch("\\P{L}+", "123", true);
}

test "XSD regex rejects malformed patterns" {
    try testing.expectError(error.InvalidPattern, compile(testing.allocator, "("));
    try testing.expectError(error.InvalidPattern, compile(testing.allocator, "[a"));
    try testing.expectError(error.InvalidPattern, compile(testing.allocator, "a{3,2}"));
    try testing.expectError(error.InvalidPattern, compile(testing.allocator, "a**"));
}
