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
const namespace = @import("namespace.zig");

pub const max_open_elements = 512;
pub const max_attributes = 64;

/// Byte offsets are 32-bit; inputs larger than 4 GiB are rejected. This keeps
/// attribute records compact for large DOMs while remaining far beyond typical
/// XML document sizes.
pub const SourceRange = struct {
    start: u32,
    end: u32,
};

pub const DefaultKind = enum { required, implied, fixed, value };

pub const AttributeType = union(enum) {
    cdata,
    id,
    idref,
    idrefs,
    entity,
    entities,
    nmtoken,
    nmtokens,
    notation: []const []const u8,
    enumeration: []const []const u8,
};

pub const ContentNode = union(enum) {
    name: []const u8,
    choice: []const *ContentNode,
    sequence: []const *ContentNode,
    quantifier: struct {
        node: *ContentNode,
        min: u8,
        max: ?u8,
    },
};

pub const ContentModel = union(enum) {
    empty,
    any,
    mixed: []const []const u8,
    children: *ContentNode,
};

pub const ElementDecl = struct {
    name: []const u8,
    model: ContentModel,
    from_external: bool = false,
};

pub const AttributeDecl = struct {
    element: []const u8,
    name: []const u8,
    attr_type: AttributeType,
    default_kind: DefaultKind,
    default_value: []const u8 = "",
    value_offset: usize = 0,
    from_external: bool = false,

    pub fn tokenized(self: AttributeDecl) bool {
        return self.attr_type != .cdata;
    }
};

pub const NotationDecl = struct {
    name: []const u8,
    public_id: ?[]const u8 = null,
    system_id: ?[]const u8 = null,
    from_external: bool = false,
};

pub const DuplicateAttribute = struct {
    element: []const u8,
    name: []const u8,
};

pub const PeIssue = struct {
    offset: usize,
};

pub const Dtd = struct {
    doctype_name: []const u8,
    elements: []const ElementDecl,
    attributes: []const AttributeDecl,
    notations: []const NotationDecl,
    entities: entities.Table,
    duplicate_elements: []const []const u8,
    duplicate_attributes: []const DuplicateAttribute,
    duplicate_notations: []const []const u8,
    pe_issues: []const PeIssue,
    undeclared_refs: []const []const u8,
    standalone: ?bool,
    namespaces: bool,
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
    /// Validate Namespaces in XML 1.0 constraints and resolve names. Disabled
    /// by default so permissive legacy documents can be scanned as raw XML.
    namespaces: bool = false,
    /// Assume the input is already well-formed XML. Skips name, character,
    /// duplicate-attribute, and namespace constraint validation. Never use
    /// this for untrusted input.
    trusted: bool = false,
    /// Allocator used when a DTD declares entities or needs parameter-entity
    /// expansion or an external subset/entity. Without it those features
    /// report `UnsupportedParameterEntity`. Entity storage lives until the
    /// parser is deinitialized.
    allocator: ?std.mem.Allocator = null,
    /// Optional resolver for external DTD subsets and parsed entities. The
    /// returned slice must remain valid for the parser's lifetime.
    resolver: ?ExternalResolver = null,
    /// Maximum nesting of external parsed entities and parameter entities.
    max_external_depth: usize = 8,
};

pub const ExternalResource = struct {
    /// Resource contents. The slice must remain valid for the parser's
    /// lifetime; the DOM may retain slices into it (entity values, DTD
    /// declarations) for the document lifetime.
    data: []const u8,
    /// Resolved URI, used as the base for nested external references.
    uri: []const u8,
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
    ) ?ExternalResource,
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
    InputTooLarge,
    UnsupportedParameterEntity,
    ExternalEntityDepthExceeded,
    InvalidQualifiedName,
    UndeclaredPrefix,
    InvalidNamespaceDeclaration,
    ReservedPrefix,
    DuplicateExpandedAttribute,
    NamespaceLimitExceeded,
};

pub const Attribute = struct {
    pub fn localName(self: Attribute) []const u8 {
        return if (self.colon == 0xFFFF) self.name else self.name[self.colon + 1 ..];
    }

    pub fn prefixName(self: Attribute) []const u8 {
        return if (self.colon == 0xFFFF) "" else self.name[0..self.colon];
    }

    /// Raw qualified name exactly as authored.
    name: []const u8,
    /// Raw value: references are not expanded and line endings are untouched.
    value: []const u8,
    name_range: SourceRange,
    value_range: SourceRange,
    /// Resolved namespace URI when namespace processing is enabled; empty for
    /// unprefixed attributes and namespace declarations.
    namespace_uri: []const u8 = "",
    /// Byte offset of the first colon in the raw name, or 0xFFFF.
    colon: u16 = 0xFFFF,
    /// Cheap duplicate-detection key for the raw name.
    name_key: u32 = 0,
    /// True when the value needs entity decoding or whitespace normalization.
    needs_decode: bool = false,
    /// True when a character reference produced a tab, LF, or CR. NMTOKENS
    /// validity requires tokens to be separated by literal spaces.
    whitespace_char_ref: bool = false,
    /// True when an ATTLIST declaration gives this attribute a tokenized
    /// (non-CDATA) type, which changes attribute-value normalization.
    tokenized: bool = false,
    /// True when the attribute was supplied by an ATTLIST default rather than
    /// authored on the element.
    from_default: bool = false,
};

pub const StartElement = struct {
    /// Raw qualified name exactly as authored.
    name: []const u8,
    name_range: SourceRange,
    attrs: []const Attribute,
    self_closing: bool,
    /// Depth after opening the element; the root element has depth 1.
    depth: usize,
    /// Resolved namespace URI when namespace processing is enabled.
    namespace_uri: []const u8 = "",
    /// Byte offset of the first colon in the raw name, or 0xFFFF.
    colon: u16 = 0xFFFF,
    /// True when the element declared at least one namespace.
    has_namespace_decls: bool = false,
};

pub const EndElement = struct {
    name: []const u8,
    name_range: SourceRange,
    /// Depth of the element being closed; the root element has depth 1.
    depth: usize,
    /// Resolved namespace URI when namespace processing is enabled.
    namespace_uri: []const u8 = "",
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
    /// True while re-scanning an external subset whose entity declarations
    /// were already parsed and validated during parameter-entity expansion.
    entities_preparsed: bool = false,
    /// False for sub-parsers that borrow the parent's entity tables.
    owns_entity_tables: bool = true,
    ns: namespace.Resolver = .{},
    xml_version: chars.Version = .xml_1_0,
    started: bool = false,
    in_external_subset: bool = false,
    text_whitespace_char_ref: bool = false,
    text_has_nel_ls: bool = false,
    tokenized_attrs: [128]struct {
        element: []const u8,
        name: []const u8,
    } = undefined,
    tokenized_attr_count: usize = 0,
    element_decls: std.ArrayList(ElementDecl) = .empty,
    attribute_decls: std.ArrayList(AttributeDecl) = .empty,
    notation_decls: std.ArrayList(NotationDecl) = .empty,
    fixed_element_decls: [32]ElementDecl = undefined,
    fixed_element_count: usize = 0,
    fixed_attribute_decls: [32]AttributeDecl = undefined,
    fixed_attribute_count: usize = 0,
    fixed_notation_decls: [16]NotationDecl = undefined,
    fixed_notation_count: usize = 0,
    duplicate_elements: std.ArrayList([]const u8) = .empty,
    duplicate_attributes: std.ArrayList(DuplicateAttribute) = .empty,
    duplicate_notations: std.ArrayList([]const u8) = .empty,
    pe_issues: std.ArrayList(PeIssue) = .empty,
    undeclared_refs: std.ArrayList([]const u8) = .empty,
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

    /// Release DTD expansion scratch storage and entity tables. Safe to call
    /// more than once.
    pub fn deinit(self: *Parser) void {
        if (self.scratch) |*arena| arena.deinit();
        self.scratch = null;
        if (self.owns_entity_tables) {
            if (self.options.allocator) |allocator| {
                self.entity_table.deinit(allocator);
                self.parameter_entities.deinit(allocator);
            }
        }
    }

    pub fn xmlVersion(self: *const Parser) chars.Version {
        return self.xml_version;
    }

    fn findInvalidLiteral(self: *const Parser, bytes: []const u8) ?usize {
        return chars.findInvalidLiteralCharVersion(bytes, self.xml_version);
    }

    inline fn nameInfo(self: *const Parser, bytes: []const u8) chars.NameInfo {
        return if (self.options.trusted)
            chars.scanNameInfoFast(bytes)
        else
            chars.scanNameInfo(bytes);
    }

    /// Entity declarations collected from the DOCTYPE internal subset.
    pub fn entityTable(self: *const Parser) *const entities.Table {
        return &self.entity_table;
    }

    pub fn dtd(self: *const Parser) Dtd {
        return .{
            .doctype_name = self.doctype_name,
            .elements = self.element_decls.items,
            .attributes = self.attribute_decls.items,
            .notations = self.notation_decls.items,
            .entities = self.entity_table,
            .duplicate_elements = self.duplicate_elements.items,
            .duplicate_attributes = self.duplicate_attributes.items,
            .duplicate_notations = self.duplicate_notations.items,
            .pe_issues = self.pe_issues.items,
            .undeclared_refs = self.undeclared_refs.items,
            .standalone = self.standalone,
            .namespaces = self.options.namespaces,
        };
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
        if (self.input.len > std.math.maxInt(u32)) {
            return self.fail(error.InputTooLarge, 0);
        }
        if (!self.utf8_input) {
            self.error_offset = 0;
            return error.NonUtf8Input;
        }
        if (!self.started) {
            self.started = true;
            try self.normalizeXml11Input();
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

    /// XML 1.1 adds NEL (U+0085) and LINE SEPARATOR (U+2028) to the line-end
    /// set. Normalize them (and CR) before tokenization, matching XML's
    /// required input normalization. This only allocates when an XML 1.1
    /// document actually contains one of the new line ends.
    fn normalizeXml11Input(self: *Parser) Error!void {
        if (declaredVersion11(self.input, self.pos) != true) return;
        if (!hasXml11LineEnds(self.input)) return;
        const allocator = self.scratchAllocator() orelse {
            return self.fail(error.OutOfMemory, 0);
        };

        var out: std.ArrayList(u8) = .empty;
        var index: usize = 0;
        while (index < self.input.len) {
            const byte = self.input[index];
            if (byte == '\r') {
                try out.append(allocator, '\n');
                if (index + 1 < self.input.len and self.input[index + 1] == '\n') {
                    index += 2;
                } else {
                    index += 1;
                }
                continue;
            }
            if (byte == 0xC2 and index + 1 < self.input.len and
                self.input[index + 1] == 0x85)
            {
                try out.append(allocator, '\n');
                index += 2;
                continue;
            }
            if (byte == 0xE2 and index + 2 < self.input.len and
                self.input[index + 1] == 0x80 and
                self.input[index + 2] == 0xA8)
            {
                try out.append(allocator, '\n');
                index += 3;
                continue;
            }
            try out.append(allocator, byte);
            index += 1;
        }
        const normalized = try out.toOwnedSlice(allocator);
        self.input = normalized;
        self.pos = if (std.mem.startsWith(u8, normalized, "\xEF\xBB\xBF"))
            3
        else
            0;
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
            const following = if (self.pos + 1 < self.input.len)
                self.input[self.pos + 1]
            else
                0;
            switch (following) {
                '/' => return .{ .end_element = try self.scanEndTag() },
                '!' => {
                    if (self.startsWith("<!--")) {
                        return .{ .comment = try self.scanComment() };
                    }
                    if (self.startsWith("<![CDATA[")) {
                        return .{ .cdata = try self.scanCdata() };
                    }
                    return self.fail(error.UnexpectedMarkup, self.pos);
                },
                '?' => return .{ .processing_instruction = try self.scanPi() },
                else => return .{ .start_element = try self.scanStartTag() },
            }
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
        const name_info = self.nameInfo(self.input[name_start..]);
        if (name_info.len == 0) return self.fail(error.InvalidName, name_start);
        const name = self.input[name_start .. name_start + name_info.len];
        self.pos = name_start + name_info.len;

        var attr_count: usize = 0;
        var self_closing = false;
        var has_namespace_decls = false;
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

            if (attr_count == self.options.max_attributes) {
                return self.fail(error.AttributeLimitExceeded, self.pos);
            }
            if (self.options.trusted) {
                try self.scanAttributeIntoTrusted(&self.attrs[attr_count]);
            } else {
                try self.scanAttributeInto(&self.attrs[attr_count]);
            }
            const attr = &self.attrs[attr_count];
            if (self.options.namespaces and
                namespace.Resolver.isNamespaceDeclaration(attr.name))
            {
                has_namespace_decls = true;
            }
            if (!self.options.trusted) {
                for (self.attrs[0..attr_count]) |existing| {
                    if (existing.name_key == attr.name_key and
                        std.mem.eql(u8, existing.name, attr.name))
                    {
                        return self.fail(
                            error.DuplicateAttribute,
                            attr.name_range.start,
                        );
                    }
                }
            }
            attr_count += 1;
        }

        try self.applyAttributeDefaults(name, &attr_count);
        for (self.attrs[0..attr_count]) |*attr| {
            attr.tokenized = self.isTokenizedAttribute(name, attr.name);
            if (self.options.namespaces and
                namespace.Resolver.isNamespaceDeclaration(attr.name))
            {
                // DTD defaults may introduce namespace declarations.
                has_namespace_decls = true;
            }
        }

        var element_namespace: []const u8 = "";
        if (self.options.namespaces) {
            if (has_namespace_decls) {
                var namespace_attrs: [max_attributes]struct {
                    name: []const u8,
                    value: []const u8,
                } = undefined;
                var namespace_attr_count: usize = 0;
                for (self.attrs[0..attr_count]) |*attr| {
                    if (!namespace.Resolver.isNamespaceDeclaration(attr.name)) {
                        continue;
                    }
                    var value = attr.value;
                    if (std.mem.indexOfScalar(u8, value, '&') != null or
                        hasWhitespace(value))
                    {
                        if (self.scratchAllocator()) |allocator| {
                            const decoded = entities.decodeAttributeAlloc(
                                allocator,
                                value,
                                &self.entity_table,
                                .{},
                                .{
                                    .version = self.xml_version,
                                    .preserve_undeclared = true,
                                    .preserve_external = true,
                                },
                            ) catch value;
                            value = decoded;
                            if (self.isTokenizedAttribute(name, attr.name)) {
                                value = normalizeTokenizedValue(
                                    allocator,
                                    decoded,
                                ) catch value;
                            }
                        }
                    }
                    attr.namespace_uri = namespace.xmlns_uri;
                    namespace_attrs[namespace_attr_count] = .{
                        .name = attr.name,
                        .value = value,
                    };
                    namespace_attr_count += 1;
                }
                if (self.options.trusted) {
                    try self.ns.pushUnchecked(
                        namespace_attrs[0..namespace_attr_count],
                    );
                } else {
                    try self.ns.push(namespace_attrs[0..namespace_attr_count]);
                }
            } else {
                try self.ns.enter();
            }

            const resolved_element = if (self.options.trusted)
                self.ns.resolveElementNameUncheckedColon(
                    name,
                    name_info.colon,
                )
            else
                try self.ns.resolveElementNameValidated(name);
            element_namespace = resolved_element.uri;

            var prefixed: [max_attributes]namespace.ResolvedName = undefined;
            var prefixed_keys: [max_attributes]u32 = undefined;
            var prefixed_count: usize = 0;
            for (self.attrs[0..attr_count]) |*attr| {
                if (attr.namespace_uri.len != 0) continue; // xmlns declaration
                if (attr.colon == 0xFFFF) continue;
                const resolved_attr = if (self.options.trusted)
                    self.ns.resolveAttributeNameUncheckedColon(
                        attr.name,
                        attr.colon,
                    )
                else
                    try self.ns.resolveAttributeNameValidated(attr.name);
                attr.namespace_uri = resolved_attr.uri;
                prefixed[prefixed_count] = resolved_attr;
                prefixed_keys[prefixed_count] = resolvedNameKey(
                    resolved_attr.uri,
                    resolved_attr.local,
                );
                prefixed_count += 1;
            }
            if (prefixed_count >= 2 and !self.options.trusted) {
                for (prefixed[0..prefixed_count], 0..) |current, index| {
                    for (prefixed[0..index]) |previous| {
                        if (std.mem.eql(u8, previous.uri, current.uri) and
                            std.mem.eql(u8, previous.local, current.local))
                        {
                            return self.fail(
                                error.DuplicateExpandedAttribute,
                                0,
                            );
                        }
                    }
                }
            }
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
            if (self.options.namespaces) self.ns.pop();
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
            .name_range = .{
                .start = @intCast(name_start),
                .end = @intCast(name_start + name_info.len),
            },
            .attrs = self.attrs[0..attr_count],
            .self_closing = self_closing,
            .depth = event_depth,
            .namespace_uri = element_namespace,
            .colon = name_info.colon,
            .has_namespace_decls = has_namespace_decls,
        };
    }

    fn scanAttributeInto(self: *Parser, out: *Attribute) Error!void {
        const name_start = self.pos;
        const name_info = self.nameInfo(self.input[name_start..]);
        if (name_info.len == 0) return self.fail(error.InvalidName, name_start);
        const name = self.input[name_start .. name_start + name_info.len];
        self.pos = name_start + name_info.len;

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
        var has_non_ascii = false;
        var needs_decode = false;
        var whitespace_char_ref = false;

        while (self.pos < self.input.len and self.input[self.pos] != quote) {
            const byte = self.input[self.pos];
            if (byte == '&') {
                needs_decode = true;
                if (self.options.trusted) {
                    const semicolon = std.mem.indexOfScalarPos(
                        u8,
                        self.input,
                        self.pos + 1,
                        ';',
                    ) orelse return self.fail(
                        error.UnexpectedEndOfInput,
                        self.pos,
                    );
                    self.pos = semicolon + 1;
                    continue;
                }
                if (self.pos + 1 < self.input.len and
                    self.input[self.pos + 1] == '#')
                {
                    const semicolon = std.mem.indexOfScalarPos(
                        u8,
                        self.input,
                        self.pos + 2,
                        ';',
                    ) orelse {
                        return self.fail(
                            error.InvalidEntityReference,
                            self.pos,
                        );
                    };
                    const body = self.input[self.pos + 1 .. semicolon];
                    const codepoint = if (body.len > 1 and body[1] == 'x')
                        chars.parseHexCharRefVersion(body[1..], self.xml_version)
                    else
                        chars.parseDecimalCharRefVersion(body[1..], self.xml_version);
                    if (codepoint) |value| {
                        if (value == '\t' or value == '\n' or value == '\r') {
                            whitespace_char_ref = true;
                        }
                    }
                }
                self.pos = try self.validateReference(self.pos, true);
                continue;
            }
            if (self.options.trusted) {
                if (byte == '\t' or byte == '\n' or byte == '\r') {
                    needs_decode = true;
                }
            } else {
                if (byte == '<') {
                    return self.fail(error.InvalidAttributeValue, self.pos);
                }
                if (byte < 0x20) {
                    if (byte == '\t' or byte == '\n' or byte == '\r') {
                        needs_decode = true;
                    } else {
                        return self.fail(error.InvalidCharacter, self.pos);
                    }
                } else if (byte >= 0x80) {
                    has_non_ascii = true;
                }
            }
            self.pos += 1;
        }
        if (self.pos >= self.input.len) {
            return self.fail(error.UnexpectedEndOfInput, self.pos);
        }

        const value = self.input[value_start..self.pos];
        if (!self.options.trusted and has_non_ascii) {
            if (self.findInvalidLiteral(value)) |bad| {
                return self.fail(error.InvalidCharacter, value_start + bad);
            }
        }
        self.pos += 1;
        out.* = .{
            .name = name,
            .value = value,
            .name_range = .{
                .start = @intCast(name_start),
                .end = @intCast(name_start + name_info.len),
            },
            .value_range = .{
                .start = @intCast(value_start),
                .end = @intCast(value_start + value.len),
            },
            .namespace_uri = "",
            .colon = name_info.colon,
            .name_key = attributeNameKey(name),
            .needs_decode = needs_decode,
            .whitespace_char_ref = whitespace_char_ref,
            .tokenized = false,
        };
    }

    fn scanAttributeIntoTrusted(self: *Parser, out: *Attribute) Error!void {
        const name_start = self.pos;
        const name_info = chars.scanNameInfoFast(self.input[name_start..]);
        if (name_info.len == 0) return self.fail(error.InvalidName, name_start);
        const name = self.input[name_start .. name_start + name_info.len];
        self.pos = name_start + name_info.len;

        self.skipSpaces();
        if (self.pos >= self.input.len or self.input[self.pos] != '=') {
            return self.fail(error.InvalidStartTag, self.pos);
        }
        self.pos += 1;
        self.skipSpaces();
        if (self.pos >= self.input.len) {
            return self.fail(error.UnexpectedEndOfInput, self.pos);
        }

        const quote = self.input[self.pos];
        if (quote != '"' and quote != '\'') {
            return self.fail(error.InvalidAttributeValue, self.pos);
        }
        self.pos += 1;
        const value_start = self.pos;
        var needs_decode = false;
        while (self.pos < self.input.len and self.input[self.pos] != quote) {
            const byte = self.input[self.pos];
            if (byte == '&') {
                needs_decode = true;
                const semicolon = std.mem.indexOfScalarPos(
                    u8,
                    self.input,
                    self.pos + 1,
                    ';',
                ) orelse return self.fail(
                    error.UnexpectedEndOfInput,
                    self.pos,
                );
                self.pos = semicolon + 1;
                continue;
            }
            if (byte == '\t' or byte == '\n' or byte == '\r') {
                needs_decode = true;
            }
            self.pos += 1;
        }
        if (self.pos >= self.input.len) {
            return self.fail(error.UnexpectedEndOfInput, self.pos);
        }

        const value = self.input[value_start..self.pos];
        self.pos += 1;
        out.* = .{
            .name = name,
            .value = value,
            .name_range = .{
                .start = @intCast(name_start),
                .end = @intCast(name_start + name_info.len),
            },
            .value_range = .{
                .start = @intCast(value_start),
                .end = @intCast(value_start + value.len),
            },
            .namespace_uri = "",
            .colon = name_info.colon,
            .name_key = 0,
            .needs_decode = needs_decode,
            .whitespace_char_ref = false,
            .tokenized = false,
        };
    }

    fn scanEndTag(self: *Parser) Error!EndElement {
        std.debug.assert(self.startsWith("</"));
        self.pos += 2;
        const name_start = self.pos;
        const name_info = self.nameInfo(self.input[name_start..]);
        const name_len = name_info.len;
        if (name_len == 0) return self.fail(error.InvalidName, name_start);
        const name = self.input[name_start .. name_start + name_len];
        self.pos = name_start + name_len;
        self.skipWhitespace();
        if (self.pos >= self.input.len or self.input[self.pos] != '>') {
            return self.fail(error.InvalidEndTag, self.pos);
        }
        self.pos += 1;

        if (self.depth == 0) return self.fail(error.MismatchedEndTag, name_start);
        var end_namespace: []const u8 = "";
        if (self.options.namespaces) {
            const resolved = try self.ns.resolveElementNameValidated(name);
            end_namespace = resolved.uri;
        }
        const expected = self.open_names[self.depth - 1];
        if (!std.mem.eql(u8, expected, name)) {
            return self.fail(error.MismatchedEndTag, name_start);
        }
        const event_depth = self.depth;
        self.depth -= 1;
        if (self.options.namespaces) self.ns.pop();
        if (self.depth < self.entity_entry_depth) {
            return self.fail(error.MismatchedEndTag, name_start);
        }
        if (self.depth == 0 and !self.fragment) self.state = .epilog;
        return .{
            .name = name,
            .name_range = .{
                .start = @intCast(name_start),
                .end = @intCast(name_start + name_len),
            },
            .depth = event_depth,
            .namespace_uri = end_namespace,
        };
    }

    fn scanText(self: *Parser) Error!?[]const u8 {
        const start = self.pos;
        self.text_whitespace_char_ref = false;
        self.text_has_nel_ls = false;
        var whitespace_char_ref = false;
        var index = start;
        while (true) {
            index = findTextSpecial(self.input, index);
            if (index >= self.input.len) break;
            switch (self.input[index]) {
                '&' => {
                    if (!self.options.trusted and index + 1 < self.input.len and
                        self.input[index + 1] == '#')
                    {
                        const semicolon = std.mem.indexOfScalarPos(
                            u8,
                            self.input,
                            index + 2,
                            ';',
                        ) orelse 0;
                        if (semicolon > index + 1) {
                            const body = self.input[index + 1 .. semicolon];
                            const codepoint = if (body.len > 1 and
                                body[1] == 'x')
                                chars.parseHexCharRefVersion(
                                    body[1..],
                                    self.xml_version,
                                )
                            else
                                chars.parseDecimalCharRefVersion(
                                    body[1..],
                                    self.xml_version,
                                );
                            if (codepoint) |value| {
                                if (value == ' ' or value == '\t' or
                                    value == '\n' or value == '\r')
                                {
                                    whitespace_char_ref = true;
                                }
                            }
                        }
                    }
                    const reference = try self.classifyReference(index);
                    if (reference.kind == .entity) {
                        if (index > start) {
                            self.pos = index;
                            const span = self.input[start..index];
                            if (!self.options.trusted) {
                                if (self.findInvalidLiteral(span)) |bad| {
                                    return self.fail(
                                        error.InvalidCharacter,
                                        start + bad,
                                    );
                                }
                                self.text_whitespace_char_ref = whitespace_char_ref;
                                self.text_has_nel_ls = hasXml11LineSeparator(
                                    span,
                                    self.xml_version,
                                );
                            }
                            return span;
                        }
                        self.pos = reference.end;
                        const entity = reference.entity.?;
                        if (!entity.external and entity.value.len == 0) {
                            // Preserve an empty entity reference as an empty
                            // text event so consumers can observe the content.
                            return "";
                        }
                        try self.expandEntityReference(
                            reference.name,
                            entity,
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
        if (!self.options.trusted) {
            if (self.findInvalidLiteral(span)) |bad| {
                return self.fail(error.InvalidCharacter, start + bad);
            }
            self.text_whitespace_char_ref = whitespace_char_ref;
            self.text_has_nel_ls = hasXml11LineSeparator(
                span,
                self.xml_version,
            );
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
        if (self.options.trusted) {
            const end = semicolon + 1;
            if (body.len == 0 or body[0] == '#' or
                entities.isPredefined(body))
            {
                return .{ .kind = .plain, .end = end };
            }
            const entity = self.entity_table.find(body) orelse
                return .{ .kind = .plain, .end = end };
            if (entity.unparsed) {
                return self.fail(error.UnparsedEntityReference, amp + 1);
            }
            if (entity.external and
                (self.options.resolver == null or
                    self.options.allocator == null))
            {
                return .{ .kind = .plain, .end = end };
            }
            return .{
                .kind = .entity,
                .end = end,
                .name = body,
                .entity = entity,
            };
        }
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
                if (self.scratchAllocator()) |allocator| {
                    try self.undeclared_refs.append(allocator, body);
                }
                return .{ .kind = .plain, .end = end };
            }
            return self.fail(error.UndeclaredEntity, amp + 1);
        };
        if (self.standalone == true and entity.from_external) {
            if (!self.options.allow_undeclared_entities) {
                return self.fail(error.UndeclaredEntity, amp + 1);
            }
            return .{ .kind = .plain, .end = end };
        }
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
            const resource = resolver.resolve(
                resolver.context,
                entity.system_id,
                public_id,
                self.resolver_base,
            ) orelse return;
            const allocator = self.scratchAllocator() orelse return;
            const decoded = try decodeExternalAlloc(resource.data, allocator);
            const body = try self.stripTextDeclaration(decoded);
            try self.pushEntityFrame(body, name, resource.uri);
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
        if (self.findInvalidLiteral(content)) |bad| {
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
        if (self.findInvalidLiteral(content)) |bad| {
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
        if (self.options.namespaces and
            std.mem.indexOfScalar(u8, target, ':') != null)
        {
            return self.fail(error.InvalidQualifiedName, target_start);
        }
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
        if (self.findInvalidLiteral(data)) |bad| {
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
        self.xml_version = if (std.mem.eql(u8, version, "1.1"))
            .xml_1_1
        else
            .xml_1_0;
        if (self.options.namespaces) {
            self.ns.allow_undeclaration = self.xml_version == .xml_1_1;
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
            try self.loadExternalSubset(system, public_id);
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
        if (self.findInvalidLiteral(value)) |bad| {
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
                    // Declarations). Other boundary mismatches are validity
                    // errors in the Fifth Edition errata.
                    if (first != 0 and last == 0) {
                        return self.fail(error.InvalidDoctype, declaration_start);
                    }
                    if (first != last) {
                        if (self.scratchAllocator()) |allocator| {
                            try self.pe_issues.append(allocator, .{
                                .offset = declaration_start,
                            });
                        }
                    }
                    if (std.mem.startsWith(
                        u8,
                        self.input[declaration_start..],
                        "<!ELEMENT",
                    )) {
                        try self.checkElementGroupNesting(
                            self.input[declaration_start .. declaration_end + 1],
                            ids,
                            declaration_start,
                        );
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

    fn checkElementGroupNesting(
        self: *Parser,
        declaration: []const u8,
        ids: []const u32,
        base: usize,
    ) Error!void {
        var stack: [128]struct { offset: usize, id: u32 } = undefined;
        var depth: usize = 0;
        for (declaration, 0..) |byte, index| {
            switch (byte) {
                '(' => {
                    if (depth < stack.len and base + index < ids.len) {
                        stack[depth] = .{
                            .offset = index,
                            .id = ids[base + index],
                        };
                        depth += 1;
                    }
                },
                ')' => {
                    if (depth == 0) continue;
                    depth -= 1;
                    const open = stack[depth];
                    const close_id = if (base + index < ids.len)
                        ids[base + index]
                    else
                        0;
                    if (open.id != close_id) {
                        if (self.scratchAllocator()) |allocator| {
                            try self.pe_issues.append(allocator, .{
                                .offset = base + open.offset,
                            });
                        }
                    }
                },
                else => {},
            }
        }
    }

    fn checkConditionalSectionNesting(
        self: *Parser,
        bytes: []const u8,
        ids: []const u32,
    ) Error!void {
        var position: usize = 0;
        while (std.mem.indexOfPos(u8, bytes, position, "<![")) |start| {
            var depth: usize = 1;
            var scan = start + 3;
            var quote: u8 = 0;
            while (scan < bytes.len and depth > 0) {
                if (quote != 0) {
                    if (bytes[scan] == quote) quote = 0;
                    scan += 1;
                    continue;
                }
                if (bytes[scan] == '"' or bytes[scan] == '\'') {
                    quote = bytes[scan];
                    scan += 1;
                    continue;
                }
                if (std.mem.startsWith(u8, bytes[scan..], "<![")) {
                    depth += 1;
                    scan += 3;
                    continue;
                }
                if (std.mem.startsWith(u8, bytes[scan..], "]]>")) {
                    depth -= 1;
                    scan += 3;
                    continue;
                }
                scan += 1;
            }
            if (depth != 0) return;
            const end = scan - 3;
            var keyword_start = start + 3;
            while (keyword_start < end and
                chars.isWhitespace(bytes[keyword_start]))
            {
                keyword_start += 1;
            }
            const start_id = if (start < ids.len) ids[start] else 0;
            const keyword_id = if (keyword_start < ids.len)
                ids[keyword_start]
            else
                0;
            const end_id = if (end < ids.len) ids[end] else 0;
            if (start_id != keyword_id or start_id != end_id) {
                if (self.scratchAllocator()) |allocator| {
                    try self.pe_issues.append(allocator, .{ .offset = start });
                }
            }
            position = scan;
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
        const resource = resolver.resolve(
            resolver.context,
            system_id,
            public_id,
            self.resolver_base,
        ) orelse return;
        const allocator = self.scratchAllocator() orelse return;
        const decoded = try decodeExternalAlloc(resource.data, allocator);

        self.external_depth += 1;
        defer self.external_depth -= 1;

        const saved_base = self.resolver_base;
        self.resolver_base = resource.uri;
        defer self.resolver_base = saved_base;
        const saved_external = self.in_external_subset;
        self.in_external_subset = true;
        defer self.in_external_subset = saved_external;

        const body = try self.stripTextDeclaration(decoded);
        var expanded: std.ArrayList(u8) = .empty;
        try self.expandSubset(body, true, &expanded, allocator, 0, true);
        const stripped = try self.stripBoundaries(expanded.items, allocator);
        try self.checkConditionalSectionNesting(stripped.bytes, stripped.ids);
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
        // Expansion parsed and validated every entity declaration already;
        // skip their bodies when the subset is scanned again.
        self.entities_preparsed = true;
        defer self.entities_preparsed = false;
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
        const mark = mark_boundaries and entity.from_external;
        if (mark) try out.append(allocator, 0x01);
        if (add_spaces) try out.append(allocator, ' ');
        defer {
            if (add_spaces) out.append(allocator, ' ') catch {};
            if (mark) out.append(allocator, 0x02) catch {};
        }
        if (entity.external) {
            const resolver = self.options.resolver orelse return;
            const public_id: ?[]const u8 = if (entity.public_id.len != 0)
                entity.public_id
            else
                null;
            const resource = resolver.resolve(
                resolver.context,
                entity.system_id,
                public_id,
                self.resolver_base,
            ) orelse return;
            const decoded = try decodeExternalAlloc(resource.data, allocator);
            const body = try self.stripTextDeclaration(decoded);

            const saved_base = self.resolver_base;
            self.resolver_base = resource.uri;
            defer self.resolver_base = saved_base;
            const saved_external = self.in_external_subset;
            self.in_external_subset = true;
            defer self.in_external_subset = saved_external;

            // The external body is raw DTD text: character references in
            // its declarations must stay encoded until the declaration is
            // parsed, or a decoded '%' could be mistaken for a PE reference.
            var expanded: std.ArrayList(u8) = .empty;
            const saved_allow = self.allow_pe_in_declarations;
            self.allow_pe_in_declarations = true;
            defer self.allow_pe_in_declarations = saved_allow;
            try self.expandSubset(
                body,
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
        if (self.options.namespaces and
            std.mem.indexOfScalar(u8, name, ':') != null)
        {
            return scanner.fail(error.InvalidQualifiedName);
        }
        const duplicate = if (parameter)
            self.parameter_entities.find(name) != null
        else
            self.entity_table.find(name) != null;
        if (duplicate and self.entities_preparsed) return;
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
            const allocator = self.options.allocator orelse
                return self.fail(error.UnsupportedParameterEntity, base);
            if (parameter) {
                self.parameter_entities.add(allocator, .{
                    .name = name,
                    .value = value,
                    .offset = base,
                    .from_external = self.in_external_subset,
                }) catch |err| return self.fail(
                    mapEntityAddError(err),
                    base,
                );
            } else {
                self.entity_table.add(allocator, .{
                    .name = name,
                    .value = value,
                    .offset = base,
                    .from_external = self.in_external_subset,
                }) catch |err| return self.fail(
                    mapEntityAddError(err),
                    base,
                );
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
        var notation: []const u8 = "";
        if (scanner.skipWhitespace() != 0 and scanner.startsWith("NDATA")) {
            if (parameter) return scanner.fail(error.InvalidDoctype);
            if (!scanner.eatKeyword("NDATA")) return scanner.fail(error.InvalidDoctype);
            try scanner.requireWhitespace();
            notation = try scanner.scanName();
            _ = scanner.skipWhitespace();
            unparsed = true;
        }
        try scanner.expectByte('>');
        if (!scanner.atEnd()) return scanner.fail(error.InvalidDoctype);

        const allocator = self.options.allocator orelse
            return self.fail(error.UnsupportedParameterEntity, base);
        if (parameter) {
            self.parameter_entities.add(allocator, .{
                .name = name,
                .value = "",
                .external = true,
                .system_id = system_id,
                .public_id = public_id,
                .offset = base,
                .from_external = self.in_external_subset,
            }) catch |err| return self.fail(
                mapEntityAddError(err),
                base,
            );
        } else {
            self.entity_table.add(allocator, .{
                .name = name,
                .value = "",
                .external = true,
                .system_id = system_id,
                .public_id = public_id,
                .unparsed = unparsed,
                .notation = notation,
                .offset = base,
                .from_external = self.in_external_subset,
            }) catch |err| return self.fail(mapEntityAddError(err), base);
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
        const element_name = try scanner.scanName();
        try scanner.requireWhitespace();
        const model = try scanContentSpec(&scanner);
        _ = scanner.skipWhitespace();
        try scanner.expectByte('>');
        if (!scanner.atEnd()) return scanner.fail(error.InvalidDoctype);
        self.pos = end + 1;
        try self.addElementDecl(.{
            .name = element_name,
            .model = model,
            .from_external = self.in_external_subset,
        });
    }

    fn scanAttlistDeclaration(self: *Parser) Error!void {
        const end = try self.declarationEnd();
        var scanner = DtdScanner.init(self, self.pos, end);
        if (!scanner.eat("<!ATTLIST")) return scanner.fail(error.InvalidDoctype);
        try scanner.requireWhitespace();
        const element_name = try scanner.scanName();
        while (true) {
            const whitespace = scanner.skipWhitespace();
            if (scanner.peek() == '>') {
                scanner.index += 1;
                break;
            }
            if (whitespace == 0) return scanner.fail(error.InvalidDoctype);
            const attribute_name = try scanner.scanName();
            try scanner.requireWhitespace();
            const attr_type = try scanAttType(&scanner);
            if (attr_type != .cdata and
                self.tokenized_attr_count < self.tokenized_attrs.len)
            {
                self.tokenized_attrs[self.tokenized_attr_count] = .{
                    .element = element_name,
                    .name = attribute_name,
                };
                self.tokenized_attr_count += 1;
            }
            try scanner.requireWhitespace();
            const default_decl = try scanDefaultDecl(&scanner);
            try self.addAttributeDecl(.{
                .element = element_name,
                .name = attribute_name,
                .attr_type = attr_type,
                .default_kind = default_decl.kind,
                .default_value = default_decl.value,
                .value_offset = default_decl.value_offset,
                .from_external = self.in_external_subset,
            });
        }
        if (!scanner.atEnd()) return scanner.fail(error.InvalidDoctype);
        self.pos = end + 1;
    }

    fn scanNotationDeclaration(self: *Parser) Error!void {
        const end = try self.declarationEnd();
        var scanner = DtdScanner.init(self, self.pos, end);
        if (!scanner.eat("<!NOTATION")) return scanner.fail(error.InvalidDoctype);
        try scanner.requireWhitespace();
        const notation_name = try scanner.scanName();
        if (self.options.namespaces and
            std.mem.indexOfScalar(u8, notation_name, ':') != null)
        {
            return scanner.fail(error.InvalidQualifiedName);
        }
        try scanner.requireWhitespace();
        var public_id: ?[]const u8 = null;
        var system_id: ?[]const u8 = null;
        if (scanner.eatKeyword("SYSTEM")) {
            try scanner.requireWhitespace();
            system_id = try scanner.scanQuoted();
        } else if (scanner.eatKeyword("PUBLIC")) {
            try scanner.requireWhitespace();
            const public_base = scanner.abs() + 1;
            public_id = try scanner.scanQuoted();
            try self.validatePubidLiteral(public_id.?, public_base);
            const whitespace = scanner.skipWhitespace();
            if (whitespace != 0 and
                (scanner.peek() == '"' or scanner.peek() == '\''))
            {
                system_id = try scanner.scanQuoted();
            }
        } else {
            return scanner.fail(error.InvalidDoctype);
        }
        _ = scanner.skipWhitespace();
        try scanner.expectByte('>');
        if (!scanner.atEnd()) return scanner.fail(error.InvalidDoctype);
        self.pos = end + 1;
        try self.addNotationDecl(.{
            .name = notation_name,
            .public_id = public_id,
            .system_id = system_id,
            .from_external = self.in_external_subset,
        });
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
        for (self.entity_table.entries()) |entity| {
            if (entity.external) continue;
            if (self.findInvalidLiteral(entity.value)) |bad| {
                return self.fail(error.InvalidCharacter, entity.offset + bad);
            }
        }

        for (self.parameter_entities.entries()) |entity| {
            if (entity.external) continue;
            if (self.findInvalidLiteral(entity.value)) |bad| {
                return self.fail(error.InvalidCharacter, entity.offset + bad);
            }
            try self.validateEntityValueReferences(entity.value);
        }

        // XML's No Recursion constraint: no entity may reference itself
        // directly or indirectly, whether or not it is used.
        var colors: [entities.max_entities]u8 = @splat(0);
        const declared = self.entity_table.entries();
        for (0..declared.len) |index| {
            if (colors[index] != 0) continue;
            if (self.entityCycle(index, &colors)) {
                return self.fail(
                    error.EntityRecursion,
                    declared[index].offset,
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
        const value = self.entity_table.at(index).value;
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
        for (self.entity_table.entries(), 0..) |entity, index| {
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
        const resource = resolver.resolve(
            resolver.context,
            entity.system_id,
            public_id,
            self.resolver_base,
        ) orelse return;
        const allocator = self.scratchAllocator() orelse return;
        const decoded = try decodeExternalAlloc(resource.data, allocator);

        self.external_depth += 1;
        defer self.external_depth -= 1;

        const saved_base = self.resolver_base;
        self.resolver_base = resource.uri;
        defer self.resolver_base = saved_base;

        var sub = Parser.initFragment(
            try self.stripTextDeclaration(decoded),
            self.options,
        );
        sub.resolver_base = self.resolver_base;
        sub.entity_table = self.entity_table;
        sub.parameter_entities = self.parameter_entities;
        sub.owns_entity_tables = false;
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
                chars.parseHexCharRefVersion(body[1..], self.xml_version)
            else
                chars.parseDecimalCharRefVersion(body[1..], self.xml_version);
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
            if (self.standalone == true and entity.from_external) {
                return self.fail(error.UndeclaredEntity, offset + 1);
            }
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
            if (self.scratchAllocator()) |allocator| {
                try self.undeclared_refs.append(allocator, body);
            }
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
            if (std.mem.eql(u8, value, "1.1")) {
                // An entity may not declare a later version than its document.
                if (self.xml_version != .xml_1_1) {
                    return self.fail(error.UnsupportedXmlVersion, start);
                }
            } else if (!std.mem.eql(u8, value, "1.0")) {
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
                    chars.parseHexCharRefVersion(body[1..], self.xml_version)
                else
                    chars.parseDecimalCharRefVersion(body[1..], self.xml_version);
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
                    chars.parseHexCharRefVersion(body[1..], self.xml_version)
                else
                    chars.parseDecimalCharRefVersion(body[1..], self.xml_version);
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

    fn addElementDecl(self: *Parser, decl: ElementDecl) Error!void {
        if (self.findElementDecl(decl.name) != null) {
            if (self.scratchAllocator()) |allocator| {
                try self.duplicate_elements.append(allocator, decl.name);
            }
            return;
        }
        if (self.scratchAllocator()) |allocator| {
            try self.element_decls.append(allocator, decl);
            return;
        }
        if (self.fixed_element_count < self.fixed_element_decls.len) {
            self.fixed_element_decls[self.fixed_element_count] = decl;
            self.fixed_element_count += 1;
        }
    }

    fn addAttributeDecl(self: *Parser, decl: AttributeDecl) Error!void {
        if (self.hasAttributeDecl(decl.element, decl.name)) return;
        if (self.scratchAllocator()) |allocator| {
            try self.attribute_decls.append(allocator, decl);
            return;
        }
        if (self.fixed_attribute_count < self.fixed_attribute_decls.len) {
            self.fixed_attribute_decls[self.fixed_attribute_count] = decl;
            self.fixed_attribute_count += 1;
        }
    }

    fn addNotationDecl(self: *Parser, decl: NotationDecl) Error!void {
        for (self.notation_decls.items) |existing| {
            if (std.mem.eql(u8, existing.name, decl.name)) {
                if (self.scratchAllocator()) |allocator| {
                    try self.duplicate_notations.append(allocator, decl.name);
                }
                return;
            }
        }
        for (self.fixed_notation_decls[0..self.fixed_notation_count]) |existing| {
            if (std.mem.eql(u8, existing.name, decl.name)) {
                if (self.scratchAllocator()) |allocator| {
                    try self.duplicate_notations.append(allocator, decl.name);
                }
                return;
            }
        }
        if (self.scratchAllocator()) |allocator| {
            try self.notation_decls.append(allocator, decl);
            return;
        }
        if (self.fixed_notation_count < self.fixed_notation_decls.len) {
            self.fixed_notation_decls[self.fixed_notation_count] = decl;
            self.fixed_notation_count += 1;
        }
    }

    fn findElementDecl(self: *const Parser, name: []const u8) ?*const ElementDecl {
        for (self.element_decls.items) |*decl| {
            if (std.mem.eql(u8, decl.name, name)) return decl;
        }
        for (self.fixed_element_decls[0..self.fixed_element_count]) |*decl| {
            if (std.mem.eql(u8, decl.name, name)) return decl;
        }
        return null;
    }

    fn hasAttributeDecl(self: *const Parser, element: []const u8, name: []const u8) bool {
        for (self.attribute_decls.items) |decl| {
            if (std.mem.eql(u8, decl.element, element) and
                std.mem.eql(u8, decl.name, name))
            {
                return true;
            }
        }
        for (self.fixed_attribute_decls[0..self.fixed_attribute_count]) |decl| {
            if (std.mem.eql(u8, decl.element, element) and
                std.mem.eql(u8, decl.name, name))
            {
                return true;
            }
        }
        return false;
    }

    fn applyAttributeDefaults(
        self: *Parser,
        element: []const u8,
        attr_count: *usize,
    ) Error!void {
        for (self.attribute_decls.items) |decl| {
            if (!std.mem.eql(u8, decl.element, element)) continue;
            if (self.standalone == true and decl.from_external) continue;
            var present = false;
            for (self.attrs[0..attr_count.*]) |attr| {
                if (std.mem.eql(u8, attr.name, decl.name)) {
                    present = true;
                    break;
                }
            }
            if (present) continue;
            const value = switch (decl.default_kind) {
                .value, .fixed => decl.default_value,
                .required, .implied => continue,
            };
            if (attr_count.* == self.options.max_attributes) {
                return self.fail(error.AttributeLimitExceeded, 0);
            }
            const name_info = chars.scanNameInfo(decl.name);
            self.attrs[attr_count.*] = .{
                .name = decl.name,
                .value = value,
                .name_range = .{ .start = 0, .end = 0 },
                .value_range = .{
                    .start = @intCast(decl.value_offset),
                    .end = @intCast(decl.value_offset + value.len),
                },
                .namespace_uri = if (namespace.Resolver.isNamespaceDeclaration(
                    decl.name,
                )) namespace.xmlns_uri else "",
                .colon = name_info.colon,
                .name_key = attributeNameKey(decl.name),
                .needs_decode = true,
                .tokenized = decl.tokenized(),
                .from_default = true,
            };
            attr_count.* += 1;
        }
        for (self.fixed_attribute_decls[0..self.fixed_attribute_count]) |decl| {
            if (!std.mem.eql(u8, decl.element, element)) continue;
            if (self.standalone == true and decl.from_external) continue;
            var present = false;
            for (self.attrs[0..attr_count.*]) |attr| {
                if (std.mem.eql(u8, attr.name, decl.name)) {
                    present = true;
                    break;
                }
            }
            if (present) continue;
            const value = switch (decl.default_kind) {
                .value, .fixed => decl.default_value,
                .required, .implied => continue,
            };
            if (attr_count.* == self.options.max_attributes) {
                return self.fail(error.AttributeLimitExceeded, 0);
            }
            const name_info = chars.scanNameInfo(decl.name);
            self.attrs[attr_count.*] = .{
                .name = decl.name,
                .value = value,
                .name_range = .{ .start = 0, .end = 0 },
                .value_range = .{
                    .start = @intCast(decl.value_offset),
                    .end = @intCast(decl.value_offset + value.len),
                },
                .namespace_uri = if (namespace.Resolver.isNamespaceDeclaration(
                    decl.name,
                )) namespace.xmlns_uri else "",
                .colon = name_info.colon,
                .name_key = attributeNameKey(decl.name),
                .needs_decode = true,
                .tokenized = decl.tokenized(),
                .from_default = true,
            };
            attr_count.* += 1;
        }
    }

    fn isTokenizedAttribute(
        self: *const Parser,
        element: []const u8,
        name: []const u8,
    ) bool {
        for (self.tokenized_attrs[0..self.tokenized_attr_count]) |decl| {
            if (std.mem.eql(u8, decl.element, element) and
                std.mem.eql(u8, decl.name, name))
            {
                return true;
            }
        }
        return false;
    }

    fn startsWith(self: *const Parser, prefix: []const u8) bool {
        return std.mem.startsWith(u8, self.input[self.pos..], prefix);
    }

    inline fn skipSpaces(self: *Parser) void {
        while (self.pos < self.input.len and self.input[self.pos] == ' ') {
            self.pos += 1;
        }
        if (self.pos < self.input.len) {
            const byte = self.input[self.pos];
            if (byte == '\t' or byte == '\n' or byte == '\r') {
                self.skipWhitespace();
            }
        }
    }

    inline fn skipWhitespace(self: *Parser) void {
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

fn mapEntityAddError(err: entities.Table.AddError) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.EntityLimitExceeded => error.EntityLimitExceeded,
    };
}

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
        if (self.parser.findInvalidLiteral(value)) |bad| {
            return self.failAt(error.InvalidCharacter, value_start + bad);
        }
        self.index += 1;
        return value;
    }
};

var fallback_content_node: ContentNode = .{ .name = "" };

fn newContentNode(
    allocator: std.mem.Allocator,
    value: ContentNode,
) Error!*ContentNode {
    const node = try allocator.create(ContentNode);
    node.* = value;
    return node;
}

fn scanContentSpec(scanner: *DtdScanner) Error!ContentModel {
    if (scanner.eatKeyword("EMPTY")) return .empty;
    if (scanner.eatKeyword("ANY")) return .any;
    if (scanner.peek() != '(') return scanner.fail(error.InvalidDoctype);

    var look = scanner.index + 1;
    while (look < scanner.text.len and chars.isWhitespace(scanner.text[look])) {
        look += 1;
    }
    if (std.mem.startsWith(u8, scanner.text[look..], "#PCDATA")) {
        return scanMixed(scanner);
    }
    return .{ .children = try scanChildrenGroup(scanner) };
}

fn scanMixed(scanner: *DtdScanner) Error!ContentModel {
    const allocator = scanner.parser.scratchAllocator();
    var names: std.ArrayList([]const u8) = .empty;
    try scanner.expectByte('(');
    _ = scanner.skipWhitespace();
    if (!scanner.eat("#PCDATA")) return scanner.fail(error.InvalidDoctype);
    _ = scanner.skipWhitespace();
    var has_names = false;
    while (scanner.peek() == '|') {
        has_names = true;
        scanner.index += 1;
        _ = scanner.skipWhitespace();
        const name = try scanner.scanName();
        if (allocator) |a| try names.append(a, name);
        _ = scanner.skipWhitespace();
    }
    try scanner.expectByte(')');
    if (scanner.peek() == '*') {
        scanner.index += 1;
    } else if (has_names) {
        return scanner.fail(error.InvalidDoctype);
    }
    if (allocator) |a| return .{ .mixed = try names.toOwnedSlice(a) };
    return .any;
}

fn scanChildrenGroup(scanner: *DtdScanner) Error!*ContentNode {
    const allocator = scanner.parser.scratchAllocator();
    try scanner.expectByte('(');
    _ = scanner.skipWhitespace();
    var children: std.ArrayList(*ContentNode) = .empty;
    const first = try scanContentParticle(scanner);
    if (allocator) |a| try children.append(a, first);
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
        const child = try scanContentParticle(scanner);
        if (allocator) |a| try children.append(a, child);
        _ = scanner.skipWhitespace();
    }
    try scanner.expectByte(')');

    var node: *ContentNode = &fallback_content_node;
    if (allocator) |a| {
        const items = try children.toOwnedSlice(a);
        node = if (separator == '|')
            try newContentNode(a, .{ .choice = items })
        else
            try newContentNode(a, .{ .sequence = items });
    }
    if (scanner.peek()) |byte| {
        if (byte == '?' or byte == '*' or byte == '+') {
            if (allocator) |a| {
                node = try newContentNode(a, .{ .quantifier = .{
                    .node = node,
                    .min = if (byte == '+') 1 else 0,
                    .max = if (byte == '?') 1 else null,
                } });
            }
            scanner.index += 1;
        }
    }
    return node;
}

fn scanContentParticle(scanner: *DtdScanner) Error!*ContentNode {
    const allocator = scanner.parser.scratchAllocator();
    _ = scanner.skipWhitespace();
    if (scanner.peek() == '(') {
        return scanChildrenGroup(scanner);
    }
    const name = try scanner.scanName();
    var node: *ContentNode = &fallback_content_node;
    if (allocator) |a| {
        node = try newContentNode(a, .{ .name = name });
    }
    if (scanner.peek()) |byte| {
        if (byte == '?' or byte == '*' or byte == '+') {
            if (allocator) |a| {
                node = try newContentNode(a, .{ .quantifier = .{
                    .node = node,
                    .min = if (byte == '+') 1 else 0,
                    .max = if (byte == '?') 1 else null,
                } });
            }
            scanner.index += 1;
        }
    }
    return node;
}

fn scanAttType(scanner: *DtdScanner) Error!AttributeType {
    if (scanner.eatKeyword("CDATA")) return .cdata;
    const tokenized = [_]struct { []const u8, AttributeType }{
        .{ "IDREFS", .idrefs },
        .{ "IDREF", .idref },
        .{ "ID", .id },
        .{ "ENTITIES", .entities },
        .{ "ENTITY", .entity },
        .{ "NMTOKENS", .nmtokens },
        .{ "NMTOKEN", .nmtoken },
    };
    for (tokenized) |entry| {
        if (scanner.eatKeyword(entry[0])) return entry[1];
    }
    if (scanner.eatKeyword("NOTATION")) {
        try scanner.requireWhitespace();
        try scanner.expectByte('(');
        _ = scanner.skipWhitespace();
        const names = try scanNameList(scanner, ')');
        try scanner.expectByte(')');
        return .{ .notation = names };
    }
    if (scanner.peek() == '(') {
        scanner.index += 1;
        _ = scanner.skipWhitespace();
        const names = try scanNmtokenList(scanner, ')');
        try scanner.expectByte(')');
        return .{ .enumeration = names };
    }
    return scanner.fail(error.InvalidDoctype);
}

fn scanNameList(
    scanner: *DtdScanner,
    terminator: u8,
) Error![]const []const u8 {
    const allocator = scanner.parser.scratchAllocator();
    var names: std.ArrayList([]const u8) = .empty;
    const first = try scanner.scanName();
    if (allocator) |a| try names.append(a, first);
    _ = scanner.skipWhitespace();
    while (scanner.peek() == '|') {
        scanner.index += 1;
        _ = scanner.skipWhitespace();
        const name = try scanner.scanName();
        if (allocator) |a| try names.append(a, name);
        _ = scanner.skipWhitespace();
    }
    _ = terminator;
    if (allocator) |a| return names.toOwnedSlice(a);
    return &.{};
}

fn scanNmtokenList(
    scanner: *DtdScanner,
    terminator: u8,
) Error![]const []const u8 {
    const allocator = scanner.parser.scratchAllocator();
    var names: std.ArrayList([]const u8) = .empty;
    const first = try scanner.scanNmtoken();
    if (allocator) |a| try names.append(a, first);
    _ = scanner.skipWhitespace();
    while (scanner.peek() == '|') {
        scanner.index += 1;
        _ = scanner.skipWhitespace();
        const name = try scanner.scanNmtoken();
        if (allocator) |a| try names.append(a, name);
        _ = scanner.skipWhitespace();
    }
    _ = terminator;
    if (allocator) |a| return names.toOwnedSlice(a);
    return &.{};
}

const DefaultDecl = struct {
    kind: DefaultKind,
    value: []const u8 = "",
    value_offset: usize = 0,
};

fn scanDefaultDecl(scanner: *DtdScanner) Error!DefaultDecl {
    if (scanner.eatKeyword("#REQUIRED")) return .{ .kind = .required };
    if (scanner.eatKeyword("#IMPLIED")) return .{ .kind = .implied };

    var fixed = false;
    if (scanner.eatKeyword("#FIXED")) {
        fixed = true;
        try scanner.requireWhitespace();
    }

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
    if (scanner.parser.findInvalidLiteral(value)) |bad| {
        return scanner.failAt(error.InvalidCharacter, value_start + bad);
    }
    scanner.index += 1;
    return .{
        .kind = if (fixed) .fixed else .value,
        .value = value,
        .value_offset = scanner.base + value_start,
    };
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
                chars.parseHexCharRefVersion(body[1..], parser.xml_version)
            else
                chars.parseDecimalCharRefVersion(body[1..], parser.xml_version);
            const cp = codepoint orelse {
                return parser.fail(error.InvalidEntityReference, index);
            };
            if (parser.xml_version == .xml_1_1 and chars.isRestrictedChar11(cp)) {
                // Restricted characters may appear only through character
                // references. Keep the reference in replacement text so the
                // included content remains well-formed.
                try out.appendSlice(allocator, value[index .. semicolon + 1]);
            } else {
                var buffer: [4]u8 = undefined;
                try out.appendSlice(allocator, chars.encodeUtf8(&buffer, cp));
            }
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
                chars.parseHexCharRefVersion(body[1..], parser.xml_version)
            else
                chars.parseDecimalCharRefVersion(body[1..], parser.xml_version);
            const cp = codepoint orelse {
                return parser.fail(error.InvalidEntityReference, index);
            };
            if (parser.xml_version == .xml_1_1 and chars.isRestrictedChar11(cp)) {
                // Restricted characters may appear only through character
                // references. Keep the reference in replacement text so the
                // included content remains well-formed.
                try out.appendSlice(allocator, value[index .. semicolon + 1]);
            } else {
                var buffer: [4]u8 = undefined;
                try out.appendSlice(allocator, chars.encodeUtf8(&buffer, cp));
            }
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
        // Parameter-entity boundary markers may surround the INCLUDE/IGNORE
        // keyword, for example `<![%sect1.attlist;[`.
        while (cursor < input.len and
            (chars.isWhitespace(input[cursor]) or
                input[cursor] == 0x01 or input[cursor] == 0x02))
        {
            cursor += 1;
        }
        const keyword_start = cursor;
        while (cursor < input.len and chars.isAsciiNameChar(input[cursor])) cursor += 1;
        const keyword = input[keyword_start..cursor];
        while (cursor < input.len and
            (chars.isWhitespace(input[cursor]) or
                input[cursor] == 0x01 or input[cursor] == 0x02))
        {
            cursor += 1;
        }
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
            if (std.mem.startsWith(u8, input[scan..], "<!--")) {
                const end = std.mem.indexOfPos(u8, input, scan + 4, "-->") orelse
                    return error.UnexpectedEndOfInput;
                scan = end + 3;
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

fn attributeNameKey(name: []const u8) u32 {
    const last = name[name.len - 1];
    return (@as(u32, @intCast(name.len)) << 16) ^
        (@as(u32, name[0]) << 8) ^ @as(u32, last);
}

fn resolvedNameKey(uri: []const u8, local: []const u8) u32 {
    const first = if (uri.len != 0) uri[0] else 0;
    return (@as(u32, @intCast(uri.len)) << 20) ^
        (@as(u32, @intCast(local.len)) << 8) ^
        @as(u32, first) ^ @as(u32, local[0]);
}

fn hasWhitespace(value: []const u8) bool {
    for (value) |byte| {
        if (chars.isWhitespace(byte)) return true;
    }
    return false;
}

fn normalizeTokenizedValue(
    allocator: std.mem.Allocator,
    value: []const u8,
) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var pending_space = false;
    var started = false;
    for (value) |byte| {
        if (chars.isWhitespace(byte)) {
            if (started) pending_space = true;
            continue;
        }
        if (pending_space) {
            try out.append(allocator, ' ');
            pending_space = false;
        }
        try out.append(allocator, byte);
        started = true;
    }
    return out.toOwnedSlice(allocator);
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

fn declaredVersion11(input: []const u8, start: usize) ?bool {
    if (!std.mem.startsWith(u8, input[start..], "<?xml")) return null;
    const end = std.mem.indexOfPos(u8, input, start + 5, "?>") orelse return null;
    const declaration = input[start + 5 .. end];
    const version_pos = std.mem.indexOf(u8, declaration, "version") orelse return null;
    var index = version_pos + "version".len;
    while (index < declaration.len and chars.isWhitespace(declaration[index])) {
        index += 1;
    }
    if (index >= declaration.len or declaration[index] != '=') return null;
    index += 1;
    while (index < declaration.len and chars.isWhitespace(declaration[index])) {
        index += 1;
    }
    if (index >= declaration.len or
        (declaration[index] != '"' and declaration[index] != '\''))
    {
        return null;
    }
    const quote = declaration[index];
    index += 1;
    const value_start = index;
    while (index < declaration.len and declaration[index] != quote) {
        index += 1;
    }
    return std.mem.eql(u8, declaration[value_start..index], "1.1");
}

fn hasXml11LineSeparator(input: []const u8, version: chars.Version) bool {
    if (version != .xml_1_1) return false;
    return std.mem.indexOf(u8, input, "\xC2\x85") != null or
        std.mem.indexOf(u8, input, "\xE2\x80\xA8") != null;
}

fn hasXml11LineEnds(input: []const u8) bool {
    var index: usize = 0;
    while (index < input.len) : (index += 1) {
        const byte = input[index];
        if (byte == 0xC2 and index + 1 < input.len and input[index + 1] == 0x85) {
            return true;
        }
        if (byte == 0xE2 and index + 2 < input.len and
            input[index + 1] == 0x80 and input[index + 2] == 0xA8)
        {
            return true;
        }
    }
    return false;
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
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(input, .{ .allocator = arena.allocator() });
    defer parser.deinit();
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
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(input, .{ .allocator = arena.allocator() });
    defer parser.deinit();
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
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(input, .{ .allocator = arena.allocator() });
    defer parser.deinit();
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

test "DTD attribute defaults and tokenized types are exposed" {
    const input =
        "<!DOCTYPE doc [" ++
        "<!ELEMENT doc EMPTY>" ++
        "<!ATTLIST doc a CDATA \"x\" b NMTOKEN \"  y  z \" c CDATA #IMPLIED d CDATA #REQUIRED>" ++
        "]><doc d='v'/>";
    var parser = Parser.init(input, .{});
    defer parser.deinit();

    var found = false;
    while (try parser.next()) |event| {
        switch (event) {
            .start_element => |element| {
                found = true;
                try std.testing.expectEqual(@as(usize, 3), element.attrs.len);
                var saw_a = false;
                var saw_b = false;
                var saw_d = false;
                for (element.attrs) |attr| {
                    if (std.mem.eql(u8, attr.name, "a")) {
                        saw_a = true;
                        try std.testing.expectEqualStrings("x", attr.value);
                        try std.testing.expect(attr.from_default);
                    } else if (std.mem.eql(u8, attr.name, "b")) {
                        saw_b = true;
                        try std.testing.expectEqualStrings("  y  z ", attr.value);
                        try std.testing.expect(attr.tokenized);
                        try std.testing.expect(attr.from_default);
                    } else if (std.mem.eql(u8, attr.name, "d")) {
                        saw_d = true;
                        try std.testing.expectEqualStrings("v", attr.value);
                        try std.testing.expect(!attr.from_default);
                    }
                }
                try std.testing.expect(saw_a and saw_b and saw_d);
            },
            else => {},
        }
    }
    try std.testing.expect(found);
}
