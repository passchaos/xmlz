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

    const xpath_eval = b.addExecutable(.{
        .name = "xpath-eval",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/xpath_eval.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    xpath_eval.root_module.addImport("xmlz", mod);
    b.installArtifact(xpath_eval);

    const c14n_tool = b.addExecutable(.{
        .name = "c14n",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/c14n.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    c14n_tool.root_module.addImport("xmlz", mod);
    b.installArtifact(c14n_tool);

    const xslt_tool = b.addExecutable(.{
        .name = "xslt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/xslt.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    xslt_tool.root_module.addImport("xmlz", mod);
    b.installArtifact(xslt_tool);

    const xsd_tool = b.addExecutable(.{
        .name = "xsd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/xsd.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    xsd_tool.root_module.addImport("xmlz", mod);
    b.installArtifact(xsd_tool);

    const catalog_tool = b.addExecutable(.{
        .name = "catalog",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/catalog.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    catalog_tool.root_module.addImport("xmlz", mod);
    b.installArtifact(catalog_tool);

    const schematron_tool = b.addExecutable(.{
        .name = "schematron",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/schematron.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    schematron_tool.root_module.addImport("xmlz", mod);
    b.installArtifact(schematron_tool);

    const xinclude_tool = b.addExecutable(.{
        .name = "xinclude",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/xinclude.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    xinclude_tool.root_module.addImport("xmlz", mod);
    b.installArtifact(xinclude_tool);

    const rng_tool = b.addExecutable(.{
        .name = "rng",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/rng.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    rng_tool.root_module.addImport("xmlz", mod);
    b.installArtifact(rng_tool);

    const xpath_diff = b.addSystemCommand(&.{
        "python3",
        "tools/xpath_diff.py",
    });
    xpath_diff.addFileArg(xpath_eval.getEmittedBin());
    const xpath_diff_step = b.step(
        "xpath-diff",
        "Differential XPath checks against libxml2's xmllint",
    );
    xpath_diff_step.dependOn(&xpath_diff.step);

    const c14n_diff = b.addSystemCommand(&.{
        "python3",
        "tools/c14n_diff.py",
    });
    c14n_diff.addFileArg(c14n_tool.getEmittedBin());
    const c14n_diff_step = b.step(
        "c14n-diff",
        "Differential canonicalization checks against libxml2's xmllint",
    );
    c14n_diff_step.dependOn(&c14n_diff.step);

    const xslt_diff = b.addSystemCommand(&.{
        "python3",
        "tools/xslt_diff.py",
    });
    xslt_diff.addFileArg(xslt_tool.getEmittedBin());
    const xslt_diff_step = b.step(
        "xslt-diff",
        "Differential XSLT checks against libxslt through lxml",
    );
    xslt_diff_step.dependOn(&xslt_diff.step);

    const xslt_suite = b.addSystemCommand(&.{
        "python3",
        "tools/libxslt_suite.py",
        "testdata/libxslt-general",
    });
    xslt_suite.addFileArg(xslt_tool.getEmittedBin());
    const xslt_suite_step = b.step(
        "xslt-suite",
        "Run the libxslt general regression suite",
    );
    xslt_suite_step.dependOn(&xslt_suite.step);

    const xslt_exslt_suite = b.addSystemCommand(&.{
        "python3",
        "tools/libxslt_exslt_suite.py",
        "testdata/libxslt-exslt",
    });
    xslt_exslt_suite.addFileArg(xslt_tool.getEmittedBin());
    const xslt_exslt_suite_step = b.step(
        "xslt-exslt-suite",
        "Run the libxslt EXSLT regression suite",
    );
    xslt_exslt_suite_step.dependOn(&xslt_exslt_suite.step);

    const xslt_rec_suite = b.addSystemCommand(&.{
        "python3",
        "tools/libxslt_rec_suite.py",
        "testdata/libxslt-rec",
    });
    xslt_rec_suite.addFileArg(xslt_tool.getEmittedBin());
    const xslt_rec_suite_step = b.step(
        "xslt-rec-suite",
        "Run the libxslt REC (XSLT specification) regression suite",
    );
    xslt_rec_suite_step.dependOn(&xslt_rec_suite.step);

    const xslt_misc_suite = b.addSystemCommand(&.{
        "python3",
        "tools/libxslt_misc_suite.py",
        "testdata/libxslt-misc",
    });
    xslt_misc_suite.addFileArg(xslt_tool.getEmittedBin());
    const xslt_misc_suite_step = b.step(
        "xslt-misc-suite",
        "Run the libxslt feature regression corpora",
    );
    xslt_misc_suite_step.dependOn(&xslt_misc_suite.step);

    const xslt_bench = b.addSystemCommand(&.{
        "python3",
        "tools/xslt_bench.py",
    });
    xslt_bench.addFileArg(xslt_tool.getEmittedBin());
    const xslt_bench_step = b.step(
        "xslt-bench",
        "Benchmark XSLT identity transforms against libxslt (needs lxml)",
    );
    xslt_bench_step.dependOn(&xslt_bench.step);

    const xsd_diff = b.addSystemCommand(&.{
        "python3",
        "tools/xsd_diff.py",
    });
    xsd_diff.addFileArg(xsd_tool.getEmittedBin());
    const xsd_diff_step = b.step(
        "xsd-diff",
        "Differential XML Schema checks against libxml2 through lxml",
    );
    xsd_diff_step.dependOn(&xsd_diff.step);

    const rng_diff = b.addSystemCommand(&.{
        "python3",
        "tools/rng_diff.py",
    });
    rng_diff.addFileArg(rng_tool.getEmittedBin());
    const rng_diff_step = b.step(
        "rng-diff",
        "Differential RELAX NG checks against libxml2 through lxml",
    );
    rng_diff_step.dependOn(&rng_diff.step);

    const rng_compact_diff = b.addSystemCommand(&.{
        "python3",
        "tools/rng_compact_diff.py",
    });
    rng_compact_diff.addFileArg(rng_tool.getEmittedBin());
    const rng_compact_diff_step = b.step(
        "rng-compact-diff",
        "Differential RELAX NG compact syntax checks against libxml2",
    );
    rng_compact_diff_step.dependOn(&rng_compact_diff.step);

    const xinclude_diff = b.addSystemCommand(&.{
        "python3",
        "tools/xinclude_diff.py",
    });
    xinclude_diff.addFileArg(xinclude_tool.getEmittedBin());
    const xinclude_diff_step = b.step(
        "xinclude-diff",
        "Differential XInclude checks against libxml2's xmllint",
    );
    xinclude_diff_step.dependOn(&xinclude_diff.step);

    const schematron_diff = b.addSystemCommand(&.{
        "python3",
        "tools/schematron_diff.py",
    });
    schematron_diff.addFileArg(schematron_tool.getEmittedBin());
    const schematron_diff_step = b.step(
        "schematron-diff",
        "Differential ISO Schematron checks against the ISO skeleton through lxml",
    );
    schematron_diff_step.dependOn(&schematron_diff.step);

    const catalog_diff = b.addSystemCommand(&.{
        "python3",
        "tools/catalog_diff.py",
    });
    catalog_diff.addFileArg(catalog_tool.getEmittedBin());
    const catalog_diff_step = b.step(
        "catalog-diff",
        "Differential OASIS XML Catalogs checks against libxml2's xmlcatalog",
    );
    catalog_diff_step.dependOn(&catalog_diff.step);

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
