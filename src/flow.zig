const std = @import("std");
const root = @import("root.zig");

pub const FlowError = error{
    SourceEqualsSink,
    NodeIndexOutOfRange,
} || std.mem.Allocator.Error;

/// Edmonds-Karp algorithm for Max Flow.
/// Models the graph as a directed network where each edge provides capacity `weight`.
/// For undirected behavior, edges must be added in both directions by the caller.
/// Returns the maximum flow from source to sink.
pub fn maxFlowEdmondsKarp(
    graph: root.Graph,
    source: usize,
    sink: usize,
    allocator: std.mem.Allocator,
) FlowError!f64 {
    if (source == sink) return FlowError.SourceEqualsSink;
    if (source >= graph.node_count or sink >= graph.node_count) return FlowError.NodeIndexOutOfRange;

    // Build adjacency list for fast lookup
    var adj = try allocator.alloc(std.ArrayList(usize), graph.node_count);
    defer {
        for (adj) |*list| list.deinit(allocator);
        allocator.free(adj);
    }
    for (adj) |*list| list.* = std.ArrayList(usize).empty;

    // Initialize capacities and flow
    var capacity = std.AutoHashMap(struct {usize, usize}, f64).init(allocator);
    defer capacity.deinit();

    var flow_map = std.AutoHashMap(struct {usize, usize}, f64).init(allocator);
    defer flow_map.deinit();

    for (graph.edges.items) |edge| {
        try adj[edge.source].append(allocator, edge.target);
        try adj[edge.target].append(allocator, edge.source); // Add reverse edge for residual graph
        
        const cap = capacity.get(.{edge.source, edge.target}) orelse 0.0;
        try capacity.put(.{edge.source, edge.target}, cap + edge.weight);
        
        if (!capacity.contains(.{edge.target, edge.source})) {
            try capacity.put(.{edge.target, edge.source}, 0.0);
        }
        try flow_map.put(.{edge.source, edge.target}, 0.0);
        try flow_map.put(.{edge.target, edge.source}, 0.0);
    }

    var parent = try allocator.alloc(?usize, graph.node_count);
    defer allocator.free(parent);

    var max_flow: f64 = 0;

    var queue = std.ArrayList(usize).empty;
    defer queue.deinit(allocator);

    while (true) {
        @memset(parent, null);
        parent[source] = source; // Mark source as visited

        queue.clearRetainingCapacity();
        try queue.append(allocator, source);

        var path_found = false;
        var q_idx: usize = 0;

        while (q_idx < queue.items.len) : (q_idx += 1) {
            const u = queue.items[q_idx];
            if (u == sink) {
                path_found = true;
                break;
            }

            for (adj[u].items) |v| {
                if (parent[v] == null) {
                    const cap = capacity.get(.{u, v}) orelse 0.0;
                    const f = flow_map.get(.{u, v}) orelse 0.0;
                    if (cap - f > 0) {
                        parent[v] = u;
                        try queue.append(allocator, v);
                    }
                }
            }
        }

        if (!path_found) break;

        // Trace back to find path capacity
        var path_flow: f64 = std.math.floatMax(f64);
        var s: usize = sink;
        while (s != source) {
            const p = parent[s].?;
            const cap = capacity.get(.{p, s}) orelse 0.0;
            const f = flow_map.get(.{p, s}) orelse 0.0;
            path_flow = @min(path_flow, cap - f);
            s = p;
        }

        // Add path flow to overall flow
        max_flow += path_flow;

        // Update residual capacities
        var v: usize = sink;
        while (v != source) {
            const u = parent[v].?;
            const f_uv = flow_map.get(.{u, v}) orelse 0.0;
            const f_vu = flow_map.get(.{v, u}) orelse 0.0;
            try flow_map.put(.{u, v}, f_uv + path_flow);
            try flow_map.put(.{v, u}, f_vu - path_flow);
            v = u;
        }
    }

    return max_flow;
}

test "Edmonds-Karp Max Flow" {
    var graph = root.Graph.init(std.testing.allocator, 6);
    defer graph.deinit();

    // Source = 0, Sink = 5
    try graph.addEdge(0, 1, 16);
    try graph.addEdge(0, 2, 13);
    try graph.addEdge(1, 2, 10);
    try graph.addEdge(1, 3, 12);
    try graph.addEdge(2, 1, 4);
    try graph.addEdge(2, 4, 14);
    try graph.addEdge(3, 2, 9);
    try graph.addEdge(3, 5, 20);
    try graph.addEdge(4, 3, 7);
    try graph.addEdge(4, 5, 4);

    const max_f = try maxFlowEdmondsKarp(graph, 0, 5, std.testing.allocator);
    try std.testing.expectEqual(@as(f64, 23.0), max_f);
}
