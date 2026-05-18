const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("graph", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // Cross-validation suite — separate `zig build crossval` step.
    // Compares zig-graph output against networkx 3.6.1 and closed-form
    // references on canonical small graphs (karate club, Petersen, P_5,
    // C_6, K_5). Wired into `zig build test` as well so any regression
    // against the external reference fails CI loudly.
    const crossval_mod = b.createModule(.{
        .root_source_file = b.path("tests/crossval_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    crossval_mod.addImport("graph", mod);
    const crossval_tests = b.addTest(.{
        .root_module = crossval_mod,
    });
    const run_crossval = b.addRunArtifact(crossval_tests);
    const crossval_step = b.step("crossval", "Run cross-validation against networkx + closed-form references");
    crossval_step.dependOn(&run_crossval.step);
    // Also run on `zig build test` so the external-reference contract is
    // not silently broken by a future change.
    test_step.dependOn(&run_crossval.step);

    // Example
    const example_mod = b.createModule(.{
        .root_source_file = b.path("examples/centrality.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_mod.addImport("graph", mod);
    const example_exe = b.addExecutable(.{
        .name = "example-centrality",
        .root_module = example_mod,
    });
    b.installArtifact(example_exe);
    const run_example = b.addRunArtifact(example_exe);
    const example_step = b.step("example-centrality", "Run the centrality example");
    example_step.dependOn(&run_example.step);

    // README Quickstart example — vendored verbatim from README.md as the
    // executable form of the documentation. Backed by `tools/doctest.sh`
    // which diff-checks the README block against this file; drift fails.
    const quickstart_mod = b.createModule(.{
        .root_source_file = b.path("examples/quickstart.zig"),
        .target = target,
        .optimize = optimize,
    });
    quickstart_mod.addImport("graph", mod);
    const quickstart_exe = b.addExecutable(.{
        .name = "example-quickstart",
        .root_module = quickstart_mod,
    });
    b.installArtifact(quickstart_exe);
    const run_quickstart = b.addRunArtifact(quickstart_exe);
    const quickstart_step = b.step("example-quickstart", "Run the README Quickstart example");
    quickstart_step.dependOn(&run_quickstart.step);

    // Doc-tests — extract README's Quickstart + API blocks, diff against
    // the vendored example + source, run binary, check output.
    const doctest = b.addSystemCommand(&.{ "bash", "tools/doctest.sh" });
    doctest.step.dependOn(b.getInstallStep());
    const doctest_step = b.step("doctest", "Verify README claims match the code");
    doctest_step.dependOn(&doctest.step);

    // Benchmarks — separate step (`zig build bench`) so `zig build test`
    // stays fast. Always built in ReleaseFast so numbers reflect optimised
    // codegen regardless of the user's top-level optimize flag.
    const bench_step = b.step("bench", "Run PageRank / centrality / construct / betweenness / louvain / fiedler benchmarks");
    const bench_sources = [_]struct {
        name: []const u8,
        path: []const u8,
    }{
        .{ .name = "bench-pagerank", .path = "bench/bench_pagerank.zig" },
        .{ .name = "bench-centrality", .path = "bench/bench_centrality.zig" },
        .{ .name = "bench-construct", .path = "bench/bench_construct.zig" },
        .{ .name = "bench-betweenness", .path = "bench/bench_betweenness.zig" },
        .{ .name = "bench-louvain", .path = "bench/bench_louvain.zig" },
        .{ .name = "bench-fiedler", .path = "bench/bench_fiedler.zig" },
    };
    for (bench_sources) |bs| {
        const bench_mod = b.createModule(.{
            .root_source_file = b.path(bs.path),
            .target = target,
            .optimize = .ReleaseFast,
        });
        bench_mod.addImport("graph", mod);
        const bench_exe = b.addExecutable(.{
            .name = bs.name,
            .root_module = bench_mod,
        });
        const run_bench = b.addRunArtifact(bench_exe);
        run_bench.has_side_effects = true; // ensure rerun on `zig build bench`
        bench_step.dependOn(&run_bench.step);
    }

    // Scale benchmark — separate step (`zig build bench-scale`) so the
    // regular `bench` umbrella stays under a minute. The scale bench
    // builds 100K and 1M-node ER graphs (~320 MB peak RSS at 1M) and
    // runs PageRank / directedPageRank / SSSP / BFS / weightedDegree
    // with invariant assertions at scale. Closes the STATUS.md G1 gate.
    const bench_scale_mod = b.createModule(.{
        .root_source_file = b.path("bench/bench_scale.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_scale_mod.addImport("graph", mod);
    const bench_scale_exe = b.addExecutable(.{
        .name = "bench-scale",
        .root_module = bench_scale_mod,
    });
    const run_bench_scale = b.addRunArtifact(bench_scale_exe);
    run_bench_scale.has_side_effects = true;
    const bench_scale_step = b.step("bench-scale", "Run scale benchmarks (100K + 1M-node ER graphs) with invariant checks");
    bench_scale_step.dependOn(&run_bench_scale.step);

    // Coverage driver — plain executable that exercises every public API
    // + every error path so kcov can measure src/root.zig line coverage.
    // Per the zig-cobs v1.2.0 toolchain note: Zig 0.16 test-runner
    // debug-info doesn't surface line-coverage to the nixpkgs kcov build
    // (compiled without libbfd-dev); a plain exe with standard ELF+DWARF
    // captures cleanly.
    const cov_mod = b.createModule(.{
        .root_source_file = b.path("examples/coverage_driver.zig"),
        .target = target,
        .optimize = optimize,
    });
    cov_mod.addImport("graph", mod);
    const cov_exe = b.addExecutable(.{
        .name = "coverage-driver",
        .root_module = cov_mod,
    });
    b.installArtifact(cov_exe);
    const run_cov = b.addRunArtifact(cov_exe);
    const cov_step = b.step("coverage-driver", "Run the kcov coverage driver");
    cov_step.dependOn(&run_cov.step);
}
