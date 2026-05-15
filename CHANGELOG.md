# Changelog

All notable changes to `zig-graph` are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Honesty correction — 2026-05-15

Prior `v1.0` / `v1.1` / "production-grade hygiene milestone" /
"full algorithm surface" framing was a Type-I error class per the
no-premature-production-claims doctrine:

- **Zig itself is on 0.16, not 1.0.** No Zig library can credibly claim
  API stability beyond "stable on Zig 0.16 today" until the language
  itself ships 1.0. The v1.x git tags are honored for changelog
  continuity, but every reader should treat this as **pre-1.0 in semver
  spirit** until both that gate and a real-deployment gate close.
- **Zero production deployment exists.** No real-traffic operation, no
  soak time, no incident history. The hygiene work
  (LICENSE / SECURITY / CONTRIBUTING / CI / CODE_OF_CONDUCT / dependabot
  / CODEOWNERS) is real. The production claim it implied **wasn't
  earned** — and the numerical surface in particular still has at
  least one real-narrow-tolerance mutation survivor on
  `eigenvectorCentrality` (`M05`) honestly classified rather than
  closed.

Going forward, the AGENT_HARNESS proof vocabulary (`scaffold` /
`compiled` / `unit-tested` / `integration-tested` / `audited` /
`benchmarked` / `hardware-verified`) is used strictly. See `STATUS.md`
for the per-component proof index + the gates (G1 scale-tested
throughput on SNAP-class graphs + a committed `bench/RESULTS.md`,
G2 soak time + downstream user, G3 independent numerics review,
G4 external-reference cross-val for Fiedler, G5 Zig 1.0) that would
justify a stronger claim.

### Added
- Mutation-testing harness (`tools/mutation-test.sh`) applying 14 hand-picked
  operators across `src/{root, spectral, community, centrality}.zig`. Targets
  the numerical-algorithm code that the cross-validation suite probes but
  doesn't fully kill: PageRank damping sign + base mass, eigenvector
  power-iteration norm check, Fiedler Rayleigh-quotient cross-term
  coefficient, Louvain self-loop weighted-degree coefficient, Brandes
  betweenness undirected-halving and recurrence base case. Result on this
  commit: **11 killed / 3 survived (78.6%)** with all three survivors
  honestly classified:
  * `M05 eigenvectorCentrality iterations halved` — real-narrow gap; the
    1e-4 cross-val tolerance is just loose enough to admit 16 power-iteration
    steps where 32 is the default. Not a real algorithm bug.
  * `M09 Fiedler tau drops +1 safety margin` — equivalent mutant; the
    deflation step removes the all-ones mode regardless of tau as long as
    2·max_deg ≥ λ_max(L), which holds by Gershgorin.
  * `M11 Louvain best-gain comparator > to >=` — equivalent mutant for
    floating-point inputs; the boundary `gain_rel == best_gain + tolerance`
    is a measure-zero event on real graphs.
- New regression test in `src/community.zig`:
  `louvain self-loop weighted-degree: heavy self-loop forces singleton`.
  Constructs a barbell-6 with a heavy self-loop (weight 5) on node 0 and
  asserts that node 0 forms its own community (the modularity-optimal
  partition under correct undirected-self-loop degree accounting). Kills
  mutation `M12 (self-loop degree contribution 2.0 -> 1.0)`, which silently
  passed under the previous test suite because no Louvain test exercised
  self-loops.

- Cross-validation suite (`tests/crossval_test.zig`, `zig build crossval`)
  comparing zig-graph against networkx 3.6.1 + closed-form references on
  Zachary's Karate Club (weighted), Petersen graph, P_5, C_6, K_5. Observed
  deltas on weighted karate: PageRank 9.6e-12, eigenvector centrality
  1.1e-15, modularity / conductance / cut size exact, Louvain Q = 0.444904
  matching networkx weighted-louvain best-of-50-seeds (0.444904). 14 tests;
  wired into `zig build test` so the external-reference contract holds in CI.
- Directed PageRank cross-validation extends the suite to `directedPagerank`
  (previously audited only by internal invariants). References generated via
  `nx.pagerank(DiGraph(...), alpha=0.85, tol=1e-12, max_iter=2000)` on four
  canonical directed graphs: (i) inbound directed star (5 leaves → 1 center),
  (ii) directed cycle C_5 (rotational symmetry → uniform 0.2), (iii) 7-node
  fully asymmetric DiGraph with a sink and a back-edge, (iv) directed perfect
  binary tree (4 leaf sinks — exercises dangling-mass redistribution). Max
  observed delta vs networkx across all four: 1.02e-12 (star), 0 (cycle,
  closed-form), 5.09e-13 (asym), 1.92e-13 (binary tree). Five new tests
  (4 hard gates + 1 audit summary), test count 64 → 69.

### Changed
- Test count: 69 → 70 (added the self-loop Louvain regression described above).

## [1.1.0] — 2026-05-13

**Full algorithm surface.** Adds the seven algorithms the v0.1 README
listed as out-of-scope plus the supporting traversal primitives.

> Note: `v1.0.0` (also dated 2026-05-13) shipped earlier the same day as a
> hygiene-only milestone (CI / SECURITY / contributor docs / API-freeze
> statement). It is preserved as the previous tag. This is the first release
> with the genuine algorithmic v1.0 content; bumped to `v1.1.0` to avoid
> rewriting the already-published `v1.0.0` tag.

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

### Out of scope
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
