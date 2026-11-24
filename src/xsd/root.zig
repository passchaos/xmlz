//! XML Schema validation.

const std = @import("std");
const dom = @import("../dom.zig");

pub const regex = @import("regex.zig");
pub const datatypes = @import("datatypes.zig");
pub const schema = @import("schema.zig");
pub const validate_mod = @import("validate.zig");

pub const Schema = schema.Schema;
pub const SchemaDocument = schema.SchemaDocument;
pub const Options = schema.Options;
pub const Resolver = schema.Resolver;
pub const Resource = schema.Resource;
pub const Error = schema.Error;
pub const ValidationError = validate_mod.ValidationError;
pub const ValidationResult = validate_mod.Result;

/// Compile an XML Schema document.
pub fn parse(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
) Error!Schema {
    return schema.parse(allocator, document);
}

/// Compile a schema document with include/import resolution.
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
