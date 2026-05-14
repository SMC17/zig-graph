//! Community detection via the Louvain method (Blondel, Guillaume, Lambiotte,
//! Lefebvre 2008, "Fast unfolding of communities in large networks").
//!
//! Louvain greedily maximises modularity in two repeated phases:
//!
//!   1. **Local-move phase.** For each node `v`, evaluate the modularity
//!      gain of moving `v` from its current community into the community of
//!      each neighbour. Move `v` into the community with the largest
//!      positive gain. Repeat until no node moves.
//!   2. **Aggregation phase.** Build a new graph whose nodes are the
//!      communities of the previous level; inter-community edge weights sum
//!      to the new graph's edge weights, intra-community sums become
//!      self-loops. Restart phase 1 on the aggregated graph.
//!
//! The algorithm halts when a full phase-1 pass produces no improvement.
//!
//! Modularity (Newman):
//!
//!   Q = (1 / 2m) Σ_ij [A_ij − k_i k_j / 2m] · δ(c_i, c_j)
//!
//! where `m = Σ_e w_e` is total edge weight, `k_i` is weighted degree, and
//! `δ` is 1 if nodes share a community.

const std = @import("std");
const root = @import("root.zig");
const Graph = root.Graph;
const Error = root.Error;

pub const LouvainOptions = struct {
    /// Maximum outer phases (level passes). Louvain converges quickly; this
    /// is just a safety bound.
    max_levels: usize = 32,
    /// Maximum local-move sweeps per level.
    max_sweeps_per_level: usize = 64,
    /// Local-move loop stops when the sum-modularity improvement in a sweep
    /// drops below `tolerance`.
    tolerance: f64 = 1e-7,
};

pub const LouvainResult = struct {
    /// `labels[i]` is the community id assigned to original-graph node `i`.
    /// Community ids are compacted to `0..num_communities`.
    labels: []u32,
    num_communities: usize,
    /// Modularity of the final partition.
    modularity: f64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *LouvainResult) void {
        self.allocator.free(self.labels);
    }
};

/// Run Louvain. Caller owns the result; free with `result.deinit()`.
pub fn louvain(graph: Graph, allocator: std.mem.Allocator, options: LouvainOptions) Error!LouvainResult {
    const n0 = graph.node_count;
    if (n0 == 0) {
        return .{
            .labels = try allocator.alloc(u32, 0),
            .num_communities = 0,
            .modularity = 0.0,
            .allocator = allocator,
        };
    }

    // Each level operates on a weighted aggregated graph represented as
    // adjacency-list-of-(neighbour, total_weight) pairs to absorb parallel
    // edges and self-loops cleanly.
    var current = try Aggregated.fromGraph(graph, allocator);
    defer current.deinit();

    // `partition[i]` for the *original* node i tracks which final community
    // it belongs to. We update it via the level-by-level mapping.
    const partition = try allocator.alloc(u32, n0);
    errdefer allocator.free(partition);
    for (partition, 0..) |*p, i| p.* = @as(u32, @intCast(i));

    var level: usize = 0;
    while (level < options.max_levels) : (level += 1) {
        const improved = try runLocalMove(&current, allocator, options);
        if (!improved and level > 0) break;

        // Build the dense-id remap that aggregate will use, then apply it to
        // partition so partition[i] indexes into the next super-graph cleanly.
        const remap = try allocator.alloc(u32, current.n);
        defer allocator.free(remap);
        const seen_init: i64 = -1;
        const seen = try allocator.alloc(i64, current.n);
        defer allocator.free(seen);
        for (seen) |*s| s.* = seen_init;
        var k: u32 = 0;
        for (current.community, 0..) |c, i| {
            if (seen[c] == seen_init) {
                seen[c] = @as(i64, k);
                k += 1;
            }
            remap[i] = @as(u32, @intCast(seen[c]));
        }

        for (partition) |*p| {
            // partition[i] indexes into the current super-graph; apply the
            // community label, then the dense remap.
            const super = @as(usize, p.*);
            p.* = remap[super];
        }

        if (!improved) break;
        if (k == 1) break;

        // Aggregate.
        const next = try current.aggregate(allocator);
        current.deinit();
        current = next;
    }

    const num_comm = compactInPlace(partition);
    const q = try computeModularityOnOriginal(graph, partition, allocator);

    return .{
        .labels = partition,
        .num_communities = num_comm,
        .modularity = q,
        .allocator = allocator,
    };
}

/// Modularity of an arbitrary partition over an arbitrary graph. Useful for
/// tests / external comparisons.
pub fn modularity(graph: Graph, partition: []const u32, allocator: std.mem.Allocator) Error!f64 {
    return computeModularityOnOriginal(graph, partition, allocator);
}

// ---- internals ----

/// Weighted adjacency-list representation used by Louvain. `selfloop[i]` is
/// `2 * w` where `w` is the self-loop weight at node `i` (accounted twice in
/// the modularity sum). Edge `(i, j)` with i != j is stored on both sides.
const Aggregated = struct {
    n: usize,
    neighbours: [][]NeighbourWeight,
    self_loop: []f64, // total self-loop weight (already includes both endpoints)
    deg: []f64, // weighted degree including self-loops counted twice
    community: []u32,
    allocator: std.mem.Allocator,
    /// total edge weight m (NOT 2m). m = (sum of inter-cluster contribs / 2)
    /// + sum of self-loops.
    m: f64,

    const NeighbourWeight = struct { node: u32, weight: f64 };

    fn deinit(self: *Aggregated) void {
        for (self.neighbours) |row| self.allocator.free(row);
        self.allocator.free(self.neighbours);
        self.allocator.free(self.self_loop);
        self.allocator.free(self.deg);
        self.allocator.free(self.community);
    }

    /// Build from a `Graph`, absorbing duplicate edges into summed weights
    /// per neighbour pair.
    fn fromGraph(graph: Graph, allocator: std.mem.Allocator) Error!Aggregated {
        const n = graph.node_count;
        // First pass: collect into hash maps per node, then materialise.
        var maps = try allocator.alloc(std.AutoHashMapUnmanaged(u32, f64), n);
        defer {
            for (maps) |*m| m.deinit(allocator);
            allocator.free(maps);
        }
        for (maps) |*m| m.* = .empty;

        const self_loop = try allocator.alloc(f64, n);
        errdefer allocator.free(self_loop);
        @memset(self_loop, 0.0);

        for (graph.edges.items) |edge| {
            if (edge.source == edge.target) {
                self_loop[edge.source] += edge.weight; // counted once here, doubled in `deg`
                continue;
            }
            const s = @as(u32, @intCast(edge.source));
            const t = @as(u32, @intCast(edge.target));
            const gop_s = try maps[edge.source].getOrPut(allocator, t);
            if (!gop_s.found_existing) gop_s.value_ptr.* = 0.0;
            gop_s.value_ptr.* += edge.weight;
            const gop_t = try maps[edge.target].getOrPut(allocator, s);
            if (!gop_t.found_existing) gop_t.value_ptr.* = 0.0;
            gop_t.value_ptr.* += edge.weight;
        }

        const neighbours = try allocator.alloc([]NeighbourWeight, n);
        errdefer {
            for (neighbours) |row| allocator.free(row);
            allocator.free(neighbours);
        }
        for (neighbours, 0..) |*row, i| {
            row.* = try allocator.alloc(NeighbourWeight, maps[i].count());
            var it = maps[i].iterator();
            var j: usize = 0;
            while (it.next()) |e| : (j += 1) {
                row.*[j] = .{ .node = e.key_ptr.*, .weight = e.value_ptr.* };
            }
        }

        const deg = try allocator.alloc(f64, n);
        errdefer allocator.free(deg);
        @memset(deg, 0.0);
        for (neighbours, 0..) |row, i| {
            for (row) |nb| deg[i] += nb.weight;
            // Self-loops contribute 2 * w to weighted degree (the "double
            // count" inherent to undirected sums of A_ij).
            deg[i] += 2.0 * self_loop[i];
        }

        const community = try allocator.alloc(u32, n);
        errdefer allocator.free(community);
        for (community, 0..) |*c, i| c.* = @as(u32, @intCast(i));

        var m_total: f64 = 0.0;
        for (deg) |d| m_total += d;
        m_total *= 0.5;

        return .{
            .n = n,
            .neighbours = neighbours,
            .self_loop = self_loop,
            .deg = deg,
            .community = community,
            .allocator = allocator,
            .m = m_total,
        };
    }

    /// Build the next-level aggregated graph: nodes become communities,
    /// inter-community weights sum, intra-community weights become
    /// self-loops.
    fn aggregate(self: Aggregated, allocator: std.mem.Allocator) Error!Aggregated {
        // Compact community labels to dense ids 0..k.
        const new_id = try allocator.alloc(u32, self.n);
        defer allocator.free(new_id);
        var k: u32 = 0;
        const seen_id_init: i64 = -1;
        var seen = try allocator.alloc(i64, self.n);
        defer allocator.free(seen);
        for (seen) |*s| s.* = seen_id_init;
        for (self.community, 0..) |c, i| {
            if (seen[c] == seen_id_init) {
                seen[c] = @as(i64, k);
                k += 1;
            }
            new_id[i] = @as(u32, @intCast(seen[c]));
        }
        const new_n = @as(usize, k);

        // Build hash maps for new graph.
        var maps = try allocator.alloc(std.AutoHashMapUnmanaged(u32, f64), new_n);
        defer {
            for (maps) |*m| m.deinit(allocator);
            allocator.free(maps);
        }
        for (maps) |*m| m.* = .empty;
        const new_self_loop = try allocator.alloc(f64, new_n);
        errdefer allocator.free(new_self_loop);
        @memset(new_self_loop, 0.0);

        for (0..self.n) |i| {
            const ci = new_id[i];
            // Inherit self-loops.
            new_self_loop[ci] += self.self_loop[i];
            for (self.neighbours[i]) |nb| {
                const j = @as(usize, nb.node);
                const cj = new_id[j];
                if (ci == cj) {
                    // Intra-community edge: each side adds half so total
                    // contribution equals the original edge weight.
                    new_self_loop[ci] += nb.weight * 0.5;
                } else if (ci < cj) {
                    // To avoid double-counting inter-community edges (we'll
                    // iterate from both endpoints), only insert when ci < cj.
                    // We DO need both directions in the neighbour list though.
                    const gop1 = try maps[ci].getOrPut(allocator, cj);
                    if (!gop1.found_existing) gop1.value_ptr.* = 0.0;
                    gop1.value_ptr.* += nb.weight;
                    const gop2 = try maps[cj].getOrPut(allocator, ci);
                    if (!gop2.found_existing) gop2.value_ptr.* = 0.0;
                    gop2.value_ptr.* += nb.weight;
                }
                // else: handled when iterating from j.
            }
        }

        const neighbours = try allocator.alloc([]NeighbourWeight, new_n);
        errdefer {
            for (neighbours) |row| allocator.free(row);
            allocator.free(neighbours);
        }
        for (neighbours, 0..) |*row, i| {
            row.* = try allocator.alloc(NeighbourWeight, maps[i].count());
            var it = maps[i].iterator();
            var j: usize = 0;
            while (it.next()) |e| : (j += 1) {
                row.*[j] = .{ .node = e.key_ptr.*, .weight = e.value_ptr.* };
            }
        }

        const deg = try allocator.alloc(f64, new_n);
        errdefer allocator.free(deg);
        @memset(deg, 0.0);
        for (neighbours, 0..) |row, i| {
            for (row) |nb| deg[i] += nb.weight;
            deg[i] += 2.0 * new_self_loop[i];
        }

        const community = try allocator.alloc(u32, new_n);
        errdefer allocator.free(community);
        for (community, 0..) |*c, i| c.* = @as(u32, @intCast(i));

        var m_total: f64 = 0.0;
        for (deg) |d| m_total += d;
        m_total *= 0.5;

        return .{
            .n = new_n,
            .neighbours = neighbours,
            .self_loop = new_self_loop,
            .deg = deg,
            .community = community,
            .allocator = allocator,
            .m = m_total,
        };
    }
};

/// One full local-move phase. Returns `true` if anything moved.
fn runLocalMove(g: *Aggregated, allocator: std.mem.Allocator, options: LouvainOptions) Error!bool {
    if (g.m <= 0.0) return false;

    // Track total weighted degree per community.
    const sum_tot = try allocator.alloc(f64, g.n);
    defer allocator.free(sum_tot);
    @memcpy(sum_tot, g.deg);

    // Per-iteration scratch: weight from node i to each candidate community.
    const ki_in = try allocator.alloc(f64, g.n);
    defer allocator.free(ki_in);
    @memset(ki_in, 0.0);
    // Which communities touched this round (so we can clear cheaply).
    var touched = try std.ArrayList(u32).initCapacity(allocator, g.n);
    defer touched.deinit(allocator);

    var any_move = false;
    var sweep: usize = 0;
    const two_m = 2.0 * g.m;
    while (sweep < options.max_sweeps_per_level) : (sweep += 1) {
        var moved_this_sweep = false;
        var i: usize = 0;
        while (i < g.n) : (i += 1) {
            const ci = g.community[i];

            // Build k_{i, C} per neighbour community.
            for (touched.items) |c| ki_in[c] = 0.0;
            touched.clearRetainingCapacity();
            for (g.neighbours[i]) |nb| {
                if (@as(usize, nb.node) == i) continue;
                const c_nb = g.community[nb.node];
                if (ki_in[c_nb] == 0.0) try touched.append(allocator, c_nb);
                ki_in[c_nb] += nb.weight;
            }

            // ΔQ from removing i from its community and adding to candidate c:
            //   ΔQ = (Σ_in(c) + k_{i,c}) / (2m)
            //      − ((Σ_tot(c) + k_i) / (2m))²
            //      − [ Σ_in(ci_no_i) / (2m) − (Σ_tot(ci_no_i) / (2m))²
            //          − (k_i / (2m))² ]
            // Simplified (Blondel et al. closed form):
            //   ΔQ(move to c) ∝ k_{i,c} − Σ_tot(c) * k_i / (2m)
            // Use the formulation comparing relative gains, with current
            // community treated symmetrically.

            const k_i = g.deg[i];
            // "Remove i from ci" requires the tot-of-ci minus k_i.
            const tot_ci = sum_tot[ci] - k_i;
            // k_{i, ci} = self-edges to current community (excluding self-loop counted twice).
            const k_i_ci = if (ci < g.n) ki_in[ci] else 0.0;

            // Gain of staying: gain( move to ci ) is reference 0 if we re-pick ci.
            // We compute ΔQ relative to "removed and left alone", then choose the max.
            // Best move starts as staying (ci, gain 0).
            var best_c: u32 = ci;
            var best_gain: f64 = 0.0;

            for (touched.items) |c| {
                const k_i_c = ki_in[c];
                const tot_c = if (c == ci) tot_ci else sum_tot[c];
                const gain = k_i_c - tot_c * k_i / two_m;
                // Subtract the "stay in ci" baseline so we make a fair comparison.
                const gain_rel = gain - (k_i_ci - tot_ci * k_i / two_m);
                if (gain_rel > best_gain + options.tolerance) {
                    best_gain = gain_rel;
                    best_c = c;
                }
            }

            if (best_c != ci) {
                sum_tot[ci] -= k_i;
                sum_tot[best_c] += k_i;
                g.community[i] = best_c;
                moved_this_sweep = true;
                any_move = true;
            }
        }
        if (!moved_this_sweep) break;
    }
    return any_move;
}

/// Compact labels in place to 0..k. Returns k.
fn compactInPlace(labels: []u32) usize {
    if (labels.len == 0) return 0;
    // Use a heap-free approach: scan, assign new ids on first encounter.
    // Use a map from old label → new id. Bound by labels.len.
    var k: u32 = 0;
    // Simple approach: for each label, look it up against an inline table.
    // Worst-case O(n²) but the labels.len here is typically thousands at
    // most for Louvain. For larger graphs we'd switch to a hash map.
    var i: usize = 0;
    while (i < labels.len) : (i += 1) {
        const target = labels[i];
        // Search the prefix [0..i) for the first index with this target.
        var found_at: ?usize = null;
        var j: usize = 0;
        while (j < i) : (j += 1) {
            if (labels[j] == target) {
                found_at = j;
                break;
            }
        }
        if (found_at) |fa| {
            // Already remapped — but the value at labels[fa] is already a new id
            // because we overwrite as we go.
            labels[i] = labels[fa];
        } else {
            labels[i] = k;
            k += 1;
        }
    }
    return @as(usize, k);
}

fn computeModularityOnOriginal(graph: Graph, partition: []const u32, allocator: std.mem.Allocator) Error!f64 {
    const n = graph.node_count;
    if (n == 0 or partition.len != n) return 0.0;

    const deg = try root.weightedDegree(graph, allocator);
    defer allocator.free(deg);

    var two_m: f64 = 0.0;
    for (deg) |d| two_m += d;
    if (two_m == 0.0) return 0.0;

    var q: f64 = 0.0;
    for (graph.edges.items) |edge| {
        if (partition[edge.source] == partition[edge.target]) {
            // A_ij contribution: each undirected edge contributes 2 * w to A.
            q += 2.0 * edge.weight;
        }
    }
    // Subtract expectation: (k_i k_j) / (2m), summed over same-community pairs.
    // Sum over communities of (Σ_{i in c} k_i)^2 / (2m).
    var sum_deg_sq: std.AutoHashMapUnmanaged(u32, f64) = .empty;
    defer sum_deg_sq.deinit(allocator);
    for (partition, 0..) |c, i| {
        const gop = try sum_deg_sq.getOrPut(allocator, c);
        if (!gop.found_existing) gop.value_ptr.* = 0.0;
        gop.value_ptr.* += deg[i];
    }
    var it = sum_deg_sq.iterator();
    while (it.next()) |e| {
        q -= (e.value_ptr.* * e.value_ptr.*) / two_m;
    }
    return q / two_m;
}

// ---- tests ----

const testing = std.testing;

test "louvain on two K_3 joined by bridge: two communities, high modularity" {
    var g = Graph.init(testing.allocator, 6);
    defer g.deinit();
    try g.addEdge(0, 1, 1.0);
    try g.addEdge(1, 2, 1.0);
    try g.addEdge(0, 2, 1.0);
    try g.addEdge(3, 4, 1.0);
    try g.addEdge(4, 5, 1.0);
    try g.addEdge(3, 5, 1.0);
    try g.addEdge(2, 3, 1.0); // bridge

    var r = try louvain(g, testing.allocator, .{});
    defer r.deinit();

    try testing.expectEqual(@as(usize, 2), r.num_communities);
    // Nodes 0,1,2 same community; 3,4,5 same community; different from each other.
    try testing.expectEqual(r.labels[0], r.labels[1]);
    try testing.expectEqual(r.labels[1], r.labels[2]);
    try testing.expectEqual(r.labels[3], r.labels[4]);
    try testing.expectEqual(r.labels[4], r.labels[5]);
    try testing.expect(r.labels[0] != r.labels[3]);
    // Known modularity Q ≈ 0.3571 for this graph (2/7 - 1 / sum-of-deg-sq term).
    // We test a loose lower bound here.
    try testing.expect(r.modularity > 0.30);
}

test "louvain on a clique returns one community" {
    var g = Graph.init(testing.allocator, 5);
    defer g.deinit();
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        var j: usize = i + 1;
        while (j < 5) : (j += 1) try g.addEdge(i, j, 1.0);
    }
    var r = try louvain(g, testing.allocator, .{});
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.num_communities);
}

test "louvain on empty graph returns zero modularity, zero communities" {
    var g = Graph.init(testing.allocator, 0);
    defer g.deinit();
    var r = try louvain(g, testing.allocator, .{});
    defer r.deinit();
    try testing.expectEqual(@as(usize, 0), r.num_communities);
    try testing.expectEqual(@as(f64, 0.0), r.modularity);
}

test "louvain fuzz: modularity in [-0.5, 1]" {
    var rng = std.Random.DefaultPrng.init(0xC0_DE_C0_DE_C0_DE_C0_DE);
    const r = rng.random();
    var k: usize = 0;
    while (k < 60) : (k += 1) {
        const n: usize = @as(usize, r.uintLessThan(u8, 30)) + 4;
        const m: usize = r.uintLessThan(usize, 3 * n + 1);
        var g = Graph.init(testing.allocator, n);
        defer g.deinit();
        var j: usize = 0;
        while (j < m) : (j += 1) {
            const s = r.uintLessThan(usize, n);
            var t = r.uintLessThan(usize, n);
            if (t == s) t = (t + 1) % n;
            try g.addEdge(s, t, 0.1 + r.float(f64) * 4.0);
        }
        var res = try louvain(g, testing.allocator, .{});
        defer res.deinit();
        try testing.expect(res.modularity >= -0.5 - 1e-9);
        try testing.expect(res.modularity <= 1.0 + 1e-9);
        try testing.expect(res.num_communities >= 1);
        try testing.expect(res.num_communities <= n);
    }
}

test "modularity function matches louvain self-report" {
    var g = Graph.init(testing.allocator, 6);
    defer g.deinit();
    try g.addEdge(0, 1, 1.0);
    try g.addEdge(1, 2, 1.0);
    try g.addEdge(0, 2, 1.0);
    try g.addEdge(3, 4, 1.0);
    try g.addEdge(4, 5, 1.0);
    try g.addEdge(3, 5, 1.0);
    try g.addEdge(2, 3, 1.0);

    var r = try louvain(g, testing.allocator, .{});
    defer r.deinit();
    const q = try modularity(g, r.labels, testing.allocator);
    try testing.expectApproxEqAbs(r.modularity, q, 1e-9);
}
