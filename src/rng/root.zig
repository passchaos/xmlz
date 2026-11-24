//! RELAX NG validation over `dom.Document`.

const std = @import("std");
const dom = @import("../dom.zig");

pub const schema = @import("schema.zig");
pub const compact = @import("compact.zig");
pub const validate_mod = @import("validate.zig");

pub const Schema = schema.Schema;
pub const Options = schema.Options;
pub const Resolver = schema.Resolver;
pub const Resource = schema.Resource;
pub const Error = schema.Error;
pub const ValidationError = validate_mod.ValidationError;
pub const ValidationResult = validate_mod.Result;
pub const structure_namespace = schema.structure_namespace;

/// Compile a RELAX NG schema document.
pub fn parse(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
) Error!Schema {
    return schema.parse(allocator, document);
}

/// Compile a schema written in the RELAX NG compact syntax.
pub fn parseCompact(
    allocator: std.mem.Allocator,
    source: []const u8,
) Error!Schema {
    return compact.parse(allocator, source);
}

/// Compile a compact syntax schema with include/external resolution.
pub fn parseCompactWithOptions(
    allocator: std.mem.Allocator,
    source: []const u8,
    options: Options,
) Error!Schema {
    return compact.parseWithOptions(allocator, source, options);
}

/// Compile a schema with include/externalRef resolution.
pub fn parseWithOptions(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
    options: Options,
) Error!Schema {
    return schema.parseWithOptions(allocator, document, options);
}

/// Validate an instance document against a compiled schema.
pub fn validate(
    compiled: *const Schema,
    allocator: std.mem.Allocator,
    document: *const dom.Document,
) validate_mod.Error!ValidationResult {
    return validate_mod.validate(compiled, allocator, document);
}

test {
    _ = @import("tests.zig");
}
