//! Graph-construction throughput benchmark for zig-graph.
//!
//! Measures the cost of `Graph.init` plus N `addEdge` calls at three sizes
//! (1 K / 10 K / 100 K edges). Each run pre-generates the (src, dst) pairs so
//! we measure the construction-path cost, not RNG. Reports ns per addEdge and
//! addEdges per second.
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
    edges: usize,
    runs: usize,
};

const sizes = [_]Size{
    .{ .label = "1k_edges", .edges = 1_000, .runs = 2_000 },
    .{ .label = "10k_edges", .edges = 10_000, .runs = 200 },
    .{ .label = "100k_edges", .edges = 100_000, .runs = 20 },
};

const warmup_runs: usize = 3;

const Pair = struct { src: usize, dst: usize };

fn buildPairs(allocator: std.mem.Allocator, n_nodes: usize, n_edges: usize, seed: u64) ![]Pair {
    const pairs = try allocator.alloc(Pair, n_edges);
    var rng = std.Random.DefaultPrng.init(seed);
    const r = rng.random();
    for (pairs) |*p| {
        const s = r.uintLessThan(usize, n_nodes);
        var d = r.uintLessThan(usize, n_nodes);
        if (d == s) d = (d + 1) % n_nodes;
        p.* = .{ .src = s, .dst = d };
    }
    return pairs;
}

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    std.debug.print("# zig-graph bench: construct (ReleaseFast, MONOTONIC ns)\n", .{});

    for (sizes) |s| {
        // Pick a node count proportional to edges so degree stays bounded.
        const n_nodes = s.edges / 4 + 4;
        const pairs = try buildPairs(allocator, n_nodes, s.edges, 0xC0_DEC_0DE_60A1);
        defer allocator.free(pairs);

        var w: usize = 0;
        while (w < warmup_runs) : (w += 1) {
            var g = graph.Graph.init(allocator, n_nodes);
            defer g.deinit();
            for (pairs) |p| try g.addEdge(p.src, p.dst, 1.0);
            std.mem.doNotOptimizeAway(g.edges.items.len);
        }

        const t0 = nanos();
        var i: usize = 0;
        while (i < s.runs) : (i += 1) {
            var g = graph.Graph.init(allocator, n_nodes);
            for (pairs) |p| try g.addEdge(p.src, p.dst, 1.0);
            std.mem.doNotOptimizeAway(g.edges.items.len);
            g.deinit();
        }
        const total_ns = nanos() - t0;

        const total_edges: u128 = @as(u128, s.edges) * @as(u128, s.runs);
        const ns_per_edge: u128 = @as(u128, total_ns) / @max(total_edges, 1);
        const edges_per_sec: u128 = (total_edges * @as(u128, std.time.ns_per_s)) /
            @max(@as(u128, total_ns), 1);
        const ns_per_run = total_ns / s.runs;

        std.debug.print(
            "bench=construct size={s} nodes={d} edges={d} op=ADD_EDGE runs={d} total_ns={d} ns_per_op={d} ns_per_edge={d} edges_per_sec={d} ns_per_run={d}\n",
            .{ s.label, n_nodes, s.edges, s.runs, total_ns, ns_per_edge, ns_per_edge, edges_per_sec, ns_per_run },
        );
    }
}
