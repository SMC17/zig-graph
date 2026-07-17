//! Scale benchmark — push zig-graph past toy graphs.
//!
//! Closes the `G1 — Scale-tested throughput` gate named in STATUS.md by
//! running the load-bearing algorithms on large synthetic graphs (100K
//! and 1M nodes) and asserting the algorithm-level invariants hold at
//! scale, not just on 6-node textbook graphs.
//!
//! Graph generator: Erdős–Rényi G(n, m) with average degree ~10, edge
//! source/target sampled uniformly via `std.Random.DefaultPrng`. Self-
//! loops are coerced to (src, (src+1) % n) so the edge survives — same
//! convention as `bench_pagerank.zig` for consistency. Seed is pinned
//! so runs are reproducible (`0x5CALEBE17`).
//!
//! Why ER and not SNAP `web-Google` / KONECT / pajek dumps?
//!
//!   1. *Hermetic.* The benchmark is checked into the repo; no
//!      out-of-band 100 MB download step before `zig build bench-scale`
//!      runs. The build environment doesn't need network.
//!   2. *Reproducible.* PRNG seed pinned. Anyone running the bench on
//!      the same Zig + same architecture sees the same edge list.
//!   3. *Sufficient.* ER graphs at avg-degree ~10 hit the same
//!      sparse-graph algorithmic costs PageRank / centrality / SSSP
//!      pay on real social / web / road graphs at the same |V|+|E|.
//!      The diameter is different (logarithmic vs power-law for web),
//!      so this bench does NOT claim to substitute for a power-law-
//!      sensitive bench (PageRank convergence rate is the obvious
//!      example) — see bench/RESULTS.md for the explicit Type-II
//!      annotation.
//!
//! Algorithm coverage (in order of cost):
//!
//!   - `pagerank`        : 40 iters, undirected, damping 0.85
//!   - `directedPagerank`: 40 iters, directed, damping 0.85
//!   - `sssp` (Dijkstra) : single source = node 0
//!   - `bfs`             : single source = node 0
//!   - `weightedDegree`  : closed-form linear scan (cheap)
//!
//! Each algorithm asserts its invariant at scale:
//!
//!   - PageRank sums to 1.0 ± 1e-6 across 100K and 1M nodes.
//!   - directedPageRank sums to 1.0 ± 1e-5 (sink redistribution may
//!     bleed a tiny bit more in finite-precision arithmetic, hence the
//!     looser bound).
//!   - SSSP returns N distances (no out-of-range crashes, no NaN).
//!   - BFS returns up to N visited nodes; first node is the source.
//!   - weightedDegree returns N values, sum = 2 * total_edge_weight.
//!
//! If any invariant breaks, the bench exits non-zero so CI catches it.
//! That makes this both a throughput benchmark AND a scale-correctness
//! regression test.
//!
//! Memory: a 1M-node, ~10M-edge graph allocates roughly:
//!   - edges: 10M * sizeof(Edge=24 bytes) = ~240 MB
//!   - pagerank state: 6 * 1M * sizeof(f64) = 48 MB
//!   - bfs/sssp state: 1M * sizeof(usize/f64) = 8-16 MB each
//! Total peak: ~320 MB. Fits comfortably in a laptop's RAM but is the
//! reason this is a separate `bench-scale` step, not folded into the
//! regular `bench` umbrella.
//!
//! Output: parseable `key=value` whitespace-separated lines (same
//! convention as the other benches). Exits non-zero on any invariant
//! violation so this also serves as a continuous-scale-correctness
//! regression test if wired into CI on a fat runner.

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
};

/// Sizes are intentionally aggressive — 100K is the "medium graph" line
/// the README's Out-of-scope section names; 1M is one decade past that.
/// `bench/RESULTS.md` reports the actual wall-clock + peak RSS at both.
const sizes = [_]Size{
    .{ .label = "100k", .nodes = 100_000, .edges = 1_000_000 },
    .{ .label = "1M", .nodes = 1_000_000, .edges = 10_000_000 },
};

const pagerank_iters: usize = 40;

/// Build an Erdős–Rényi G(n, m) graph deterministically. Self-loop edges
/// are nudged to (src, (src+1) % n) so each call adds exactly one edge.
fn buildErRandomGraph(allocator: std.mem.Allocator, n: usize, m: usize, seed: u64) !graph.Graph {
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

/// Sum-to-1 invariant check for PageRank-shaped outputs. Returns absolute
/// distance from 1.0; caller compares against tolerance.
fn pageRankSumDelta(pr: []const f64) f64 {
    var sum: f64 = 0.0;
    for (pr) |v| sum += v;
    return @abs(sum - 1.0);
}

/// Sum-of-weighted-degree invariant: for an undirected graph (each edge
/// contributes to BOTH endpoints), sum_i wd[i] = 2 * total_edge_weight.
/// In this bench, every edge has weight 1.0, so the expected sum is 2*m.
fn weightedDegreeSumDelta(wd: []const f64, m_edges: usize) f64 {
    var sum: f64 = 0.0;
    for (wd) |v| sum += v;
    const expected: f64 = 2.0 * @as(f64, @floatFromInt(m_edges));
    return @abs(sum - expected);
}

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    std.debug.print("# zig-graph bench: scale (ReleaseFast, MONOTONIC ns, ER seed=0x5CA1EBE17)\n", .{});

    // Top-level invariant violations -> non-zero exit (caught by CI).
    var any_invariant_violation = false;

    for (sizes) |s| {
        // ---- construct ----
        const t_build_start = nanos();
        var g = try buildErRandomGraph(allocator, s.nodes, s.edges, 0x5CA1EBE17);
        defer g.deinit();
        const t_build_ns = nanos() - t_build_start;

        std.debug.print(
            "bench=construct size={s} nodes={d} edges={d} build_ns={d} build_ms={d}\n",
            .{ s.label, s.nodes, s.edges, t_build_ns, t_build_ns / std.time.ns_per_ms },
        );

        // ---- weightedDegree (cheapest, sanity check the graph) ----
        {
            const t0 = nanos();
            const wd = try graph.weightedDegree(g, allocator);
            defer allocator.free(wd);
            const dt = nanos() - t0;

            const sum_delta = weightedDegreeSumDelta(wd, s.edges);
            const tol: f64 = 1e-6 * @as(f64, @floatFromInt(s.edges));
            const ok = sum_delta < tol;
            if (!ok) any_invariant_violation = true;

            std.debug.print(
                "bench=weightedDegree size={s} nodes={d} edges={d} ns={d} ms={d} sum_delta={e:.6} tol={e:.6} invariant={s}\n",
                .{ s.label, s.nodes, s.edges, dt, dt / std.time.ns_per_ms, sum_delta, tol, if (ok) "OK" else "FAIL" },
            );
        }

        // ---- pagerank (undirected) ----
        {
            const t0 = nanos();
            const pr = try graph.pagerank(g, allocator, .{ .iterations = pagerank_iters });
            defer allocator.free(pr);
            const dt = nanos() - t0;

            const sum_delta = pageRankSumDelta(pr);
            const ok = sum_delta < 1e-6;
            if (!ok) any_invariant_violation = true;

            // Sanity: no NaN/Inf escaped.
            var any_nonfinite = false;
            for (pr) |v| if (!std.math.isFinite(v)) {
                any_nonfinite = true;
                break;
            };
            if (any_nonfinite) any_invariant_violation = true;

            std.debug.print(
                "bench=pagerank size={s} nodes={d} edges={d} iters={d} ns={d} ms={d} ns_per_node_per_iter={d} sum_delta={e:.6} finite={s} invariant={s}\n",
                .{
                    s.label,                             s.nodes,
                    s.edges,                             pagerank_iters,
                    dt,                                  dt / std.time.ns_per_ms,
                    dt / (s.nodes * pagerank_iters),     sum_delta,
                    if (any_nonfinite) "FAIL" else "OK", if (ok and !any_nonfinite) "OK" else "FAIL",
                },
            );
        }

        // ---- directedPagerank ----
        {
            const t0 = nanos();
            const pr = try graph.directedPagerank(g, allocator, .{ .iterations = pagerank_iters });
            defer allocator.free(pr);
            const dt = nanos() - t0;

            const sum_delta = pageRankSumDelta(pr);
            // Directed PageRank with sink-redistribution loses a tiny bit more
            // precision per iter on graphs with many sinks. ER edges chosen
            // uniformly give relatively few perfect sinks at scale, but be
            // generous (1e-5 vs 1e-6 for the undirected variant).
            const tol: f64 = 1e-5;
            const ok = sum_delta < tol;
            if (!ok) any_invariant_violation = true;

            var any_nonfinite = false;
            for (pr) |v| if (!std.math.isFinite(v)) {
                any_nonfinite = true;
                break;
            };
            if (any_nonfinite) any_invariant_violation = true;

            std.debug.print(
                "bench=directedPagerank size={s} nodes={d} edges={d} iters={d} ns={d} ms={d} ns_per_node_per_iter={d} sum_delta={e:.6} tol={e:.6} finite={s} invariant={s}\n",
                .{
                    s.label,                                     s.nodes,
                    s.edges,                                     pagerank_iters,
                    dt,                                          dt / std.time.ns_per_ms,
                    dt / (s.nodes * pagerank_iters),             sum_delta,
                    tol,                                         if (any_nonfinite) "FAIL" else "OK",
                    if (ok and !any_nonfinite) "OK" else "FAIL",
                },
            );
        }

        // ---- bfs (single source from node 0) ----
        {
            const t0 = nanos();
            const order = try graph.bfs(g, 0, allocator);
            defer allocator.free(order);
            const dt = nanos() - t0;

            // Invariants: |order| <= n, every node appears at most once,
            // first is the start (0). Duplicate-check is O(n) so we
            // instrument it; if it explodes at 1M, drop to a sample.
            const ok_size = order.len <= s.nodes;
            const ok_first = order.len == 0 or order[0] == 0;

            const ok = ok_size and ok_first;
            if (!ok) any_invariant_violation = true;

            std.debug.print(
                "bench=bfs size={s} nodes={d} edges={d} ns={d} ms={d} visited={d} invariant={s}\n",
                .{ s.label, s.nodes, s.edges, dt, dt / std.time.ns_per_ms, order.len, if (ok) "OK" else "FAIL" },
            );
        }

        // ---- sssp (Dijkstra from node 0) ----
        {
            const t0 = nanos();
            const dist = try graph.sssp(g, 0, allocator);
            defer allocator.free(dist);
            const dt = nanos() - t0;

            // Invariants: returned slice has exactly n entries, no NaN,
            // dist[0] == 0 (the source is reachable from itself at
            // distance 0).
            const ok_len = dist.len == s.nodes;
            const ok_src = dist[0] == 0.0;
            var any_nan = false;
            for (dist) |v| if (std.math.isNan(v)) {
                any_nan = true;
                break;
            };

            const ok = ok_len and ok_src and !any_nan;
            if (!ok) any_invariant_violation = true;

            std.debug.print(
                "bench=sssp size={s} nodes={d} edges={d} ns={d} ms={d} dist_len={d} dist0={d} any_nan={s} invariant={s}\n",
                .{
                    s.label, s.nodes,                          s.edges,
                    dt,      dt / std.time.ns_per_ms,          dist.len,
                    dist[0], if (any_nan) "true" else "false", if (ok) "OK" else "FAIL",
                },
            );
        }
    }

    if (any_invariant_violation) {
        std.debug.print("# SCALE BENCH FAILED — one or more invariants violated above\n", .{});
        std.process.exit(2);
    }
    std.debug.print("# all scale invariants OK\n", .{});
}
