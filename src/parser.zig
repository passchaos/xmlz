//! Zero-copy XML 1.0 pull parser with full well-formedness checking.
//!
//! The parser borrows every name, attribute value, text span, comment, and PI
//! payload from the input slice. Tokenization performs no allocation. DTD
//! internal-subset entity declarations are collected into a fixed-capacity
//! table; expansion limits are enforced when consumers decode references.
//!
//! Input must already be UTF-8 (use `encoding.decodeAlloc` for BOM stripping
//! and legacy encodings). A leading UTF-8 BOM is accepted and skipped.

const std = @import("std");
const chars = @import("chars.zig");
const entities = @import("entities.zig");
const encoding = @import("encoding.zig");
const markup = @import("markup.zig");

pub const max_open_elements = 512;
pub const max_attributes = 64;

pub const SourceRange = struct {
    start: usize,
    end: usize,
};

pub const Options = struct {
    /// Maximum element nesting depth. Values above `max_open_elements` are
    /// clamped; the default matches libxml2's classic security limit.
    max_depth: usize = 256,
    /// Maximum attributes on one element. Values above `max_attributes` are
    /// clamped.
    max_attributes: usize = 64,
    /// Accept references to undeclared entities as literal text. Disabled by
    /// default: an undeclared entity is a well-formedness error.
    allow_undeclared_entities: bool = false,
    /// Accept `<!DOCTYPE ...>`. Disabled rejects every doctype.
    allow_doctype: bool = true,
    /// Allocator used only when a DTD needs parameter-entity expansion or an
    /// external subset/entity must be loaded. Without it those features report
    /// `UnsupportedParameterEntity`.
    allocator: ?std.mem.Allocator = null,
    /// Optional resolver for external DTD subsets and parsed entities. The
    /// returned slice must remain valid for the parser's lifetime.
    resolver: ?ExternalResolver = null,
    /// Maximum nesting of external parsed entities and parameter entities.
    max_external_depth: usize = 8,
};

pub const ExternalResolver = struct {
    context: ?*anyopaque = null,
    /// Resolve an external identifier. Return null when the resource is not
    /// available; the parser then treats declarations in it as unavailable.
    resolve: *const fn (
        context: ?*anyopaque,
        system_id: []const u8,
        public_id: ?[]const u8,
        base_system_id: ?[]const u8,
    ) ?[]const u8,
};

pub const Error = error{
    OutOfMemory,
    NonUtf8Input,
    UnexpectedEndOfInput,
    InvalidSyntax,
    InvalidCharacter,
    InvalidName,
    InvalidStartTag,
    InvalidEndTag,
    MismatchedEndTag,
    DuplicateAttribute,
    InvalidAttributeValue,
    InvalidEntityReference,
    UndeclaredEntity,
    UnparsedEntityReference,
    EntityRecursion,
    EntityLimitExceeded,
    DepthLimitExceeded,
    AttributeLimitExceeded,
    MultipleRootElements,
    MissingRootElement,
    ContentAfterRoot,
    InvalidComment,
    InvalidCdata,
    InvalidProcessingInstruction,
    InvalidXmlDeclaration,
    UnsupportedXmlVersion,
    InvalidDoctype,
    UnexpectedDoctype,
    UnexpectedMarkup,
    RootElementMismatch,
    UnsupportedParameterEntity,
    ExternalEntityDepthExceeded,
};

pub const Attribute = struct {
    /// Raw qualified name exactly as authored.
    name: []const u8,
    /// Raw value: references are not expanded and line endings are untouched.
    value: []const u8,
    name_range: SourceRange,
    value_range: SourceRange,
};

pub const StartElement = struct {
    /// Raw qualified name exactly as authored.
    name: []const u8,
    name_range: SourceRange,
    attrs: []const Attribute,
    self_closing: bool,
    /// Depth after opening the element; the root element has depth 1.
    depth: usize,
};

pub const EndElement = struct {
    name: []const u8,
    name_range: SourceRange,
    /// Depth of the element being closed; the root element has depth 1.
    depth: usize,
};

pub const Declaration = struct {
    raw: []const u8,
    version: []const u8,
    encoding: ?[]const u8,
    standalone: ?bool,
};

pub const Instruction = struct {
    target: []const u8,
    data: []const u8,
};

pub const Doctype = struct {
    raw: []const u8,
    name: []const u8,
    public_id: ?[]const u8,
    system_id: ?[]const u8,
    has_internal_subset: bool,
};

pub const Event = union(enum) {
    xml_declaration: Declaration,
    start_element: StartElement,
    end_element: EndElement,
    text: []const u8,
    cdata: []const u8,
    comment: []const u8,
    processing_instruction: Instruction,
    doctype: Doctype,
};

const State = enum {
    prolog,
    content,
    epilog,
    done,
};

const InputFrame = struct {
    input: []const u8,
    pos: usize,
    current_entity: []const u8,
    entity_entry_depth: usize,
    resolver_base: ?[]const u8,
};

pub const max_entity_frames = 16;

pub const Parser = struct {
    input: []const u8,
    pos: usize = 0,
    state: State = .prolog,
    depth: usize = 0,
    root_seen: bool = false,
    seen_doctype: bool = false,
    doctype_name: []const u8 = "",
    decl_allowed: bool = true,
    utf8_input: bool = true,
    options: Options,
    open_names: [max_open_elements][]const u8 = undefined,
    attrs: [max_attributes]Attribute = undefined,
    entity_table: entities.Table = .{},
    parameter_entities: entities.Table = .{},
    external_depth: usize = 0,
    external_checked: std.StaticBitSet(entities.max_entities) = .empty,
    fragment: bool = false,
    external_subset_present: bool = false,
    parameter_reference_seen: bool = false,
    standalone: ?bool = null,
    resolver_base: ?[]const u8 = null,
    allow_pe_in_declarations: bool = false,
    external_stack: [16][]const u8 = undefined,
    external_stack_len: usize = 0,
    frames: [max_entity_frames]InputFrame = undefined,
    frame_count: usize = 0,
    current_entity: []const u8 = "",
    entity_entry_depth: usize = 0,
    scratch: ?std.heap.ArenaAllocator = null,
    error_offset: usize = 0,
    error_input: ?[]const u8 = null,

    pub fn init(input: []const u8, options: Options) Parser {
        var self: Parser = .{
            .input = input,
            .options = options,
        };
        if (self.options.max_depth == 0) self.options.max_depth = 1;
        if (self.options.max_depth > max_open_elements) {
            self.options.max_depth = max_open_elements;
        }
        if (self.options.max_attributes == 0) self.options.max_attributes = 1;
        if (self.options.max_attributes > max_attributes) {
            self.options.max_attributes = max_attributes;
        }

        if (std.mem.startsWith(u8, input, "\xEF\xBB\xBF")) {
            self.pos = 3;
        } else if (std.mem.startsWith(u8, input, "\xFF\xFE") or
            std.mem.startsWith(u8, input, "\xFE\xFF") or
            std.mem.startsWith(u8, input, "\x00\x00\xFE\xFF") or
            std.mem.startsWith(u8, input, "\xFF\xFE\x00\x00"))
        {
            self.utf8_input = false;
        }
        return self;
    }

    /// Create a parser for external parsed entity content: a sequence of
    /// elements, text, and markup without a single-root requirement.
    pub fn initFragment(input: []const u8, options: Options) Parser {
        var self = init(input, options);
        self.state = .content;
        self.fragment = true;
        return self;
    }

    /// Release DTD expansion scratch storage. Safe to call more than once.
    pub fn deinit(self: *Parser) void {
        if (self.scratch) |*arena| arena.deinit();
        self.scratch = null;
    }

    /// Entity declarations collected from the DOCTYPE internal subset.
    pub fn entityTable(self: *const Parser) *const entities.Table {
        return &self.entity_table;
    }

    /// Byte offset where the most recent error was detected.
    pub fn errorOffset(self: *const Parser) usize {
        return self.error_offset;
    }

    /// Input slice that was active when the most recent error was detected.
    pub fn errorInput(self: *const Parser) []const u8 {
        return self.error_input orelse self.input;
    }

    pub const LineColumn = struct {
        line: usize,
        column: usize,
    };

    /// Compute a 1-based line/column for a byte offset. Errors are rare, so
    /// this is computed lazily instead of tracking position on every byte.
    pub fn lineColumn(self: *const Parser, offset: usize) LineColumn {
        const source = self.error_input orelse self.input;
        const limit = @min(offset, source.len);
        var line: usize = 1;
        var line_start: usize = 0;
        var index: usize = 0;
        while (index < limit) : (index += 1) {
            if (source[index] == '\n') {
                line += 1;
                line_start = index + 1;
            }
        }
        return .{ .line = line, .column = offset - line_start + 1 };
    }

    /// Return the next event, or null at a clean end of document.
    pub fn next(self: *Parser) Error!?Event {
        if (!self.utf8_input) {
            self.error_offset = 0;
            return error.NonUtf8Input;
        }
        while (true) {
            switch (self.state) {
                .prolog => {
                    if (try self.nextProlog()) |event| return event;
                    return null;
                },
                .content => {
                    if (try self.nextContent()) |event| return event;
                    continue;
                },
                .epilog => {
                    if (try self.nextEpilog()) |event| return event;
                    return null;
                },
                .done => return null,
            }
        }
    }

    fn nextProlog(self: *Parser) Error!?Event {
        if (self.decl_allowed) {
            self.decl_allowed = false;
            if (self.startsWith("<?xml") and
                self.pos + 5 < self.input.len and
                chars.isWhitespace(self.input[self.pos + 5]))
            {
                return .{ .xml_declaration = try self.scanXmlDeclaration() };
            }
        }

        self.skipWhitespace();
        if (self.pos >= self.input.len) {
            if (!self.root_seen) return self.fail(error.MissingRootElement, self.pos);
            self.state = .done;
            return null;
        }

        if (self.startsWith("<!--")) return .{ .comment = try self.scanComment() };
        if (self.startsWith("<?")) return .{ .processing_instruction = try self.scanPi() };
        if (self.startsWith("<!DOCTYPE")) {
            if (!self.options.allow_doctype) {
                return self.fail(error.UnexpectedDoctype, self.pos);
            }
            if (self.seen_doctype) return self.fail(error.UnexpectedDoctype, self.pos);
            return .{ .doctype = try self.scanDoctype() };
        }
        if (self.startsWith("<!")) return self.fail(error.UnexpectedMarkup, self.pos);
        if (self.input[self.pos] == '<') {
            self.state = .content;
            return .{ .start_element = try self.scanStartTag() };
        }
        return self.fail(error.InvalidSyntax, self.pos);
    }

    fn nextContent(self: *Parser) Error!?Event {
        if (self.pos >= self.input.len) {
            if (self.frame_count != 0) {
                try self.popEntityFrame();
                return null;
            }
            if (self.fragment and self.depth == 0) {
                self.state = .done;
                return null;
            }
            return self.fail(error.UnexpectedEndOfInput, self.pos);
        }
        if (self.input[self.pos] == '<') {
            if (self.startsWith("</")) return .{ .end_element = try self.scanEndTag() };
            if (self.startsWith("<!--")) return .{ .comment = try self.scanComment() };
            if (self.startsWith("<![CDATA[")) return .{ .cdata = try self.scanCdata() };
            if (self.startsWith("<?")) {
                return .{ .processing_instruction = try self.scanPi() };
            }
            if (self.startsWith("<!")) return self.fail(error.UnexpectedMarkup, self.pos);
            return .{ .start_element = try self.scanStartTag() };
        }
        if (try self.scanText()) |text| return .{ .text = text };
        return null;
    }

    fn nextEpilog(self: *Parser) Error!?Event {
        self.skipWhitespace();
        if (self.pos >= self.input.len) {
            self.state = .done;
            return null;
        }
        if (self.startsWith("<!--")) return .{ .comment = try self.scanComment() };
        if (self.startsWith("<?")) return .{ .processing_instruction = try self.scanPi() };
        if (self.input[self.pos] == '<') {
            return self.fail(error.MultipleRootElements, self.pos);
        }
        return self.fail(error.ContentAfterRoot, self.pos);
    }

    fn scanStartTag(self: *Parser) Error!StartElement {
        const start = self.pos;
        std.debug.assert(self.input[self.pos] == '<');
        self.pos += 1;

        const name_start = self.pos;
        const name_len = chars.scanName(self.input[name_start..]);
        if (name_len == 0) return self.fail(error.InvalidName, name_start);
        const name = self.input[name_start .. name_start + name_len];
        self.pos = name_start + name_len;

        var attr_count: usize = 0;
        var self_closing = false;
        while (true) {
            const before_whitespace = self.pos;
            self.skipWhitespace();
            if (self.pos >= self.input.len) {
                return self.fail(error.UnexpectedEndOfInput, self.pos);
            }
            switch (self.input[self.pos]) {
                '>' => {
                    self.pos += 1;
                    break;
                },
                '/' => {
                    if (self.pos + 1 >= self.input.len or
                        self.input[self.pos + 1] != '>')
                    {
                        return self.fail(error.InvalidStartTag, self.pos);
                    }
                    self.pos += 2;
                    self_closing = true;
                    break;
                },
                else => {
                    if (self.pos == before_whitespace) {
                        return self.fail(error.InvalidStartTag, self.pos);
                    }
                },
            }

            const attr = try self.scanAttribute();
            for (self.attrs[0..attr_count]) |existing| {
                if (std.mem.eql(u8, existing.name, attr.name)) {
                    return self.fail(error.DuplicateAttribute, attr.name_range.start);
                }
            }
            if (attr_count == self.options.max_attributes) {
                return self.fail(error.AttributeLimitExceeded, attr.name_range.start);
            }
            self.attrs[attr_count] = attr;
            attr_count += 1;
        }

        const is_root = !self.root_seen;
        if (is_root) {
            // The DOCTYPE name matching the root element type is a validity
            // constraint, not a well-formedness constraint, so it is not
            // enforced by the core parser.
            self.root_seen = true;
        }

        var event_depth = self.depth;
        if (self_closing) {
            event_depth += 1;
            if (is_root and !self.fragment) {
                self.state = .epilog;
            }
        } else {
            if (self.depth == self.options.max_depth) {
                return self.fail(error.DepthLimitExceeded, start);
            }
            self.open_names[self.depth] = name;
            self.depth += 1;
            event_depth = self.depth;
        }

        return .{
            .name = name,
            .name_range = .{ .start = name_start, .end = name_start + name_len },
            .attrs = self.attrs[0..attr_count],
            .self_closing = self_closing,
            .depth = event_depth,
        };
    }

    fn scanAttribute(self: *Parser) Error!Attribute {
        const name_start = self.pos;
        const name_len = chars.scanName(self.input[name_start..]);
        if (name_len == 0) return self.fail(error.InvalidName, name_start);
        const name = self.input[name_start .. name_start + name_len];
        self.pos = name_start + name_len;

        self.skipWhitespace();
        if (self.pos >= self.input.len or self.input[self.pos] != '=') {
            return self.fail(error.InvalidStartTag, self.pos);
        }
        self.pos += 1;
        self.skipWhitespace();
        if (self.pos >= self.input.len) {
            return self.fail(error.UnexpectedEndOfInput, self.pos);
        }

        const quote = self.input[self.pos];
        if (quote != '"' and quote != '\'') {
            return self.fail(error.InvalidAttributeValue, self.pos);
        }
        self.pos += 1;
        const value_start = self.pos;

        while (self.pos < self.input.len and self.input[self.pos] != quote) {
            const byte = self.input[self.pos];
            if (byte == '<') {
                return self.fail(error.InvalidAttributeValue, self.pos);
            }
            if (byte == '&') {
                self.pos = try self.validateReference(self.pos, true);
                continue;
            }
            self.pos += 1;
        }
        if (self.pos >= self.input.len) {
            return self.fail(error.UnexpectedEndOfInput, self.pos);
        }

        const value = self.input[value_start..self.pos];
        if (chars.findInvalidXmlChar(value)) |bad| {
            return self.fail(error.InvalidCharacter, value_start + bad);
        }
        self.pos += 1;
        return .{
            .name = name,
            .value = value,
            .name_range = .{ .start = name_start, .end = name_start + name_len },
            .value_range = .{ .start = value_start, .end = value_start + value.len },
        };
    }

    fn scanEndTag(self: *Parser) Error!EndElement {
        std.debug.assert(self.startsWith("</"));
        self.pos += 2;
        const name_start = self.pos;
        const name_len = chars.scanName(self.input[name_start..]);
        if (name_len == 0) return self.fail(error.InvalidName, name_start);
        const name = self.input[name_start .. name_start + name_len];
        self.pos = name_start + name_len;
        self.skipWhitespace();
        if (self.pos >= self.input.len or self.input[self.pos] != '>') {
            return self.fail(error.InvalidEndTag, self.pos);
        }
        self.pos += 1;

        if (self.depth == 0) return self.fail(error.MismatchedEndTag, name_start);
        const expected = self.open_names[self.depth - 1];
        if (!std.mem.eql(u8, expected, name)) {
            return self.fail(error.MismatchedEndTag, name_start);
        }
        const event_depth = self.depth;
        self.depth -= 1;
        if (self.depth < self.entity_entry_depth) {
            return self.fail(error.MismatchedEndTag, name_start);
        }
        if (self.depth == 0 and !self.fragment) self.state = .epilog;
        return .{
            .name = name,
            .name_range = .{ .start = name_start, .end = name_start + name_len },
            .depth = event_depth,
        };
    }

    fn scanText(self: *Parser) Error!?[]const u8 {
        const start = self.pos;
        var index = start;
        while (true) {
            index = findTextSpecial(self.input, index);
            if (index >= self.input.len) break;
            switch (self.input[index]) {
                '&' => {
                    const reference = try self.classifyReference(index);
                    if (reference.kind == .entity) {
                        if (index > start) {
                            self.pos = index;
                            const span = self.input[start..index];
                            if (chars.findInvalidXmlChar(span)) |bad| {
                                return self.fail(error.InvalidCharacter, start + bad);
                            }
                            return span;
                        }
                        self.pos = reference.end;
                        try self.expandEntityReference(
                            reference.name,
                            reference.entity.?,
                        );
                        return null;
                    }
                    index = reference.end;
                },
                ']' => {
                    if (index + 2 < self.input.len and
                        self.input[index + 1] == ']' and
                        self.input[index + 2] == '>')
                    {
                        return self.fail(error.InvalidCdata, index);
                    }
                    index += 1;
                },
                else => break, // '<'
            }
        }
        self.pos = index;
        const span = self.input[start..index];
        if (chars.findInvalidXmlChar(span)) |bad| {
            return self.fail(error.InvalidCharacter, start + bad);
        }
        return span;
    }

    const Reference = struct {
        kind: enum { plain, entity },
        end: usize,
        name: []const u8 = "",
        entity: ?*const entities.Entity = null,
    };

    fn classifyReference(self: *Parser, amp: usize) Error!Reference {
        const semicolon = std.mem.indexOfScalarPos(u8, self.input, amp + 1, ';') orelse {
            return self.fail(error.InvalidEntityReference, amp);
        };
        const body = self.input[amp + 1 .. semicolon];
        try self.validateReferenceSyntax(body, amp);
        const end = semicolon + 1;
        if (body.len == 0 or body[0] == '#' or entities.isPredefined(body)) {
            return .{ .kind = .plain, .end = end };
        }
        const entity = self.entity_table.find(body) orelse {
            if (self.options.allow_undeclared_entities) {
                return .{ .kind = .plain, .end = end };
            }
            if (self.standalone != true and
                (self.external_subset_present or self.parameter_reference_seen))
            {
                return .{ .kind = .plain, .end = end };
            }
            return self.fail(error.UndeclaredEntity, amp + 1);
        };
        if (entity.unparsed) {
            return self.fail(error.UnparsedEntityReference, amp + 1);
        }
        if (entity.external and
            (self.options.resolver == null or self.options.allocator == null))
        {
            // Without a resolver the replacement text is unavailable; keep the
            // reference as literal text for the consumer.
            return .{ .kind = .plain, .end = end };
        }
        return .{
            .kind = .entity,
            .end = end,
            .name = body,
            .entity = entity,
        };
    }

    fn expandEntityReference(
        self: *Parser,
        name: []const u8,
        entity: *const entities.Entity,
    ) Error!void {
        if (entity.external) {
            const resolver = self.options.resolver orelse return;
            const public_id: ?[]const u8 = if (entity.public_id.len != 0)
                entity.public_id
            else
                null;
            const source = resolver.resolve(
                resolver.context,
                entity.system_id,
                public_id,
                self.resolver_base,
            ) orelse return;
            const allocator = self.scratchAllocator() orelse return;
            const decoded = try decodeExternalAlloc(source, allocator);
            const body = try self.stripTextDeclaration(decoded);
            try self.pushEntityFrame(body, name, entity.system_id);
            return;
        }

        var value = entity.value;
        if (std.mem.indexOf(u8, value, "&#") != null) {
            if (self.scratchAllocator()) |allocator| {
                value = try decodeCharacterReferences(self, value, allocator);
            }
        }
        try self.pushEntityFrame(value, name, self.resolver_base);
    }

    fn pushEntityFrame(
        self: *Parser,
        input: []const u8,
        name: []const u8,
        resolver_base: ?[]const u8,
    ) Error!void {
        if (self.frame_count == self.frames.len) {
            return self.fail(error.EntityRecursion, self.pos);
        }
        if (std.mem.eql(u8, self.current_entity, name)) {
            return self.fail(error.EntityRecursion, self.pos);
        }
        for (self.frames[0..self.frame_count]) |frame| {
            if (frame.current_entity.len != 0 and
                std.mem.eql(u8, frame.current_entity, name))
            {
                return self.fail(error.EntityRecursion, self.pos);
            }
        }
        self.frames[self.frame_count] = .{
            .input = self.input,
            .pos = self.pos,
            .current_entity = self.current_entity,
            .entity_entry_depth = self.entity_entry_depth,
            .resolver_base = self.resolver_base,
        };
        self.frame_count += 1;
        self.input = input;
        self.pos = 0;
        self.current_entity = name;
        self.entity_entry_depth = self.depth;
        self.resolver_base = resolver_base;
    }

    fn popEntityFrame(self: *Parser) Error!void {
        std.debug.assert(self.frame_count != 0);
        if (self.depth != self.entity_entry_depth) {
            return self.fail(error.MismatchedEndTag, self.pos);
        }
        self.frame_count -= 1;
        const frame = self.frames[self.frame_count];
        self.input = frame.input;
        self.pos = frame.pos;
        self.current_entity = frame.current_entity;
        self.entity_entry_depth = frame.entity_entry_depth;
        self.resolver_base = frame.resolver_base;
    }

    fn scanCdata(self: *Parser) Error![]const u8 {
        std.debug.assert(self.startsWith("<![CDATA["));
        const content_start = self.pos + "<![CDATA[".len;
        const end = std.mem.indexOfPos(u8, self.input, content_start, "]]>") orelse {
            return self.fail(error.UnexpectedEndOfInput, self.input.len);
        };
        const content = self.input[content_start..end];
        if (chars.findInvalidXmlChar(content)) |bad| {
            return self.fail(error.InvalidCharacter, content_start + bad);
        }
        self.pos = end + 3;
        return content;
    }

    fn scanComment(self: *Parser) Error![]const u8 {
        std.debug.assert(self.startsWith("<!--"));
        const content_start = self.pos + "<!--".len;
        const end = std.mem.indexOfPos(u8, self.input, content_start, "-->") orelse {
            return self.fail(error.UnexpectedEndOfInput, self.input.len);
        };
        const content = self.input[content_start..end];
        if (std.mem.indexOf(u8, content, "--")) |bad| {
            return self.fail(error.InvalidComment, content_start + bad);
        }
        if (content.len != 0 and content[content.len - 1] == '-') {
            return self.fail(error.InvalidComment, end - 1);
        }
        if (chars.findInvalidXmlChar(content)) |bad| {
            return self.fail(error.InvalidCharacter, content_start + bad);
        }
        self.pos = end + 3;
        return content;
    }

    fn scanPi(self: *Parser) Error!Instruction {
        std.debug.assert(self.startsWith("<?"));
        self.pos += 2;
        const target_start = self.pos;
        const target_len = chars.scanName(self.input[target_start..]);
        if (target_len == 0) return self.fail(error.InvalidName, target_start);
        const target = self.input[target_start .. target_start + target_len];
        if (std.ascii.eqlIgnoreCase(target, "xml")) {
            return self.fail(error.InvalidProcessingInstruction, target_start);
        }
        self.pos = target_start + target_len;

        if (self.startsWith("?>")) {
            self.pos += 2;
            return .{ .target = target, .data = "" };
        }
        if (self.pos >= self.input.len or
            !chars.isWhitespace(self.input[self.pos]))
        {
            return self.fail(error.InvalidProcessingInstruction, self.pos);
        }
        self.skipWhitespace();
        const data_start = self.pos;
        const end = std.mem.indexOfPos(u8, self.input, data_start, "?>") orelse {
            return self.fail(error.UnexpectedEndOfInput, self.input.len);
        };
        const data = self.input[data_start..end];
        if (chars.findInvalidXmlChar(data)) |bad| {
            return self.fail(error.InvalidCharacter, data_start + bad);
        }
        self.pos = end + 2;
        return .{ .target = target, .data = data };
    }

    fn scanXmlDeclaration(self: *Parser) Error!Declaration {
        const start = self.pos;
        self.pos += "<?xml".len;
        if (!self.skipWhitespaceRequired()) {
            return self.fail(error.InvalidXmlDeclaration, self.pos);
        }

        const version = try self.scanDeclarationValue("version");
        if (!validVersionNumber(version)) {
            return self.fail(error.UnsupportedXmlVersion, self.pos);
        }

        var declared_encoding: ?[]const u8 = null;
        var standalone: ?bool = null;
        while (true) {
            const had_whitespace = self.skipWhitespaceCount() != 0;
            if (self.startsWith("?>")) {
                self.pos += 2;
                break;
            }
            if (self.pos >= self.input.len) {
                return self.fail(error.UnexpectedEndOfInput, self.pos);
            }
            if (!had_whitespace) {
                return self.fail(error.InvalidXmlDeclaration, self.pos);
            }

            const name_start = self.pos;
            const name_len = chars.scanName(self.input[name_start..]);
            if (name_len == 0) {
                return self.fail(error.InvalidXmlDeclaration, name_start);
            }
            const name = self.input[name_start .. name_start + name_len];
            self.pos = name_start + name_len;
            if (std.mem.eql(u8, name, "encoding") and declared_encoding == null and
                standalone == null)
            {
                const value = try self.scanDeclarationValue(null);
                if (!validEncodingName(value)) {
                    return self.fail(error.InvalidXmlDeclaration, name_start);
                }
                declared_encoding = value;
            } else if (std.mem.eql(u8, name, "standalone") and standalone == null) {
                const value = try self.scanDeclarationValue(null);
                if (std.mem.eql(u8, value, "yes")) {
                    standalone = true;
                } else if (std.mem.eql(u8, value, "no")) {
                    standalone = false;
                } else {
                    return self.fail(error.InvalidXmlDeclaration, name_start);
                }
            } else {
                return self.fail(error.InvalidXmlDeclaration, name_start);
            }
        }

        self.standalone = standalone;
        return .{
            .raw = self.input[start..self.pos],
            .version = version,
            .encoding = declared_encoding,
            .standalone = standalone,
        };
    }

    /// Parse `S? = S? quoted-value` after an optional expected name.
    fn scanDeclarationValue(self: *Parser, expected_name: ?[]const u8) Error![]const u8 {
        if (expected_name) |expected| {
            const name_start = self.pos;
            const name_len = chars.scanName(self.input[name_start..]);
            if (name_len == 0 or
                !std.mem.eql(u8, self.input[name_start .. name_start + name_len], expected))
            {
                return self.fail(error.InvalidXmlDeclaration, name_start);
            }
            self.pos = name_start + name_len;
        }
        self.skipWhitespace();
        if (self.pos >= self.input.len or self.input[self.pos] != '=') {
            return self.fail(error.InvalidXmlDeclaration, self.pos);
        }
        self.pos += 1;
        self.skipWhitespace();
        if (self.pos >= self.input.len or
            (self.input[self.pos] != '"' and self.input[self.pos] != '\''))
        {
            return self.fail(error.InvalidXmlDeclaration, self.pos);
        }
        const quote = self.input[self.pos];
        self.pos += 1;
        const value_start = self.pos;
        while (self.pos < self.input.len and self.input[self.pos] != quote) {
            self.pos += 1;
        }
        if (self.pos >= self.input.len) {
            return self.fail(error.UnexpectedEndOfInput, self.pos);
        }
        const value = self.input[value_start..self.pos];
        self.pos += 1;
        return value;
    }

    fn scanDoctype(self: *Parser) Error!Doctype {
        const start = self.pos;
        self.pos += "<!DOCTYPE".len;
        if (!self.skipWhitespaceRequired()) {
            return self.fail(error.InvalidDoctype, self.pos);
        }

        const name_start = self.pos;
        const name_len = chars.scanName(self.input[name_start..]);
        if (name_len == 0) return self.fail(error.InvalidDoctype, name_start);
        const name = self.input[name_start .. name_start + name_len];
        self.pos = name_start + name_len;

        var public_id: ?[]const u8 = null;
        var system_id: ?[]const u8 = null;
        const had_whitespace = self.skipWhitespaceCount() != 0;

        if (self.startsWith("SYSTEM")) {
            if (!had_whitespace) return self.fail(error.InvalidDoctype, self.pos);
            self.pos += "SYSTEM".len;
            if (!self.skipWhitespaceRequired()) {
                return self.fail(error.InvalidDoctype, self.pos);
            }
            system_id = try self.scanQuotedLiteral();
            _ = self.skipWhitespaceCount();
        } else if (self.startsWith("PUBLIC")) {
            if (!had_whitespace) return self.fail(error.InvalidDoctype, self.pos);
            self.pos += "PUBLIC".len;
            if (!self.skipWhitespaceRequired()) {
                return self.fail(error.InvalidDoctype, self.pos);
            }
            const public_start = self.pos + 1;
            public_id = try self.scanQuotedLiteral();
            try self.validatePubidLiteral(public_id.?, public_start);
            if (!self.skipWhitespaceRequired()) {
                return self.fail(error.InvalidDoctype, self.pos);
            }
            system_id = try self.scanQuotedLiteral();
            _ = self.skipWhitespaceCount();
        }

        var has_internal_subset = false;
        if (self.pos < self.input.len and self.input[self.pos] == '[') {
            has_internal_subset = true;
            try self.parseInternalSubset();
            _ = self.skipWhitespaceCount();
        }
        if (self.pos >= self.input.len or self.input[self.pos] != '>') {
            return self.fail(error.InvalidDoctype, self.pos);
        }
        self.pos += 1;

        if (system_id) |system| {
            self.external_subset_present = true;
            if (self.standalone != true) {
                try self.loadExternalSubset(system, public_id);
            }
        }
        try self.validateEntityDeclarations();

        self.seen_doctype = true;
        self.doctype_name = name;
        return .{
            .raw = self.input[start..self.pos],
            .name = name,
            .public_id = public_id,
            .system_id = system_id,
            .has_internal_subset = has_internal_subset,
        };
    }

    fn scanQuotedLiteral(self: *Parser) Error![]const u8 {
        if (self.pos >= self.input.len or
            (self.input[self.pos] != '"' and self.input[self.pos] != '\''))
        {
            return self.fail(error.InvalidDoctype, self.pos);
        }
        const quote = self.input[self.pos];
        self.pos += 1;
        const value_start = self.pos;
        while (self.pos < self.input.len and self.input[self.pos] != quote) {
            self.pos += 1;
        }
        if (self.pos >= self.input.len) {
            return self.fail(error.UnexpectedEndOfInput, self.pos);
        }
        const value = self.input[value_start..self.pos];
        if (chars.findInvalidXmlChar(value)) |bad| {
            return self.fail(error.InvalidCharacter, value_start + bad);
        }
        self.pos += 1;
        return value;
    }

    fn parseInternalSubset(self: *Parser) Error!void {
        const bracket = self.pos;
        const end = findInternalSubsetEnd(self.input, bracket + 1) orelse {
            return self.fail(error.UnexpectedEndOfInput, self.input.len);
        };
        const raw = self.input[bracket + 1 .. end];

        if (!internalSubsetNeedsExpansion(raw)) {
            self.pos = bracket + 1;
            try self.parseSubsetDeclarations(true, null);
            self.pos = end + 1;
            return;
        }

        self.parameter_reference_seen = true;
        const allocator = self.scratchAllocator() orelse {
            return self.fail(error.UnsupportedParameterEntity, bracket + 1);
        };
        var expanded: std.ArrayList(u8) = .empty;
        try self.expandSubset(raw, false, &expanded, allocator, 0, true);
        const stripped = try self.stripBoundaries(expanded.items, allocator);

        const saved_input = self.input;
        self.input = stripped.bytes;
        self.pos = 0;
        try self.parseSubsetDeclarations(false, stripped.ids);
        self.input = saved_input;
        self.pos = end + 1;
    }

    fn parseSubsetDeclarations(
        self: *Parser,
        stop_at_bracket: bool,
        boundary_ids: ?[]const u32,
    ) Error!void {
        while (true) {
            self.skipSubsetSpace();
            if (self.pos >= self.input.len) {
                if (stop_at_bracket) {
                    return self.fail(error.UnexpectedEndOfInput, self.pos);
                }
                return;
            }
            if (stop_at_bracket and self.input[self.pos] == ']') return;

            const declaration_start = self.pos;
            const declaration_end = try self.subsetDeclarationEnd();
            if (boundary_ids) |ids| {
                if (declaration_end < ids.len) {
                    const first = ids[declaration_start];
                    const last = ids[declaration_end];
                    // A declaration may not begin inside a parameter-entity
                    // replacement and continue outside it (WFC: PE Between
                    // Declarations). The converse is a validity constraint in
                    // the Fifth Edition errata, matching libxml2 and expat.
                    if (first != 0 and first != last) {
                        return self.fail(error.InvalidDoctype, declaration_start);
                    }
                }
            }

            if (self.startsWith("<!--")) {
                _ = try self.scanComment();
                continue;
            }
            if (self.startsWith("<?")) {
                _ = try self.scanPi();
                continue;
            }
            if (self.startsWith("<!")) {
                try self.scanMarkupDeclaration();
                continue;
            }
            return self.fail(error.InvalidDoctype, self.pos);
        }
    }

    fn subsetDeclarationEnd(self: *Parser) Error!usize {
        if (self.startsWith("<!--")) {
            return (std.mem.indexOfPos(
                u8,
                self.input,
                self.pos + 4,
                "-->",
            ) orelse return self.fail(
                error.UnexpectedEndOfInput,
                self.input.len,
            )) + 2;
        }
        if (self.startsWith("<?")) {
            return (std.mem.indexOfPos(
                u8,
                self.input,
                self.pos + 2,
                "?>",
            ) orelse return self.fail(
                error.UnexpectedEndOfInput,
                self.input.len,
            )) + 1;
        }
        if (self.startsWith("<!")) {
            return self.declarationEnd();
        }
        return self.fail(error.InvalidDoctype, self.pos);
    }

    fn stripBoundaries(
        self: *Parser,
        input: []const u8,
        allocator: std.mem.Allocator,
    ) Error!struct { bytes: []u8, ids: []u32 } {
        var bytes: std.ArrayList(u8) = .empty;
        var ids: std.ArrayList(u32) = .empty;
        var stack: [max_entity_frames]u32 = undefined;
        var stack_len: usize = 0;
        var current: u32 = 0;
        var next_id: u32 = 1;
        for (input) |byte| {
            switch (byte) {
                0x01 => {
                    if (stack_len == stack.len) {
                        return self.fail(error.EntityRecursion, 0);
                    }
                    stack[stack_len] = current;
                    stack_len += 1;
                    current = next_id;
                    next_id +%= 1;
                },
                0x02 => {
                    if (stack_len == 0) {
                        return self.fail(error.InvalidDoctype, 0);
                    }
                    stack_len -= 1;
                    current = stack[stack_len];
                },
                else => {
                    try bytes.append(allocator, byte);
                    try ids.append(allocator, current);
                },
            }
        }
        if (stack_len != 0) return self.fail(error.InvalidDoctype, 0);
        return .{
            .bytes = try bytes.toOwnedSlice(allocator),
            .ids = try ids.toOwnedSlice(allocator),
        };
    }

    fn skipSubsetSpace(self: *Parser) void {
        while (self.pos < self.input.len) {
            const byte = self.input[self.pos];
            if (byte == 0 or chars.isWhitespace(byte)) {
                self.pos += 1;
            } else break;
        }
    }

    fn scratchAllocator(self: *Parser) ?std.mem.Allocator {
        const base = self.options.allocator orelse return null;
        if (self.scratch == null) self.scratch = std.heap.ArenaAllocator.init(base);
        return self.scratch.?.allocator();
    }

    fn loadExternalSubset(
        self: *Parser,
        system_id: []const u8,
        public_id: ?[]const u8,
    ) Error!void {
        const resolver = self.options.resolver orelse return;
        if (self.external_depth >= self.options.max_external_depth) {
            return self.fail(error.ExternalEntityDepthExceeded, 0);
        }
        const source = resolver.resolve(
            resolver.context,
            system_id,
            public_id,
            self.resolver_base,
        ) orelse return;
        const allocator = self.scratchAllocator() orelse return;
        const decoded = try decodeExternalAlloc(source, allocator);

        self.external_depth += 1;
        defer self.external_depth -= 1;

        const saved_base = self.resolver_base;
        self.resolver_base = system_id;
        defer self.resolver_base = saved_base;

        const body = try self.stripTextDeclaration(decoded);
        var expanded: std.ArrayList(u8) = .empty;
        try self.expandSubset(body, true, &expanded, allocator, 0, true);
        const stripped = try self.stripBoundaries(expanded.items, allocator);
        var filtered: std.ArrayList(u8) = .empty;
        var filtered_ids: std.ArrayList(u32) = .empty;
        try evaluateConditionals(
            allocator,
            stripped.bytes,
            stripped.ids,
            &filtered,
            &filtered_ids,
        );
        const buffer = try filtered.toOwnedSlice(allocator);
        const ids = try filtered_ids.toOwnedSlice(allocator);

        const saved_input = self.input;
        const saved_pos = self.pos;
        const saved_allow = self.allow_pe_in_declarations;
        self.allow_pe_in_declarations = true;
        self.input = buffer;
        self.pos = 0;
        try self.parseSubsetDeclarations(false, ids);
        self.input = saved_input;
        self.pos = saved_pos;
        self.allow_pe_in_declarations = saved_allow;
    }

    fn expandSubset(
        self: *Parser,
        raw: []const u8,
        external: bool,
        out: *std.ArrayList(u8),
        allocator: std.mem.Allocator,
        depth: usize,
        mark_boundaries: bool,
    ) Error!void {
        if (depth > self.options.max_external_depth) {
            return self.fail(error.ExternalEntityDepthExceeded, 0);
        }
        const saved_allow = self.allow_pe_in_declarations;
        if (external) self.allow_pe_in_declarations = true;
        defer self.allow_pe_in_declarations = saved_allow;
        var pos: usize = 0;
        var quote: u8 = 0;
        while (pos < raw.len) {
            const byte = raw[pos];
            if (quote != 0) {
                try out.append(allocator, byte);
                if (byte == quote) quote = 0;
                pos += 1;
                continue;
            }
            switch (byte) {
                '"', '\'' => {
                    quote = byte;
                    try out.append(allocator, byte);
                    pos += 1;
                },
                '%' => {
                    const reference = parseParameterReference(raw, pos) orelse {
                        return self.fail(error.InvalidEntityReference, pos);
                    };
                    try self.appendParameterEntity(
                        reference.name,
                        out,
                        allocator,
                        depth + 1,
                        true,
                        mark_boundaries,
                    );
                    pos = reference.end;
                },
                '<' => {
                    if (std.mem.startsWith(u8, raw[pos..], "<!--")) {
                        const end = std.mem.indexOfPos(u8, raw, pos + 4, "-->") orelse {
                            return self.fail(error.UnexpectedEndOfInput, raw.len);
                        };
                        try out.appendSlice(allocator, raw[pos .. end + 3]);
                        pos = end + 3;
                        continue;
                    }
                    if (std.mem.startsWith(u8, raw[pos..], "<?")) {
                        const end = std.mem.indexOfPos(u8, raw, pos + 2, "?>") orelse {
                            return self.fail(error.UnexpectedEndOfInput, raw.len);
                        };
                        try out.appendSlice(allocator, raw[pos .. end + 2]);
                        pos = end + 2;
                        continue;
                    }
                    if (std.mem.startsWith(u8, raw[pos..], "<!ENTITY")) {
                        const end = markup.findDeclarationEnd(raw, pos + 2) orelse {
                            return self.fail(error.UnexpectedEndOfInput, raw.len);
                        };
                        const declaration = raw[pos .. end + 1];
                        try self.parseEntityDeclarationSlice(declaration, 0);
                        try out.appendSlice(allocator, declaration);
                        pos = end + 1;
                        continue;
                    }
                    if (!external and std.mem.startsWith(u8, raw[pos..], "<!")) {
                        const end = markup.findDeclarationEnd(raw, pos + 2) orelse {
                            return self.fail(error.UnexpectedEndOfInput, raw.len);
                        };
                        try out.appendSlice(allocator, raw[pos .. end + 1]);
                        pos = end + 1;
                        continue;
                    }
                    try out.append(allocator, byte);
                    pos += 1;
                },
                else => {
                    try out.append(allocator, byte);
                    pos += 1;
                },
            }
        }
    }

    fn appendParameterEntity(
        self: *Parser,
        name: []const u8,
        out: *std.ArrayList(u8),
        allocator: std.mem.Allocator,
        depth: usize,
        add_spaces: bool,
        mark_boundaries: bool,
    ) Error!void {
        if (depth > self.options.max_external_depth) {
            return self.fail(error.ExternalEntityDepthExceeded, 0);
        }
        const entity = self.parameter_entities.find(name) orelse {
            return self.fail(error.UndeclaredEntity, 0);
        };
        if (mark_boundaries) try out.append(allocator, 0x01);
        if (add_spaces) try out.append(allocator, ' ');
        defer {
            if (add_spaces) out.append(allocator, ' ') catch {};
            if (mark_boundaries) out.append(allocator, 0x02) catch {};
        }
        if (entity.external) {
            const resolver = self.options.resolver orelse return;
            const public_id: ?[]const u8 = if (entity.public_id.len != 0)
                entity.public_id
            else
                null;
            const source = resolver.resolve(
                resolver.context,
                entity.system_id,
                public_id,
                self.resolver_base,
            ) orelse return;
            const decoded = try decodeExternalAlloc(source, allocator);
            const body = try self.stripTextDeclaration(decoded);

            const saved_base = self.resolver_base;
            self.resolver_base = entity.system_id;
            defer self.resolver_base = saved_base;

            const decoded_body = try decodeParameterReplacement(
                self,
                body,
                allocator,
            );
            var expanded: std.ArrayList(u8) = .empty;
            const saved_allow = self.allow_pe_in_declarations;
            self.allow_pe_in_declarations = true;
            defer self.allow_pe_in_declarations = saved_allow;
            try self.expandSubset(
                decoded_body,
                true,
                &expanded,
                allocator,
                depth,
                mark_boundaries,
            );
            var filtered: std.ArrayList(u8) = .empty;
            var filtered_ids: std.ArrayList(u32) = .empty;
            try evaluateConditionals(
                allocator,
                expanded.items,
                null,
                &filtered,
                &filtered_ids,
            );
            try out.appendSlice(allocator, filtered.items);
        } else {
            const decoded_body = try decodeParameterReplacement(
                self,
                entity.value,
                allocator,
            );
            try self.expandSubset(
                decoded_body,
                true,
                out,
                allocator,
                depth,
                mark_boundaries,
            );
        }
    }

    fn expandEntityValue(
        self: *Parser,
        value: []const u8,
        allocator: std.mem.Allocator,
    ) Error![]const u8 {
        if (std.mem.indexOfScalar(u8, value, '%') == null) return value;
        var expanded: std.ArrayList(u8) = .empty;
        var index: usize = 0;
        while (index < value.len) {
            if (value[index] != '%') {
                try expanded.append(allocator, value[index]);
                index += 1;
                continue;
            }
            const reference = parseParameterReference(value, index) orelse {
                return self.fail(error.InvalidEntityReference, index);
            };
            try self.appendParameterEntity(
                reference.name,
                &expanded,
                allocator,
                0,
                false,
                false,
            );
            index = reference.end;
        }
        return expanded.toOwnedSlice(allocator);
    }

    fn scanEntityDeclaration(self: *Parser) Error!void {
        const start = self.pos;
        const end = try self.declarationEnd();
        try self.parseEntityDeclarationSlice(self.input[start .. end + 1], start);
        self.pos = end + 1;
    }

    fn parseEntityDeclarationSlice(
        self: *Parser,
        declaration: []const u8,
        base: usize,
    ) Error!void {
        var scanner = DtdScanner{ .parser = self, .text = declaration, .base = base };
        if (!scanner.eat("<!ENTITY")) return scanner.fail(error.InvalidDoctype);
        try scanner.requireWhitespace();

        var parameter = false;
        if (scanner.peek() == '%') {
            parameter = true;
            scanner.index += 1;
            try scanner.requireWhitespace();
        }

        const name = try scanner.scanName();
        const duplicate = if (parameter)
            self.parameter_entities.find(name) != null
        else
            self.entity_table.find(name) != null;
        try scanner.requireWhitespace();

        if (scanner.peek() == '"' or scanner.peek() == '\'') {
            const value_base = scanner.abs() + 1;
            var value = try scanner.scanQuoted();
            if (std.mem.indexOfScalar(u8, value, '%') != null) {
                if (!self.allow_pe_in_declarations and !duplicate) {
                    // WFC: PE Between Declarations (internal subset).
                    return self.fail(error.InvalidEntityReference, value_base);
                }
                const allocator = self.scratchAllocator() orelse {
                    return self.fail(error.UnsupportedParameterEntity, value_base);
                };
                value = try self.expandEntityValue(value, allocator);
            }
            try self.validateEntityValueSyntax(value, value_base);
            _ = scanner.skipWhitespace();
            try scanner.expectByte('>');
            if (!scanner.atEnd()) return scanner.fail(error.InvalidDoctype);
            if (parameter) {
                self.parameter_entities.add(.{
                    .name = name,
                    .value = value,
                    .offset = base,
                }) catch {
                    return self.fail(error.EntityLimitExceeded, base);
                };
            } else {
                self.entity_table.add(.{
                    .name = name,
                    .value = value,
                    .offset = base,
                }) catch {
                    return self.fail(error.EntityLimitExceeded, base);
                };
            }
            return;
        }

        var public_id: []const u8 = "";
        var system_id: []const u8 = "";
        if (scanner.eatKeyword("SYSTEM")) {
            try scanner.requireWhitespace();
            system_id = try scanner.scanQuoted();
        } else if (scanner.eatKeyword("PUBLIC")) {
            try scanner.requireWhitespace();
            const public_base = scanner.abs() + 1;
            public_id = try scanner.scanQuoted();
            try self.validatePubidLiteral(public_id, public_base);
            try scanner.requireWhitespace();
            system_id = try scanner.scanQuoted();
        } else {
            return scanner.fail(error.InvalidDoctype);
        }

        var unparsed = false;
        if (scanner.skipWhitespace() != 0 and scanner.startsWith("NDATA")) {
            if (parameter) return scanner.fail(error.InvalidDoctype);
            if (!scanner.eatKeyword("NDATA")) return scanner.fail(error.InvalidDoctype);
            try scanner.requireWhitespace();
            _ = try scanner.scanName();
            _ = scanner.skipWhitespace();
            unparsed = true;
        }
        try scanner.expectByte('>');
        if (!scanner.atEnd()) return scanner.fail(error.InvalidDoctype);

        if (parameter) {
            self.parameter_entities.add(.{
                .name = name,
                .value = "",
                .external = true,
                .system_id = system_id,
                .public_id = public_id,
                .offset = base,
            }) catch {
                return self.fail(error.EntityLimitExceeded, base);
            };
        } else {
            self.entity_table.add(.{
                .name = name,
                .value = "",
                .external = true,
                .system_id = system_id,
                .public_id = public_id,
                .unparsed = unparsed,
                .offset = base,
            }) catch {
                return self.fail(error.EntityLimitExceeded, base);
            };
        }
    }

    fn scanMarkupDeclaration(self: *Parser) Error!void {
        if (self.startsWith("<!ELEMENT")) return self.scanElementDeclaration();
        if (self.startsWith("<!ATTLIST")) return self.scanAttlistDeclaration();
        if (self.startsWith("<!NOTATION")) return self.scanNotationDeclaration();
        if (self.startsWith("<!ENTITY")) return self.scanEntityDeclaration();
        return self.fail(error.InvalidDoctype, self.pos);
    }

    fn declarationEnd(self: *Parser) Error!usize {
        return markup.findDeclarationEnd(self.input, self.pos + 2) orelse
            self.fail(error.UnexpectedEndOfInput, self.input.len);
    }

    fn scanElementDeclaration(self: *Parser) Error!void {
        const end = try self.declarationEnd();
        var scanner = DtdScanner.init(self, self.pos, end);
        if (!scanner.eat("<!ELEMENT")) return scanner.fail(error.InvalidDoctype);
        try scanner.requireWhitespace();
        _ = try scanner.scanName();
        try scanner.requireWhitespace();
        try scanContentSpec(&scanner);
        _ = scanner.skipWhitespace();
        try scanner.expectByte('>');
        if (!scanner.atEnd()) return scanner.fail(error.InvalidDoctype);
        self.pos = end + 1;
    }

    fn scanAttlistDeclaration(self: *Parser) Error!void {
        const end = try self.declarationEnd();
        var scanner = DtdScanner.init(self, self.pos, end);
        if (!scanner.eat("<!ATTLIST")) return scanner.fail(error.InvalidDoctype);
        try scanner.requireWhitespace();
        _ = try scanner.scanName();
        while (true) {
            const whitespace = scanner.skipWhitespace();
            if (scanner.peek() == '>') {
                scanner.index += 1;
                break;
            }
            if (whitespace == 0) return scanner.fail(error.InvalidDoctype);
            _ = try scanner.scanName();
            try scanner.requireWhitespace();
            try scanAttType(&scanner);
            try scanner.requireWhitespace();
            try scanDefaultDecl(&scanner);
        }
        if (!scanner.atEnd()) return scanner.fail(error.InvalidDoctype);
        self.pos = end + 1;
    }

    fn scanNotationDeclaration(self: *Parser) Error!void {
        const end = try self.declarationEnd();
        var scanner = DtdScanner.init(self, self.pos, end);
        if (!scanner.eat("<!NOTATION")) return scanner.fail(error.InvalidDoctype);
        try scanner.requireWhitespace();
        _ = try scanner.scanName();
        try scanner.requireWhitespace();
        if (scanner.eatKeyword("SYSTEM")) {
            try scanner.requireWhitespace();
            _ = try scanner.scanQuoted();
        } else if (scanner.eatKeyword("PUBLIC")) {
            try scanner.requireWhitespace();
            const public_base = scanner.abs() + 1;
            const public_id = try scanner.scanQuoted();
            try self.validatePubidLiteral(public_id, public_base);
            const whitespace = scanner.skipWhitespace();
            if (whitespace != 0 and
                (scanner.peek() == '"' or scanner.peek() == '\''))
            {
                _ = try scanner.scanQuoted();
            }
        } else {
            return scanner.fail(error.InvalidDoctype);
        }
        _ = scanner.skipWhitespace();
        try scanner.expectByte('>');
        if (!scanner.atEnd()) return scanner.fail(error.InvalidDoctype);
        self.pos = end + 1;
    }

    fn validateEntityValueSyntax(
        self: *Parser,
        value: []const u8,
        base: usize,
    ) Error!void {
        var index: usize = 0;
        while (index < value.len) {
            switch (value[index]) {
                '%' => return self.fail(error.InvalidEntityReference, base + index),
                '&' => {
                    const semicolon = std.mem.indexOfScalarPos(
                        u8,
                        value,
                        index + 1,
                        ';',
                    ) orelse return self.fail(
                        error.InvalidEntityReference,
                        base + index,
                    );
                    try self.validateReferenceSyntax(
                        value[index + 1 .. semicolon],
                        base + index,
                    );
                    index = semicolon + 1;
                },
                else => index += 1,
            }
        }
    }

    fn validatePubidLiteral(
        self: *Parser,
        value: []const u8,
        base: usize,
    ) Error!void {
        for (value, 0..) |byte, index| {
            if (!isPubidChar(byte)) {
                return self.fail(error.InvalidDoctype, base + index);
            }
        }
    }

    fn validateEntityDeclarations(self: *Parser) Error!void {
        // Validate every replacement value's characters and references.
        for (self.entity_table.entries[0..self.entity_table.count]) |entity| {
            if (entity.external) continue;
            if (chars.findInvalidXmlChar(entity.value)) |bad| {
                return self.fail(error.InvalidCharacter, entity.offset + bad);
            }
        }

        for (self.parameter_entities.entries[0..self.parameter_entities.count]) |entity| {
            if (entity.external) continue;
            if (chars.findInvalidXmlChar(entity.value)) |bad| {
                return self.fail(error.InvalidCharacter, entity.offset + bad);
            }
            try self.validateEntityValueReferences(entity.value);
        }

        // XML's No Recursion constraint: no entity may reference itself
        // directly or indirectly, whether or not it is used.
        var colors: [entities.max_entities]u8 = @splat(0);
        for (0..self.entity_table.count) |index| {
            if (colors[index] != 0) continue;
            if (self.entityCycle(index, &colors)) {
                return self.fail(
                    error.EntityRecursion,
                    self.entity_table.entries[index].offset,
                );
            }
        }
    }

    fn entityOffset(self: *const Parser, name: []const u8) usize {
        const index = std.mem.indexOf(u8, self.input, name) orelse return 0;
        return index;
    }

    fn validateEntityValueReferences(self: *Parser, value: []const u8) Error!void {
        var cursor: usize = 0;
        while (std.mem.indexOfScalarPos(u8, value, cursor, '&')) |amp| {
            const semicolon = std.mem.indexOfScalarPos(u8, value, amp + 1, ';') orelse {
                return self.fail(error.InvalidEntityReference, amp);
            };
            const body = value[amp + 1 .. semicolon];
            try self.validateReferenceBody(body, amp, false);
            cursor = semicolon + 1;
        }
    }

    fn entityCycle(
        self: *Parser,
        index: usize,
        colors: *[entities.max_entities]u8,
    ) bool {
        colors[index] = 1;
        const value = self.entity_table.entries[index].value;
        var cursor: usize = 0;
        while (std.mem.indexOfScalarPos(u8, value, cursor, '&')) |amp| {
            const semicolon = std.mem.indexOfScalarPos(u8, value, amp + 1, ';') orelse
                break;
            const body = value[amp + 1 .. semicolon];
            cursor = semicolon + 1;
            if (body.len == 0 or body[0] == '#') continue;
            if (entities.isPredefined(body)) continue;
            const target = self.entityIndex(body) orelse continue;
            if (colors[target] == 1) return true;
            if (colors[target] == 0 and self.entityCycle(target, colors)) return true;
        }
        colors[index] = 2;
        return false;
    }

    fn entityIndex(self: *const Parser, name: []const u8) ?usize {
        for (self.entity_table.entries[0..self.entity_table.count], 0..) |entity, index| {
            if (std.mem.eql(u8, entity.name, name)) return index;
        }
        return null;
    }

    fn validateReference(self: *Parser, amp: usize, in_attribute: bool) Error!usize {
        const semicolon = std.mem.indexOfScalarPos(u8, self.input, amp + 1, ';') orelse {
            // A reference must terminate before markup or end of input.
            return self.fail(error.InvalidEntityReference, amp);
        };
        const body = self.input[amp + 1 .. semicolon];
        try self.validateReferenceBody(body, amp, in_attribute);
        if (!in_attribute and body.len != 0 and body[0] != '#' and
            !entities.isPredefined(body))
        {
            if (self.entity_table.find(body)) |entity| {
                if (entity.external and !entity.unparsed) {
                    try self.validateExternalEntity(entity);
                }
            }
        }
        return semicolon + 1;
    }

    fn validateExternalEntity(self: *Parser, entity: *const entities.Entity) Error!void {
        for (self.external_stack[0..self.external_stack_len]) |active| {
            if (std.mem.eql(u8, active, entity.name)) {
                return self.fail(error.EntityRecursion, 0);
            }
        }
        if (self.external_stack_len == self.external_stack.len) {
            return self.fail(error.ExternalEntityDepthExceeded, 0);
        }
        const index = self.entityIndex(entity.name) orelse return;
        if (self.external_checked.isSet(index)) return;
        self.external_checked.set(index);
        self.external_stack[self.external_stack_len] = entity.name;
        self.external_stack_len += 1;
        defer self.external_stack_len -= 1;

        const resolver = self.options.resolver orelse return;
        if (entity.system_id.len == 0) return;
        if (self.options.allocator == null) return;
        if (self.external_depth >= self.options.max_external_depth) {
            return self.fail(error.ExternalEntityDepthExceeded, 0);
        }
        const public_id: ?[]const u8 = if (entity.public_id.len != 0)
            entity.public_id
        else
            null;
        const source = resolver.resolve(
            resolver.context,
            entity.system_id,
            public_id,
            self.resolver_base,
        ) orelse return;
        const allocator = self.scratchAllocator() orelse return;
        const decoded = try decodeExternalAlloc(source, allocator);

        self.external_depth += 1;
        defer self.external_depth -= 1;

        const saved_base = self.resolver_base;
        self.resolver_base = entity.system_id;
        defer self.resolver_base = saved_base;

        var sub = Parser.initFragment(
            try self.stripTextDeclaration(decoded),
            self.options,
        );
        sub.resolver_base = self.resolver_base;
        sub.entity_table = self.entity_table;
        sub.parameter_entities = self.parameter_entities;
        sub.external_depth = self.external_depth;
        sub.external_checked = self.external_checked;
        sub.external_stack = self.external_stack;
        sub.external_stack_len = self.external_stack_len;
        sub.allow_pe_in_declarations = self.allow_pe_in_declarations;
        defer sub.deinit();
        while (true) {
            const event = sub.next() catch |err| {
                self.error_offset = sub.errorOffset();
                self.error_input = sub.input;
                return err;
            };
            if (event == null) break;
        }
    }

    fn validateReferenceSyntax(
        self: *Parser,
        body: []const u8,
        offset: usize,
    ) Error!void {
        if (body.len == 0) return self.fail(error.InvalidEntityReference, offset);
        if (body[0] == '#') {
            const codepoint = if (body.len > 1 and
                (body[1] == 'x' or body[1] == 'X'))
                chars.parseHexCharRef(body[1..])
            else
                chars.parseDecimalCharRef(body[1..]);
            if (codepoint == null) {
                return self.fail(error.InvalidEntityReference, offset);
            }
            return;
        }
        if (!chars.isName(body)) {
            return self.fail(error.InvalidEntityReference, offset + 1);
        }
    }

    fn validateReferenceBody(
        self: *Parser,
        body: []const u8,
        offset: usize,
        in_attribute: bool,
    ) Error!void {
        try self.validateReferenceSyntax(body, offset);
        if (body.len == 0 or body[0] == '#') return;
        if (entities.isPredefined(body)) return;

        if (self.entity_table.find(body)) |entity| {
            if (entity.unparsed) {
                return self.fail(error.UnparsedEntityReference, offset);
            }
            if (in_attribute) {
                if (entity.external or
                    !self.attributeExpansionValid(entity.value, 0))
                {
                    return self.fail(error.InvalidAttributeValue, offset);
                }
            }
            return;
        }
        if (self.options.allow_undeclared_entities) return;
        // With an external subset or internal parameter-entity references,
        // a declaration may live in a part of the DTD this processor did not
        // read, so an unresolved reference is a validity issue rather than a
        // well-formedness error.
        if (self.standalone != true and
            (self.external_subset_present or self.parameter_reference_seen))
        {
            return;
        }
        return self.fail(error.UndeclaredEntity, offset + 1);
    }

    fn stripTextDeclaration(self: *Parser, source: []const u8) Error![]const u8 {
        var start: usize = 0;
        if (std.mem.startsWith(u8, source, "\xEF\xBB\xBF")) start = 3;
        if (!std.mem.startsWith(u8, source[start..], "<?xml")) {
            return source[start..];
        }
        const after = start + 5;
        if (after >= source.len or !chars.isWhitespace(source[after])) {
            return source[start..];
        }
        const end = std.mem.indexOfPos(u8, source, after, "?>") orelse {
            return self.fail(error.UnexpectedEndOfInput, source.len);
        };
        const declaration = source[start .. end + 2];
        var cursor: usize = start + 5;
        var version: ?[]const u8 = null;
        var has_encoding = false;
        var saw_encoding = false;
        while (true) {
            while (cursor < end and chars.isWhitespace(source[cursor])) cursor += 1;
            if (cursor >= end) break;
            const name_start = cursor;
            const name_len = chars.scanName(source[cursor..end]);
            if (name_len == 0) {
                return self.fail(error.InvalidXmlDeclaration, cursor);
            }
            const name = source[name_start .. name_start + name_len];
            cursor = name_start + name_len;
            while (cursor < end and chars.isWhitespace(source[cursor])) cursor += 1;
            if (cursor >= end or source[cursor] != '=') {
                return self.fail(error.InvalidXmlDeclaration, cursor);
            }
            cursor += 1;
            while (cursor < end and chars.isWhitespace(source[cursor])) cursor += 1;
            if (cursor >= end or
                (source[cursor] != '"' and source[cursor] != '\''))
            {
                return self.fail(error.InvalidXmlDeclaration, cursor);
            }
            const quote = source[cursor];
            cursor += 1;
            const value_start = cursor;
            while (cursor < end and source[cursor] != quote) cursor += 1;
            if (cursor >= end) {
                return self.fail(error.InvalidXmlDeclaration, cursor);
            }
            const value = source[value_start..cursor];
            cursor += 1;
            if (std.mem.eql(u8, name, "version")) {
                if (version != null or saw_encoding) {
                    return self.fail(error.InvalidXmlDeclaration, name_start);
                }
                version = value;
            } else if (std.mem.eql(u8, name, "encoding")) {
                if (!validEncodingName(value) or has_encoding) {
                    return self.fail(error.InvalidXmlDeclaration, value_start);
                }
                has_encoding = true;
                saw_encoding = true;
            } else {
                return self.fail(error.InvalidXmlDeclaration, name_start);
            }
        }
        _ = declaration;
        if (!has_encoding) {
            // A text declaration, when present, must declare an encoding.
            return self.fail(error.InvalidXmlDeclaration, start);
        }
        if (version) |value| {
            if (!std.mem.eql(u8, value, "1.0")) {
                return self.fail(error.UnsupportedXmlVersion, start);
            }
        }
        return source[end + 2 ..];
    }

    fn attributeExpansionValid(
        self: *Parser,
        value: []const u8,
        depth: usize,
    ) bool {
        if (depth > entities.max_expansion_depth) return false;
        var scan = value;
        if (std.mem.indexOf(u8, scan, "&#") != null) {
            if (self.scratchAllocator()) |allocator| {
                scan = decodeCharacterReferences(self, scan, allocator) catch
                    return false;
            }
        }
        var index: usize = 0;
        while (index < scan.len) {
            if (scan[index] == '<') return false;
            if (scan[index] != '&') {
                index += 1;
                continue;
            }
            const semicolon = std.mem.indexOfScalarPos(u8, scan, index + 1, ';') orelse
                return false;
            const body = scan[index + 1 .. semicolon];
            index = semicolon + 1;
            if (body.len == 0) return false;
            if (body[0] == '#') {
                const codepoint = if (body.len > 1 and body[1] == 'x')
                    chars.parseHexCharRef(body[1..])
                else
                    chars.parseDecimalCharRef(body[1..]);
                const cp = codepoint orelse return false;
                if (cp == '<' or cp == '&') return false;
                continue;
            }
            if (entities.isPredefined(body)) continue;
            const entity = self.entity_table.find(body) orelse return false;
            if (entity.external) return false;
            if (!self.attributeExpansionValid(entity.value, depth + 1)) {
                return false;
            }
        }
        return true;
    }

    fn entityValueContainsLt(
        self: *const Parser,
        value: []const u8,
        depth: usize,
    ) bool {
        if (depth > entities.max_expansion_depth) return true;
        var cursor: usize = 0;
        while (cursor < value.len) {
            if (value[cursor] == '<') return true;
            if (value[cursor] != '&') {
                cursor += 1;
                continue;
            }
            const semicolon = std.mem.indexOfScalarPos(u8, value, cursor + 1, ';') orelse
                return false;
            const body = value[cursor + 1 .. semicolon];
            cursor = semicolon + 1;
            if (body.len == 0) continue;
            if (body[0] == '#') {
                const codepoint = if (body.len > 1 and body[1] == 'x')
                    chars.parseHexCharRef(body[1..])
                else
                    chars.parseDecimalCharRef(body[1..]);
                if (codepoint) |cp| {
                    if (cp == '<') return true;
                }
                continue;
            }
            if (entities.isPredefined(body)) continue;
            const entity = self.entity_table.find(body) orelse continue;
            if (!entity.external and self.entityValueContainsLt(entity.value, depth + 1)) {
                return true;
            }
        }
        return false;
    }

    fn entityValueReferencesExternal(
        self: *const Parser,
        value: []const u8,
        depth: usize,
    ) bool {
        if (depth > entities.max_expansion_depth) return true;
        var cursor: usize = 0;
        while (std.mem.indexOfScalarPos(u8, value, cursor, '&')) |amp| {
            const semicolon = std.mem.indexOfScalarPos(u8, value, amp + 1, ';') orelse
                return false;
            const body = value[amp + 1 .. semicolon];
            cursor = semicolon + 1;
            if (body.len == 0 or body[0] == '#') continue;
            if (entities.isPredefined(body)) continue;
            const entity = self.entity_table.find(body) orelse continue;
            if (entity.external) return true;
            if (self.entityValueReferencesExternal(entity.value, depth + 1)) {
                return true;
            }
        }
        return false;
    }

    fn startsWith(self: *const Parser, prefix: []const u8) bool {
        return std.mem.startsWith(u8, self.input[self.pos..], prefix);
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.input.len and
            chars.isWhitespace(self.input[self.pos]))
        {
            self.pos += 1;
        }
    }

    fn skipWhitespaceCount(self: *Parser) usize {
        const start = self.pos;
        self.skipWhitespace();
        return self.pos - start;
    }

    fn skipWhitespaceRequired(self: *Parser) bool {
        return self.skipWhitespaceCount() != 0;
    }

    fn fail(self: *Parser, err: Error, offset: usize) Error {
        self.error_offset = offset;
        self.error_input = self.input;
        return err;
    }
};

/// Small recursive-descent scanner over one DTD markup declaration. The
/// declaration end is located first with quote-aware scanning, so the scanner
/// can validate grammar without mutating parser position until it succeeds.
const DtdScanner = struct {
    parser: *Parser,
    text: []const u8,
    base: usize,
    index: usize = 0,

    fn init(parser: *Parser, start: usize, end: usize) DtdScanner {
        return .{
            .parser = parser,
            .text = parser.input[start .. end + 1],
            .base = start,
        };
    }

    fn abs(self: *const DtdScanner) usize {
        return self.base + self.index;
    }

    fn atEnd(self: *const DtdScanner) bool {
        return self.index >= self.text.len;
    }

    fn peek(self: *const DtdScanner) ?u8 {
        return if (self.index < self.text.len) self.text[self.index] else null;
    }

    fn startsWith(self: *const DtdScanner, prefix: []const u8) bool {
        return std.mem.startsWith(u8, self.text[self.index..], prefix);
    }

    fn fail(self: *DtdScanner, err: Error) Error {
        return self.parser.fail(err, self.abs());
    }

    fn failAt(self: *DtdScanner, err: Error, relative: usize) Error {
        return self.parser.fail(err, self.base + relative);
    }

    fn eat(self: *DtdScanner, token: []const u8) bool {
        if (!self.startsWith(token)) return false;
        self.index += token.len;
        return true;
    }

    fn eatKeyword(self: *DtdScanner, word: []const u8) bool {
        if (!self.startsWith(word)) return false;
        const after = self.index + word.len;
        if (after < self.text.len and chars.isAsciiNameChar(self.text[after])) {
            return false;
        }
        self.index = after;
        return true;
    }

    fn skipWhitespace(self: *DtdScanner) usize {
        const start = self.index;
        while (self.index < self.text.len and
            chars.isWhitespace(self.text[self.index]))
        {
            self.index += 1;
        }
        return self.index - start;
    }

    fn requireWhitespace(self: *DtdScanner) Error!void {
        if (self.skipWhitespace() == 0) return self.fail(error.InvalidDoctype);
    }

    fn expectByte(self: *DtdScanner, byte: u8) Error!void {
        if (self.peek() != byte) return self.fail(error.InvalidDoctype);
        self.index += 1;
    }

    fn scanName(self: *DtdScanner) Error![]const u8 {
        const len = chars.scanName(self.text[self.index..]);
        if (len == 0) return self.fail(error.InvalidName);
        const name = self.text[self.index .. self.index + len];
        self.index += len;
        return name;
    }

    fn scanNmtoken(self: *DtdScanner) Error![]const u8 {
        const len = chars.scanNmtoken(self.text[self.index..]);
        if (len == 0) return self.fail(error.InvalidName);
        const token = self.text[self.index .. self.index + len];
        self.index += len;
        return token;
    }

    fn scanQuoted(self: *DtdScanner) Error![]const u8 {
        const quote = self.peek() orelse return self.fail(error.UnexpectedEndOfInput);
        if (quote != '"' and quote != '\'') return self.fail(error.InvalidDoctype);
        self.index += 1;
        const value_start = self.index;
        while (self.index < self.text.len and self.text[self.index] != quote) {
            self.index += 1;
        }
        if (self.index >= self.text.len) {
            return self.fail(error.UnexpectedEndOfInput);
        }
        const value = self.text[value_start..self.index];
        if (chars.findInvalidXmlChar(value)) |bad| {
            return self.failAt(error.InvalidCharacter, value_start + bad);
        }
        self.index += 1;
        return value;
    }
};

fn scanContentSpec(scanner: *DtdScanner) Error!void {
    if (scanner.eatKeyword("EMPTY") or scanner.eatKeyword("ANY")) return;
    if (scanner.peek() != '(') return scanner.fail(error.InvalidDoctype);

    var look = scanner.index + 1;
    while (look < scanner.text.len and chars.isWhitespace(scanner.text[look])) {
        look += 1;
    }
    if (std.mem.startsWith(u8, scanner.text[look..], "#PCDATA")) {
        return scanMixed(scanner);
    }
    return scanChildrenGroup(scanner);
}

fn scanMixed(scanner: *DtdScanner) Error!void {
    try scanner.expectByte('(');
    _ = scanner.skipWhitespace();
    if (!scanner.eat("#PCDATA")) return scanner.fail(error.InvalidDoctype);
    _ = scanner.skipWhitespace();
    var has_names = false;
    while (scanner.peek() == '|') {
        has_names = true;
        scanner.index += 1;
        _ = scanner.skipWhitespace();
        _ = try scanner.scanName();
        _ = scanner.skipWhitespace();
    }
    try scanner.expectByte(')');
    if (scanner.peek() == '*') {
        scanner.index += 1;
    } else if (has_names) {
        return scanner.fail(error.InvalidDoctype);
    }
}

fn scanChildrenGroup(scanner: *DtdScanner) Error!void {
    try scanner.expectByte('(');
    _ = scanner.skipWhitespace();
    try scanContentParticle(scanner);
    _ = scanner.skipWhitespace();

    var separator: ?u8 = null;
    while (scanner.peek()) |byte| {
        if (byte != '|' and byte != ',') break;
        if (separator) |previous| {
            if (previous != byte) return scanner.fail(error.InvalidDoctype);
        }
        separator = byte;
        scanner.index += 1;
        _ = scanner.skipWhitespace();
        try scanContentParticle(scanner);
        _ = scanner.skipWhitespace();
    }
    try scanner.expectByte(')');
    if (scanner.peek()) |byte| {
        if (byte == '?' or byte == '*' or byte == '+') scanner.index += 1;
    }
}

fn scanContentParticle(scanner: *DtdScanner) Error!void {
    _ = scanner.skipWhitespace();
    if (scanner.peek() == '(') {
        try scanChildrenGroup(scanner);
        return;
    }
    _ = try scanner.scanName();
    if (scanner.peek()) |byte| {
        if (byte == '?' or byte == '*' or byte == '+') scanner.index += 1;
    }
}

fn scanAttType(scanner: *DtdScanner) Error!void {
    const tokenized = [_][]const u8{
        "CDATA",    "IDREFS",  "IDREF", "ID", "ENTITIES", "ENTITY",
        "NMTOKENS", "NMTOKEN",
    };
    for (tokenized) |keyword| {
        if (scanner.eatKeyword(keyword)) return;
    }
    if (scanner.eatKeyword("NOTATION")) {
        try scanner.requireWhitespace();
        try scanner.expectByte('(');
        _ = scanner.skipWhitespace();
        _ = try scanner.scanName();
        _ = scanner.skipWhitespace();
        while (scanner.peek() == '|') {
            scanner.index += 1;
            _ = scanner.skipWhitespace();
            _ = try scanner.scanName();
            _ = scanner.skipWhitespace();
        }
        try scanner.expectByte(')');
        return;
    }
    if (scanner.peek() == '(') {
        scanner.index += 1;
        _ = scanner.skipWhitespace();
        _ = try scanner.scanNmtoken();
        _ = scanner.skipWhitespace();
        while (scanner.peek() == '|') {
            scanner.index += 1;
            _ = scanner.skipWhitespace();
            _ = try scanner.scanNmtoken();
            _ = scanner.skipWhitespace();
        }
        try scanner.expectByte(')');
        return;
    }
    return scanner.fail(error.InvalidDoctype);
}

fn scanDefaultDecl(scanner: *DtdScanner) Error!void {
    if (scanner.eatKeyword("#REQUIRED") or scanner.eatKeyword("#IMPLIED")) {
        return;
    }
    if (scanner.eatKeyword("#FIXED")) try scanner.requireWhitespace();

    const quote = scanner.peek() orelse return scanner.fail(error.UnexpectedEndOfInput);
    if (quote != '"' and quote != '\'') return scanner.fail(error.InvalidDoctype);
    scanner.index += 1;
    const value_start = scanner.index;
    while (scanner.index < scanner.text.len and scanner.text[scanner.index] != quote) {
        const byte = scanner.text[scanner.index];
        if (byte == '<') return scanner.fail(error.InvalidAttributeValue);
        if (byte == '&') {
            const semicolon = std.mem.indexOfScalarPos(
                u8,
                scanner.text,
                scanner.index + 1,
                ';',
            ) orelse return scanner.fail(error.InvalidEntityReference);
            try scanner.parser.validateReferenceBody(
                scanner.text[scanner.index + 1 .. semicolon],
                scanner.base + scanner.index,
                true,
            );
            scanner.index = semicolon + 1;
            continue;
        }
        scanner.index += 1;
    }
    if (scanner.index >= scanner.text.len) {
        return scanner.fail(error.UnexpectedEndOfInput);
    }
    const value = scanner.text[value_start..scanner.index];
    if (chars.findInvalidXmlChar(value)) |bad| {
        return scanner.failAt(error.InvalidCharacter, value_start + bad);
    }
    scanner.index += 1;
}

fn decodeCharacterReferences(
    parser: *Parser,
    value: []const u8,
    allocator: std.mem.Allocator,
) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < value.len) {
        if (value[index] != '&') {
            try out.append(allocator, value[index]);
            index += 1;
            continue;
        }
        const semicolon = std.mem.indexOfScalarPos(u8, value, index + 1, ';') orelse {
            return parser.fail(error.InvalidEntityReference, index);
        };
        const body = value[index + 1 .. semicolon];
        if (body.len > 0 and body[0] == '#') {
            const codepoint = if (body.len > 1 and body[1] == 'x')
                chars.parseHexCharRef(body[1..])
            else
                chars.parseDecimalCharRef(body[1..]);
            const cp = codepoint orelse {
                return parser.fail(error.InvalidEntityReference, index);
            };
            var buffer: [4]u8 = undefined;
            try out.appendSlice(allocator, chars.encodeUtf8(&buffer, cp));
            index = semicolon + 1;
            continue;
        }
        try out.appendSlice(allocator, value[index .. semicolon + 1]);
        index = semicolon + 1;
    }
    return out.toOwnedSlice(allocator);
}

fn decodeParameterReplacement(
    parser: *Parser,
    value: []const u8,
    allocator: std.mem.Allocator,
) Error![]const u8 {
    if (std.mem.indexOfScalar(u8, value, '&') == null) return value;
    var out: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < value.len) {
        if (value[index] != '&') {
            try out.append(allocator, value[index]);
            index += 1;
            continue;
        }
        const semicolon = std.mem.indexOfScalarPos(u8, value, index + 1, ';') orelse {
            return parser.fail(error.InvalidEntityReference, index);
        };
        const body = value[index + 1 .. semicolon];
        if (body.len > 0 and body[0] == '#') {
            const codepoint = if (body.len > 1 and
                (body[1] == 'x' or body[1] == 'X'))
                chars.parseHexCharRef(body[1..])
            else
                chars.parseDecimalCharRef(body[1..]);
            const cp = codepoint orelse {
                return parser.fail(error.InvalidEntityReference, index);
            };
            var buffer: [4]u8 = undefined;
            try out.appendSlice(allocator, chars.encodeUtf8(&buffer, cp));
            index = semicolon + 1;
            continue;
        }
        if (entities.predefinedReplacement(body)) |byte| {
            try out.append(allocator, byte);
            index = semicolon + 1;
            continue;
        }
        // Leave general entity references for the entity's own expansion.
        try out.appendSlice(allocator, value[index .. semicolon + 1]);
        index = semicolon + 1;
    }
    return out.toOwnedSlice(allocator);
}

const ParameterReference = struct {
    name: []const u8,
    end: usize,
};

fn parseParameterReference(raw: []const u8, pos: usize) ?ParameterReference {
    if (pos >= raw.len or raw[pos] != '%') return null;
    const name_start = pos + 1;
    const name_len = chars.scanName(raw[name_start..]);
    if (name_len == 0) return null;
    const name_end = name_start + name_len;
    if (name_end >= raw.len or raw[name_end] != ';') return null;
    return .{ .name = raw[name_start..name_end], .end = name_end + 1 };
}

/// Locate the `]` that closes the internal subset, skipping declarations,
/// comments, processing instructions, and parameter references.
fn findInternalSubsetEnd(input: []const u8, start: usize) ?usize {
    var pos = start;
    while (pos < input.len) {
        if (input[pos] == ']') return pos;
        if (std.mem.startsWith(u8, input[pos..], "<!--")) {
            const end = std.mem.indexOfPos(u8, input, pos + 4, "-->") orelse return null;
            pos = end + 3;
            continue;
        }
        if (std.mem.startsWith(u8, input[pos..], "<?")) {
            const end = std.mem.indexOfPos(u8, input, pos + 2, "?>") orelse return null;
            pos = end + 2;
            continue;
        }
        if (std.mem.startsWith(u8, input[pos..], "<!")) {
            const end = markup.findDeclarationEnd(input, pos + 2) orelse return null;
            pos = end + 1;
            continue;
        }
        if (input[pos] == '%') {
            const reference = parseParameterReference(input, pos) orelse return null;
            pos = reference.end;
            continue;
        }
        pos += 1;
    }
    return null;
}

fn internalSubsetNeedsExpansion(raw: []const u8) bool {
    var pos: usize = 0;
    while (pos < raw.len) {
        if (raw[pos] == '%') return true;
        if (std.mem.startsWith(u8, raw[pos..], "<!--")) {
            const end = std.mem.indexOfPos(u8, raw, pos + 4, "-->") orelse return false;
            pos = end + 3;
            continue;
        }
        if (std.mem.startsWith(u8, raw[pos..], "<?")) {
            const end = std.mem.indexOfPos(u8, raw, pos + 2, "?>") orelse return false;
            pos = end + 2;
            continue;
        }
        if (std.mem.startsWith(u8, raw[pos..], "<!")) {
            const end = markup.findDeclarationEnd(raw, pos + 2) orelse return false;
            pos = end + 1;
            continue;
        }
        pos += 1;
    }
    return false;
}

/// Resolve external conditional sections after parameter-entity expansion.
fn appendConditionalByte(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    out_ids: *std.ArrayList(u32),
    input_ids: ?[]const u32,
    position: usize,
    byte: u8,
) Error!void {
    try out.append(allocator, byte);
    if (input_ids) |ids| {
        try out_ids.append(
            allocator,
            if (position < ids.len) ids[position] else 0,
        );
    } else {
        try out_ids.append(allocator, 0);
    }
}

/// Resolve external conditional sections after parameter-entity expansion.
fn evaluateConditionals(
    allocator: std.mem.Allocator,
    input: []const u8,
    input_ids: ?[]const u32,
    out: *std.ArrayList(u8),
    out_ids: *std.ArrayList(u32),
) Error!void {
    var pos: usize = 0;
    var quote: u8 = 0;
    while (pos < input.len) {
        const byte = input[pos];
        if (quote != 0) {
            try appendConditionalByte(allocator, out, out_ids, input_ids, pos, byte);
            if (byte == quote) quote = 0;
            pos += 1;
            continue;
        }
        if (byte == '"' or byte == '\'') {
            quote = byte;
            try appendConditionalByte(allocator, out, out_ids, input_ids, pos, byte);
            pos += 1;
            continue;
        }
        if (std.mem.startsWith(u8, input[pos..], "<!--")) {
            const end = std.mem.indexOfPos(u8, input, pos + 4, "-->") orelse
                return error.UnexpectedEndOfInput;
            var index = pos;
            while (index < end + 3) : (index += 1) {
                try appendConditionalByte(
                    allocator,
                    out,
                    out_ids,
                    input_ids,
                    index,
                    input[index],
                );
            }
            pos = end + 3;
            continue;
        }
        if (std.mem.startsWith(u8, input[pos..], "<?")) {
            const end = std.mem.indexOfPos(u8, input, pos + 2, "?>") orelse
                return error.UnexpectedEndOfInput;
            var index = pos;
            while (index < end + 2) : (index += 1) {
                try appendConditionalByte(
                    allocator,
                    out,
                    out_ids,
                    input_ids,
                    index,
                    input[index],
                );
            }
            pos = end + 2;
            continue;
        }
        if (!std.mem.startsWith(u8, input[pos..], "<![")) {
            try appendConditionalByte(allocator, out, out_ids, input_ids, pos, byte);
            pos += 1;
            continue;
        }

        var cursor = pos + 3;
        while (cursor < input.len and chars.isWhitespace(input[cursor])) cursor += 1;
        const keyword_start = cursor;
        while (cursor < input.len and chars.isAsciiNameChar(input[cursor])) cursor += 1;
        const keyword = input[keyword_start..cursor];
        while (cursor < input.len and chars.isWhitespace(input[cursor])) cursor += 1;
        if (cursor >= input.len or input[cursor] != '[') {
            return error.InvalidDoctype;
        }
        const content_start = cursor + 1;

        var depth: usize = 1;
        var scan = content_start;
        var section_quote: u8 = 0;
        while (scan < input.len and depth > 0) {
            if (section_quote != 0) {
                if (input[scan] == section_quote) section_quote = 0;
                scan += 1;
                continue;
            }
            if (input[scan] == '"' or input[scan] == '\'') {
                section_quote = input[scan];
                scan += 1;
                continue;
            }
            if (std.mem.startsWith(u8, input[scan..], "<![")) {
                depth += 1;
                scan += 3;
                continue;
            }
            if (std.mem.startsWith(u8, input[scan..], "]]>")) {
                depth -= 1;
                scan += 3;
                continue;
            }
            scan += 1;
        }
        if (depth != 0) return error.UnexpectedEndOfInput;
        const content_end = scan - 3;

        if (std.mem.eql(u8, keyword, "INCLUDE")) {
            const ids_slice: ?[]const u32 = if (input_ids) |ids|
                ids[content_start..content_end]
            else
                null;
            try evaluateConditionals(
                allocator,
                input[content_start..content_end],
                ids_slice,
                out,
                out_ids,
            );
        } else if (!std.mem.eql(u8, keyword, "IGNORE")) {
            return error.InvalidDoctype;
        }
        pos = scan;
    }
}

fn isPubidChar(byte: u8) bool {
    return switch (byte) {
        ' ', '\r', '\n', 'a'...'z', 'A'...'Z', '0'...'9' => true,
        '-',
        '\'',
        '(',
        ')',
        '+',
        ',',
        '.',
        '/',
        ':',
        '=',
        '?',
        ';',
        '!',
        '*',
        '#',
        '@',
        '$',
        '_',
        '%',
        => true,
        else => false,
    };
}

/// Find the next byte that requires special handling in character data:
/// `<` (markup), `&` (reference), or `]` (possible `]]>` terminator).
fn findTextSpecial(input: []const u8, start: usize) usize {
    const Vec = @Vector(16, u8);
    const lt: Vec = @splat('<');
    const amp: Vec = @splat('&');
    const rb: Vec = @splat(']');
    var index = start;
    while (index + 16 <= input.len) : (index += 16) {
        const chunk: Vec = input[index..][0..16].*;
        const mask: u16 = @bitCast((chunk == lt) | (chunk == amp) | (chunk == rb));
        if (mask != 0) return index + @ctz(mask);
    }
    while (index < input.len) : (index += 1) {
        switch (input[index]) {
            '<', '&', ']' => return index,
            else => {},
        }
    }
    return input.len;
}

fn decodeExternalAlloc(
    source: []const u8,
    allocator: std.mem.Allocator,
) Error![]const u8 {
    return encoding.decodeAlloc(allocator, source, 64 * 1024 * 1024) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidCharacter,
    };
}

fn validVersionNumber(value: []const u8) bool {
    if (value.len < 3 or value[0] != '1' or value[1] != '.') return false;
    for (value[2..]) |byte| {
        if (byte < '0' or byte > '9') return false;
    }
    return true;
}

fn validEncodingName(value: []const u8) bool {
    if (value.len == 0) return false;
    if (!std.ascii.isAlphabetic(value[0])) return false;
    for (value[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and
            byte != '.' and byte != '_' and byte != '-')
        {
            return false;
        }
    }
    return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectEvents(input: []const u8, expected: []const Event) !void {
    var parser = Parser.init(input, .{});
    for (expected) |expected_event| {
        const event = (try parser.next()) orelse {
            std.debug.print("missing event for input: {s}\n", .{input});
            return error.TestUnexpectedResult;
        };
        try expectEventEqual(expected_event, event);
    }
    try testing.expect((try parser.next()) == null);
}

fn expectEventEqual(expected: Event, actual: Event) !void {
    try testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
    switch (expected) {
        .xml_declaration => |e| {
            try testing.expectEqualStrings(e.version, actual.xml_declaration.version);
        },
        .start_element => |e| {
            try testing.expectEqualStrings(e.name, actual.start_element.name);
            try testing.expectEqual(e.self_closing, actual.start_element.self_closing);
            try testing.expectEqual(e.depth, actual.start_element.depth);
            try testing.expectEqual(e.attrs.len, actual.start_element.attrs.len);
        },
        .end_element => |e| {
            try testing.expectEqualStrings(e.name, actual.end_element.name);
            try testing.expectEqual(e.depth, actual.end_element.depth);
        },
        .text => |e| try testing.expectEqualStrings(e, actual.text),
        .cdata => |e| try testing.expectEqualStrings(e, actual.cdata),
        .comment => |e| try testing.expectEqualStrings(e, actual.comment),
        .processing_instruction => |e| {
            try testing.expectEqualStrings(e.target, actual.processing_instruction.target);
            try testing.expectEqualStrings(e.data, actual.processing_instruction.data);
        },
        .doctype => |e| {
            try testing.expectEqualStrings(e.name, actual.doctype.name);
        },
    }
}

fn expectParseError(input: []const u8, expected: Error) !void {
    var parser = Parser.init(input, .{});
    while (true) {
        const event = parser.next() catch |err| {
            try testing.expectEqual(expected, err);
            return;
        };
        if (event == null) break;
    }
    std.debug.print("expected {s} for input: {s}\n", .{ @errorName(expected), input });
    return error.TestUnexpectedResult;
}

test "parser accepts a complete document with declarations and markup" {
    const input = "\xEF\xBB\xBF" ++
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<?xml-stylesheet href="a"?>
        \\<!-- prolog -->
        \\<svg xmlns="http://www.w3.org/2000/svg" width='10'>
        \\  <g id="x"><rect width="1"/></g>
        \\  text &amp; more
        \\  <![CDATA[<raw>]]>
        \\</svg>
        \\<!-- epilog -->
    ;
    var parser = Parser.init(input, .{});
    var seen_root = false;
    var seen_text = false;
    var seen_cdata = false;
    var seen_comment: usize = 0;
    while (try parser.next()) |event| {
        switch (event) {
            .xml_declaration => |decl| {
                try testing.expectEqualStrings("1.0", decl.version);
                try testing.expectEqualStrings("UTF-8", decl.encoding.?);
                try testing.expectEqual(true, decl.standalone.?);
            },
            .processing_instruction => |pi| {
                try testing.expectEqualStrings("xml-stylesheet", pi.target);
            },
            .comment => seen_comment += 1,
            .doctype => return error.TestUnexpectedResult,
            .start_element => |element| {
                if (std.mem.eql(u8, element.name, "svg")) {
                    seen_root = true;
                    try testing.expectEqual(@as(usize, 1), element.depth);
                    try testing.expectEqual(@as(usize, 2), element.attrs.len);
                    try testing.expectEqualStrings(
                        "http://www.w3.org/2000/svg",
                        element.attrs[0].value,
                    );
                }
                if (std.mem.eql(u8, element.name, "rect")) {
                    try testing.expect(element.self_closing);
                    try testing.expectEqual(@as(usize, 3), element.depth);
                }
            },
            .end_element => |element| {
                if (std.mem.eql(u8, element.name, "svg")) {
                    try testing.expectEqual(@as(usize, 1), element.depth);
                }
            },
            .text => |text| {
                if (std.mem.indexOf(u8, text, "&amp;") != null) seen_text = true;
            },
            .cdata => |data| {
                try testing.expectEqualStrings("<raw>", data);
                seen_cdata = true;
            },
        }
    }
    try testing.expect(seen_root);
    try testing.expect(seen_text);
    try testing.expect(seen_cdata);
    try testing.expectEqual(@as(usize, 2), seen_comment);
}

test "parser accepts self-closing root and trailing misc" {
    var parser = Parser.init("<a/> <!-- c --> <?p d?>", .{});
    const root = (try parser.next()).?.start_element;
    try testing.expectEqualStrings("a", root.name);
    try testing.expect(root.self_closing);
    try testing.expectEqual(@as(usize, 1), root.depth);
    try testing.expectEqualStrings(" c ", (try parser.next()).?.comment);
    const pi = (try parser.next()).?.processing_instruction;
    try testing.expectEqualStrings("p", pi.target);
    try testing.expectEqualStrings("d", pi.data);
    try testing.expect((try parser.next()) == null);
}

test "parser reports well-formedness violations" {
    try expectParseError("", error.MissingRootElement);
    try expectParseError("   ", error.MissingRootElement);
    try expectParseError("<a>", error.UnexpectedEndOfInput);
    try expectParseError("<a></b>", error.MismatchedEndTag);
    try expectParseError("<a><b></a></b>", error.MismatchedEndTag);
    try expectParseError("<a/><b/>", error.MultipleRootElements);
    try expectParseError("<a/>text", error.ContentAfterRoot);
    try expectParseError("<a b='1' b='2'/>", error.DuplicateAttribute);
    try expectParseError("<a b=1/>", error.InvalidAttributeValue);
    try expectParseError("<a b='<'/>", error.InvalidAttributeValue);
    try expectParseError("<a b='&missing;'/>", error.UndeclaredEntity);
    try expectParseError("<a>&missing;</a>", error.UndeclaredEntity);
    try expectParseError("<a>&amp</a>", error.InvalidEntityReference);
    try expectParseError("<a>&#0;</a>", error.InvalidEntityReference);
    try expectParseError("<a>&#xD800;</a>", error.InvalidEntityReference);
    try expectParseError("<1a/>", error.InvalidName);
    try expectParseError("<a 1b='x'/>", error.InvalidName);
    try expectParseError("<a></a >x", error.ContentAfterRoot);
    try expectParseError("<a>]]></a>", error.InvalidCdata);
    try expectParseError("<a><!-- a -- b --></a>", error.InvalidComment);
    try expectParseError("<a><!-- a ---></a>", error.InvalidComment);
    try expectParseError("<a><?xml version='1.0'?></a>", error.InvalidProcessingInstruction);
    try expectParseError("<a>\x00</a>", error.InvalidCharacter);
    try expectParseError("<a>\xFF</a>", error.InvalidCharacter);
    try expectParseError("<?xml version='1.0'?><?xml version='1.0'?><a/>", error.InvalidProcessingInstruction);
    try expectParseError("<a/><!DOCTYPE a>", error.MultipleRootElements);
    try expectParseError("<!DOCTYPE a [<!ENTITY e 'x'>]><a>&f;</a>", error.UndeclaredEntity);
}

test "parser accepts internal entity declarations and validates recursion" {
    const input = "<!DOCTYPE svg [<!ENTITY R \"<rect/>\"><!ENTITY C 'blue'>]><svg>&R;<rect fill='&C;'/></svg>";
    var parser = Parser.init(input, .{});
    var saw_doctype = false;
    var saw_entity_rect = false;
    while (try parser.next()) |event| {
        switch (event) {
            .doctype => |doctype| {
                saw_doctype = true;
                try testing.expectEqualStrings("svg", doctype.name);
                try testing.expect(doctype.has_internal_subset);
            },
            .start_element => |element| {
                if (std.mem.eql(u8, element.name, "rect")) {
                    saw_entity_rect = true;
                }
            },
            else => {},
        }
    }
    try testing.expect(saw_doctype);
    try testing.expect(saw_entity_rect);
    try testing.expectEqual(@as(usize, 2), parser.entityTable().count);

    try expectParseError(
        "<!DOCTYPE a [<!ENTITY x '&y;'><!ENTITY y '&x;'>]><a/>",
        error.EntityRecursion,
    );
    try expectParseError(
        "<!DOCTYPE a [<!ENTITY x '&missing;'>]><a>&x;</a>",
        error.UndeclaredEntity,
    );
    try expectParseError(
        "<!DOCTYPE a [<!ENTITY x '<'>]><a b='&x;'/>",
        error.InvalidAttributeValue,
    );
}

test "parser enforces depth and attribute limits" {
    var deep: [256]u8 = undefined;
    var index: usize = 0;
    for (0..32) |_| {
        deep[index] = '<';
        deep[index + 1] = 'a';
        deep[index + 2] = '>';
        index += 3;
    }
    for (0..32) |_| {
        deep[index] = '<';
        deep[index + 1] = '/';
        deep[index + 2] = 'a';
        deep[index + 3] = '>';
        index += 4;
    }
    const input = deep[0..index];

    var parser = Parser.init(input, .{ .max_depth = 8 });
    while (true) {
        _ = parser.next() catch |err| {
            try testing.expectEqual(Error.DepthLimitExceeded, err);
            break;
        };
    }

    var limited = Parser.init("<a a='1' b='2'/>", .{ .max_attributes = 1 });
    try testing.expectError(error.AttributeLimitExceeded, limited.next());
}

test "parser rejects non-UTF-8 byte order marks" {
    try expectParseError("\xFF\xFE<\x00a\x00/\x00>\x00", error.NonUtf8Input);
    try expectParseError("\xFE\xFF\x00<\x00a\x00/\x00>", error.NonUtf8Input);
}

test "parser accepts XML declarations in any valid order" {
    var declaration_parser = Parser.init(
        "<?xml version='1.0' encoding=\"UTF-8\" standalone='no'?><a/>",
        .{},
    );
    const decl = (try declaration_parser.next()).?.xml_declaration;
    try testing.expectEqualStrings("UTF-8", decl.encoding.?);
    try testing.expectEqual(false, decl.standalone.?);

    try expectParseError("<?xml encoding='UTF-8' version='1.0'?><a/>", error.InvalidXmlDeclaration);
    try expectParseError("<?xml version='2.0'?><a/>", error.UnsupportedXmlVersion);
    try expectParseError("<?xml version='1.0' encoding='bad name'?><a/>", error.InvalidXmlDeclaration);
    try expectParseError("<?xml version='1.0' standalone='maybe'?><a/>", error.InvalidXmlDeclaration);
    try expectParseError(" <?xml version='1.0'?><a/>", error.InvalidProcessingInstruction);
}

test "parser handles doctype external identifiers and opaque declarations" {
    const input =
        \\<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd" [
        \\  <!ELEMENT svg ANY>
        \\  <!ATTLIST svg width CDATA #IMPLIED>
        \\  <!-- comment ] -->
        \\  <!ENTITY st 'stroke="red"'>
        \\]>
        \\<svg/>
    ;
    var parser = Parser.init(input, .{});
    const doctype = (try parser.next()).?.doctype;
    try testing.expectEqualStrings("svg", doctype.name);
    try testing.expectEqualStrings(
        "-//W3C//DTD SVG 1.1//EN",
        doctype.public_id.?,
    );
    try testing.expectEqualStrings(
        "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd",
        doctype.system_id.?,
    );
    try testing.expectEqualStrings("stroke=\"red\"", parser.entityTable().find("st").?.value);
    const root = (try parser.next()).?.start_element;
    try testing.expectEqualStrings("svg", root.name);
}

test "parser recovers line and column for errors" {
    var parser = Parser.init("<a>\n  <b>\n</a>", .{});
    while (true) {
        _ = parser.next() catch |err| {
            try testing.expectEqual(Error.MismatchedEndTag, err);
            const position = parser.lineColumn(parser.errorOffset());
            try testing.expectEqual(@as(usize, 3), position.line);
            try testing.expectEqual(@as(usize, 3), position.column);
            return;
        };
    }
    return error.TestUnexpectedResult;
}

test "text scanner stops at markup and validates references" {
    const input = "<a>x &amp; y &lt; z</a>";
    var parser = Parser.init(input, .{});
    _ = try parser.next();
    const text = (try parser.next()).?.text;
    try testing.expectEqualStrings("x &amp; y &lt; z", text);
    const end = (try parser.next()).?.end_element;
    try testing.expectEqualStrings("a", end.name);
}
