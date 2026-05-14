//! PageRank throughput benchmark for zig-graph.
//!
//! Builds Erdős–Rényi-style random sparse graphs at three sizes (100 / 1 000 /
//! 10 000 nodes, average degree ~8) using a deterministic PRNG, then measures
//! the wall time to run a full 40-iteration PageRank pass. We report the total
//! ms per convergence and the configured iteration count so the convergence
//! cost per node is `total_ns / (iters * n)`.
//!
//! Timing: `std.time.Timer` and `std.time.nanoTimestamp` were removed in Zig
//! 0.16's stdlib reshuffle. We call `std.os.linux.clock_gettime(.MONOTONIC,
//! &ts)` directly — same pattern Zig 0.16 itself uses internally.
//!
//! Output is parseable `key=value` whitespace-separated.

const std = @import("std");
const graph = @import("graph");

inline fn nanos() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s +
        @as(u64, @intCast(ts.nsec));
}

const Size = struct {
    label: []const u8,
    nodes: usize,
    edges: usize,
    runs: usize,
};

const sizes = [_]Size{
    .{ .label = "100n", .nodes = 100, .edges = 400, .runs = 2_000 },
    .{ .label = "1k", .nodes = 1_000, .edges = 4_000, .runs = 200 },
    .{ .label = "10k", .nodes = 10_000, .edges = 40_000, .runs = 20 },
};

const warmup_runs: usize = 3;
const pagerank_iters: usize = 40;

fn buildRandomGraph(allocator: std.mem.Allocator, n: usize, m: usize, seed: u64) !graph.Graph {
    var g = graph.Graph.init(allocator, n);
    errdefer g.deinit();
    var rng = std.Random.DefaultPrng.init(seed);
    const r = rng.random();
    var i: usize = 0;
    while (i < m) : (i += 1) {
        const src = r.uintLessThan(usize, n);
        var dst = r.uintLessThan(usize, n);
        if (dst == src) dst = (dst + 1) % n;
        try g.addEdge(src, dst, 1.0);
    }
    return g;
}

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    std.debug.print("# zig-graph bench: pagerank (ReleaseFast, MONOTONIC ns)\n", .{});

    for (sizes) |s| {
        var g = try buildRandomGraph(allocator, s.nodes, s.edges, 0x60A1_BE17);
        defer g.deinit();

        // Warm-up — discarded.
        var w: usize = 0;
        while (w < warmup_runs) : (w += 1) {
            const pr = try graph.pagerank(g, allocator, .{ .iterations = pagerank_iters });
            std.mem.doNotOptimizeAway(pr[0]);
            allocator.free(pr);
        }

        // Measurement.
        const t0 = nanos();
        var i: usize = 0;
        while (i < s.runs) : (i += 1) {
            const pr = try graph.pagerank(g, allocator, .{ .iterations = pagerank_iters });
            std.mem.doNotOptimizeAway(pr[0]);
            allocator.free(pr);
        }
        const total_ns = nanos() - t0;

        const ns_per_op = total_ns / s.runs;
        const ops_per_sec: u128 =
            (@as(u128, s.runs) * @as(u128, std.time.ns_per_s)) /
            @max(@as(u128, total_ns), 1);
        const ms_per_run = ns_per_op / std.time.ns_per_ms;

        std.debug.print(
            "bench=pagerank size={s} nodes={d} edges={d} iters_per_run={d} op=PAGERANK runs={d} total_ns={d} ns_per_op={d} ms_per_run={d} ops_per_sec={d}\n",
            .{ s.label, s.nodes, s.edges, pagerank_iters, s.runs, total_ns, ns_per_op, ms_per_run, ops_per_sec },
        );
    }
}
