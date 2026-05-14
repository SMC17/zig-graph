//! Eigenvector-centrality throughput benchmark for zig-graph.
//!
//! Random sparse graphs at three sizes (100 / 1 000 / 10 000 nodes, avg degree
//! ~8). Measures full 32-iteration power-iteration runs; reports total ns per
//! run and amortised ns per single power-iteration step (total / runs / iters)
//! plus ms per run.
//!
//! Timing: `std.os.linux.clock_gettime(.MONOTONIC, &ts)` directly — Zig 0.16
//! removed `std.time.Timer` and `std.time.nanoTimestamp`.

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
    .{ .label = "100n", .nodes = 100, .edges = 400, .runs = 5_000 },
    .{ .label = "1k", .nodes = 1_000, .edges = 4_000, .runs = 500 },
    .{ .label = "10k", .nodes = 10_000, .edges = 40_000, .runs = 50 },
};

const warmup_runs: usize = 3;
const power_iters: usize = 32;

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

    std.debug.print("# zig-graph bench: eigenvector centrality (ReleaseFast, MONOTONIC ns)\n", .{});

    for (sizes) |s| {
        var g = try buildRandomGraph(allocator, s.nodes, s.edges, 0xCE17_60A1);
        defer g.deinit();

        var w: usize = 0;
        while (w < warmup_runs) : (w += 1) {
            const ec = try graph.eigenvectorCentrality(g, allocator, .{ .iterations = power_iters });
            std.mem.doNotOptimizeAway(ec[0]);
            allocator.free(ec);
        }

        const t0 = nanos();
        var i: usize = 0;
        while (i < s.runs) : (i += 1) {
            const ec = try graph.eigenvectorCentrality(g, allocator, .{ .iterations = power_iters });
            std.mem.doNotOptimizeAway(ec[0]);
            allocator.free(ec);
        }
        const total_ns = nanos() - t0;

        const ns_per_run = total_ns / s.runs;
        const ns_per_step = ns_per_run / power_iters;
        const ops_per_sec: u128 =
            (@as(u128, s.runs) * @as(u128, std.time.ns_per_s)) /
            @max(@as(u128, total_ns), 1);
        const ms_per_run = ns_per_run / std.time.ns_per_ms;

        std.debug.print(
            "bench=centrality size={s} nodes={d} edges={d} iters_per_run={d} op=POWER_ITER runs={d} total_ns={d} ns_per_op={d} ns_per_step={d} ms_per_run={d} ops_per_sec={d}\n",
            .{ s.label, s.nodes, s.edges, power_iters, s.runs, total_ns, ns_per_run, ns_per_step, ms_per_run, ops_per_sec },
        );
    }
}
