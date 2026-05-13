# zig-graph

Sparse undirected graph primitives and spectral algorithms in pure Zig. No
dependencies, no allocation hidden from the caller, suitable for hosts and
servers that need centrality / PageRank / cut-based partition scoring on
small-to-medium graphs.

## Status

`v0.1.0` — initial release. 15 tests cover edge insertion validation,
weighted degree, eigenvector centrality (regular triangle, star,
disconnected, heavy-edge bias), PageRank (cycle uniformity, star asymmetry,
dangling-node redistribution, weighted-edge ordering, normalization to 1),
and cut/conductance (barbell, partition-size mismatch, empty-side handling).

Minimum Zig version: `0.15.0`. Tested on Zig `0.16.0`.

## Algorithms

| Function | What it computes |
|----------|------------------|
| `weightedDegree` | Sum of incident edge weights per node |
| `eigenvectorCentrality` | Power iteration on the weighted adjacency matrix, L2-normalized result |
| `pagerank` | Undirected PageRank with damping (default 0.85), dangling-node uniform redistribution |
| `cutEdges` | Count of edges crossing a node-level partition |
| `conductance` | Standard graph conductance for a subset: `cut(S) / min(vol(S), vol(V\S))` |

## Design choices

- **Edges are undirected.** Each algorithm walks both endpoints symmetrically.
  To model a directed graph, callers add edges in only one direction and
  interpret results accordingly; the library does not enforce a direction.
- **No node payload in the graph type.** Nodes are bare `usize` IDs in
  `0..node_count`. Callers keep their own arrays of metadata (labels,
  coordinates, type tags) indexed by node ID. This keeps the library
  composable with any data model — extracted directly from a sovereign
  research codebase where it had to coexist with NYISO-specific node and
  edge schemas without forcing them into the library type.
- **Caller-owned result buffers.** Every algorithm takes an allocator and
  returns a slice. Caller owns the result and frees it with
  `allocator.free`. No internal allocation pools, no implicit cleanup.

## Install

Add to `build.zig.zon`:

```zig
.dependencies = .{
    .graph = .{
        .url = "https://github.com/SMC17/zig-graph/archive/refs/tags/v0.1.0.tar.gz",
        .hash = "...",
    },
},
```

In `build.zig`:

```zig
const graph = b.dependency("graph", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("graph", graph.module("graph"));
```

## Quickstart

```zig
const std = @import("std");
const graph = @import("graph");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Build a small graph: a triangle plus a pendant node.
    var g = graph.Graph.init(allocator, 4);
    defer g.deinit();
    try g.addEdge(0, 1, 1.0);
    try g.addEdge(1, 2, 1.0);
    try g.addEdge(0, 2, 1.0);
    try g.addEdge(0, 3, 1.0); // pendant attached to node 0

    const ec = try graph.eigenvectorCentrality(g, allocator, .{});
    defer allocator.free(ec);
    for (ec, 0..) |v, i| std.debug.print("node {d} centrality {d:.4}\n", .{ i, v });

    const pr = try graph.pagerank(g, allocator, .{});
    defer allocator.free(pr);
    for (pr, 0..) |v, i| std.debug.print("node {d} pagerank {d:.4}\n", .{ i, v });
}
```

## API

```zig
pub const Edge = struct { source: usize, target: usize, weight: f64 = 1.0 };

pub const Graph = struct {
    node_count: usize,
    edges: std.ArrayList(Edge),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, node_count: usize) Graph;
    pub fn deinit(self: *Graph) void;
    pub fn addEdge(self: *Graph, source: usize, target: usize, weight: f64) Error!void;
};

pub fn weightedDegree(graph: Graph, allocator: std.mem.Allocator) Error![]f64;

pub const EigenvectorOptions = struct { iterations: usize = 32 };
pub fn eigenvectorCentrality(
    graph: Graph,
    allocator: std.mem.Allocator,
    options: EigenvectorOptions,
) Error![]f64;

pub const PageRankOptions = struct {
    damping: f64 = 0.85,
    iterations: usize = 40,
};
pub fn pagerank(
    graph: Graph,
    allocator: std.mem.Allocator,
    options: PageRankOptions,
) Error![]f64;

pub fn cutEdges(graph: Graph, partition: []const u32) Error!usize;
pub fn conductance(
    graph: Graph,
    allocator: std.mem.Allocator,
    partition: []const u32,
    set: u32,
) Error!f64;

pub const Error = error{
    NodeIndexOutOfRange,
    PartitionSizeMismatch,
} || std.mem.Allocator.Error;
```

## Algorithmic notes

**Eigenvector centrality** runs power iteration on the weighted adjacency
matrix for a fixed number of steps (default 32). Each step computes
`x' = A x` and normalizes. For connected non-bipartite graphs the
Perron-Frobenius eigenvector dominates and 32 iterations are usually
sufficient for f64-precision convergence on graphs up to ~10⁴ nodes. For
larger graphs or tighter convergence, increase `iterations`.

**PageRank** uses the undirected formulation: each edge contributes
`damping * rank(endpoint) * weight / degree(endpoint)` mass to the other
endpoint per iteration. Dangling nodes (zero weighted degree) redistribute
their rank uniformly across all nodes per iteration to preserve mass
conservation. Result sums to ~1.0 modulo floating-point error.

**Conductance** uses the standard definition `cut(S) / min(vol(S), vol(V\S))`
where `vol(X)` is the sum of weighted degrees of nodes in `X`. Returns
`0.0` if either side has zero volume (caller can treat this as
"undefined").

## Out of scope for v0.1.0

- Fiedler value / algebraic connectivity (requires shift-and-invert or
  Lanczos on the Laplacian — non-trivial linear algebra)
- Betweenness centrality (all-pairs shortest paths)
- Closeness centrality
- Community detection (Louvain, Leiden)
- Directed PageRank (planned)
- Graph traversal helpers (BFS / DFS / SSSP)

Future versions may add these. PRs welcome — the bar is "well-tested
correctness against canonical small examples" plus a benchmark on a
medium graph.

## License

MIT. See `LICENSE`.
