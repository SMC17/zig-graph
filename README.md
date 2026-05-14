# zig-graph

[![CI](https://github.com/SMC17/zig-graph/actions/workflows/ci.yml/badge.svg)](https://github.com/SMC17/zig-graph/actions/workflows/ci.yml) [![Release](https://img.shields.io/github/v/release/SMC17/zig-graph?display_name=tag&sort=semver)](https://github.com/SMC17/zig-graph/releases) [![License](https://img.shields.io/github/license/SMC17/zig-graph)](LICENSE)

Sparse graph primitives and spectral / centrality / community / traversal
algorithms in pure Zig. No dependencies, no allocation hidden from the caller,
suitable for hosts and servers that need real graph analytics on
small-to-medium graphs.

## Status

`v1.1.0` — full algorithm surface. 50 tests cover correctness on canonical
small graphs (path, cycle, star, complete, barbell), error-path validation,
and four random-graph fuzz harnesses (centrality / pagerank / cut +
betweenness + Fiedler + Louvain) checking finiteness, mass conservation,
non-negativity of betweenness, modularity bounds `[-0.5, 1]`, and spectral
bounds (`0 ≤ λ₁ ≤ 2·max_deg`).

> `v1.0.0` shipped as a hygiene-only milestone (CI / SECURITY / contributor
> docs) and is preserved as the previous tag. `v1.1.0` is the first release
> with the full algorithm surface — the seven algorithms the original `v0.1.0`
> README listed as out-of-scope are all implemented here.

Minimum Zig version: `0.16.0`. Tested on Zig `0.16.0`.

CI covers Linux x86_64, Linux aarch64, and macOS arm64 (native runners), plus
cross-compile sanity for `aarch64-linux-gnu`, `aarch64-macos`,
`x86_64-linux-gnu`, and `x86_64-macos` from the x86_64 host.

## Algorithms

| Function | What it computes |
|----------|------------------|
| `weightedDegree` | Sum of incident edge weights per node |
| `eigenvectorCentrality` | Power iteration on the weighted adjacency matrix, L2-normalized |
| `pagerank` | Undirected PageRank with damping (default 0.85), dangling-node uniform redistribution |
| `directedPagerank` | Directed PageRank respecting edge direction; sinks redistribute mass uniformly |
| `betweennessCentrality` | Brandes' algorithm — BFS (`unweighted = true`) or Dijkstra per source. Optional `[0, 1]` normalisation. |
| `closenessCentrality` | Wasserman-Faust normalised closeness (handles disconnected components) |
| `fiedlerValue` / `fiedlerVector` | Second-smallest eigenvalue of the Laplacian + corresponding eigenvector via deflated power iteration on `τI − L` |
| `louvain` | Modularity-maximising community detection (Blondel et al. 2008) |
| `modularity` | Modularity `Q` of an arbitrary partition |
| `cutEdges` | Count of edges crossing a node-level partition |
| `conductance` | Standard graph conductance for a subset: `cut(S) / min(vol(S), vol(V\S))` |
| `bfs` / `dfs` | Traversal visit order from a start node |
| `sssp` | Dijkstra single-source distances; `inf` for unreachable nodes |
| `bfsPath` | Shortest unweighted path from start → end, or `null` |
| `buildAdjacency` / `buildDirectedAdjacency` | Build a CSR-style adjacency (useful for callers that want to share one across multiple operations) |

## Design choices

- **Edges are undirected by default.** Each algorithm except
  `directedPagerank` and `buildDirectedAdjacency` walks both endpoints
  symmetrically. To use directed semantics, prefer `directedPagerank` or
  build a directed adjacency yourself.
- **No node payload in the graph type.** Nodes are bare `usize` IDs in
  `0..node_count`. Callers keep their own arrays of metadata (labels,
  coordinates, type tags) indexed by node ID. Extracted directly from a
  sovereign research codebase where the algorithms had to coexist with
  domain-specific node and edge schemas without forcing them into the
  library type.
- **Caller-owned result buffers.** Every algorithm takes an allocator and
  returns a slice (or a small result struct exposing one). Caller owns the
  result and frees it with `allocator.free` or `.deinit()`. No internal
  allocation pools, no implicit cleanup.

## Install

Add to `build.zig.zon`:

```zig
.dependencies = .{
    .graph = .{
        .url = "https://github.com/SMC17/zig-graph/archive/refs/tags/v1.1.0.tar.gz",
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

// --- degree / spectral / pagerank ---
pub fn weightedDegree(graph: Graph, allocator: std.mem.Allocator) Error![]f64;

pub const EigenvectorOptions = struct { iterations: usize = 32 };
pub fn eigenvectorCentrality(graph: Graph, allocator: std.mem.Allocator, options: EigenvectorOptions) Error![]f64;

pub const PageRankOptions = struct { damping: f64 = 0.85, iterations: usize = 40 };
pub fn pagerank(graph: Graph, allocator: std.mem.Allocator, options: PageRankOptions) Error![]f64;

pub const DirectedPageRankOptions = struct { damping: f64 = 0.85, iterations: usize = 40 };
pub fn directedPagerank(graph: Graph, allocator: std.mem.Allocator, options: DirectedPageRankOptions) Error![]f64;

pub const FiedlerOptions = struct { iterations: usize = 1_000, tolerance: f64 = 1e-10 };
pub const FiedlerResult = struct { value: f64, vector: []f64, iterations: usize, allocator: std.mem.Allocator };
pub fn fiedler(graph: Graph, allocator: std.mem.Allocator, options: FiedlerOptions) Error!FiedlerResult;
pub fn fiedlerValue(graph: Graph, allocator: std.mem.Allocator, options: FiedlerOptions) Error!f64;
pub fn fiedlerVector(graph: Graph, allocator: std.mem.Allocator, options: FiedlerOptions) Error![]f64;

// --- centrality ---
pub const BetweennessOptions = struct { unweighted: bool = false, normalize: bool = false };
pub fn betweennessCentrality(graph: Graph, allocator: std.mem.Allocator, options: BetweennessOptions) Error![]f64;
pub fn closenessCentrality(graph: Graph, allocator: std.mem.Allocator) Error![]f64;

// --- community ---
pub const LouvainOptions = struct {
    max_levels: usize = 32,
    max_sweeps_per_level: usize = 64,
    tolerance: f64 = 1e-7,
};
pub const LouvainResult = struct { labels: []u32, num_communities: usize, modularity: f64, allocator: std.mem.Allocator };
pub fn louvain(graph: Graph, allocator: std.mem.Allocator, options: LouvainOptions) Error!LouvainResult;
pub fn modularity(graph: Graph, partition: []const u32, allocator: std.mem.Allocator) Error!f64;

// --- partition quality ---
pub fn cutEdges(graph: Graph, partition: []const u32) Error!usize;
pub fn conductance(graph: Graph, allocator: std.mem.Allocator, partition: []const u32, set: u32) Error!f64;

// --- traversal ---
pub fn bfs(graph: Graph, start: usize, allocator: std.mem.Allocator) Error![]u32;
pub fn dfs(graph: Graph, start: usize, allocator: std.mem.Allocator) Error![]u32;
pub fn sssp(graph: Graph, start: usize, allocator: std.mem.Allocator) Error![]f64;
pub fn bfsPath(graph: Graph, start: usize, end: usize, allocator: std.mem.Allocator) Error!?[]u32;

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
sufficient for f64-precision convergence on graphs up to ~10⁴ nodes.

**Undirected PageRank** uses the symmetric formulation: each edge contributes
`damping * rank(endpoint) * weight / degree(endpoint)` mass to the other
endpoint per iteration. Dangling nodes (zero weighted degree) redistribute
their rank uniformly. Result sums to ~1.0.

**Directed PageRank** walks edges only in their stated direction. Sinks
(zero out-weight) redistribute mass uniformly per iteration to preserve
mass conservation. Result sums to ~1.0.

**Betweenness centrality** implements Brandes 2001. Two code paths: BFS for
`unweighted = true` (O(|V| · |E|) total), Dijkstra otherwise
(O(|V| · (|V| + |E|) log |V|)). The accumulation pass aggregates
dependencies in reverse stack order. Output is halved to avoid
double-counting undirected shortest paths. With `normalize = true` the
result is scaled by `2 / ((n-1)(n-2))` so values lie in `[0, 1]`.

**Closeness centrality** uses Wasserman-Faust normalisation:
`((R-1)/(n-1)) · ((R-1)/sum_dist)` where `R` is the reachable component
size from `v`. Isolated nodes get 0.

**Fiedler value** is computed by deflated power iteration on
`M = τI − L` where `τ = 2·max_deg + 1` (Gershgorin bound on `λ_max(L)`).
The all-ones eigenvector (corresponding to `λ₀ = 0`) is projected out
after each step, so the iterate converges to the eigenvector of `M`'s
*next* largest eigenvalue — which corresponds to `L`'s smallest
non-zero eigenvalue, the Fiedler value. We then return `λ₁` directly via
the Rayleigh quotient `xᵀ L x`. Cost per iteration: `O(|V| + |E|)`. No
matrix factorisation, no Lanczos basis, no Krylov subspace storage.
Convergence rate depends on the spectral gap `|λ₂ − λ₁|`.

Canonical Fiedler values used in tests (unit weights):

| Graph | λ₁ |
|-------|----|
| Path P₄ | `2 (1 − cos(π/4))` ≈ 0.5858 |
| Path P₁₀ | `2 (1 − cos(π/10))` ≈ 0.0979 |
| Cycle C₆ | `2 (1 − cos(π/3))` = 1.0 |
| Star K₁,₄ | 1.0 |
| Complete K₄ | 4.0 |
| Barbell (two K₃ + bridge) | ≈ 0.4384 |
| Two disconnected K₂ | 0.0 (within 1e-6) |

**Louvain community detection** follows Blondel et al. 2008: alternating
local-move and aggregation phases. Local-move sweeps every node and tries
each neighbour's community, picking the largest `ΔQ` move. Aggregation
collapses each community into a super-node with self-loops carrying the
intra-community weight. Halts when a local-move phase produces no
improvement. Result includes the final modularity `Q`.

**Conductance** uses the standard definition `cut(S) / min(vol(S), vol(V\S))`
where `vol(X)` is the sum of weighted degrees of nodes in `X`. Returns
`0.0` if either side has zero volume (caller can treat this as
"undefined").

## Out of scope for v1.0

These are deliberately deferred. Each has been thought through; the bar to
ship is "correctness against canonical small examples + invariant fuzz +
benchmark on a medium graph", same bar as everything else in v1.0.

- **Leiden refinement.** Louvain occasionally creates internally
  disconnected communities at deep aggregation; Leiden (Traag et al. 2019)
  fixes this with a refinement phase. Future minor version.
- **Parallel-edge weighting** at construction time. Right now duplicate
  edges accumulate as parallel edges. For most algorithms this is
  semantically correct (the weight sums at the algorithm level); Louvain
  collapses them in `Aggregated.fromGraph`. If you want explicit
  parallel-edge merging at the `Graph` level, do it in your own builder.
- **Hypergraphs.** The library is a binary-edge graph. Hyperedges with
  arity > 2 need a different data model (incidence matrix) — out of
  scope.
- **ILP-based optimal community detection.** The maximum-modularity
  partition is NP-hard; we ship the standard heuristic. If you want exact
  optima for small graphs, wrap a MILP solver.
- **CSR storage at the Graph level.** The current `ArrayList(Edge)`
  representation costs us a one-time `O(|V| + |E|)` adjacency build per
  traversal/centrality call. For graphs into the millions of edges the
  amortisation matters; the right upgrade path is to add a
  `compileAdjacency()` method on `Graph` that caches the CSR. We have not
  yet hit a customer where this is binding, so we have not paid the
  complexity cost.
- **GPU offload.** This is intentionally a pure-Zig host-side library.
  GPU work belongs in a separate sibling crate.

PRs welcome.

## Benchmarks

```sh
zig build bench
```

Six benchmarks ship under `bench/`:

- `bench_pagerank.zig` — undirected PageRank on random sparse graphs at
  100 / 1 000 / 10 000 nodes (avg degree ~8).
- `bench_centrality.zig` — eigenvector centrality on the same shapes.
- `bench_construct.zig` — `Graph.init` + N `addEdge` calls at 1 K /
  10 K / 100 K edges.
- `bench_betweenness.zig` — Brandes' algorithm (BFS variant) at
  100 / 1 000 nodes. (10 K skipped — Brandes is O(VE) and a 10 K-node
  sparse graph takes minutes.)
- `bench_louvain.zig` — full Louvain pass at 100 / 1 000 nodes. Reports
  the final modularity Q + community count alongside timing.
- `bench_fiedler.zig` — deflated power iteration at 100 / 1 000 / 10 000
  nodes. Reports the converged Fiedler value + iteration count alongside
  timing.

Output is parseable `key=value` whitespace-separated lines so external
collectors can scrape them. Timing uses
`std.os.linux.clock_gettime(.MONOTONIC, &ts)` directly — `std.time.Timer`
and `std.time.nanoTimestamp` were removed in Zig 0.16's stdlib reshuffle.

Representative numbers on the maintainer's workstation
(Intel Core i7-1065G7 @ 1.30 GHz, Linux 7.0.3-arch1-1 x86_64, Zig
0.16.0, `zig build bench` with `-Doptimize=ReleaseFast`):

| Bench         | Size         | ms/run  | ops/sec | notes |
| ------------- | ------------ | ------- | ------- | ----- |
| pagerank      | 100 nodes    |   0.45  |  2 228  | 40 iters |
| pagerank      | 1 000 nodes  |   8     |    123  | 40 iters |
| pagerank      | 10 000 nodes | 280     |      3  | 40 iters |
| centrality    | 100 nodes    |   0.56  |  1 770  | 32 power iters |
| centrality    | 1 000 nodes  |   4.9   |    204  | 32 power iters |
| centrality    | 10 000 nodes |  64     |     15  | 32 power iters |
| betweenness   | 100 nodes    |   3.9   |    257  | Brandes O(VE) |
| betweenness   | 1 000 nodes  | 502     |      1  | Brandes O(VE) |
| louvain       | 100 nodes    |   2.8   |    359  | Q ≈ 0.32 |
| louvain       | 1 000 nodes  |  20     |     49  | Q ≈ 0.33 |
| fiedler       | 100 nodes    |   8.1   |    123  | 574 iters to converge |
| fiedler       | 1 000 nodes  | 264     |      3  | hit iter cap (1000) on disc. ER graph |
| fiedler       | 10 000 nodes |1 366    |      0  | disconnected components → λ₁ ≈ 0 |
| construct     | 1 K edges    |   0.16  | 6.4 M edges/s |  |
| construct     | 10 K edges   |   3.2   | 3.1 M edges/s |  |
| construct     | 100 K edges  |   3.0   | 33.3 M edges/s | amortised |

These numbers are on a busy laptop running concurrent agents; run-to-run
variance is ±2× for the inner-loop benchmarks. Bring your own data on a
quiet machine for steady measurements. Fiedler runs on disconnected
random graphs converge to ≈ 0 — that is correct (a graph with k
components has k zero eigenvalues), not a bug.

## License

MIT. See `LICENSE`.

## Part of the Sovereign Stack

This is one of a set of small, composable Zig libraries.

- [**zig-cobs**](https://github.com/SMC17/zig-cobs) — COBS byte-stuffing framing, zero-alloc
- [**zig-frame-protocol**](https://github.com/SMC17/zig-frame-protocol) — versioned binary frame protocol
- [**zig-h3**](https://github.com/SMC17/zig-h3) — H3 v4 spatial index (composes naturally with graph algorithms over cell adjacency)

See [github.com/SMC17](https://github.com/SMC17) for the full portfolio.
