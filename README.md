# zig-graph

Sparse undirected graph primitives and spectral algorithms in pure Zig. No
dependencies, no allocation hidden from the caller, suitable for hosts and
servers that need centrality / PageRank / cut-based partition scoring on
small-to-medium graphs.

## Status

`v0.1.0` — initial release. 16 tests cover edge insertion validation,
weighted degree, eigenvector centrality (regular triangle, star,
disconnected, heavy-edge bias), PageRank (cycle uniformity, star asymmetry,
dangling-node redistribution, weighted-edge ordering, normalization to 1),
cut/conductance (barbell, partition-size mismatch, empty-side handling), plus
a 10 000-iteration random-graph fuzz test that asserts centrality stays
finite, PageRank sums to 1.0, and `cutEdges` is bounded by `|E|` across
random partitions.

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

## Benchmarks

```sh
zig build bench
```

Three benchmarks ship under `bench/`:

- `bench_pagerank.zig` — PageRank convergence on random sparse graphs at
  100 / 1 000 / 10 000 nodes (avg degree ~8). Reports total ns per
  convergence + ms per run + configured iteration count (40).
- `bench_centrality.zig` — eigenvector centrality on the same matrix.
  Reports total ns + amortised ns per power-iteration step (32 steps
  per run).
- `bench_construct.zig` — `Graph.init` + N `addEdge` calls at 1 K /
  10 K / 100 K edges. Reports ns per `addEdge` and edges-added per
  second.

Each benchmark warms up for 3 runs, then measures with enough runs to
dampen variance over roughly one second of wall time at each size.
Output is parseable `key=value` lines so external collectors can scrape
them. Timing uses `std.os.linux.clock_gettime(.MONOTONIC, &ts)`
directly — `std.time.Timer` and `std.time.nanoTimestamp` were removed
in Zig 0.16's stdlib reshuffle.

Representative numbers on the maintainer's workstation
(Intel Core i7-1065G7 @ 1.30 GHz, Linux 7.0.3-arch1-1 x86_64, Zig
0.16.0, `zig build bench` with `-Doptimize=ReleaseFast`):

| Bench       | Size        | ns/op (run) | ms/run | ops/sec |
| ----------- | ----------- | ----------- | ------ | ------- |
| pagerank    | 100 nodes   | 1.76 M      |   1.76 |     569 |
| pagerank    | 1 000 nodes | 3.41 M      |   3.41 |     292 |
| pagerank    | 10 000 nodes| 71.1 M      |  71.1  |      14 |
| centrality  | 100 nodes   | 249 K       |   0.25 |   4 006 |
| centrality  | 1 000 nodes | 5.65 M      |   5.65 |     177 |
| centrality  | 10 000 nodes| 21.8 M      |  21.8  |      45 |
| construct   | 1 K edges   | 660 ns/edge |   0.66 | 1.5 M edges/s |
| construct   | 10 K edges  | 367 ns/edge |   3.68 | 2.7 M edges/s |
| construct   | 100 K edges | 442 ns/edge |  44.3  | 2.3 M edges/s |

The PageRank and centrality inner loops are bandwidth-bound: ns/op
scales roughly linearly with edges per run (40 × edges per PageRank
convergence; 32 × edges per centrality run). `addEdge` throughput is
dominated by the growable-array reallocation amortisation cost — the
1 K row's higher per-edge cost reflects the smaller working set
amortising over fewer resizes.

These numbers are on a busy laptop running concurrent agents; run-to-run
variance is ±2x for centrality and pagerank at the 100 / 1 K rows. Bring
your own data on a quiet machine for steady measurements.

## License

MIT. See `LICENSE`.

## Part of the Sovereign Stack

This is one of a set of small, composable Zig libraries.

- [**zig-cobs**](https://github.com/SMC17/zig-cobs) — COBS byte-stuffing framing, zero-alloc
- [**zig-frame-protocol**](https://github.com/SMC17/zig-frame-protocol) — versioned binary frame protocol
- [**zig-h3**](https://github.com/SMC17/zig-h3) — H3 v4 spatial index (composes naturally with graph algorithms over cell adjacency)

See [github.com/SMC17](https://github.com/SMC17) for the full portfolio.
