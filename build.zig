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
}
