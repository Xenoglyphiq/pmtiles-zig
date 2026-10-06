const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Core: `@import("pmtiles")`. Header, directories, tile ids, find_entry.
    const core = b.addModule("pmtiles", .{
        .root_source_file = b.path("src/pmtiles.zig"),
        .target = target,
    });
    // io: `@import("pmtiles_io")`. Sources, decompression, getTile, readMetadata.
    const io = b.addModule("pmtiles_io", .{
        .root_source_file = b.path("src/io.zig"),
        .target = target,
        .imports = &.{.{ .name = "pmtiles", .module = core }},
    });

    // zig build test: unit tests and the fuzz targets (`zig build test --fuzz`).
    // The io tests embed two of the spec's conformance archives.
    const io_test_mod = b.createModule(.{
        .root_source_file = b.path("src/io.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "pmtiles", .module = core }},
    });
    inline for (.{ "small.pmtiles", "small-uncompressed.pmtiles" }) |name| {
        io_test_mod.addAnonymousImport(name, .{
            .root_source_file = b.path(".spec/conformance/cases/archives/" ++ name),
        });
    }
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = core })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = io_test_mod })).step);

    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "pmtiles", .module = core },
        .{ .name = "pmtiles_io", .module = io },
    };

    // zig build conformance: every case in the vendored spec's manifest.
    const runner = b.addExecutable(.{
        .name = "conformance",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/conformance.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
    });
    const run_conformance = b.addRunArtifact(runner);
    run_conformance.addFileArg(b.path(".spec/conformance/manifest.json"));
    const conformance_step = b.step("conformance", "Run the spec's conformance cases");
    conformance_step.dependOn(&run_conformance.step);

    // zig build bench [-- <dir>]: get_tile timings on <dir>/bench.pmtiles and
    // <dir>/coords.txt (default .spec/bench), always ReleaseFast.
    const bench_core = b.createModule(.{
        .root_source_file = b.path("src/pmtiles.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const bench_io = b.createModule(.{
        .root_source_file = b.path("src/io.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "pmtiles", .module = bench_core }},
    });
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "pmtiles", .module = bench_core },
                .{ .name = "pmtiles_io", .module = bench_io },
            },
        }),
    });
    const run_bench = b.addRunArtifact(bench);
    run_bench.setCwd(b.path("."));
    run_bench.addPassthruArgs();
    const bench_step = b.step("bench", "Time get_tile over the spec's 10,000 bench coordinates");
    bench_step.dependOn(&run_bench.step);

    // zig build examples: the three canonical examples. remote_metadata needs
    // the network.
    const examples_step = b.step("examples", "Run the three canonical examples");
    inline for (.{ "inspect_archive", "fetch_one_tile", "remote_metadata" }) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/" ++ name ++ ".zig"),
                .target = target,
                .optimize = optimize,
                .imports = imports,
            }),
        });
        const run = b.addRunArtifact(exe);
        run.setCwd(b.path("."));
        examples_step.dependOn(&run.step);
    }
}
