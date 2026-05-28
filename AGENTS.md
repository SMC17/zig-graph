# zig-graph Agent Entry Point

Zig 0.16 sparse graph primitives:
- Traversal: `bfs`, `dfs`, `sssp` (Dijkstra), `bfsPath`.
- Centrality: `eigenvectorCentrality`, `betweennessCentrality` (Brandes),
  `closenessCentrality`, `pagerank` (undirected + directed).
- Spectral: `fiedlerValue`, `fiedlerVector`, `fiedler`.
- Community: `louvain` (Blondel et al. 2008), `modularity`.
- Partition quality: `cutEdges`, `conductance`.
- Flow: `maxFlowEdmondsKarp`.

## Workflow

```sh
zig fmt --check src/ build.zig
zig build test          # 70 tests (51 unit + 19 cross-val vs networkx 3.6.1)
zig build bench         # 6 benches, ReleaseFast
zig build bench-scale   # 100K + 1M-node ER graphs with invariant checks
```

See [`STATUS.md`](STATUS.md) for the proof-vocabulary index per component
and the open gates (G1 power-law scale-test, G2 soak time, G3 independent
numerics review, G4 Fiedler external-reference cross-val, G5 Zig 1.0).

## Conventions

- Caller-owned allocation. Every result is freed by the caller with
  `allocator.free` or `.deinit()`. No internal pools.
- Edges are undirected by default. Directed variants are explicit
  (`directedPagerank`, `buildDirectedAdjacency`, `maxFlowEdmondsKarp`).
- New algorithms need: closed-form unit test on a canonical small graph
  + invariant fuzz + (where applicable) cross-validation against
  networkx 3.6.1 in `tests/crossval_test.zig`.
- Pre-1.0 vocabulary discipline: no "production-grade" / "battle-tested"
  / "stable v1.0" claims until Zig itself ships 1.0.
