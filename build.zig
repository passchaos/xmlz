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

    const conformance = b.addExecutable(.{
        .name = "conformance",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/conformance.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    conformance.root_module.addImport("xmlz", mod);
    const run_conformance = b.addRunArtifact(conformance);
    run_conformance.addArg("testdata/xmlconf");
    if (b.args) |args| run_conformance.addArgs(args);
    const conformance_step = b.step(
        "conformance",
        "Run the W3C XML conformance suite (testdata/xmlconf)",
    );
    conformance_step.dependOn(&run_conformance.step);

    const check_step = b.step("check", "Run unit tests and the conformance suite");
    check_step.dependOn(test_step);
    check_step.dependOn(conformance_step);

    const bench_step = b.step(
        "bench",
        "Run xmlz benchmarks against expat, pugixml, and libxml2",
    );
    const bench_optimize: std.builtin.OptimizeMode = .ReleaseFast;

    const gen = b.addExecutable(.{
        .name = "gen-bench-input",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/gen.zig"),
            .target = target,
            .optimize = bench_optimize,
        }),
    });
    const gen_run = b.addRunArtifact(gen);
    const bench_input = gen_run.addOutputFileArg("svg-large.xml");
    bench_step.dependOn(&gen_run.step);

    const xmlz_bench = b.addExecutable(.{
        .name = "xmlz-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/xmlz_bench.zig"),
            .target = target,
            .optimize = bench_optimize,
        }),
    });
    xmlz_bench.root_module.addImport("xmlz", mod);
    const xmlz_run = b.addRunArtifact(xmlz_bench);
    xmlz_run.addFileArg(bench_input);
    bench_step.dependOn(&xmlz_run.step);

    const expat_bench = b.addExecutable(.{
        .name = "expat-bench",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = bench_optimize,
            .link_libc = true,
        }),
    });
    expat_bench.root_module.addCSourceFile(.{
        .file = b.path("bench/expat_bench.c"),
        .flags = &.{ "-O3", "-std=c11" },
    });
    expat_bench.root_module.linkSystemLibrary("expat", .{});
    const expat_run = b.addRunArtifact(expat_bench);
    expat_run.addFileArg(bench_input);
    bench_step.dependOn(&expat_run.step);

    const pugixml_bench = b.addExecutable(.{
        .name = "pugixml-bench",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = bench_optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });
    pugixml_bench.root_module.addCSourceFile(.{
        .file = b.path("bench/pugixml_bench.cpp"),
        .flags = &.{ "-O3", "-std=c++17" },
    });
    pugixml_bench.root_module.linkSystemLibrary("pugixml", .{});
    const pugixml_run = b.addRunArtifact(pugixml_bench);
    pugixml_run.addFileArg(bench_input);
    bench_step.dependOn(&pugixml_run.step);

    const libxml2_bench = b.addExecutable(.{
        .name = "libxml2-bench",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = bench_optimize,
            .link_libc = true,
        }),
    });
    libxml2_bench.root_module.addCSourceFile(.{
        .file = b.path("bench/libxml2_bench.c"),
        .flags = &.{ "-O3", "-std=c11" },
    });
    libxml2_bench.root_module.addIncludePath(.{
        .cwd_relative = "/usr/include/libxml2",
    });
    libxml2_bench.root_module.linkSystemLibrary("xml2", .{});
    const libxml2_run = b.addRunArtifact(libxml2_bench);
    libxml2_run.addFileArg(bench_input);
    bench_step.dependOn(&libxml2_run.step);
}
