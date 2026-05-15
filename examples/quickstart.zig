// examples/quickstart.zig
//
// This file is the README "Quickstart" code block, vendored verbatim
// (lines 113..145 of README.md). It exists so the documentation claim is
// EXECUTABLE: `tools/doctest.sh` extracts the block from README and
// diffs against this file; drift between README and code FAILS the
// doc-test.
//
// If you edit the README Quickstart, you MUST update this file too.
// Conversely, if you change the API, you MUST update the README
// Quickstart. The doctest enforces the contract.

const std = @import("std");
const graph = @import("graph");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Two triangles joined by a bridge edge — a textbook two-community graph.
    var g = graph.Graph.init(allocator, 6);
    defer g.deinit();
    try g.addEdge(0, 1, 1.0);
    try g.addEdge(1, 2, 1.0);
    try g.addEdge(0, 2, 1.0);
    try g.addEdge(3, 4, 1.0);
    try g.addEdge(4, 5, 1.0);
    try g.addEdge(3, 5, 1.0);
    try g.addEdge(2, 3, 1.0); // bridge

    const bc = try graph.betweennessCentrality(g, allocator, .{ .unweighted = true });
    defer allocator.free(bc);

    var r = try graph.louvain(g, allocator, .{});
    defer r.deinit();

    var fr = try graph.fiedler(g, allocator, .{});
    defer fr.deinit();

    std.debug.print("communities={d} modularity={d:.4} fiedler={d:.4}\n",
        .{ r.num_communities, r.modularity, fr.value });
    for (bc, 0..) |v, i| std.debug.print(" node {d}: betweenness {d:.2}\n", .{ i, v });
}
