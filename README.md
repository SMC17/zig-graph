# zig-graph

[![CI](https://github.com/SMC17/zig-graph/actions/workflows/ci.yml/badge.svg)](https://github.com/SMC17/zig-graph/actions/workflows/ci.yml) [![Release](https://img.shields.io/github/v/release/SMC17/zig-graph?display_name=tag&sort=semver)](https://github.com/SMC17/zig-graph/releases) [![License](https://img.shields.io/github/license/SMC17/zig-graph)](LICENSE)

**A pure-Zig sparse graph library: 15 algorithms over BFS / DFS / Dijkstra / PageRank / Brandes betweenness / closeness / eigenvector centrality / Fiedler spectral / Louvain community, 50 / 50 tests passing, ~10 k random-graph fuzz iterations per build, zero hidden allocation, no dependencies.**

A `Graph` is `node_count` plus an `ArrayList(Edge)` of `{source, target,
weight}`. Edges are treated as undirected unless you use the directed
variant. Node payload (labels, geographic data, type tags) is *not* part
of the graph type — callers index their own arrays by node id. This is
what makes the library composable with any caller's data model.

## Status

`v1.2.0` — full algorithm surface. Evidence level: **unit-tested +
property-fuzzed + coverage-measured**.

**Line coverage: 86.98% on `src/` (394/453 lines)** across all 5
source files — `root.zig` 94.20%, `community.zig` 93.55%, `centrality.zig`
81.16%, `traversal.zig` 81.20%, `spectral.zig` 76.74%. Measured by
`tools/coverage.sh` (kcov against a dedicated `coverage-driver`
executable; reproducible in CI on every push). Uncovered lines are
predominantly defensive `unreachable` branches + `errdefer` cleanup
paths.

50 / 50 tests pass on Zig 0.16.0 (`zig build test`):

- Closed-form Fiedler-value tests against the analytic spectrum for
  `P_4`, `P_10`, `C_6`, `K_{1,4}` star, `K_4` complete, and a six-node
  barbell — tolerance `1e-5` to `1e-6`.
- Brandes betweenness on a 5-node path matches the analytic `(0, 3, 4, 3, 0)`;
  star center matches `(n-1)(n-2)/2 = 6` exactly; normalised star
  centrality is exactly `1.0`.
- PageRank sums to `1.0 ± 1e-6` on every test graph and fuzz iteration;
  dangling-node test asserts that a node with no incident edges still
  receives positive mass (uniform redistribution path).
- Louvain on two K₃ joined by a bridge recovers exactly two
  communities with modularity `Q > 0.30`; on a clique recovers one
  community; modularity self-report matches the standalone
  `modularity()` function.
- Four random-graph fuzz harnesses checking algorithm-level invariants:
  - **centrality / pagerank / cut** — 10 000 random graphs
    (1–64 nodes, `0..2n` edges); eigenvector finiteness (no NaN /
    Inf), PageRank `Σ = 1 ± 1e-6` and tiny-negative round-off only,
    cutEdges `≤ m`.
  - **fiedler** — 200 random graphs; `λ₁ ≥ -1e-8`, `λ₁ ≤ 2·max_deg + 1e-6`.
  - **betweenness** — 100 random graphs; `bc[v] ≥ -1e-9`,
    `bc[v] ≤ (n-1)(n-2)/2`, no NaN.
  - **louvain** — 60 random graphs; modularity `Q ∈ [-0.5, 1]`,
    `num_communities ∈ [1, n]`.

> `v1.0.0` shipped as a hygiene-only milestone (CI / SECURITY / contributor
> docs) and is preserved as the previous tag. `v1.1.0` is the first release
> with the full algorithm surface — the seven algorithms the original
> `v0.1.0` README listed as out-of-scope are all implemented here.

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

A seventh **scale benchmark** lives behind a separate `zig build bench-scale`
step (kept off the regular `bench` umbrella because the 1M-node graph
takes ~30 s and ~320 MB peak RSS):

- `bench_scale.zig` — 100K-node and 1M-node Erdős–Rényi graphs
  (avg degree ~20) running `pagerank`, `directedPagerank`, `bfs`,
  `sssp` (Dijkstra), and `weightedDegree`, each with its
  algorithm-level invariant asserted at scale. The process exits
  non-zero if any invariant breaks — the bench doubles as a
  scale-correctness regression test.
  **Pinned-hardware numbers** in [`bench/RESULTS.md`](bench/RESULTS.md):
  PageRank on 1M nodes / 10M edges in 27 s, sum-to-1 invariant
  delta 2.7e-14 (Intel Core i7-1065G7 @ 1.30 GHz, Linux, Zig 0.16,
  laptop with concurrent agents).

Output is parseable `key=value` whitespace-separated lines so external
collectors can scrape them. Timing uses
`std.os.linux.clock_gettime(.MONOTONIC, &ts)` directly — `std.time.Timer`
and `std.time.nanoTimestamp` were removed in Zig 0.16's stdlib reshuffle.

Representative numbers on the maintainer's workstation
(Intel Core i7-1065G7 @ 1.30 GHz, Linux 7.0.3-arch1-1 x86_64, Zig 0.16.0,
`zig build bench -Doptimize=ReleaseFast`, run on a busy laptop running
concurrent agents):

| Bench         | Size         |  ms/run | ops/sec | notes |
| ------------- | ------------ | ------: | ------: | ----- |
| pagerank      | 100 nodes    |    0.11 |   8 868 | 40 iters |
| pagerank      | 1 000 nodes  |    1.27 |     784 | 40 iters |
| pagerank      | 10 000 nodes |   17.4  |      57 | 40 iters |
| centrality    | 100 nodes    |    0.22 |   4 487 | 32 power iters |
| centrality    | 1 000 nodes  |    1.36 |     736 | 32 power iters |
| centrality    | 10 000 nodes |   25.97 |      38 | 32 power iters |
| betweenness   | 100 nodes    |    1.98 |     505 | Brandes BFS, O(VE) |
| betweenness   | 1 000 nodes  |  182.18 |       5 | Brandes BFS, O(VE) |
| louvain       | 100 nodes    |    0.91 |   1 098 | Q ≈ 0.319, 6 communities |
| louvain       | 1 000 nodes  |    9.46 |     105 | Q ≈ 0.330, 16 communities |
| fiedler       | 100 nodes    |    2.92 |     342 | 574 iters to converge, λ₁ ≈ 0.7955 |
| fiedler       | 1 000 nodes  |   65.19 |      15 | hit iter cap (1 000) on disconnected ER graph |
| fiedler       | 10 000 nodes |  479    |       2 | disconnected components → λ₁ ≈ 0 (correct) |
| construct     | 1 K edges    |    0.17 |  11.4 M edges/s | 87 ns/edge |
| construct     | 10 K edges   |    1.19 |   8.4 M edges/s | 119 ns/edge |
| construct     | 100 K edges  |   10.31 |   9.7 M edges/s | 103 ns/edge |

These numbers are on a busy laptop running concurrent agents; run-to-run
variance is ±2× for the inner-loop benchmarks. Bring your own data on a
quiet machine for steady measurements. Fiedler runs on disconnected
Erdős–Rényi random graphs converge to ≈ 0 — that is correct (a graph
with `k` components has `k` zero eigenvalues), not a bug.

## A fleet component — composable, replaceable, auditable

`zig-graph` is one hull section in a fleet of small, correctness-first
Zig libraries. The Graph type is bounded (one struct, three fields, one
edge list), the algorithms are composable (every routine takes a `Graph`
+ `Allocator` and returns caller-owned memory — no shared global state
between calls), the components are replaceable (no internal CSR cache,
no hidden cross-algorithm assumptions — you can rip out and swap any
algorithm without touching the others), and the surface is auditable
(every algorithm has at least one closed-form unit test against a
canonical graph, plus invariant-checking fuzz over random graphs).
That's what "Verifiable Fleet Engineering" means here in practice:
ships that operate independently, can be repaired at sea against their
own contract, and compose into larger fleets without negotiating
contracts with each other at runtime.

## Honest Type-I / Type-II accounting

Things this README could be read to over-claim (Type-I risk):

- "Validated against closed-form λ₁" applies to the **values** the
  algorithm returns on tiny canonical graphs (paths, cycles, stars,
  cliques, barbells), not to the full Fiedler-vector decomposition. On
  pathological inputs (very tight spectral gap, near-degenerate
  eigenvalues, or disconnected components with `k > 2`) deflated power
  iteration is known to converge slowly and can return a vector that
  mixes the bottom-`k` eigenspace. For research-grade spectral work on
  big graphs you want Lanczos / LOBPCG; that is intentionally out of
  scope here.
- Louvain is a **heuristic**. The library's modularity result is the
  modularity of the local-optimum partition Louvain finds, not the
  global maximum (NP-hard in general). On graphs with very tight cluster
  separation Louvain occasionally produces internally-disconnected
  communities at deep aggregation; that is a known Louvain artefact and
  the README "Out of scope" section names Leiden refinement as the
  follow-up.
- The benchmark numbers come from a single laptop run while many other
  agents were active. Treat the table as the *shape* of the cost curve,
  not as a steady-state production figure.

Things this README could be read to under-claim (Type-II risk):

- The fuzz harnesses run on every `zig build test`, so any future
  regression that lets NaN escape from PageRank, that lets betweenness
  go negative, or that pushes Louvain modularity outside `[-0.5, 1]`
  breaks CI loudly. That is a strong continuous-validation property the
  README does not headline.
- The PageRank dangling-node path is exercised by a dedicated unit test
  that asserts an isolated node receives positive mass and the total
  still sums to `1.0 ± 1e-6` — meaning the library does *not* silently
  leak mass on graphs with sinks, which is the most common PageRank
  implementation bug.
- No internal allocator. Every result is caller-owned and freed with
  `allocator.free` or `.deinit()`. There is no global state and no
  thread-local cache, so the library is safe to use from multiple
  threads as long as each thread holds its own `Graph` and `Allocator`.

## License

MIT. See `LICENSE`.

## Part of the Sovereign Stack

This is one of a set of small, composable Zig libraries.

- [**zig-cobs**](https://github.com/SMC17/zig-cobs) — COBS byte-stuffing framing, zero-alloc
- [**zig-frame-protocol**](https://github.com/SMC17/zig-frame-protocol) — versioned binary frame protocol
- [**zig-h3**](https://github.com/SMC17/zig-h3) — H3 v4 spatial index (composes naturally with graph algorithms over cell adjacency)

See [github.com/SMC17](https://github.com/SMC17) for the full portfolio.
