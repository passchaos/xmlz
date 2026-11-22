//! Run Schematron patterns embedded in a host schema document.
//!
//! RELAX NG schemas can carry `sch:pattern` elements directly; XSD schemas
//! carry them inside `xs:annotation/xs:appinfo`. The host schema itself must
//! already be valid.

const std = @import("std");
const xmlz = @import("xmlz");

/// Validate `instance_document` against the embedded patterns. Returns true
/// when there are no patterns or every assertion holds. Failed assertions are
/// printed to stderr; successful reports are ignored for validity.
pub fn validate(
    allocator: std.mem.Allocator,
    schema_document: *const xmlz.dom.Document,
    instance_document: *const xmlz.dom.Document,
    ancestor: ?xmlz.schematron.Ancestor,
) !bool {
    const patterns = try xmlz.schematron.findEmbeddedPatterns(
        allocator,
        schema_document,
        ancestor,
    );
    defer allocator.free(patterns);
    if (patterns.len == 0) return true;
    var compiled = try xmlz.schematron.parsePatterns(
        allocator,
        schema_document,
        patterns,
    );
    defer compiled.deinit();
    var result = try xmlz.schematron.validate(
        &compiled,
        allocator,
        instance_document,
        .{},
    );
    defer result.deinit();
    if (result.isValid()) return true;
    for (result.failures) |failure| {
        if (failure.kind != .assert) continue;
        std.debug.print("{s}: {s}\n", .{
            failure.pattern_id,
            failure.message,
        });
    }
    return false;
}
