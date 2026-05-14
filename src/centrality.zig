//! Betweenness and closeness centrality.
//!
//! Both routines run a single-source shortest-path search from every vertex.
//! For betweenness we use **Brandes' algorithm** (Brandes 2001, "A Faster
//! Algorithm for Betweenness Centrality") with separate code paths for
//! unweighted (BFS) and weighted (Dijkstra) graphs.
//!
//! - `betweennessCentrality(graph, allocator, .{})`
//!     Returns the (un-normalised) betweenness for every node. For
//!     undirected graphs the values are divided by 2 to avoid counting each
//!     path twice. Pass `.normalize = true` to scale by `2 / ((n-1)(n-2))`
//!     so the result lies in `[0, 1]`.
//! - `closenessCentrality(graph, allocator)`
//!     Returns `(reachable_count − 1) / Σ d(v, u)` for each `v`. Equal to
//!     standard closeness on connected graphs and to Wasserman-Faust
//!     normalised closeness on disconnected graphs (gives 0 for isolated
//!     nodes).

const std = @import("std");
const root = @import("root.zig");
const Graph = root.Graph;
const Error = root.Error;
const traversal = @import("traversal.zig");

pub const BetweennessOptions = struct {
    /// Treat all edge weights as 1 (use BFS). Faster — O(|V|·|E|).
    unweighted: bool = false,
    /// Normalise by 2 / ((n-1)(n-2)) so values lie in [0, 1].
    normalize: bool = false,
};

/// Brandes' algorithm. Result is the betweenness of every node.
pub fn betweennessCentrality(
    graph: Graph,
    allocator: std.mem.Allocator,
    options: BetweennessOptions,
) Error![]f64 {
    const n = graph.node_count;
    const cb = try allocator.alloc(f64, n);
    errdefer allocator.free(cb);
    @memset(cb, 0.0);
    if (n < 3) {
        // For n < 3 betweenness is identically zero.
        return cb;
    }

    var adj = try traversal.buildAdjacency(graph, allocator);
    defer adj.deinit();

    // Scratch buffers reused across the |V| SSSPs.
    const sigma = try allocator.alloc(f64, n);
    defer allocator.free(sigma);
    const dist = try allocator.alloc(f64, n);
    defer allocator.free(dist);
    const delta = try allocator.alloc(f64, n);
    defer allocator.free(delta);

    var stack = try std.ArrayList(u32).initCapacity(allocator, n);
    defer stack.deinit(allocator);
    var queue = try std.ArrayList(u32).initCapacity(allocator, n);
    defer queue.deinit(allocator);

    // Predecessor lists. preds[v] is a slice of u32; we use ArrayLists.
    var preds = try allocator.alloc(std.ArrayList(u32), n);
    defer {
        for (preds) |*p| p.deinit(allocator);
        allocator.free(preds);
    }
    for (preds) |*p| p.* = .empty;

    var s: usize = 0;
    while (s < n) : (s += 1) {
        // Reset scratch.
        @memset(sigma, 0.0);
        sigma[s] = 1.0;
        for (dist) |*d| d.* = -1.0;
        dist[s] = 0.0;
        @memset(delta, 0.0);
        stack.clearRetainingCapacity();
        for (preds) |*p| p.clearRetainingCapacity();

        if (options.unweighted) {
            // BFS — O(|V| + |E|) per source.
            queue.clearRetainingCapacity();
            try queue.append(allocator, @as(u32, @intCast(s)));
            var head: usize = 0;
            while (head < queue.items.len) : (head += 1) {
                const v = @as(usize, queue.items[head]);
                try stack.append(allocator, @as(u32, @intCast(v)));
                for (adj.slice(v)) |nb| {
                    const w = nb.node;
                    if (dist[w] < 0.0) {
                        dist[w] = dist[v] + 1.0;
                        try queue.append(allocator, @as(u32, @intCast(w)));
                    }
                    if (dist[w] == dist[v] + 1.0) {
                        sigma[w] += sigma[v];
                        try preds[w].append(allocator, @as(u32, @intCast(v)));
                    }
                }
            }
        } else {
            // Dijkstra — O((|V| + |E|) log |V|) per source.
            const HeapItem = struct { d: f64, node: u32 };
            var heap = try std.ArrayList(HeapItem).initCapacity(allocator, n);
            defer heap.deinit(allocator);
            try heapPush(HeapItem, allocator, &heap, .{ .d = 0.0, .node = @as(u32, @intCast(s)) });
            // Track which nodes have been finalized to avoid double-push on stack.
            const finalized = try allocator.alloc(bool, n);
            defer allocator.free(finalized);
            @memset(finalized, false);
            while (heap.items.len > 0) {
                const top = heapPop(HeapItem, &heap);
                const v = @as(usize, top.node);
                if (finalized[v]) continue;
                finalized[v] = true;
                try stack.append(allocator, @as(u32, @intCast(v)));
                for (adj.slice(v)) |nb| {
                    const w = nb.node;
                    const new_d = dist[v] + nb.weight;
                    if (dist[w] < 0.0 or new_d < dist[w] - 1e-12) {
                        dist[w] = new_d;
                        sigma[w] = sigma[v];
                        preds[w].clearRetainingCapacity();
                        try preds[w].append(allocator, @as(u32, @intCast(v)));
                        try heapPush(HeapItem, allocator, &heap, .{ .d = new_d, .node = @as(u32, @intCast(w)) });
                    } else if (@abs(new_d - dist[w]) <= 1e-12) {
                        sigma[w] += sigma[v];
                        try preds[w].append(allocator, @as(u32, @intCast(v)));
                    }
                }
            }
        }

        // Backwards accumulation.
        var i: usize = stack.items.len;
        while (i > 0) {
            i -= 1;
            const w = @as(usize, stack.items[i]);
            for (preds[w].items) |p_u32| {
                const p = @as(usize, p_u32);
                if (sigma[w] > 0.0) {
                    delta[p] += (sigma[p] / sigma[w]) * (1.0 + delta[w]);
                }
            }
            if (w != s) cb[w] += delta[w];
        }
    }

    // Undirected: each shortest path counted twice.
    for (cb) |*v| v.* *= 0.5;

    if (options.normalize and n > 2) {
        const denom = @as(f64, @floatFromInt((n - 1) * (n - 2))) / 2.0;
        for (cb) |*v| v.* /= denom;
    }
    return cb;
}

/// Closeness centrality `C(v) = (R - 1) / Σ d(v, u over reachable u)` where
/// `R` is the number of nodes reachable from `v` including itself. For
/// connected graphs this is the standard closeness; for disconnected graphs
/// it is Wasserman-Faust normalised so isolated nodes get 0.
pub fn closenessCentrality(graph: Graph, allocator: std.mem.Allocator) Error![]f64 {
    const n = graph.node_count;
    const out = try allocator.alloc(f64, n);
    errdefer allocator.free(out);
    @memset(out, 0.0);
    if (n == 0) return out;

    var v: usize = 0;
    while (v < n) : (v += 1) {
        const d = try traversal.sssp(graph, v, allocator);
        defer allocator.free(d);
        var sum: f64 = 0.0;
        var reachable: usize = 0;
        for (d) |di| {
            if (!std.math.isInf(di)) {
                sum += di;
                reachable += 1;
            }
        }
        if (reachable > 1 and sum > 0.0) {
            out[v] = @as(f64, @floatFromInt(reachable - 1)) / sum;
            // Wasserman-Faust scaling: weight by reachable component fraction.
            // C(v) = ((R-1)/(n-1)) * ((R-1)/sum)
            const frac = @as(f64, @floatFromInt(reachable - 1)) /
                @as(f64, @floatFromInt(n - 1));
            out[v] *= frac;
        }
    }
    return out;
}

// ---- Tiny generic binary heap (min-heap by `.d`) ----

fn heapPush(comptime T: type, allocator: std.mem.Allocator, heap: *std.ArrayList(T), item: T) Error!void {
    try heap.append(allocator, item);
    var i: usize = heap.items.len - 1;
    while (i > 0) {
        const parent = (i - 1) / 2;
        if (heap.items[parent].d <= heap.items[i].d) break;
        const tmp = heap.items[parent];
        heap.items[parent] = heap.items[i];
        heap.items[i] = tmp;
        i = parent;
    }
}

fn heapPop(comptime T: type, heap: *std.ArrayList(T)) T {
    const top = heap.items[0];
    const last = heap.pop().?;
    if (heap.items.len == 0) return top;
    heap.items[0] = last;
    var i: usize = 0;
    const n = heap.items.len;
    while (true) {
        const l = 2 * i + 1;
        const r = 2 * i + 2;
        var smallest = i;
        if (l < n and heap.items[l].d < heap.items[smallest].d) smallest = l;
        if (r < n and heap.items[r].d < heap.items[smallest].d) smallest = r;
        if (smallest == i) break;
        const tmp = heap.items[smallest];
        heap.items[smallest] = heap.items[i];
        heap.items[i] = tmp;
        i = smallest;
    }
    return top;
}

// ---- tests ----

const testing = std.testing;

test "betweenness on a line graph: monotonic peak in the middle" {
    var g = Graph.init(testing.allocator, 5);
    defer g.deinit();
    try g.addEdge(0, 1, 1.0);
    try g.addEdge(1, 2, 1.0);
    try g.addEdge(2, 3, 1.0);
    try g.addEdge(3, 4, 1.0);

    const bc = try betweennessCentrality(g, testing.allocator, .{ .unweighted = true });
    defer testing.allocator.free(bc);
    // For a path 0-1-2-3-4, betweenness is (0, 3, 4, 3, 0).
    try testing.expectApproxEqAbs(@as(f64, 0.0), bc[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 3.0), bc[1], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 4.0), bc[2], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 3.0), bc[3], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.0), bc[4], 1e-9);
}

test "betweenness on barbell: bridge nodes dominate" {
    // Two K_3 joined by bridge 2-3.
    var g = Graph.init(testing.allocator, 6);
    defer g.deinit();
    try g.addEdge(0, 1, 1.0);
    try g.addEdge(1, 2, 1.0);
    try g.addEdge(0, 2, 1.0);
    try g.addEdge(3, 4, 1.0);
    try g.addEdge(4, 5, 1.0);
    try g.addEdge(3, 5, 1.0);
    try g.addEdge(2, 3, 1.0); // bridge

    const bc = try betweennessCentrality(g, testing.allocator, .{ .unweighted = true });
    defer testing.allocator.free(bc);
    // Bridge nodes 2 and 3 must have the highest betweenness.
    try testing.expect(bc[2] > bc[0]);
    try testing.expect(bc[3] > bc[5]);
    try testing.expectApproxEqAbs(bc[2], bc[3], 1e-9);
}

test "betweenness on star: center has betweenness (n-1)(n-2)/2; leaves are 0" {
    var g = Graph.init(testing.allocator, 5);
    defer g.deinit();
    try g.addEdge(0, 1, 1.0);
    try g.addEdge(0, 2, 1.0);
    try g.addEdge(0, 3, 1.0);
    try g.addEdge(0, 4, 1.0);

    const bc = try betweennessCentrality(g, testing.allocator, .{ .unweighted = true });
    defer testing.allocator.free(bc);
    try testing.expectApproxEqAbs(@as(f64, 6.0), bc[0], 1e-9);
    for ([_]usize{ 1, 2, 3, 4 }) |i| {
        try testing.expectApproxEqAbs(@as(f64, 0.0), bc[i], 1e-9);
    }
}

test "betweenness normalized: star center is exactly 1.0" {
    var g = Graph.init(testing.allocator, 5);
    defer g.deinit();
    try g.addEdge(0, 1, 1.0);
    try g.addEdge(0, 2, 1.0);
    try g.addEdge(0, 3, 1.0);
    try g.addEdge(0, 4, 1.0);

    const bc = try betweennessCentrality(g, testing.allocator, .{
        .unweighted = true,
        .normalize = true,
    });
    defer testing.allocator.free(bc);
    try testing.expectApproxEqAbs(@as(f64, 1.0), bc[0], 1e-9);
}

test "weighted betweenness on path with non-unit edges still peaks in the middle" {
    var g = Graph.init(testing.allocator, 4);
    defer g.deinit();
    try g.addEdge(0, 1, 2.0);
    try g.addEdge(1, 2, 3.0);
    try g.addEdge(2, 3, 1.5);

    const bc = try betweennessCentrality(g, testing.allocator, .{});
    defer testing.allocator.free(bc);
    try testing.expect(bc[1] > bc[0]);
    try testing.expect(bc[2] > bc[3]);
}

test "closeness on star: center has highest closeness" {
    var g = Graph.init(testing.allocator, 5);
    defer g.deinit();
    try g.addEdge(0, 1, 1.0);
    try g.addEdge(0, 2, 1.0);
    try g.addEdge(0, 3, 1.0);
    try g.addEdge(0, 4, 1.0);

    const cc = try closenessCentrality(g, testing.allocator);
    defer testing.allocator.free(cc);
    // Center distance sum = 4 → C = 4/4 = 1.0 (fully connected fraction 1).
    try testing.expectApproxEqAbs(@as(f64, 1.0), cc[0], 1e-9);
    // Leaf distance sum = 1 + 2 + 2 + 2 = 7 → C = 4/7.
    try testing.expectApproxEqAbs(@as(f64, 4.0 / 7.0), cc[1], 1e-9);
    try testing.expectApproxEqAbs(cc[1], cc[2], 1e-9);
}

test "closeness on cycle is uniform" {
    var g = Graph.init(testing.allocator, 4);
    defer g.deinit();
    try g.addEdge(0, 1, 1.0);
    try g.addEdge(1, 2, 1.0);
    try g.addEdge(2, 3, 1.0);
    try g.addEdge(3, 0, 1.0);

    const cc = try closenessCentrality(g, testing.allocator);
    defer testing.allocator.free(cc);
    for (cc[1..]) |v| try testing.expectApproxEqAbs(cc[0], v, 1e-9);
}

test "closeness gives 0 for isolated nodes" {
    var g = Graph.init(testing.allocator, 4);
    defer g.deinit();
    try g.addEdge(0, 1, 1.0);
    // Nodes 2, 3 isolated.
    const cc = try closenessCentrality(g, testing.allocator);
    defer testing.allocator.free(cc);
    try testing.expect(cc[2] == 0.0);
    try testing.expect(cc[3] == 0.0);
}

test "betweenness fuzz: non-negative, sum bounded" {
    var rng = std.Random.DefaultPrng.init(0xBE7F_BE7F_BE7F_BE7F);
    const r = rng.random();
    var k: usize = 0;
    while (k < 100) : (k += 1) {
        const n: usize = @as(usize, r.uintLessThan(u8, 16)) + 3;
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
        const bc = try betweennessCentrality(g, testing.allocator, .{ .unweighted = true });
        defer testing.allocator.free(bc);
        // Bound: each node's betweenness ≤ (n-1)(n-2)/2.
        const upper = @as(f64, @floatFromInt((n - 1) * (n - 2))) / 2.0;
        for (bc) |v| {
            try testing.expect(v >= -1e-9);
            try testing.expect(v <= upper + 1e-6);
            try testing.expect(!std.math.isNan(v));
        }
    }
}
