//! XSLT 1.0 transformation over `dom.Document`.

const std = @import("std");
const dom = @import("../dom.zig");
const compile = @import("compile.zig");
const transform_mod = @import("transform.zig");

pub const Stylesheet = compile.Stylesheet;
pub const Options = compile.Options;
pub const Resolver = compile.Resolver;
pub const Resource = compile.Resource;
pub const Result = transform_mod.Result;
pub const Output = compile.Output;
pub const OutputMethod = compile.OutputMethod;
pub const Error = compile.Error || transform_mod.Error;
pub const xsl_namespace = compile.xsl_namespace;

/// Compile an XSLT stylesheet document without external includes or imports.
pub fn parse(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
) Error!Stylesheet {
    return compile.compile(allocator, document);
}

/// Compile a stylesheet, resolving `xsl:include` and `xsl:import` through the
/// supplied resolver.
pub fn parseWithOptions(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
    options: Options,
) Error!Stylesheet {
    return compile.compileWithOptions(allocator, document, options);
}

/// Apply a compiled stylesheet to a source document.
pub fn apply(
    stylesheet: *const Stylesheet,
    source: *const dom.Document,
    options: Options,
) Error!Result {
    return transform_mod.apply(
        stylesheet.arena.child_allocator,
        stylesheet,
        source,
        options,
    );
}

/// Apply with an explicit allocator for the transformation and result
/// arenas. Batch callers can pass a reusable arena and reset it after each
/// result is released, avoiding per-application allocation churn.
pub fn applyWithAllocator(
    allocator: std.mem.Allocator,
    stylesheet: *const Stylesheet,
    source: *const dom.Document,
    options: Options,
) Error!Result {
    return transform_mod.apply(allocator, stylesheet, source, options);
}

/// Compile and apply a stylesheet in one call.
pub fn transform(
    allocator: std.mem.Allocator,
    stylesheet_document: *const dom.Document,
    source_document: *const dom.Document,
    options: Options,
) Error!Result {
    var stylesheet = try parseWithOptions(
        allocator,
        stylesheet_document,
        options,
    );
    defer stylesheet.deinit();
    return apply(&stylesheet, source_document, options);
}

const testing = std.testing;

test {
    _ = @import("tests.zig");
}
