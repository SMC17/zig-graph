//! Fiedler-value throughput benchmark for zig-graph.
//!
//! Inverse-power iteration on the Laplacian via the deflated (τI − L) shift.
//! Cost per iteration is O(|V| + |E|). We measure 100 / 1 000 / 10 000-node
//! sparse random graphs and report total ns + ms per converge plus the
//! converged Fiedler value as a parseable `fiedler=...` field.

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
    .{ .label = "100n", .nodes = 100, .edges = 400, .runs = 200 },
    .{ .label = "1k", .nodes = 1_000, .edges = 4_000, .runs = 30 },
    .{ .label = "10k", .nodes = 10_000, .edges = 40_000, .runs = 3 },
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

    std.debug.print("# zig-graph bench: fiedler (ReleaseFast, MONOTONIC ns)\n", .{});

    for (sizes) |s| {
        var g = try buildRandomGraph(allocator, s.nodes, s.edges, 0xF1ED_60A1);
        defer g.deinit();

        var w: usize = 0;
        while (w < warmup_runs) : (w += 1) {
            var r = try graph.fiedler(g, allocator, .{ .iterations = 1_000 });
            std.mem.doNotOptimizeAway(r.value);
            r.deinit();
        }

        const t0 = nanos();
        var i: usize = 0;
        var last_v: f64 = 0.0;
        var last_iters: usize = 0;
        while (i < s.runs) : (i += 1) {
            var r = try graph.fiedler(g, allocator, .{ .iterations = 1_000 });
            std.mem.doNotOptimizeAway(r.value);
            last_v = r.value;
            last_iters = r.iterations;
            r.deinit();
        }
        const total_ns = nanos() - t0;

        const ns_per_run = total_ns / s.runs;
        const ops_per_sec: u128 =
            (@as(u128, s.runs) * @as(u128, std.time.ns_per_s)) /
            @max(@as(u128, total_ns), 1);
        const ms_per_run = ns_per_run / std.time.ns_per_ms;

        std.debug.print(
            "bench=fiedler size={s} nodes={d} edges={d} op=DEFLATED_POWER runs={d} total_ns={d} ns_per_op={d} ms_per_run={d} ops_per_sec={d} fiedler={d:.6} iters_to_converge={d}\n",
            .{ s.label, s.nodes, s.edges, s.runs, total_ns, ns_per_run, ms_per_run, ops_per_sec, last_v, last_iters },
        );
    }
}
