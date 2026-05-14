//! Sparse graph primitives, spectral, centrality, community and traversal
//! algorithms.
//!
//! A `Graph` is a count of nodes (IDs are `0..node_count`) plus an edge list
//! `{source, target, weight}`. Edges are treated as **undirected** — each
//! algorithm walks both endpoints symmetrically. To model a directed graph,
//! callers add edges in only one direction and interpret the results
//! accordingly; the library does not enforce a direction.
//!
//! Node payload (labels, geographic data, type tags, etc.) is **not** part of
//! the graph. Callers keep their own arrays indexed by node ID for whatever
//! side data they need. This keeps the library composable with any data model.
//!
//! ## Algorithms (v0.1.0)
//!
//! - `weightedDegree` — sum of incident edge weights per node
//! - `eigenvectorCentrality` — power iteration on the (weighted) adjacency
//!   matrix, returning the normalized principal eigenvector
//! - `pagerank` — undirected PageRank with damping, dangling-node handling
//!   (uniform redistribution)
//! - `cutEdges` — count of edges crossing a node partition
//! - `conductance` — standard graph conductance for a subset:
//!   `cut(S) / min(vol(S), vol(V\S))`
//!
//! All algorithms allocate result arrays through the caller-provided
//! allocator and return ownership to the caller (free with `allocator.free`).

const std = @import("std");

const traversal = @import("traversal.zig");
const centrality = @import("centrality.zig");
const spectral = @import("spectral.zig");
const community = @import("community.zig");

// ---- traversal re-exports ----

pub const bfs = traversal.bfs;
pub const dfs = traversal.dfs;
pub const sssp = traversal.sssp;
pub const bfsPath = traversal.bfsPath;
pub const Neighbor = traversal.Neighbor;
pub const Adjacency = traversal.Adjacency;
pub const buildAdjacency = traversal.buildAdjacency;
pub const buildDirectedAdjacency = traversal.buildDirectedAdjacency;

// ---- centrality re-exports ----

pub const BetweennessOptions = centrality.BetweennessOptions;
pub const betweennessCentrality = centrality.betweennessCentrality;
pub const closenessCentrality = centrality.closenessCentrality;

// ---- spectral re-exports ----

pub const FiedlerOptions = spectral.FiedlerOptions;
pub const FiedlerResult = spectral.FiedlerResult;
pub const fiedler = spectral.fiedler;
pub const fiedlerValue = spectral.fiedlerValue;
pub const fiedlerVector = spectral.fiedlerVector;

// ---- community re-exports ----

pub const LouvainOptions = community.LouvainOptions;
pub const LouvainResult = community.LouvainResult;
pub const louvain = community.louvain;
pub const modularity = community.modularity;

pub const Edge = struct {
    source: usize,
    target: usize,
    weight: f64 = 1.0,
};

pub const Error = error{
    NodeIndexOutOfRange,
    PartitionSizeMismatch,
} || std.mem.Allocator.Error;

pub const Graph = struct {
    node_count: usize,
    edges: std.ArrayList(Edge),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, node_count: usize) Graph {
        return .{
            .node_count = node_count,
            .edges = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Graph) void {
        self.edges.deinit(self.allocator);
    }

    /// Append an edge. Both `source` and `target` must be `< node_count`.
    pub fn addEdge(self: *Graph, source: usize, target: usize, weight: f64) Error!void {
        if (source >= self.node_count or target >= self.node_count) {
            return Error.NodeIndexOutOfRange;
        }
        try self.edges.append(self.allocator, .{
            .source = source,
            .target = target,
            .weight = weight,
        });
    }
};

/// Compute the weighted degree of every node treating edges as undirected.
/// Returns a slice owned by the caller; free with `allocator.free`.
pub fn weightedDegree(graph: Graph, allocator: std.mem.Allocator) Error![]f64 {
    const out = try allocator.alloc(f64, graph.node_count);
    @memset(out, 0.0);
    for (graph.edges.items) |edge| {
        out[edge.source] += edge.weight;
        out[edge.target] += edge.weight;
    }
    return out;
}

pub const EigenvectorOptions = struct {
    iterations: usize = 32,
};

/// Compute the normalized principal eigenvector of the weighted adjacency
/// matrix via power iteration. Result is L2-normalized.
///
/// For a graph with zero edges or where iteration converges to the zero
/// vector, the returned slice is all zeros.
pub fn eigenvectorCentrality(
    graph: Graph,
    allocator: std.mem.Allocator,
    options: EigenvectorOptions,
) Error![]f64 {
    const n = graph.node_count;
    const result = try allocator.alloc(f64, n);
    errdefer allocator.free(result);

    if (n == 0) return result;

    const initial = 1.0 / @sqrt(@as(f64, @floatFromInt(n)));
    @memset(result, initial);

    var next = try allocator.alloc(f64, n);
    defer allocator.free(next);

    var i: usize = 0;
    while (i < options.iterations) : (i += 1) {
        @memset(next, 0.0);
        for (graph.edges.items) |edge| {
            next[edge.source] += result[edge.target] * edge.weight;
            next[edge.target] += result[edge.source] * edge.weight;
        }
        var norm_sq: f64 = 0.0;
        for (next) |v| norm_sq += v * v;
        const norm = @sqrt(norm_sq);
        if (norm == 0.0) {
            @memset(result, 0.0);
            return result;
        }
        for (next, 0..) |v, idx| result[idx] = v / norm;
    }
    return result;
}

pub const PageRankOptions = struct {
    damping: f64 = 0.85,
    iterations: usize = 40,
};

/// Undirected PageRank. Each edge contributes mass in both directions weighted
/// by `edge.weight / degree(endpoint)`. Dangling nodes (zero weighted degree)
/// have their rank redistributed uniformly across all nodes per iteration.
///
/// Ranks sum to approximately 1.0 modulo floating-point error.
pub fn pagerank(
    graph: Graph,
    allocator: std.mem.Allocator,
    options: PageRankOptions,
) Error![]f64 {
    const n = graph.node_count;
    const result = try allocator.alloc(f64, n);
    errdefer allocator.free(result);

    if (n == 0) return result;

    const degree = try weightedDegree(graph, allocator);
    defer allocator.free(degree);

    var next = try allocator.alloc(f64, n);
    defer allocator.free(next);

    const base = 1.0 / @as(f64, @floatFromInt(n));
    @memset(result, base);

    var i: usize = 0;
    while (i < options.iterations) : (i += 1) {
        @memset(next, (1.0 - options.damping) * base);

        // Distribute dangling-node mass uniformly.
        for (result, 0..) |value, idx| {
            if (degree[idx] == 0.0) {
                const share = options.damping * value * base;
                for (next) |*target| target.* += share;
            }
        }

        for (graph.edges.items) |edge| {
            if (degree[edge.source] > 0.0) {
                next[edge.target] += options.damping * result[edge.source] *
                    edge.weight / degree[edge.source];
            }
            if (degree[edge.target] > 0.0) {
                next[edge.source] += options.damping * result[edge.target] *
                    edge.weight / degree[edge.target];
            }
        }
        @memcpy(result, next);
    }
    return result;
}

/// Number of edges whose endpoints have different partition labels.
/// `partition.len` must equal `graph.node_count`.
pub fn cutEdges(graph: Graph, partition: []const u32) Error!usize {
    if (partition.len != graph.node_count) return Error.PartitionSizeMismatch;
    var count: usize = 0;
    for (graph.edges.items) |edge| {
        if (partition[edge.source] != partition[edge.target]) count += 1;
    }
    return count;
}

/// Standard graph conductance for the subset `S = { i : partition[i] == set }`.
///
/// Defined as `cut(S, V\S) / min(vol(S), vol(V\S))` where `vol(X)` is the
/// sum of weighted degrees of nodes in `X`, counting each edge's endpoint
/// degree. Returns `0.0` if either side has zero volume.
pub fn conductance(
    graph: Graph,
    allocator: std.mem.Allocator,
    partition: []const u32,
    set: u32,
) Error!f64 {
    if (partition.len != graph.node_count) return Error.PartitionSizeMismatch;

    const degree = try weightedDegree(graph, allocator);
    defer allocator.free(degree);

    var vol_s: f64 = 0.0;
    var vol_complement: f64 = 0.0;
    for (partition, 0..) |label, idx| {
        if (label == set) vol_s += degree[idx] else vol_complement += degree[idx];
    }
    if (vol_s == 0.0 or vol_complement == 0.0) return 0.0;

    var cut_weight: f64 = 0.0;
    for (graph.edges.items) |edge| {
        const s_in = partition[edge.source] == set;
        const t_in = partition[edge.target] == set;
        if (s_in != t_in) cut_weight += edge.weight;
    }
    const denom = @min(vol_s, vol_complement);
    return cut_weight / denom;
}

// ---- tests ----

comptime {
    _ = traversal;
    _ = centrality;
    _ = spectral;
    _ = community;
}

const testing = std.testing;

test "empty graph allocates zero-length result arrays cleanly" {
    var g = Graph.init(testing.allocator, 0);
    defer g.deinit();

    const deg = try weightedDegree(g, testing.allocator);
    defer testing.allocator.free(deg);
    try testing.expectEqual(@as(usize, 0), deg.len);

    const ec = try eigenvectorCentrality(g, testing.allocator, .{});
    defer testing.allocator.free(ec);
    try testing.expectEqual(@as(usize, 0), ec.len);

    const pr = try pagerank(g, testing.allocator, .{});
    defer testing.allocator.free(pr);
    try testing.expectEqual(@as(usize, 0), pr.len);
}

test "addEdge rejects out-of-range indices" {
    var g = Graph.init(testing.allocator, 3);
    defer g.deinit();
    try testing.expectError(Error.NodeIndexOutOfRange, g.addEdge(3, 0, 1.0));
    try testing.expectError(Error.NodeIndexOutOfRange, g.addEdge(0, 3, 1.0));
}

test "weightedDegree on simple triangle" {
    var g = Graph.init(testing.allocator, 3);
    defer g.deinit();
    try g.addEdge(0, 1, 2.0);
    try g.addEdge(1, 2, 3.0);
    try g.addEdge(0, 2, 4.0);

    const deg = try weightedDegree(g, testing.allocator);
    defer testing.allocator.free(deg);

    try testing.expectApproxEqAbs(@as(f64, 6.0), deg[0], 1e-9); // 2 + 4
    try testing.expectApproxEqAbs(@as(f64, 5.0), deg[1], 1e-9); // 2 + 3
    try testing.expectApproxEqAbs(@as(f64, 7.0), deg[2], 1e-9); // 3 + 4
}

test "eigenvectorCentrality on regular triangle is uniform" {
    var g = Graph.init(testing.allocator, 3);
    defer g.deinit();
    try g.addEdge(0, 1, 1.0);
    try g.addEdge(1, 2, 1.0);
    try g.addEdge(0, 2, 1.0);

    const ec = try eigenvectorCentrality(g, testing.allocator, .{});
    defer testing.allocator.free(ec);

    // K3 has eigenvector centrality (1/√3, 1/√3, 1/√3).
    const expected = 1.0 / @sqrt(@as(f64, 3.0));
    for (ec) |v| try testing.expectApproxEqAbs(expected, v, 1e-6);
}

test "eigenvectorCentrality on star graph: center dominates" {
    var g = Graph.init(testing.allocator, 4);
    defer g.deinit();
    try g.addEdge(0, 1, 1.0);
    try g.addEdge(0, 2, 1.0);
    try g.addEdge(0, 3, 1.0);

    const ec = try eigenvectorCentrality(g, testing.allocator, .{});
    defer testing.allocator.free(ec);

    // Star center has the highest centrality; leaves are equal and lower.
    try testing.expect(ec[0] > ec[1]);
    try testing.expectApproxEqAbs(ec[1], ec[2], 1e-9);
    try testing.expectApproxEqAbs(ec[2], ec[3], 1e-9);
}

test "eigenvectorCentrality on disconnected graph returns zeros (norm-0 branch)" {
    var g = Graph.init(testing.allocator, 4);
    defer g.deinit();
    // No edges → adjacency * x = 0 → norm = 0 → result clamped to zeros.
    const ec = try eigenvectorCentrality(g, testing.allocator, .{});
    defer testing.allocator.free(ec);
    for (ec) |v| try testing.expectEqual(@as(f64, 0.0), v);
}

test "pagerank sums to approximately 1.0" {
    var g = Graph.init(testing.allocator, 5);
    defer g.deinit();
    try g.addEdge(0, 1, 1.0);
    try g.addEdge(1, 2, 1.0);
    try g.addEdge(2, 3, 1.0);
    try g.addEdge(3, 4, 1.0);
    try g.addEdge(4, 0, 1.0);

    const pr = try pagerank(g, testing.allocator, .{});
    defer testing.allocator.free(pr);

    var total: f64 = 0.0;
    for (pr) |v| total += v;
    try testing.expectApproxEqAbs(@as(f64, 1.0), total, 1e-6);
}

test "pagerank on cycle is uniform" {
    var g = Graph.init(testing.allocator, 4);
    defer g.deinit();
    try g.addEdge(0, 1, 1.0);
    try g.addEdge(1, 2, 1.0);
    try g.addEdge(2, 3, 1.0);
    try g.addEdge(3, 0, 1.0);

    const pr = try pagerank(g, testing.allocator, .{});
    defer testing.allocator.free(pr);

    const expected = 1.0 / 4.0;
    for (pr) |v| try testing.expectApproxEqAbs(expected, v, 1e-4);
}

test "pagerank on star: center has highest rank" {
    var g = Graph.init(testing.allocator, 5);
    defer g.deinit();
    try g.addEdge(0, 1, 1.0);
    try g.addEdge(0, 2, 1.0);
    try g.addEdge(0, 3, 1.0);
    try g.addEdge(0, 4, 1.0);

    const pr = try pagerank(g, testing.allocator, .{});
    defer testing.allocator.free(pr);

    for ([_]usize{ 1, 2, 3, 4 }) |leaf| {
        try testing.expect(pr[0] > pr[leaf]);
    }
    // Leaves are symmetric.
    try testing.expectApproxEqAbs(pr[1], pr[2], 1e-6);
    try testing.expectApproxEqAbs(pr[2], pr[3], 1e-6);
    try testing.expectApproxEqAbs(pr[3], pr[4], 1e-6);
}

test "pagerank with dangling node redistributes mass" {
    var g = Graph.init(testing.allocator, 3);
    defer g.deinit();
    // Node 2 has no incident edges (dangling).
    try g.addEdge(0, 1, 1.0);

    const pr = try pagerank(g, testing.allocator, .{});
    defer testing.allocator.free(pr);

    var total: f64 = 0.0;
    for (pr) |v| total += v;
    try testing.expectApproxEqAbs(@as(f64, 1.0), total, 1e-6);
    try testing.expect(pr[2] > 0.0);
}

test "cutEdges and conductance on a barbell graph" {
    // Two triangles connected by a single bridge edge:
    // 0-1, 1-2, 0-2  (triangle A)
    // 3-4, 4-5, 3-5  (triangle B)
    // 2-3            (bridge)
    var g = Graph.init(testing.allocator, 6);
    defer g.deinit();
    try g.addEdge(0, 1, 1.0);
    try g.addEdge(1, 2, 1.0);
    try g.addEdge(0, 2, 1.0);
    try g.addEdge(3, 4, 1.0);
    try g.addEdge(4, 5, 1.0);
    try g.addEdge(3, 5, 1.0);
    try g.addEdge(2, 3, 1.0);

    const partition = [_]u32{ 0, 0, 0, 1, 1, 1 };
    const cut = try cutEdges(g, &partition);
    try testing.expectEqual(@as(usize, 1), cut);

    const cond = try conductance(g, testing.allocator, &partition, 0);
    // vol(A) = 2+2+3 = 7 (node 2 has bridge edge too). vol(B) = 3+2+2 = 7.
    // cut_weight = 1. min(vol_s, vol_c) = 7. conductance = 1/7.
    try testing.expectApproxEqAbs(@as(f64, 1.0 / 7.0), cond, 1e-9);
}

test "cutEdges rejects partition size mismatch" {
    var g = Graph.init(testing.allocator, 3);
    defer g.deinit();
    const wrong_size = [_]u32{ 0, 1 };
    try testing.expectError(Error.PartitionSizeMismatch, cutEdges(g, &wrong_size));
}

test "conductance is zero when one side is empty" {
    var g = Graph.init(testing.allocator, 3);
    defer g.deinit();
    try g.addEdge(0, 1, 1.0);
    try g.addEdge(1, 2, 1.0);

    const all_one = [_]u32{ 0, 0, 0 };
    const cond = try conductance(g, testing.allocator, &all_one, 0);
    try testing.expectEqual(@as(f64, 0.0), cond);
}

test "eigenvectorCentrality on heavy edge biases endpoints" {
    var g = Graph.init(testing.allocator, 3);
    defer g.deinit();
    try g.addEdge(0, 1, 100.0); // heavy
    try g.addEdge(1, 2, 1.0);

    const ec = try eigenvectorCentrality(g, testing.allocator, .{});
    defer testing.allocator.free(ec);

    // Endpoints of the heavy edge dominate.
    try testing.expect(ec[0] > ec[2]);
    try testing.expect(ec[1] > ec[2]);
}

test "weights influence pagerank ordering" {
    var g = Graph.init(testing.allocator, 3);
    defer g.deinit();
    try g.addEdge(0, 1, 10.0);
    try g.addEdge(0, 2, 1.0);

    const pr = try pagerank(g, testing.allocator, .{});
    defer testing.allocator.free(pr);

    // Node 1 should receive more mass than node 2 because the edge from
    // node 0 to node 1 carries more weight.
    try testing.expect(pr[1] > pr[2]);
}

// ---- fuzz tests ----
//
// Random-graph invariants. Each iteration builds an Erdős–Rényi-style graph
// with a random node count and a random edge count, then asserts the
// algorithm-level invariants that any valid implementation must satisfy:
//
//   * `eigenvectorCentrality` returns only finite values (no NaN, no Inf)
//   * `pagerank` mass sums to ~1.0 (within 1e-6, accounting for f64 round-off)
//   * `cutEdges` is non-negative for any partition
//
// 10 000 iterations is enough that any panic, leak, NaN, or sign error in the
// numerical paths shows up within a few seconds. The PRNG seed is fixed so
// failures are reproducible.

test "fuzz: random graphs preserve centrality / pagerank / cut invariants" {
    const fuzz_iters: usize = 10_000;
    var rng = std.Random.DefaultPrng.init(0x60A1_BEEF_DEAD_C0DE);
    const r = rng.random();

    var i: usize = 0;
    while (i < fuzz_iters) : (i += 1) {
        // 1..64 nodes, 0..(2*n) edges. Small enough to keep the fuzz fast,
        // wide enough to exercise dangling nodes (m=0), self-loops, parallel
        // edges, and dense regions.
        const n: usize = @as(usize, r.uintLessThan(u8, 64)) + 1;
        const m: usize = r.uintLessThan(usize, 2 * n + 1);

        var g = Graph.init(testing.allocator, n);
        defer g.deinit();

        var j: usize = 0;
        while (j < m) : (j += 1) {
            const src = r.uintLessThan(usize, n);
            const dst = r.uintLessThan(usize, n);
            // Random weight in [0.1, 5.0] — avoid zero so degree calc is meaningful.
            const w = 0.1 + r.float(f64) * 4.9;
            try g.addEdge(src, dst, w);
        }

        // Invariant 1: eigenvector centrality is finite.
        const ec = try eigenvectorCentrality(g, testing.allocator, .{});
        defer testing.allocator.free(ec);
        for (ec) |v| {
            try testing.expect(!std.math.isNan(v));
            try testing.expect(!std.math.isInf(v));
        }

        // Invariant 2: PageRank sums to ~1.0.
        const pr = try pagerank(g, testing.allocator, .{});
        defer testing.allocator.free(pr);
        var total: f64 = 0.0;
        for (pr) |v| {
            try testing.expect(!std.math.isNan(v));
            try testing.expect(!std.math.isInf(v));
            try testing.expect(v >= -1e-12); // tiny negative round-off is tolerated
            total += v;
        }
        try testing.expectApproxEqAbs(@as(f64, 1.0), total, 1e-6);

        // Invariant 3: cutEdges is non-negative for any partition.
        const partition = try testing.allocator.alloc(u32, n);
        defer testing.allocator.free(partition);
        for (partition) |*p| p.* = r.uintLessThan(u32, 2);
        const cut = try cutEdges(g, partition);
        try testing.expect(cut <= m); // at most every edge crosses
        // `cut` is `usize` so >= 0 is implicit, but assert m-bounded for sanity.
    }
}
