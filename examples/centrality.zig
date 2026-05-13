//! Minimal zig-graph example — build a 6-node graph, compute weighted
//! degree, eigenvector centrality, and PageRank, print the rankings.
//!
//! Build: `zig build example-centrality`
//! Run:   `./zig-out/bin/example-centrality`

const std = @import("std");
const graph = @import("graph");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    // Two triangles (0-1-2 and 3-4-5) connected by a single bridge edge 2-3.
    // Node 2 and node 3 should have the highest centrality (they hold the
    // bridge); nodes 0/1/4/5 should be roughly symmetric pairs.
    var g = graph.Graph.init(a, 6);
    defer g.deinit();
    try g.addEdge(0, 1, 1.0);
    try g.addEdge(1, 2, 1.0);
    try g.addEdge(0, 2, 1.0);
    try g.addEdge(3, 4, 1.0);
    try g.addEdge(4, 5, 1.0);
    try g.addEdge(3, 5, 1.0);
    try g.addEdge(2, 3, 1.0); // the bridge

    const deg = try graph.weightedDegree(g, a);
    defer a.free(deg);

    const ec = try graph.eigenvectorCentrality(g, a, .{});
    defer a.free(ec);

    const pr = try graph.pagerank(g, a, .{});
    defer a.free(pr);

    std.debug.print("node | degree | eigenvector | pagerank\n", .{});
    std.debug.print("-----|--------|-------------|---------\n", .{});
    for (0..6) |i| {
        std.debug.print(" {d}   | {d:>6.2} |   {d:>7.4}   | {d:>7.4}\n", .{ i, deg[i], ec[i], pr[i] });
    }

    // Partition: triangle A = {0,1,2}, triangle B = {3,4,5}. The bridge is
    // the cut. Standard conductance = cut(S) / min(vol(S), vol(V\S)).
    const partition = [_]u32{ 0, 0, 0, 1, 1, 1 };
    const cut = try graph.cutEdges(g, &partition);
    const cond = try graph.conductance(g, a, &partition, 0);
    std.debug.print("\nbarbell partition: cut={d}, conductance={d:.4}\n", .{ cut, cond });
}
