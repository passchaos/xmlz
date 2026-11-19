const std = @import("std");
const builtin = @import("builtin");

const required_zig_version = "0.16.0";

pub fn build(b: *std.Build) void {
    comptime {
        if (!std.mem.eql(u8, builtin.zig_version_string, required_zig_version)) {
            @compileError("xmlz requires Zig " ++ required_zig_version ++ "; found " ++ builtin.zig_version_string);
        }
    }

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option(
        []const u8,
        "test-filter",
        "Run only unit tests whose name contains this substring",
    );

    const mod = b.addModule("xmlz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "xmlz",
        .root_module = mod,
    });
    b.installArtifact(lib);

    const filters: []const []const u8 = if (test_filter) |filter|
        &[_][]const u8{filter}
    else
        &[_][]const u8{};

    const tests = b.addTest(.{
        .root_module = mod,
        .filters = filters,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run xmlz unit tests");
    test_step.dependOn(&run_tests.step);
}
