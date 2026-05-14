# Changelog

All notable changes to `zig-graph` are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project adheres to [Semantic Versioning](https://semver.org/).

## [1.0.0] — 2026-05-13

**Full algorithm surface.** Adds the seven algorithms the v0.1 README
listed as out-of-scope plus the supporting traversal primitives.

### Added
- `betweennessCentrality(graph, allocator, options)` — Brandes' algorithm.
  BFS variant for `unweighted = true` (O(|V|·|E|)); Dijkstra variant
  otherwise. Optional `[0, 1]` normalisation via `2 / ((n-1)(n-2))`.
- `closenessCentrality(graph, allocator)` — Wasserman-Faust normalised
  closeness on top of `sssp`. Handles disconnected components (isolated
  nodes get 0).
- `fiedlerValue` / `fiedlerVector` / `fiedler` — algebraic connectivity
  via deflated power iteration on `M = τI − L` with `τ = 2·max_deg + 1`.
  Validated against closed-form λ₁ for `P_n`, `C_n`, `K_{1,n-1}`, `K_n`,
  and a barbell reference. `O((|V| + |E|) · iters)` per call, no matrix
  factorisation.
- `louvain(graph, allocator, options)` — Blondel et al. 2008 modularity
  maximisation with local-move + aggregation phases. Returns labels,
  community count, and modularity `Q`. `modularity(graph, partition,
  allocator)` exposes Newman modularity for arbitrary partitions.
- `directedPagerank(graph, allocator, options)` — directed-edge variant
  respecting edge direction; sinks redistribute mass uniformly. Result
  sums to ~1.0.
- `bfs(graph, start, allocator)` — visit order from a start node.
- `dfs(graph, start, allocator)` — iterative pre-order.
- `sssp(graph, start, allocator)` — Dijkstra single-source distances;
  `inf` for unreachable nodes.
- `bfsPath(graph, start, end, allocator)` — shortest unweighted path or
  `null`.
- `buildAdjacency` / `buildDirectedAdjacency` — CSR-style adjacency
  construction exposed as public API (used internally; useful externally
  when you want to amortise the build across multiple operations).
- Three new benchmarks: `bench_betweenness.zig`, `bench_louvain.zig`,
  `bench_fiedler.zig`.

### Changed
- Test count: 16 → 50. New tests cover correctness on canonical small
  graphs for every new algorithm plus three new random-graph fuzz
  harnesses (betweenness non-negativity + upper-bound; Fiedler spectral
  bound + non-negativity; Louvain modularity ∈ [-0.5, 1]).
- Source factored into `src/{traversal, centrality, spectral, community}.zig`
  with `src/root.zig` as the re-export hub. Existing API is preserved
  verbatim (additive).
- Minimum Zig: `0.15.0` → `0.16.0`.

### Out of scope for v1.0
- Leiden refinement (Traag et al. 2019).
- Parallel-edge merging at construction time.
- Hypergraphs.
- ILP-based optimal community detection.
- CSR caching at the `Graph` level.
- GPU offload.

These remain deliberate. See README "Out of scope for v1.0".

## [0.1.0] — 2026-05-13

Initial release. Extracted from a sovereign NYISO research codebase where the
algorithms were tangled with domain-specific node and edge schemas; this
library exposes only the schema-free primitives.

### Added
- `Graph` data structure: `node_count` + `std.ArrayList(Edge)` + allocator.
  Edges are undirected. Node payload is intentionally not part of the type.
- `Edge` struct: `source`, `target`, `weight` (default 1.0).
- `weightedDegree(graph, allocator)` — sum of incident edge weights per node.
- `eigenvectorCentrality(graph, allocator, options)` — power iteration on
  the weighted adjacency matrix, L2-normalized.
- `pagerank(graph, allocator, options)` — undirected PageRank with damping
  (default 0.85), dangling-node uniform redistribution. Result sums to ~1.0.
- `cutEdges(graph, partition)` — count of edges crossing a partition.
- `conductance(graph, allocator, partition, set)` — standard
  `cut / min(vol(S), vol(V\S))`.
- `Error` enum: `NodeIndexOutOfRange`, `PartitionSizeMismatch`, plus
  allocator errors.
- 16 tests covering correctness on canonical small graphs (triangle, star,
  cycle, barbell) plus error-path validation.

### Notes
- No allocator-hidden state. Every algorithm allocates its result through
  the caller-provided allocator; caller owns the slice and frees it.
- `Graph` deinit only releases the edge list; `node_count` is a scalar.
