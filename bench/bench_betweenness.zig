//! Betweenness-centrality throughput benchmark for zig-graph.
//!
//! Brandes' algorithm is O(|V|·|E|) for unweighted graphs and runs an SSSP
//! per source. We measure 100- and 1 000-node sparse random graphs. We
//! deliberately skip 10 K — Brandes is O(VE) and a 10 K-node sparse graph
//! takes minutes per run.

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
    .{ .label = "100n", .nodes = 100, .edges = 400, .runs = 50 },
    .{ .label = "1k", .nodes = 1_000, .edges = 4_000, .runs = 3 },
};

const warmup_runs: usize = 1;

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

    std.debug.print("# zig-graph bench: betweenness centrality (ReleaseFast, MONOTONIC ns)\n", .{});

    for (sizes) |s| {
        var g = try buildRandomGraph(allocator, s.nodes, s.edges, 0xBE7F_60A1);
        defer g.deinit();

        var w: usize = 0;
        while (w < warmup_runs) : (w += 1) {
            const bc = try graph.betweennessCentrality(g, allocator, .{ .unweighted = true });
            std.mem.doNotOptimizeAway(bc[0]);
            allocator.free(bc);
        }

        const t0 = nanos();
        var i: usize = 0;
        while (i < s.runs) : (i += 1) {
            const bc = try graph.betweennessCentrality(g, allocator, .{ .unweighted = true });
            std.mem.doNotOptimizeAway(bc[0]);
            allocator.free(bc);
        }
        const total_ns = nanos() - t0;

        const ns_per_run = total_ns / s.runs;
        const ops_per_sec: u128 =
            (@as(u128, s.runs) * @as(u128, std.time.ns_per_s)) /
            @max(@as(u128, total_ns), 1);
        const ms_per_run = ns_per_run / std.time.ns_per_ms;

        std.debug.print(
            "bench=betweenness size={s} nodes={d} edges={d} op=BRANDES_BFS runs={d} total_ns={d} ns_per_op={d} ms_per_run={d} ops_per_sec={d}\n",
            .{ s.label, s.nodes, s.edges, s.runs, total_ns, ns_per_run, ms_per_run, ops_per_sec },
        );
    }
}
