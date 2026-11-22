//! RELAX NG compact syntax parsing.
//!
//! The lexer implements the preprocessing stages from the compact syntax
//! specification: escape interpretation (`\x{...}`), comments, annotations,
//! and the token set. The parser builds the same pattern tree as the XML
//! syntax parser, including scoped `define` lookup for nested grammars.
//! `include` and `external` are not supported in compact schemas yet.

const std = @import("std");
const encoding = @import("../encoding.zig");
const schema = @import("schema.zig");
const datatypes = @import("../xsd/datatypes.zig");
const regex = @import("../xsd/regex.zig");

pub const Error = schema.Error;

pub fn parse(
    allocator: std.mem.Allocator,
    source: []const u8,
) Error!schema.Schema {
    return parseWithOptions(allocator, source, .{});
}

pub fn parseWithOptions(
    allocator: std.mem.Allocator,
    source: []const u8,
    options: schema.Options,
) Error!schema.Schema {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();
    const tokens = try tokenize(arena_allocator, source);
    const root_scope = try arena_allocator.create(Scope);
    root_scope.* = .{
        .map = std.StringHashMap(*schema.Define).init(arena_allocator),
    };
    var parser: Parser = .{
        .arena = arena_allocator,
        .backing_allocator = allocator,
        .tokens = tokens,
        .scope = root_scope,
        .namespaces = std.StringHashMap([]const u8).init(arena_allocator),
        .datatypes = std.StringHashMap([]const u8).init(arena_allocator),
        .options = options,
        .base = options.base,
    };
    errdefer parser.deinitRegexes();
    try parser.parseTopLevel();
    for (parser.defines.items) |define| {
        if (define.pattern == null) return error.InvalidSchema;
    }
    return .{
        .arena = arena,
        .start = parser.start orelse return error.InvalidSchema,
        .regexes = try parser.regexes.toOwnedSlice(arena_allocator),
    };
}

const Scope = struct {
    map: std.StringHashMap(*schema.Define),
    parent: ?*Scope = null,
};

const Kind = enum {
    identifier,
    prefixed_name,
    ns_name,
    literal,
    keyword,
    lbrace,
    rbrace,
    lparen,
    rparen,
    comma,
    amp,
    pipe,
    equals,
    pipe_equals,
    amp_equals,
    tilde,
    question,
    star,
    plus,
    minus,
    eof,
};

const Token = struct {
    kind: Kind,
    text: []const u8 = "",
};

const keywords = [_][]const u8{
    "attribute", "default",  "datatypes", "div",        "element",
    "empty",     "external", "grammar",   "include",    "inherit",
    "list",      "mixed",    "namespace", "notAllowed", "parent",
    "start",     "string",   "text",      "token",
};

fn isKeyword(text: []const u8) bool {
    for (keywords) |keyword| {
        if (std.mem.eql(u8, text, keyword)) return true;
    }
    return false;
}

const Parser = struct {
    arena: std.mem.Allocator,
    backing_allocator: std.mem.Allocator,
    tokens: []const Token,
    index: usize = 0,
    namespaces: std.StringHashMap([]const u8),
    datatypes: std.StringHashMap([]const u8),
    default_namespace: []const u8 = "",
    scope: *Scope,
    options: schema.Options = .{},
    base: []const u8 = "",
    include_stack: std.ArrayList([]const u8) = .empty,
    start: ?*const schema.Pattern = null,
    start_interleave: bool = false,
    defines: std.ArrayList(*schema.Define) = .empty,
    grammar_depth: usize = 0,
    regexes: std.ArrayList(*regex.Regex) = .empty,
    name_class_except: bool = false,

    fn deinitRegexes(self: *Parser) void {
        for (self.regexes.items) |compiled| compiled.deinit();
    }

    fn peek(self: *Parser) Token {
        return self.tokens[self.index];
    }

    fn peekAt(self: *Parser, offset: usize) Token {
        const index = self.index + offset;
        if (index >= self.tokens.len) return self.tokens[self.tokens.len - 1];
        return self.tokens[index];
    }

    fn advance(self: *Parser) Token {
        const token = self.tokens[self.index];
        if (self.index + 1 < self.tokens.len) self.index += 1;
        return token;
    }

    fn at(self: *Parser, kind: Kind) bool {
        return self.peek().kind == kind;
    }

    fn expect(self: *Parser, kind: Kind) Error!Token {
        if (!self.at(kind)) return error.InvalidPattern;
        return self.advance();
    }

    fn atKeyword(self: *Parser, word: []const u8) bool {
        const token = self.peek();
        return token.kind == .keyword and std.mem.eql(u8, token.text, word);
    }

    fn expectKeyword(self: *Parser, word: []const u8) Error!void {
        if (!self.atKeyword(word)) return error.InvalidPattern;
        _ = self.advance();
    }

    fn isAssign(kind: Kind) bool {
        return kind == .equals or kind == .pipe_equals or
            kind == .amp_equals;
    }

    fn parseTopLevel(self: *Parser) Error!void {
        try self.parseDeclarations();
        if (self.startsPattern()) {
            self.start = try self.parsePattern();
            if (!self.at(.eof)) return error.InvalidPattern;
            return;
        }
        try self.parseGrammarContent();
        if (!self.at(.eof)) return error.InvalidPattern;
        if (self.start == null) return error.InvalidSchema;
    }

    fn startsPattern(self: *Parser) bool {
        const token = self.peek();
        return switch (token.kind) {
            .lparen, .prefixed_name, .literal => true,
            .identifier => !isAssign(self.peekAt(1).kind),
            .keyword => isPatternKeyword(token.text),
            else => false,
        };
    }

    fn isPatternKeyword(word: []const u8) bool {
        return std.mem.eql(u8, word, "element") or
            std.mem.eql(u8, word, "attribute") or
            std.mem.eql(u8, word, "list") or
            std.mem.eql(u8, word, "mixed") or
            std.mem.eql(u8, word, "text") or
            std.mem.eql(u8, word, "empty") or
            std.mem.eql(u8, word, "notAllowed") or
            std.mem.eql(u8, word, "parent") or
            std.mem.eql(u8, word, "external") or
            std.mem.eql(u8, word, "grammar") or
            std.mem.eql(u8, word, "string") or
            std.mem.eql(u8, word, "token");
    }

    fn parseDeclarations(self: *Parser) Error!void {
        while (true) {
            if (self.atKeyword("namespace")) {
                _ = self.advance();
                const prefix = try self.parseIdentifierOrKeyword();
                _ = try self.expect(.equals);
                const uri = try self.parseNamespaceUri();
                if (std.mem.eql(u8, prefix, "xmlns")) {
                    return error.InvalidSchema;
                }
                if (self.namespaces.contains(prefix)) {
                    return error.InvalidSchema;
                }
                try self.namespaces.put(prefix, uri);
                continue;
            }
            if (self.atKeyword("default")) {
                _ = self.advance();
                try self.expectKeyword("namespace");
                var prefix: ?[]const u8 = null;
                if (self.at(.identifier) or self.at(.keyword)) {
                    prefix = self.advance().text;
                }
                _ = try self.expect(.equals);
                const uri = try self.parseNamespaceUri();
                self.default_namespace = uri;
                if (prefix) |name| {
                    if (self.namespaces.contains(name)) {
                        return error.InvalidSchema;
                    }
                    try self.namespaces.put(name, uri);
                }
                continue;
            }
            if (self.atKeyword("datatypes")) {
                _ = self.advance();
                const prefix = try self.parseIdentifierOrKeyword();
                _ = try self.expect(.equals);
                const uri = try self.parseLiteral();
                if (std.mem.eql(u8, prefix, "xsd") and
                    !std.mem.eql(
                        u8,
                        uri,
                        "http://www.w3.org/2001/XMLSchema-datatypes",
                    ))
                {
                    return error.InvalidSchema;
                }
                if (self.datatypes.contains(prefix)) {
                    return error.InvalidSchema;
                }
                try self.datatypes.put(prefix, uri);
                continue;
            }
            return;
        }
    }

    fn parseNamespaceUri(self: *Parser) Error![]const u8 {
        if (self.atKeyword("inherit")) {
            _ = self.advance();
            return "";
        }
        return self.parseLiteral();
    }

    fn parseIdentifierOrKeyword(self: *Parser) Error![]const u8 {
        const token = self.peek();
        if (token.kind != .identifier and token.kind != .keyword) {
            return error.InvalidPattern;
        }
        return self.advance().text;
    }

    fn parseLiteral(self: *Parser) Error![]const u8 {
        const first = try self.expect(.literal);
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(self.arena, first.text);
        while (self.at(.tilde)) {
            _ = self.advance();
            const segment = try self.expect(.literal);
            try out.appendSlice(self.arena, segment.text);
        }
        return out.toOwnedSlice(self.arena);
    }

    fn parseGrammarContent(self: *Parser) Error!void {
        while (true) {
            const token = self.peek();
            if (token.kind == .eof or token.kind == .rbrace) return;
            if (token.kind == .keyword and
                std.mem.eql(u8, token.text, "start"))
            {
                _ = self.advance();
                const assign = try self.expectAssign();
                const pattern = try self.parsePattern();
                try self.addStart(pattern, assign == .amp_equals);
                continue;
            }
            if (token.kind == .keyword and
                std.mem.eql(u8, token.text, "div"))
            {
                _ = self.advance();
                _ = try self.expect(.lbrace);
                try self.parseGrammarContent();
                _ = try self.expect(.rbrace);
                continue;
            }
            if (token.kind == .keyword and
                std.mem.eql(u8, token.text, "include"))
            {
                try self.parseInclude();
                continue;
            }
            if (token.kind == .identifier and isAssign(self.peekAt(1).kind)) {
                try self.parseDefine();
                continue;
            }
            return error.InvalidPattern;
        }
    }

    fn expectAssign(self: *Parser) Error!Kind {
        const token = self.peek();
        if (!isAssign(token.kind)) return error.InvalidPattern;
        return self.advance().kind;
    }

    fn addStart(
        self: *Parser,
        pattern: *const schema.Pattern,
        interleave: bool,
    ) Error!void {
        if (self.start) |existing| {
            self.start = if (interleave or self.start_interleave)
                try makePattern(self.arena, .{ .interleave = .{
                    .left = existing,
                    .right = pattern,
                } })
            else
                try makePattern(self.arena, .{ .choice = .{
                    .left = existing,
                    .right = pattern,
                } });
        } else {
            self.start = pattern;
            self.start_interleave = interleave;
        }
    }

    fn parseDefine(self: *Parser) Error!void {
        const name = (try self.expect(.identifier)).text;
        const assign = try self.expectAssign();
        try self.parseDefineBody(name, assign, false);
    }

    fn parseDefineBody(
        self: *Parser,
        name: []const u8,
        assign: Kind,
        override: bool,
    ) Error!void {
        const existing = self.scope.map.get(name);
        if (override and existing != null) {
            const body = try self.parsePattern();
            const replacement = try self.arena.create(schema.Define);
            replacement.* = .{
                .name = try self.arena.dupe(u8, name),
                .pattern = body,
            };
            try self.defines.append(self.arena, replacement);
            try self.scope.map.put(replacement.name, replacement);
            return;
        }
        const define = existing orelse try self.createDefine(name);
        const body = try self.parsePattern();
        if (define.pattern) |previous| {
            define.pattern = if (assign == .amp_equals)
                try makePattern(self.arena, .{ .interleave = .{
                    .left = previous,
                    .right = body,
                } })
            else
                try makePattern(self.arena, .{ .choice = .{
                    .left = previous,
                    .right = body,
                } });
        } else {
            define.pattern = body;
        }
    }

    fn createDefine(self: *Parser, name: []const u8) Error!*schema.Define {
        const define = try self.arena.create(schema.Define);
        define.* = .{ .name = try self.arena.dupe(u8, name) };
        try self.defines.append(self.arena, define);
        try self.scope.map.put(define.name, define);
        return define;
    }

    fn findDefine(self: *Parser, name: []const u8) ?*schema.Define {
        var scope: ?*Scope = self.scope;
        while (scope) |current| {
            if (current.map.get(name)) |define| return define;
            scope = current.parent;
        }
        return null;
    }

    fn findDefineInParent(self: *Parser, name: []const u8) ?*schema.Define {
        var scope = self.scope.parent;
        while (scope) |current| {
            if (current.map.get(name)) |define| return define;
            scope = current.parent;
        }
        return null;
    }

    fn parsePattern(self: *Parser) Error!*const schema.Pattern {
        var left = try self.parsePostfix();
        var operator: ?Kind = null;
        while (true) {
            const kind = self.peek().kind;
            if (kind != .comma and kind != .amp and kind != .pipe) break;
            _ = self.advance();
            if (operator != null and operator.? != kind) {
                return error.InvalidPattern;
            }
            operator = kind;
            const right = try self.parsePostfix();
            left = try combinePatterns(self.arena, kind, left, right);
        }
        return left;
    }

    fn parsePostfix(self: *Parser) Error!*const schema.Pattern {
        var atom = try self.parseAtom();
        while (true) {
            switch (self.peek().kind) {
                .question => {
                    _ = self.advance();
                    atom = try makePattern(self.arena, .{ .optional = atom });
                },
                .star => {
                    _ = self.advance();
                    atom = try makePattern(self.arena, .{ .zero_or_more = atom });
                },
                .plus => {
                    _ = self.advance();
                    atom = try makePattern(self.arena, .{ .one_or_more = atom });
                },
                else => return atom,
            }
        }
    }

    fn parseAtom(self: *Parser) Error!*const schema.Pattern {
        const token = self.peek();
        if (token.kind == .keyword) {
            if (std.mem.eql(u8, token.text, "element")) {
                _ = self.advance();
                const name_class = try self.parseNameClass(true);
                _ = try self.expect(.lbrace);
                const content = try self.parsePattern();
                _ = try self.expect(.rbrace);
                return makePattern(self.arena, .{ .element = .{
                    .name_class = name_class,
                    .content = content,
                } });
            }
            if (std.mem.eql(u8, token.text, "attribute")) {
                _ = self.advance();
                const name_class = try self.parseNameClass(false);
                _ = try self.expect(.lbrace);
                const content = try self.parsePattern();
                _ = try self.expect(.rbrace);
                return makePattern(self.arena, .{ .attribute = .{
                    .name_class = name_class,
                    .content = content,
                } });
            }
            if (std.mem.eql(u8, token.text, "list") or
                std.mem.eql(u8, token.text, "mixed"))
            {
                _ = self.advance();
                _ = try self.expect(.lbrace);
                const inner = try self.parsePattern();
                _ = try self.expect(.rbrace);
                return makePattern(self.arena, if (std.mem.eql(
                    u8,
                    token.text,
                    "list",
                ))
                    .{ .list = inner }
                else
                    .{ .mixed = inner });
            }
            if (std.mem.eql(u8, token.text, "text")) {
                _ = self.advance();
                return makePattern(self.arena, .text);
            }
            if (std.mem.eql(u8, token.text, "empty")) {
                _ = self.advance();
                return makePattern(self.arena, .empty);
            }
            if (std.mem.eql(u8, token.text, "notAllowed")) {
                _ = self.advance();
                return makePattern(self.arena, .not_allowed);
            }
            if (std.mem.eql(u8, token.text, "parent")) {
                _ = self.advance();
                if (self.grammar_depth == 0) return error.InvalidPattern;
                const name = (try self.expect(.identifier)).text;
                const define = self.findDefineInParent(name) orelse
                    return error.InvalidPattern;
                return makePattern(self.arena, .{ .parent_ref = define });
            }
            if (std.mem.eql(u8, token.text, "external")) {
                _ = self.advance();
                return self.parseExternal();
            }
            if (std.mem.eql(u8, token.text, "grammar")) {
                return self.parseNestedGrammar();
            }
            if (std.mem.eql(u8, token.text, "string") or
                std.mem.eql(u8, token.text, "token"))
            {
                _ = self.advance();
                return self.parseDataOrValue("", token.text);
            }
            return error.InvalidPattern;
        }
        if (token.kind == .prefixed_name) {
            _ = self.advance();
            const resolved = try self.resolveDatatype(token.text);
            return self.parseDataOrValue(resolved.library, resolved.local);
        }
        if (token.kind == .identifier) {
            _ = self.advance();
            const define = self.findDefine(token.text) orelse
                try self.createDefine(token.text);
            return makePattern(self.arena, .{ .ref = define });
        }
        if (token.kind == .literal) {
            const text = try self.parseLiteral();
            return makePattern(self.arena, .{ .value = .{
                .library = "",
                .type_name = "token",
                .kind = .token,
                .text = text,
            } });
        }
        if (token.kind == .lparen) {
            _ = self.advance();
            const inner = try self.parsePattern();
            _ = try self.expect(.rparen);
            return inner;
        }
        return error.InvalidPattern;
    }

    const ResolvedDatatype = struct {
        library: []const u8,
        local: []const u8,
    };

    fn resolveDatatype(self: *Parser, raw: []const u8) Error!ResolvedDatatype {
        const colon = std.mem.indexOfScalar(u8, raw, ':') orelse
            return error.InvalidPattern;
        const prefix = raw[0..colon];
        const local = raw[colon + 1 ..];
        const library = if (std.mem.eql(u8, prefix, "xsd"))
            "http://www.w3.org/2001/XMLSchema-datatypes"
        else
            self.datatypes.get(prefix) orelse return error.InvalidSchema;
        return .{ .library = library, .local = local };
    }

    fn datatypeKind(
        library: []const u8,
        type_name: []const u8,
    ) Error!datatypes.Kind {
        if (library.len == 0) {
            if (std.mem.eql(u8, type_name, "string")) return .string;
            if (std.mem.eql(u8, type_name, "token")) return .token;
            return error.InvalidSchema;
        }
        if (!isXsdLibrary(library)) return error.InvalidSchema;
        if (datatypes.builtin(type_name)) |builtin| return builtin.kind;
        return error.InvalidSchema;
    }

    fn parseDataOrValue(
        self: *Parser,
        library: []const u8,
        type_name: []const u8,
    ) Error!*const schema.Pattern {
        const kind = try datatypeKind(library, type_name);
        if (self.at(.literal)) {
            const text = try self.parseLiteral();
            return makePattern(self.arena, .{ .value = .{
                .library = library,
                .type_name = type_name,
                .kind = kind,
                .text = text,
            } });
        }
        var facets: datatypes.Facets = .{};
        if (self.at(.lbrace)) {
            _ = self.advance();
            while (!self.at(.rbrace)) {
                const name = try self.parseIdentifierOrKeyword();
                _ = try self.expect(.equals);
                const value = try self.parseLiteral();
                try self.applyParam(&facets, name, value);
                if (self.at(.comma)) _ = self.advance();
            }
            _ = try self.expect(.rbrace);
        }
        var except: ?*const schema.Pattern = null;
        if (self.at(.minus)) {
            _ = self.advance();
            except = try self.parsePattern();
        }
        return makePattern(self.arena, .{ .data = .{
            .library = library,
            .type_name = type_name,
            .kind = kind,
            .facets = facets,
            .except = except,
        } });
    }

    fn applyParam(
        self: *Parser,
        facets: *datatypes.Facets,
        name: []const u8,
        value: []const u8,
    ) Error!void {
        const owned = try self.arena.dupe(u8, value);
        if (std.mem.eql(u8, name, "pattern")) {
            const compiled = try self.arena.create(regex.Regex);
            compiled.* = regex.compile(self.backing_allocator, owned) catch |err|
                switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.InvalidPattern,
                };
            try self.regexes.append(self.arena, compiled);
            if (facets.patterns.len == 0) {
                const list = try self.arena.alloc(*const regex.Regex, 1);
                list[0] = compiled;
                facets.patterns = list;
            } else {
                const list = try self.arena.alloc(
                    *const regex.Regex,
                    facets.patterns.len + 1,
                );
                @memcpy(list[0..facets.patterns.len], facets.patterns);
                list[facets.patterns.len] = compiled;
                facets.patterns = list;
            }
            return;
        }
        if (std.mem.eql(u8, name, "minInclusive")) {
            facets.min_inclusive = owned;
        } else if (std.mem.eql(u8, name, "maxInclusive")) {
            facets.max_inclusive = owned;
        } else if (std.mem.eql(u8, name, "minExclusive")) {
            facets.min_exclusive = owned;
        } else if (std.mem.eql(u8, name, "maxExclusive")) {
            facets.max_exclusive = owned;
        } else if (std.mem.eql(u8, name, "length")) {
            facets.length = std.fmt.parseInt(usize, value, 10) catch
                return error.InvalidPattern;
        } else if (std.mem.eql(u8, name, "minLength")) {
            facets.min_length = std.fmt.parseInt(usize, value, 10) catch
                return error.InvalidPattern;
        } else if (std.mem.eql(u8, name, "maxLength")) {
            facets.max_length = std.fmt.parseInt(usize, value, 10) catch
                return error.InvalidPattern;
        } else if (std.mem.eql(u8, name, "totalDigits")) {
            facets.total_digits = std.fmt.parseInt(usize, value, 10) catch
                return error.InvalidPattern;
        } else if (std.mem.eql(u8, name, "fractionDigits")) {
            facets.fraction_digits = std.fmt.parseInt(usize, value, 10) catch
                return error.InvalidPattern;
        } else if (std.mem.eql(u8, name, "enumeration")) {
            const list = try self.arena.alloc(
                []const u8,
                facets.enumeration.len + 1,
            );
            @memcpy(list[0..facets.enumeration.len], facets.enumeration);
            list[facets.enumeration.len] = owned;
            facets.enumeration = list;
        } else {
            return error.InvalidPattern;
        }
    }

    fn parseNameClass(
        self: *Parser,
        element: bool,
    ) Error!*const schema.NameClass {
        var left = try self.parseNameClassAtom(element);
        var used_except = self.name_class_except;
        self.name_class_except = false;
        var has_union = false;
        while (self.at(.pipe)) {
            has_union = true;
            _ = self.advance();
            const right = try self.parseNameClassAtom(element);
            if (self.name_class_except) used_except = true;
            self.name_class_except = false;
            left = try makeNameClass(self.arena, .{ .choice = .{
                .left = left,
                .right = right,
            } });
        }
        if (has_union and used_except) return error.InvalidPattern;
        return left;
    }

    fn parseNameClassAtom(
        self: *Parser,
        element: bool,
    ) Error!*const schema.NameClass {
        const token = self.peek();
        switch (token.kind) {
            .identifier, .keyword => {
                _ = self.advance();
                const ns = if (element) self.default_namespace else "";
                return makeNameClass(self.arena, .{ .name = .{
                    .ns = ns,
                    .local = token.text,
                } });
            },
            .prefixed_name => {
                _ = self.advance();
                const colon = std.mem.indexOfScalar(u8, token.text, ':') orelse
                    return error.InvalidPattern;
                const prefix = token.text[0..colon];
                const local = token.text[colon + 1 ..];
                const ns = try self.resolveNamespace(prefix);
                return makeNameClass(self.arena, .{ .name = .{
                    .ns = ns,
                    .local = local,
                } });
            },
            .ns_name => {
                _ = self.advance();
                const ns = try self.resolveNamespace(token.text);
                var except: ?*const schema.NameClass = null;
                if (self.at(.minus)) {
                    _ = self.advance();
                    self.name_class_except = true;
                    except = try self.parseNameClassAtom(element);
                }
                return makeNameClass(self.arena, .{ .ns_name = .{
                    .ns = ns,
                    .except = except,
                } });
            },
            .star => {
                _ = self.advance();
                var except: ?*const schema.NameClass = null;
                if (self.at(.minus)) {
                    _ = self.advance();
                    self.name_class_except = true;
                    except = try self.parseNameClassAtom(element);
                }
                return makeNameClass(self.arena, .{ .any_name = .{
                    .except = except,
                } });
            },
            .lparen => {
                _ = self.advance();
                const inner = try self.parseNameClass(element);
                self.name_class_except = false;
                _ = try self.expect(.rparen);
                return inner;
            },
            else => return error.InvalidPattern,
        }
    }

    fn resolveNamespace(self: *Parser, prefix: []const u8) Error![]const u8 {
        if (std.mem.eql(u8, prefix, "xml")) {
            return "http://www.w3.org/XML/1998/namespace";
        }
        return self.namespaces.get(prefix) orelse error.InvalidSchema;
    }

    fn parseInclude(self: *Parser) Error!void {
        _ = self.advance();
        const href = try self.parseLiteral();
        const inherited = try self.parseInherit();
        const source = try self.loadCompact(href);
        const included_start = try self.parseIncludedFile(source, inherited);
        if (self.at(.lbrace)) {
            _ = self.advance();
            const before = self.start;
            try self.parseIncludeContent();
            _ = try self.expect(.rbrace);
            if (self.start == before) {
                if (included_start) |pattern| {
                    try self.addStart(pattern, false);
                }
            }
        } else if (included_start) |pattern| {
            try self.addStart(pattern, false);
        }
    }

    fn parseIncludeContent(self: *Parser) Error!void {
        while (true) {
            const token = self.peek();
            if (token.kind == .eof or token.kind == .rbrace) return;
            if (token.kind == .keyword and
                std.mem.eql(u8, token.text, "start"))
            {
                _ = self.advance();
                const assign = try self.expectAssign();
                const pattern = try self.parsePattern();
                try self.addStart(pattern, assign == .amp_equals);
                continue;
            }
            if (token.kind == .keyword and
                std.mem.eql(u8, token.text, "div"))
            {
                _ = self.advance();
                _ = try self.expect(.lbrace);
                try self.parseIncludeContent();
                _ = try self.expect(.rbrace);
                continue;
            }
            if (token.kind == .identifier and isAssign(self.peekAt(1).kind)) {
                try self.parseOverrideDefine();
                continue;
            }
            return error.InvalidPattern;
        }
    }

    /// A definition inside an include block replaces the included definition.
    /// References inside the replacement body still resolve to the included
    /// definition.
    fn parseOverrideDefine(self: *Parser) Error!void {
        const name = (try self.expect(.identifier)).text;
        const assign = try self.expectAssign();
        try self.parseDefineBody(name, assign, true);
    }

    fn parseExternal(self: *Parser) Error!*const schema.Pattern {
        const href = try self.parseLiteral();
        const inherited = try self.parseInherit();
        const source = try self.loadCompact(href);
        return self.parseExternalFile(source, inherited);
    }

    fn parseInherit(self: *Parser) Error![]const u8 {
        if (!self.atKeyword("inherit")) return self.default_namespace;
        _ = self.advance();
        _ = try self.expect(.equals);
        const prefix = try self.parseIdentifierOrKeyword();
        return self.resolveNamespace(prefix);
    }

    fn loadCompact(self: *Parser, href: []const u8) Error![]const u8 {
        const resolver = self.options.resolver orelse
            return error.InvalidSchema;
        const resource = resolver.load(
            resolver.context,
            href,
            self.base,
        ) orelse return error.InvalidSchema;
        const uri = if (resource.uri.len != 0) resource.uri else href;
        const owned_uri = try self.arena.dupe(u8, uri);
        for (self.include_stack.items) |active| {
            if (std.mem.eql(u8, active, owned_uri)) {
                return error.InvalidSchema;
            }
        }
        try self.include_stack.append(self.arena, owned_uri);
        return decodeCompact(self.arena, resource.data) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidSchema,
        };
    }

    const SavedEnvironment = struct {
        tokens: []const Token,
        index: usize,
        namespaces: std.StringHashMap([]const u8),
        datatypes: std.StringHashMap([]const u8),
        default_namespace: []const u8,
        start: ?*const schema.Pattern,
        start_interleave: bool,
    };

    fn saveEnvironment(self: *Parser) SavedEnvironment {
        return .{
            .tokens = self.tokens,
            .index = self.index,
            .namespaces = self.namespaces,
            .datatypes = self.datatypes,
            .default_namespace = self.default_namespace,
            .start = self.start,
            .start_interleave = self.start_interleave,
        };
    }

    fn restoreEnvironment(self: *Parser, saved: SavedEnvironment) void {
        self.tokens = saved.tokens;
        self.index = saved.index;
        self.namespaces = saved.namespaces;
        self.datatypes = saved.datatypes;
        self.default_namespace = saved.default_namespace;
        self.start = saved.start;
        self.start_interleave = saved.start_interleave;
    }

    fn enterFile(self: *Parser, source: []const u8, inherited: []const u8) Error!void {
        self.namespaces = std.StringHashMap([]const u8).init(self.arena);
        self.datatypes = std.StringHashMap([]const u8).init(self.arena);
        self.default_namespace = inherited;
        self.tokens = try tokenize(self.arena, source);
        self.index = 0;
        self.start = null;
        self.start_interleave = false;
    }

    fn parseIncludedFile(
        self: *Parser,
        source: []const u8,
        inherited: []const u8,
    ) Error!?*const schema.Pattern {
        const saved = self.saveEnvironment();
        defer {
            self.restoreEnvironment(saved);
            _ = self.include_stack.pop();
        }
        try self.enterFile(source, inherited);
        try self.parseDeclarations();
        try self.parseGrammarContent();
        if (!self.at(.eof)) return error.InvalidPattern;
        return self.start;
    }

    fn parseExternalFile(
        self: *Parser,
        source: []const u8,
        inherited: []const u8,
    ) Error!*const schema.Pattern {
        const saved = self.saveEnvironment();
        defer {
            self.restoreEnvironment(saved);
            _ = self.include_stack.pop();
        }
        try self.enterFile(source, inherited);
        try self.parseDeclarations();
        if (!self.startsPattern()) return error.InvalidPattern;
        const pattern = try self.parsePattern();
        if (!self.at(.eof)) return error.InvalidPattern;
        return pattern;
    }

    fn parseNestedGrammar(self: *Parser) Error!*const schema.Pattern {
        _ = self.advance();
        _ = try self.expect(.lbrace);
        const outer_scope = self.scope;
        const scope = try self.arena.create(Scope);
        scope.* = .{
            .map = std.StringHashMap(*schema.Define).init(self.arena),
            .parent = outer_scope,
        };
        self.scope = scope;
        defer self.scope = outer_scope;
        const outer_start = self.start;
        const outer_interleave = self.start_interleave;
        self.start = null;
        self.start_interleave = false;
        defer {
            self.start = outer_start;
            self.start_interleave = outer_interleave;
        }
        self.grammar_depth += 1;
        defer self.grammar_depth -= 1;
        try self.parseGrammarContent();
        _ = try self.expect(.rbrace);
        return self.start orelse error.InvalidSchema;
    }
};

fn makePattern(
    allocator: std.mem.Allocator,
    value: schema.Pattern,
) Error!*const schema.Pattern {
    const ptr = try allocator.create(schema.Pattern);
    ptr.* = value;
    return ptr;
}

fn makeNameClass(
    allocator: std.mem.Allocator,
    value: schema.NameClass,
) Error!*const schema.NameClass {
    const ptr = try allocator.create(schema.NameClass);
    ptr.* = value;
    return ptr;
}

fn combinePatterns(
    allocator: std.mem.Allocator,
    operator: Kind,
    left: *const schema.Pattern,
    right: *const schema.Pattern,
) Error!*const schema.Pattern {
    return switch (operator) {
        .comma => makePattern(allocator, .{ .group = .{
            .left = left,
            .right = right,
        } }),
        .amp => makePattern(allocator, .{ .interleave = .{
            .left = left,
            .right = right,
        } }),
        .pipe => makePattern(allocator, .{ .choice = .{
            .left = left,
            .right = right,
        } }),
        else => error.InvalidPattern,
    };
}

fn isXsdLibrary(library: []const u8) bool {
    return std.mem.eql(
        u8,
        library,
        "http://www.w3.org/2001/XMLSchema-datatypes",
    ) or std.mem.eql(
        u8,
        library,
        "http://relaxng.org/ns/compatibility/datatypes/1.0",
    );
}

fn decodeCompact(
    allocator: std.mem.Allocator,
    source: []const u8,
) ![]const u8 {
    if (source.len >= 2 and source[0] == 0xFF and source[1] == 0xFE) {
        return encoding.decodeWithEncodingAlloc(
            allocator,
            source,
            .utf16_le,
            64 * 1024 * 1024,
        );
    }
    if (source.len >= 2 and source[0] == 0xFE and source[1] == 0xFF) {
        return encoding.decodeWithEncodingAlloc(
            allocator,
            source,
            .utf16_be,
            64 * 1024 * 1024,
        );
    }
    return encoding.decodeWithEncodingAlloc(
        allocator,
        source,
        .utf8,
        64 * 1024 * 1024,
    );
}

fn preprocess(
    allocator: std.mem.Allocator,
    source: []const u8,
) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var index: usize = 0;
    while (index < source.len) {
        if (source[index] == '\\') {
            var cursor = index + 1;
            var xs: usize = 0;
            while (cursor < source.len and source[cursor] == 'x') : (cursor += 1) {
                xs += 1;
            }
            if (xs != 0 and cursor < source.len and source[cursor] == '{') {
                cursor += 1;
                var value: u32 = 0;
                var digits: usize = 0;
                while (cursor < source.len and source[cursor] != '}') : (cursor += 1) {
                    const digit = std.fmt.charToDigit(source[cursor], 16) catch
                        return error.InvalidPattern;
                    value = value * 16 + digit;
                    digits += 1;
                    if (digits > 6) return error.InvalidPattern;
                }
                if (cursor >= source.len or digits == 0) {
                    return error.InvalidPattern;
                }
                cursor += 1;
                if (value > 0x10FFFF or (value >= 0xD800 and value <= 0xDFFF)) {
                    return error.InvalidPattern;
                }
                var buffer: [4]u8 = undefined;
                const length = std.unicode.utf8Encode(
                    @intCast(value),
                    &buffer,
                ) catch return error.InvalidPattern;
                try out.appendSlice(allocator, buffer[0..length]);
                index = cursor;
                continue;
            }
        }
        try out.append(allocator, source[index]);
        index += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn tokenize(
    allocator: std.mem.Allocator,
    source: []const u8,
) Error![]const Token {
    const text = try preprocess(allocator, source);
    var tokens: std.ArrayList(Token) = .empty;
    errdefer tokens.deinit(allocator);
    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        if (byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n') {
            index += 1;
            continue;
        }
        if (byte == '#') {
            while (index < text.len and text[index] != '\n') index += 1;
            continue;
        }
        if (byte == '[') {
            index = try skipAnnotation(text, index);
            continue;
        }
        if (byte == '>') {
            if (index + 1 >= text.len or text[index + 1] != '>') {
                return error.InvalidPattern;
            }
            index = try skipFollowAnnotation(text, index + 2);
            continue;
        }
        if (byte == '"' or byte == '\'') {
            const start = index;
            var quote_count: usize = 1;
            if (index + 2 < text.len and text[index + 1] == byte and
                text[index + 2] == byte)
            {
                quote_count = 3;
            }
            index += quote_count;
            const content_start = index;
            if (quote_count == 1) {
                while (index < text.len and text[index] != byte) {
                    if (text[index] == '\n') return error.InvalidPattern;
                    index += 1;
                }
                if (index >= text.len) return error.InvalidPattern;
                try tokens.append(allocator, .{
                    .kind = .literal,
                    .text = text[content_start..index],
                });
                index += 1;
            } else {
                while (index + 2 < text.len) {
                    if (text[index] == byte and text[index + 1] == byte and
                        text[index + 2] == byte)
                    {
                        break;
                    }
                    index += 1;
                }
                if (index + 2 >= text.len) return error.InvalidPattern;
                try tokens.append(allocator, .{
                    .kind = .literal,
                    .text = text[content_start..index],
                });
                index += 3;
            }
            _ = start;
            continue;
        }
        if (byte == '\\') {
            index += 1;
            const name_start = index;
            index = scanNCName(text, index);
            if (index == name_start) return error.InvalidPattern;
            try tokens.append(allocator, .{
                .kind = .identifier,
                .text = text[name_start..index],
            });
            continue;
        }
        if (isNameStart(byte)) {
            const name_start = index;
            index = scanNCName(text, index);
            const name = text[name_start..index];
            if (index < text.len and text[index] == ':') {
                index += 1;
                if (index < text.len and text[index] == '*') {
                    index += 1;
                    try tokens.append(allocator, .{
                        .kind = .ns_name,
                        .text = name,
                    });
                    continue;
                }
                const local_start = index;
                index = scanNCName(text, index);
                if (index == local_start) return error.InvalidPattern;
                try tokens.append(allocator, .{
                    .kind = .prefixed_name,
                    .text = text[name_start..index],
                });
                continue;
            }
            try tokens.append(allocator, .{
                .kind = if (isKeyword(name)) .keyword else .identifier,
                .text = name,
            });
            continue;
        }
        const kind: Kind = switch (byte) {
            '{' => .lbrace,
            '}' => .rbrace,
            '(' => .lparen,
            ')' => .rparen,
            ',' => .comma,
            '~' => .tilde,
            '?' => .question,
            '*' => .star,
            '+' => .plus,
            '-' => .minus,
            '&' => blk: {
                if (index + 1 < text.len and text[index + 1] == '=') {
                    index += 1;
                    break :blk .amp_equals;
                }
                break :blk .amp;
            },
            '|' => blk: {
                if (index + 1 < text.len and text[index + 1] == '=') {
                    index += 1;
                    break :blk .pipe_equals;
                }
                break :blk .pipe;
            },
            '=' => .equals,
            else => return error.InvalidPattern,
        };
        try tokens.append(allocator, .{ .kind = kind });
        index += 1;
    }
    try tokens.append(allocator, .{ .kind = .eof });
    return tokens.toOwnedSlice(allocator);
}

fn skipAnnotation(text: []const u8, start: usize) Error!usize {
    var index = start;
    var depth: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        if (byte == '[') {
            depth += 1;
            index += 1;
            continue;
        }
        if (byte == ']') {
            depth -= 1;
            index += 1;
            if (depth == 0) return index;
            continue;
        }
        if (byte == '"' or byte == '\'') {
            index += 1;
            while (index < text.len and text[index] != byte) index += 1;
            if (index >= text.len) return error.InvalidPattern;
            index += 1;
            continue;
        }
        index += 1;
    }
    return error.InvalidPattern;
}

fn skipFollowAnnotation(text: []const u8, start: usize) Error!usize {
    var index = start;
    while (index < text.len and
        (text[index] == ' ' or text[index] == '\t' or
            text[index] == '\r' or text[index] == '\n'))
    {
        index += 1;
    }
    if (index >= text.len or !isNameStart(text[index])) {
        return error.InvalidPattern;
    }
    index = scanNCName(text, index);
    if (index < text.len and text[index] == ':') {
        index += 1;
        const local_start = index;
        index = scanNCName(text, index);
        if (index == local_start) return error.InvalidPattern;
    }
    while (index < text.len and
        (text[index] == ' ' or text[index] == '\t' or
            text[index] == '\r' or text[index] == '\n'))
    {
        index += 1;
    }
    if (index < text.len and text[index] == '[') {
        return skipAnnotation(text, index);
    }
    return index;
}

fn isNameStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_' or byte >= 0x80;
}

fn isNameChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or
        byte == '.' or byte >= 0x80;
}

fn scanNCName(text: []const u8, start: usize) usize {
    if (start >= text.len or !isNameStart(text[start])) return start;
    var index = start + 1;
    while (index < text.len and isNameChar(text[index])) index += 1;
    return index;
}
