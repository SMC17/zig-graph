//! Graph traversal helpers: BFS, DFS, Dijkstra SSSP, and BFS-based shortest
//! unweighted path reconstruction.
//!
//! All routines treat edges as undirected (matching the `Graph` convention)
//! and build a CSR-style adjacency structure on entry. The CSR build is
//! `O(|V| + |E|)` and is released before the routine returns. Result arrays
//! are allocated through the caller-provided allocator and owned by the
//! caller (`allocator.free`).

const std = @import("std");
const root = @import("root.zig");
const Graph = root.Graph;
const Error = root.Error;

/// Compact adjacency list built once per traversal call. Each entry stores
/// the neighbour node and the (positive) edge weight.
pub const Neighbor = struct {
    node: usize,
    weight: f64,
};

/// CSR-ish adjacency: `offsets[i..i+1]` slices `neighbors` for node `i`.
/// Built from an undirected edge list — every edge produces two entries.
pub const Adjacency = struct {
    offsets: []usize,
    neighbors: []Neighbor,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Adjacency) void {
        self.allocator.free(self.offsets);
        self.allocator.free(self.neighbors);
    }

    pub fn slice(self: Adjacency, node: usize) []const Neighbor {
        return self.neighbors[self.offsets[node]..self.offsets[node + 1]];
    }
};

/// Build a CSR-style undirected adjacency from a `Graph`. Each `Edge {s, t}`
/// contributes one entry at `s` and one at `t`. Self-loops contribute two
/// entries at the same node (consistent with how the existing centrality
/// routines treat them).
pub fn buildAdjacency(graph: Graph, allocator: std.mem.Allocator) Error!Adjacency {
    const n = graph.node_count;
    const offsets = try allocator.alloc(usize, n + 1);
    errdefer allocator.free(offsets);
    @memset(offsets, 0);

    for (graph.edges.items) |edge| {
        offsets[edge.source] += 1;
        offsets[edge.target] += 1;
    }
    // Exclusive prefix sum.
    var running: usize = 0;
    for (offsets) |*o| {
        const tmp = o.*;
        o.* = running;
        running += tmp;
    }

    const total = running;
    const neighbors = try allocator.alloc(Neighbor, total);
    errdefer allocator.free(neighbors);

    // Fill — temporarily advance offsets, then restore.
    var cursor = try allocator.alloc(usize, n);
    defer allocator.free(cursor);
    @memcpy(cursor, offsets[0..n]);

    for (graph.edges.items) |edge| {
        const s = edge.source;
        const t = edge.target;
        neighbors[cursor[s]] = .{ .node = t, .weight = edge.weight };
        cursor[s] += 1;
        neighbors[cursor[t]] = .{ .node = s, .weight = edge.weight };
        cursor[t] += 1;
    }
    return .{ .offsets = offsets, .neighbors = neighbors, .allocator = allocator };
}

/// Build a directed CSR adjacency. Each edge contributes only one entry from
/// `source → target`. Used by directed PageRank and (optionally) directed
/// traversals.
pub fn buildDirectedAdjacency(graph: Graph, allocator: std.mem.Allocator) Error!Adjacency {
    const n = graph.node_count;
    const offsets = try allocator.alloc(usize, n + 1);
    errdefer allocator.free(offsets);
    @memset(offsets, 0);

    for (graph.edges.items) |edge| offsets[edge.source] += 1;
    var running: usize = 0;
    for (offsets) |*o| {
        const tmp = o.*;
        o.* = running;
        running += tmp;
    }

    const total = running;
    const neighbors = try allocator.alloc(Neighbor, total);
    errdefer allocator.free(neighbors);

    var cursor = try allocator.alloc(usize, n);
    defer allocator.free(cursor);
    @memcpy(cursor, offsets[0..n]);
    for (graph.edges.items) |edge| {
        neighbors[cursor[edge.source]] = .{ .node = edge.target, .weight = edge.weight };
        cursor[edge.source] += 1;
    }
    return .{ .offsets = offsets, .neighbors = neighbors, .allocator = allocator };
}

/// Breadth-first traversal from `start`. Returns the visit order — nodes are
/// listed in the order they were dequeued. Disconnected nodes are not
/// included.
pub fn bfs(graph: Graph, start: usize, allocator: std.mem.Allocator) Error![]u32 {
    if (start >= graph.node_count) return Error.NodeIndexOutOfRange;
    var adj = try buildAdjacency(graph, allocator);
    defer adj.deinit();

    const n = graph.node_count;
    const visited = try allocator.alloc(bool, n);
    defer allocator.free(visited);
    @memset(visited, false);

    var order = try std.ArrayList(u32).initCapacity(allocator, n);
    errdefer order.deinit(allocator);

    var queue = try std.ArrayList(u32).initCapacity(allocator, n);
    defer queue.deinit(allocator);

    visited[start] = true;
    try queue.append(allocator, @as(u32, @intCast(start)));
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const v = @as(usize, queue.items[head]);
        try order.append(allocator, @as(u32, @intCast(v)));
        for (adj.slice(v)) |nb| {
            if (!visited[nb.node]) {
                visited[nb.node] = true;
                try queue.append(allocator, @as(u32, @intCast(nb.node)));
            }
        }
    }
    return order.toOwnedSlice(allocator);
}

/// Depth-first traversal from `start`. Iterative (explicit stack). Returns
/// pre-order visit order. Disconnected nodes are not included.
pub fn dfs(graph: Graph, start: usize, allocator: std.mem.Allocator) Error![]u32 {
    if (start >= graph.node_count) return Error.NodeIndexOutOfRange;
    var adj = try buildAdjacency(graph, allocator);
    defer adj.deinit();

    const n = graph.node_count;
    const visited = try allocator.alloc(bool, n);
    defer allocator.free(visited);
    @memset(visited, false);

    var order = try std.ArrayList(u32).initCapacity(allocator, n);
    errdefer order.deinit(allocator);

    var stack = try std.ArrayList(u32).initCapacity(allocator, n);
    defer stack.deinit(allocator);

    try stack.append(allocator, @as(u32, @intCast(start)));
    while (stack.items.len > 0) {
        const v = @as(usize, stack.pop().?);
        if (visited[v]) continue;
        visited[v] = true;
        try order.append(allocator, @as(u32, @intCast(v)));
        // Push neighbours in reverse so first listed is explored first.
        const nbrs = adj.slice(v);
        var i: usize = nbrs.len;
        while (i > 0) {
            i -= 1;
            if (!visited[nbrs[i].node]) {
                try stack.append(allocator, @as(u32, @intCast(nbrs[i].node)));
            }
        }
    }
    return order.toOwnedSlice(allocator);
}

/// Single-source shortest-path distances via Dijkstra. Edge weights are
/// expected to be non-negative; negative weights are not validated. Returns
/// an array of length `node_count`. Unreachable nodes have `math.inf(f64)`.
pub fn sssp(graph: Graph, start: usize, allocator: std.mem.Allocator) Error![]f64 {
    if (start >= graph.node_count) return Error.NodeIndexOutOfRange;
    var adj = try buildAdjacency(graph, allocator);
    defer adj.deinit();

    const n = graph.node_count;
    const dist = try allocator.alloc(f64, n);
    errdefer allocator.free(dist);
    for (dist) |*d| d.* = std.math.inf(f64);
    dist[start] = 0.0;

    // Min-heap on (dist, node). Standard binary heap keyed by f64.
    const HeapItem = struct { d: f64, node: u32 };
    var heap = try std.ArrayList(HeapItem).initCapacity(allocator, n);
    defer heap.deinit(allocator);

    try heapPush(HeapItem, allocator, &heap, .{ .d = 0.0, .node = @as(u32, @intCast(start)) });
    while (heap.items.len > 0) {
        const top = heapPop(HeapItem, &heap);
        const u = @as(usize, top.node);
        if (top.d > dist[u]) continue; // stale entry
        for (adj.slice(u)) |nb| {
            const new_d = dist[u] + nb.weight;
            if (new_d < dist[nb.node]) {
                dist[nb.node] = new_d;
                try heapPush(HeapItem, allocator, &heap, .{ .d = new_d, .node = @as(u32, @intCast(nb.node)) });
            }
        }
    }
    return dist;
}

/// Shortest unweighted path (edge count) from `start` to `end` via BFS.
/// Returns the path as `[start, ..., end]` or `null` if unreachable. Caller
/// owns the slice.
pub fn bfsPath(graph: Graph, start: usize, end: usize, allocator: std.mem.Allocator) Error!?[]u32 {
    if (start >= graph.node_count or end >= graph.node_count) return Error.NodeIndexOutOfRange;
    var adj = try buildAdjacency(graph, allocator);
    defer adj.deinit();

    const n = graph.node_count;
    const parent = try allocator.alloc(i64, n);
    defer allocator.free(parent);
    for (parent) |*p| p.* = -1;
    parent[start] = @as(i64, @intCast(start));

    var queue = try std.ArrayList(u32).initCapacity(allocator, n);
    defer queue.deinit(allocator);
    try queue.append(allocator, @as(u32, @intCast(start)));
    var head: usize = 0;
    var found = (start == end);
    while (head < queue.items.len and !found) : (head += 1) {
        const v = @as(usize, queue.items[head]);
        for (adj.slice(v)) |nb| {
            if (parent[nb.node] == -1) {
                parent[nb.node] = @as(i64, @intCast(v));
                if (nb.node == end) {
                    found = true;
                    break;
                }
                try queue.append(allocator, @as(u32, @intCast(nb.node)));
            }
        }
    }
    if (!found) return null;

    // Reconstruct path end → start.
    var path = try std.ArrayList(u32).initCapacity(allocator, 16);
    errdefer path.deinit(allocator);
    var cur: usize = end;
    while (true) {
        try path.append(allocator, @as(u32, @intCast(cur)));
        if (cur == start) break;
        cur = @as(usize, @intCast(parent[cur]));
    }
    // Reverse in place.
    var i: usize = 0;
    var j: usize = path.items.len - 1;
    while (i < j) : ({
        i += 1;
        j -= 1;
    }) {
        const tmp = path.items[i];
        path.items[i] = path.items[j];
        path.items[j] = tmp;
    }
    return try path.toOwnedSlice(allocator);
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

test "bfs on a path graph visits in order" {
    var g = Graph.init(testing.allocator, 5);
    defer g.deinit();
    try g.addEdge(0, 1, 1.0);
    try g.addEdge(1, 2, 1.0);
    try g.addEdge(2, 3, 1.0);
    try g.addEdge(3, 4, 1.0);
    const order = try bfs(g, 0, testing.allocator);
    defer testing.allocator.free(order);
    try testing.expectEqual(@as(usize, 5), order.len);
    for (order, 0..) |v, i| try testing.expectEqual(@as(u32, @intCast(i)), v);
}

test "bfs skips disconnected components" {
    var g = Graph.init(testing.allocator, 5);
    defer g.deinit();
    try g.addEdge(0, 1, 1.0);
    try g.addEdge(2, 3, 1.0);
    const order = try bfs(g, 0, testing.allocator);
    defer testing.allocator.free(order);
    try testing.expectEqual(@as(usize, 2), order.len);
}

test "dfs on a triangle visits all three" {
    var g = Graph.init(testing.allocator, 3);
    defer g.deinit();
    try g.addEdge(0, 1, 1.0);
    try g.addEdge(1, 2, 1.0);
    try g.addEdge(0, 2, 1.0);
    const order = try dfs(g, 0, testing.allocator);
    defer testing.allocator.free(order);
    try testing.expectEqual(@as(usize, 3), order.len);
    var seen = [_]bool{ false, false, false };
    for (order) |v| seen[v] = true;
    for (seen) |s| try testing.expect(s);
}

test "sssp on a weighted path returns cumulative weights" {
    var g = Graph.init(testing.allocator, 4);
    defer g.deinit();
    try g.addEdge(0, 1, 2.0);
    try g.addEdge(1, 2, 3.0);
    try g.addEdge(2, 3, 4.0);
    const d = try sssp(g, 0, testing.allocator);
    defer testing.allocator.free(d);
    try testing.expectApproxEqAbs(@as(f64, 0.0), d[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 2.0), d[1], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 5.0), d[2], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 9.0), d[3], 1e-9);
}

test "sssp marks unreachable nodes as infinity" {
    var g = Graph.init(testing.allocator, 4);
    defer g.deinit();
    try g.addEdge(0, 1, 1.0);
    // Node 2, 3 are isolated.
    const d = try sssp(g, 0, testing.allocator);
    defer testing.allocator.free(d);
    try testing.expectEqual(@as(f64, 0.0), d[0]);
    try testing.expectApproxEqAbs(@as(f64, 1.0), d[1], 1e-9);
    try testing.expect(std.math.isInf(d[2]));
    try testing.expect(std.math.isInf(d[3]));
}

test "sssp picks the cheaper of two parallel paths" {
    var g = Graph.init(testing.allocator, 4);
    defer g.deinit();
    try g.addEdge(0, 1, 1.0);
    try g.addEdge(1, 3, 10.0);
    try g.addEdge(0, 2, 4.0);
    try g.addEdge(2, 3, 1.0);
    const d = try sssp(g, 0, testing.allocator);
    defer testing.allocator.free(d);
    // 0→2→3 = 5, 0→1→3 = 11; min is 5.
    try testing.expectApproxEqAbs(@as(f64, 5.0), d[3], 1e-9);
}

test "bfs / dfs reject out-of-range start" {
    var g = Graph.init(testing.allocator, 3);
    defer g.deinit();
    try testing.expectError(Error.NodeIndexOutOfRange, bfs(g, 3, testing.allocator));
    try testing.expectError(Error.NodeIndexOutOfRange, dfs(g, 3, testing.allocator));
    try testing.expectError(Error.NodeIndexOutOfRange, sssp(g, 3, testing.allocator));
}

test "buildAdjacency yields correct fan-out for triangle" {
    var g = Graph.init(testing.allocator, 3);
    defer g.deinit();
    try g.addEdge(0, 1, 1.0);
    try g.addEdge(1, 2, 1.0);
    try g.addEdge(0, 2, 1.0);
    var adj = try buildAdjacency(g, testing.allocator);
    defer adj.deinit();
    try testing.expectEqual(@as(usize, 2), adj.slice(0).len);
    try testing.expectEqual(@as(usize, 2), adj.slice(1).len);
    try testing.expectEqual(@as(usize, 2), adj.slice(2).len);
}

test "bfsPath returns shortest path or null" {
    var g = Graph.init(testing.allocator, 5);
    defer g.deinit();
    try g.addEdge(0, 1, 1.0);
    try g.addEdge(1, 2, 1.0);
    try g.addEdge(0, 3, 1.0);
    try g.addEdge(3, 2, 1.0);

    const p = try bfsPath(g, 0, 2, testing.allocator);
    try testing.expect(p != null);
    defer testing.allocator.free(p.?);
    try testing.expectEqual(@as(usize, 3), p.?.len);
    try testing.expectEqual(@as(u32, 0), p.?[0]);
    try testing.expectEqual(@as(u32, 2), p.?[2]);

    const none = try bfsPath(g, 0, 4, testing.allocator);
    try testing.expect(none == null);
}
