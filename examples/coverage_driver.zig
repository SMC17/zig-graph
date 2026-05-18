//! coverage_driver — plain executable that exercises every public function
//! and every public error path in `src/root.zig`. Same pattern as the rest
//! of the fleet (zig-cobs v1.2.0, zig-frame-protocol v0.2.0, zig-h3 v1.4.0,
//! sentinel-sbom v1.1.0): a single-binary executable that kcov can run
//! end-to-end. The Zig 0.16 test runner's debug-info layout doesn't
//! surface line-coverage to the nixpkgs kcov build (compiled without
//! libbfd-dev); a plain exe with standard ELF+DWARF captures cleanly.

const std = @import("std");
const graph = @import("graph");

pub fn main() !void {
    // page_allocator (not DebugAllocator) — kcov + DebugAllocator interact
    // badly under ptrace on this nixpkgs build; the leak-check exit step
    // makes kcov return "PT error" and zero out the coverage report.
    const a = std.heap.page_allocator;

    // --- 1. Graph init + addEdge + deinit ---
    {
        var g = graph.Graph.init(a, 5);
        defer g.deinit();
        try g.addEdge(0, 1, 1.0);
        try g.addEdge(1, 2, 1.0);
        try g.addEdge(2, 3, 1.0);
        try g.addEdge(3, 4, 1.0);
        try g.addEdge(4, 0, 1.0); // 5-cycle C_5
    }

    // --- 2. weightedDegree on a path graph ---
    {
        var g = graph.Graph.init(a, 4);
        defer g.deinit();
        try g.addEdge(0, 1, 1.0);
        try g.addEdge(1, 2, 1.0);
        try g.addEdge(2, 3, 1.0);
        const deg = try graph.weightedDegree(g, a);
        defer a.free(deg);
        if (deg.len != 4) return error.DegreeLenMismatch;
    }

    // --- 3. pagerank on a small graph ---
    {
        var g = graph.Graph.init(a, 4);
        defer g.deinit();
        try g.addEdge(0, 1, 1.0);
        try g.addEdge(1, 2, 1.0);
        try g.addEdge(2, 3, 1.0);
        try g.addEdge(3, 0, 1.0);
        const ranks = try graph.pagerank(g, a, .{});
        defer a.free(ranks);
        // Symmetric 4-cycle: every rank should be ~0.25.
        var sum: f64 = 0;
        for (ranks) |r| sum += r;
        if (@abs(sum - 1.0) > 1e-6) return error.RanksDoNotSum;
    }

    // --- 4. directedPagerank with dangling nodes ---
    {
        var g = graph.Graph.init(a, 5);
        defer g.deinit();
        try g.addEdge(0, 1, 1.0);
        try g.addEdge(1, 2, 1.0);
        try g.addEdge(2, 0, 1.0);
        // Node 3 and 4 are dangling (no outbound edges).
        const ranks = try graph.directedPagerank(g, a, .{});
        defer a.free(ranks);
    }

    // --- 5. eigenvectorCentrality on K_4 ---
    {
        var g = graph.Graph.init(a, 4);
        defer g.deinit();
        // Complete graph K_4: all 6 edges.
        try g.addEdge(0, 1, 1.0);
        try g.addEdge(0, 2, 1.0);
        try g.addEdge(0, 3, 1.0);
        try g.addEdge(1, 2, 1.0);
        try g.addEdge(1, 3, 1.0);
        try g.addEdge(2, 3, 1.0);
        const centr = try graph.eigenvectorCentrality(g, a, .{});
        defer a.free(centr);
        // K_4 has all-equal centrality.
    }

    // --- 6. betweenness + closeness centrality on a path P_5 ---
    {
        var g = graph.Graph.init(a, 5);
        defer g.deinit();
        try g.addEdge(0, 1, 1.0);
        try g.addEdge(1, 2, 1.0);
        try g.addEdge(2, 3, 1.0);
        try g.addEdge(3, 4, 1.0);
        const bet = try graph.betweennessCentrality(g, a, .{});
        defer a.free(bet);
        const cls = try graph.closenessCentrality(g, a);
        defer a.free(cls);
    }

    // --- 7. fiedler spectral split on a barbell ---
    {
        var g = graph.Graph.init(a, 6);
        defer g.deinit();
        // Two triangles joined by one bridge: clear Fiedler partition.
        try g.addEdge(0, 1, 1.0);
        try g.addEdge(1, 2, 1.0);
        try g.addEdge(2, 0, 1.0);
        try g.addEdge(3, 4, 1.0);
        try g.addEdge(4, 5, 1.0);
        try g.addEdge(5, 3, 1.0);
        try g.addEdge(2, 3, 1.0); // bridge
        var fr = try graph.fiedler(g, a, .{});
        defer fr.deinit();
        const val = try graph.fiedlerValue(g, a, .{});
        _ = val;
        const vec = try graph.fiedlerVector(g, a, .{});
        defer a.free(vec);
    }

    // --- 8. louvain community detection on the barbell ---
    {
        var g = graph.Graph.init(a, 6);
        defer g.deinit();
        try g.addEdge(0, 1, 1.0);
        try g.addEdge(1, 2, 1.0);
        try g.addEdge(2, 0, 1.0);
        try g.addEdge(3, 4, 1.0);
        try g.addEdge(4, 5, 1.0);
        try g.addEdge(5, 3, 1.0);
        try g.addEdge(2, 3, 1.0);
        var lr = try graph.louvain(g, a, .{});
        defer lr.deinit();
        const q = try graph.modularity(g, lr.labels, a);
        _ = q;
    }

    // --- 9. cutEdges + conductance on a partition ---
    {
        var g = graph.Graph.init(a, 6);
        defer g.deinit();
        try g.addEdge(0, 1, 1.0);
        try g.addEdge(1, 2, 1.0);
        try g.addEdge(2, 0, 1.0);
        try g.addEdge(3, 4, 1.0);
        try g.addEdge(4, 5, 1.0);
        try g.addEdge(5, 3, 1.0);
        try g.addEdge(2, 3, 1.0);
        // Two-community partition: triangles {0,1,2} and {3,4,5}.
        const partition = [_]u32{ 0, 0, 0, 1, 1, 1 };
        const cuts = try graph.cutEdges(g, &partition);
        if (cuts != 1) return error.WrongCutCount;
        const cond = try graph.conductance(g, a, &partition, 0);
        _ = cond;
    }

    // --- 10. bfs / dfs / sssp / bfsPath ---
    {
        var g = graph.Graph.init(a, 6);
        defer g.deinit();
        try g.addEdge(0, 1, 1.0);
        try g.addEdge(0, 2, 1.0);
        try g.addEdge(1, 3, 1.0);
        try g.addEdge(2, 4, 1.0);
        try g.addEdge(3, 5, 1.0);
        try g.addEdge(4, 5, 1.0);
        var adj = try graph.buildAdjacency(g, a);
        defer freeAdj(a, &adj);
        var adj_d = try graph.buildDirectedAdjacency(g, a);
        defer freeAdj(a, &adj_d);

        const bfs_dist = try graph.bfs(g, 0, a);
        defer a.free(bfs_dist);
        const dfs_order = try graph.dfs(g, 0, a);
        defer a.free(dfs_order);
        const sssp_dist = try graph.sssp(g, 0, a);
        defer a.free(sssp_dist);
        if (try graph.bfsPath(g, 0, 5, a)) |path| {
            defer a.free(path);
        }
    }

    // --- 11. Error paths ---
    {
        var g = graph.Graph.init(a, 3);
        defer g.deinit();
        // NodeIndexOutOfRange: source out of range.
        try expectErr(graph.Error.NodeIndexOutOfRange, g.addEdge(5, 0, 1.0));
        // NodeIndexOutOfRange: target out of range.
        try expectErr(graph.Error.NodeIndexOutOfRange, g.addEdge(0, 5, 1.0));
    }
    {
        var g = graph.Graph.init(a, 3);
        defer g.deinit();
        try g.addEdge(0, 1, 1.0);
        try g.addEdge(1, 2, 1.0);
        // PartitionSizeMismatch: partition len != node_count.
        const bad_partition = [_]u32{ 0, 0 };
        try expectErr(graph.Error.PartitionSizeMismatch, graph.cutEdges(g, &bad_partition));
    }
}

fn freeAdj(allocator: std.mem.Allocator, adj: *graph.Adjacency) void {
    _ = allocator;
    adj.deinit();
}

fn expectErr(expected: graph.Error, actual: anytype) !void {
    if (actual) |_| {
        return error.ExpectedError;
    } else |err| {
        if (err != expected) return error.WrongError;
    }
}
