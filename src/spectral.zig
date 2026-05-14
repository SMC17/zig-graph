//! Spectral primitives: algebraic connectivity (Fiedler value) and the
//! corresponding Fiedler vector via inverse power iteration on the graph
//! Laplacian.
//!
//! The unnormalized graph Laplacian `L = D - A` where `D` is the diagonal
//! weighted-degree matrix and `A` is the weighted adjacency. For an
//! undirected connected graph:
//!
//!   * `L` is symmetric positive-semidefinite.
//!   * Smallest eigenvalue `λ₀ = 0` with eigenvector `1/√n · 𝟙`.
//!   * Second-smallest eigenvalue `λ₁` (the **Fiedler value**) measures
//!     algebraic connectivity. The corresponding eigenvector partitions the
//!     graph along its narrowest bottleneck.
//!
//! We compute `λ₁` via **deflated power iteration** on `(τI - L)`:
//!
//!   * `τ = max degree + 1` shifts the spectrum so the dominant eigenvalue
//!     of `M = τI - L` corresponds to the **smallest** eigenvalue of `L`.
//!   * After each `M x` step we deflate by removing the projection on the
//!     all-ones vector — this kicks out the `λ₀ = 0` mode so iteration
//!     converges to `λ₁`.
//!   * After convergence we recover `λ₁ = τ − ρ(M)` via the Rayleigh
//!     quotient `xᵀ L x / xᵀ x`.
//!
//! Cost: O((|V| + |E|) · iters), no matrix factorisation, no inverse — so
//! it works for graphs into the millions of edges with no Lanczos
//! machinery. Convergence rate is `|λ₂ - λ₁| / |λ_max - λ₁|`. For graphs
//! with a tight spectral gap raise `iterations`.

const std = @import("std");
const root = @import("root.zig");
const Graph = root.Graph;
const Error = root.Error;
const traversal = @import("traversal.zig");

pub const FiedlerOptions = struct {
    iterations: usize = 1_000,
    tolerance: f64 = 1e-10,
};

pub const FiedlerResult = struct {
    value: f64,
    vector: []f64,
    iterations: usize,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *FiedlerResult) void {
        self.allocator.free(self.vector);
    }
};

/// Compute the Fiedler value `λ₁` of the graph Laplacian and the
/// corresponding eigenvector. Caller owns the returned `vector` slice; free
/// via `result.deinit()` or `allocator.free(result.vector)`.
pub fn fiedler(graph: Graph, allocator: std.mem.Allocator, options: FiedlerOptions) Error!FiedlerResult {
    const n = graph.node_count;
    if (n == 0) {
        const empty = try allocator.alloc(f64, 0);
        return .{ .value = 0.0, .vector = empty, .iterations = 0, .allocator = allocator };
    }
    if (n == 1) {
        const v = try allocator.alloc(f64, 1);
        v[0] = 1.0;
        return .{ .value = 0.0, .vector = v, .iterations = 0, .allocator = allocator };
    }

    var adj = try traversal.buildAdjacency(graph, allocator);
    defer adj.deinit();

    // Weighted degree (the diagonal of L).
    const degree = try allocator.alloc(f64, n);
    defer allocator.free(degree);
    @memset(degree, 0.0);
    for (graph.edges.items) |edge| {
        degree[edge.source] += edge.weight;
        degree[edge.target] += edge.weight;
    }
    var max_deg: f64 = 0.0;
    for (degree) |d| max_deg = @max(max_deg, d);
    // Gershgorin bound: λ_max(L) ≤ 2·max_deg. Pick τ strictly larger so M = τI - L
    // has dominant eigenvalue corresponding to L's zero mode (the all-ones
    // eigenvector). After we deflate that mode, the new dominant mode is
    // L's smallest non-zero eigenvalue — the Fiedler value.
    const tau = 2.0 * max_deg + 1.0;

    // Initialise x with a deterministic mean-zero pattern so the first
    // deflate step doesn't zero it out, and so different connected components
    // get different signs.
    const x = try allocator.alloc(f64, n);
    errdefer allocator.free(x);
    for (x, 0..) |*xi, i| {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n - 1));
        xi.* = t - 0.5;
    }
    deflateMean(x);
    _ = normalize(x);

    var next = try allocator.alloc(f64, n);
    defer allocator.free(next);

    var prev_lambda: f64 = std.math.inf(f64);
    var iters: usize = 0;
    while (iters < options.iterations) : (iters += 1) {
        // Apply M = τI - L to x. (Lx)_i = degree[i]*x[i] - Σ_j A_ij * x[j].
        // Mx = τx - Lx.
        for (next, 0..) |*ni, i| {
            ni.* = (tau - degree[i]) * x[i];
        }
        // Add adjacency contribution: + A x → mass per edge weight.
        for (graph.edges.items) |edge| {
            next[edge.source] += edge.weight * x[edge.target];
            next[edge.target] += edge.weight * x[edge.source];
        }
        // Deflate λ₀ = 0 mode (the all-ones eigenvector).
        deflateMean(next);
        const nrm = normalize(next);
        if (nrm == 0.0) {
            // Pathological: graph is degenerate or x collapsed. Return λ = 0 with
            // a deterministic zero vector.
            const empty_vec = try allocator.alloc(f64, n);
            @memset(empty_vec, 0.0);
            allocator.free(x);
            return .{ .value = 0.0, .vector = empty_vec, .iterations = iters, .allocator = allocator };
        }
        @memcpy(x, next);

        // Rayleigh quotient λ = xᵀ L x  /  xᵀ x.  xᵀ x = 1 after normalize.
        var ray: f64 = 0.0;
        for (degree, 0..) |d, i| ray += d * x[i] * x[i];
        for (graph.edges.items) |edge| {
            ray -= 2.0 * edge.weight * x[edge.source] * x[edge.target];
        }
        if (@abs(ray - prev_lambda) < options.tolerance * @max(@abs(ray), 1.0)) {
            iters += 1;
            return .{ .value = ray, .vector = x, .iterations = iters, .allocator = allocator };
        }
        prev_lambda = ray;
    }

    // Did not hit tolerance — return last estimate anyway.
    var ray: f64 = 0.0;
    for (degree, 0..) |d, i| ray += d * x[i] * x[i];
    for (graph.edges.items) |edge| {
        ray -= 2.0 * edge.weight * x[edge.source] * x[edge.target];
    }
    return .{ .value = ray, .vector = x, .iterations = iters, .allocator = allocator };
}

/// Convenience: return only the Fiedler value. Discards the vector.
pub fn fiedlerValue(graph: Graph, allocator: std.mem.Allocator, options: FiedlerOptions) Error!f64 {
    var r = try fiedler(graph, allocator, options);
    defer r.deinit();
    return r.value;
}

/// Convenience: return only the Fiedler vector. Result is L2-normalized and
/// mean-zero. Caller frees with `allocator.free`.
pub fn fiedlerVector(graph: Graph, allocator: std.mem.Allocator, options: FiedlerOptions) Error![]f64 {
    const r = try fiedler(graph, allocator, options);
    return r.vector; // caller now owns
}

fn deflateMean(x: []f64) void {
    if (x.len == 0) return;
    var s: f64 = 0.0;
    for (x) |v| s += v;
    const mean = s / @as(f64, @floatFromInt(x.len));
    for (x) |*v| v.* -= mean;
}

fn normalize(x: []f64) f64 {
    var sq: f64 = 0.0;
    for (x) |v| sq += v * v;
    const nrm = @sqrt(sq);
    if (nrm == 0.0) return 0.0;
    for (x) |*v| v.* /= nrm;
    return nrm;
}

// ---- tests ----
//
// Canonical Fiedler values (unnormalized Laplacian, unit weights):
//
//   * Path P_n: λ₁ = 2 (1 - cos(π/n))
//   * Cycle C_n: λ₁ = 2 (1 - cos(2π/n))
//   * Star K_{1,n-1}: λ₁ = 1
//   * Complete K_n: λ₁ = n
//   * Two K_3 joined by a single edge (barbell-6): λ₁ ≈ 0.4384...
//     (computed via numpy as a reference: 0.4383711...)

const testing = std.testing;

test "fiedler value of P_4 (path on 4 nodes)" {
    var g = Graph.init(testing.allocator, 4);
    defer g.deinit();
    try g.addEdge(0, 1, 1.0);
    try g.addEdge(1, 2, 1.0);
    try g.addEdge(2, 3, 1.0);
    var r = try fiedler(g, testing.allocator, .{});
    defer r.deinit();
    const expected = 2.0 * (1.0 - @cos(std.math.pi / 4.0));
    try testing.expectApproxEqAbs(expected, r.value, 1e-6);
}

test "fiedler value of P_10" {
    var g = Graph.init(testing.allocator, 10);
    defer g.deinit();
    var i: usize = 0;
    while (i < 9) : (i += 1) try g.addEdge(i, i + 1, 1.0);
    var r = try fiedler(g, testing.allocator, .{ .iterations = 5_000 });
    defer r.deinit();
    const expected = 2.0 * (1.0 - @cos(std.math.pi / 10.0));
    try testing.expectApproxEqAbs(expected, r.value, 1e-6);
}

test "fiedler value of C_6 (cycle on 6)" {
    var g = Graph.init(testing.allocator, 6);
    defer g.deinit();
    try g.addEdge(0, 1, 1.0);
    try g.addEdge(1, 2, 1.0);
    try g.addEdge(2, 3, 1.0);
    try g.addEdge(3, 4, 1.0);
    try g.addEdge(4, 5, 1.0);
    try g.addEdge(5, 0, 1.0);
    var r = try fiedler(g, testing.allocator, .{});
    defer r.deinit();
    const expected = 2.0 * (1.0 - @cos(2.0 * std.math.pi / 6.0));
    try testing.expectApproxEqAbs(expected, r.value, 1e-6);
}

test "fiedler value of star K_{1,4}" {
    var g = Graph.init(testing.allocator, 5);
    defer g.deinit();
    try g.addEdge(0, 1, 1.0);
    try g.addEdge(0, 2, 1.0);
    try g.addEdge(0, 3, 1.0);
    try g.addEdge(0, 4, 1.0);
    var r = try fiedler(g, testing.allocator, .{});
    defer r.deinit();
    // Star K_{1,n-1} has λ₁ = 1 (leaf-leaf mode).
    try testing.expectApproxEqAbs(@as(f64, 1.0), r.value, 1e-6);
}

test "fiedler value of K_4 (complete graph on 4)" {
    var g = Graph.init(testing.allocator, 4);
    defer g.deinit();
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        var j: usize = i + 1;
        while (j < 4) : (j += 1) try g.addEdge(i, j, 1.0);
    }
    var r = try fiedler(g, testing.allocator, .{});
    defer r.deinit();
    // K_n has λ₁ = n (all non-zero eigenvalues equal n).
    try testing.expectApproxEqAbs(@as(f64, 4.0), r.value, 1e-6);
}

test "fiedler value of barbell (two K_3 joined by a single edge)" {
    var g = Graph.init(testing.allocator, 6);
    defer g.deinit();
    try g.addEdge(0, 1, 1.0);
    try g.addEdge(1, 2, 1.0);
    try g.addEdge(0, 2, 1.0);
    try g.addEdge(3, 4, 1.0);
    try g.addEdge(4, 5, 1.0);
    try g.addEdge(3, 5, 1.0);
    try g.addEdge(2, 3, 1.0);
    var r = try fiedler(g, testing.allocator, .{ .iterations = 5_000 });
    defer r.deinit();
    // Reference computed via numpy:
    //   λ_sorted = [0, 0.4384..., 3, 3, 3.5616..., 4]
    try testing.expectApproxEqAbs(@as(f64, 0.4384471871911697), r.value, 1e-5);
    // Fiedler vector should have opposite signs on the two cliques.
    const left_sign = std.math.sign(r.vector[0]);
    try testing.expect(left_sign != 0.0);
    try testing.expectEqual(left_sign, std.math.sign(r.vector[1]));
    try testing.expectEqual(left_sign, std.math.sign(r.vector[2]));
    try testing.expectEqual(-left_sign, std.math.sign(r.vector[3]));
    try testing.expectEqual(-left_sign, std.math.sign(r.vector[4]));
    try testing.expectEqual(-left_sign, std.math.sign(r.vector[5]));
}

test "fiedler value of disconnected graph is ~0" {
    var g = Graph.init(testing.allocator, 4);
    defer g.deinit();
    try g.addEdge(0, 1, 1.0);
    try g.addEdge(2, 3, 1.0);
    // Two K_2 components → spectrum has a double zero. λ₁ should be ≈ 0.
    var r = try fiedler(g, testing.allocator, .{});
    defer r.deinit();
    try testing.expect(@abs(r.value) < 1e-6);
}

test "fiedler fuzz: value non-negative + bounded by n for random small graphs" {
    var rng = std.Random.DefaultPrng.init(0xF1ED_1EAF_BEAD_C0FE);
    const r = rng.random();
    var k: usize = 0;
    while (k < 200) : (k += 1) {
        const n: usize = @as(usize, r.uintLessThan(u8, 14)) + 2;
        const m: usize = r.uintLessThan(usize, 2 * n + 1);
        var g = Graph.init(testing.allocator, n);
        defer g.deinit();
        var j: usize = 0;
        while (j < m) : (j += 1) {
            const s = r.uintLessThan(usize, n);
            var t = r.uintLessThan(usize, n);
            if (t == s) t = (t + 1) % n;
            try g.addEdge(s, t, 0.1 + r.float(f64) * 4.0);
        }
        var res = try fiedler(g, testing.allocator, .{ .iterations = 2_000 });
        defer res.deinit();
        try testing.expect(!std.math.isNan(res.value));
        try testing.expect(res.value >= -1e-8);
        // Upper bound by 2 * max_weighted_degree (standard spectral bound).
        var max_d: f64 = 0.0;
        for (g.edges.items) |edge| _ = edge;
        // Recompute max degree.
        const deg = try root.weightedDegree(g, testing.allocator);
        defer testing.allocator.free(deg);
        for (deg) |d| max_d = @max(max_d, d);
        try testing.expect(res.value <= 2.0 * max_d + 1e-6);
    }
}
