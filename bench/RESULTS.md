# zig-graph benchmark results

Pinned-hardware throughput numbers for the load-bearing algorithms.
This file closes the **G1 — Scale-tested throughput** gate named in
[`STATUS.md`](../STATUS.md).

## Hardware

| field        | value                                                |
|--------------|------------------------------------------------------|
| CPU          | Intel Core i7-1065G7 @ 1.30 GHz (4 cores / 8 threads, Ice Lake) |
| RAM          | 15 GiB DDR4                                          |
| OS           | Linux 7.0.3-arch1-1 x86_64 (SMP PREEMPT_DYNAMIC)     |
| Zig          | 0.16.0                                               |
| Build flag   | `zig build bench-scale` (ReleaseFast)                |
| Timer        | `std.os.linux.clock_gettime(.MONOTONIC, ...)`        |
| Load profile | Laptop running concurrent agents; expect ±2× run-to-run variance |

Reproduce with:

```
zig build bench-scale
```

The build step compiles `bench/bench_scale.zig` in `ReleaseFast` and
runs it once. The bench exits non-zero if any algorithm-level invariant
fails at scale.

## Scale results — Erdős–Rényi G(n, m)

PRNG seed `0x5CA1EBE17` pinned in the source. Avg degree ≈ 2·m/n ≈ 20
(undirected; ER edges sampled uniformly with self-loops nudged so
exactly `m` edges land in the graph). Edge weight = 1.0 throughout.

### 100K nodes / 1M edges

| algorithm           | wall time | per-node-per-iter | invariant sum-delta | invariant verdict |
|---------------------|----------:|------------------:|--------------------:|-------------------|
| construct           |     39 ms |                 — |                   — | (no invariant)    |
| weightedDegree      |     10 ms |                 — |            0.0e+00  | **OK** (Σwd = 2m exact) |
| pagerank (undir)    |  1 121 ms |            280 ns |            3.1e-15  | **OK** (Σ = 1 ± 1e-6) |
| directedPagerank    |    779 ms |            194 ns |            1.6e-15  | **OK** (Σ = 1 ± 1e-5) |
| bfs (from node 0)   |    135 ms |                 — |              n=100k | **OK** (full reach)   |
| sssp Dijkstra (from 0) | 149 ms |                 — |          dist[0]=0  | **OK** (no NaN)       |

### 1M nodes / 10M edges

| algorithm           |  wall time | per-node-per-iter | invariant sum-delta | invariant verdict |
|---------------------|-----------:|------------------:|--------------------:|-------------------|
| construct           |     334 ms |                 — |                   — | (no invariant)    |
| weightedDegree      |     182 ms |                 — |            0.0e+00  | **OK** (Σwd = 2m exact) |
| pagerank (undir)    |  26 952 ms |            673 ns |            2.7e-14  | **OK** (Σ = 1 ± 1e-6) |
| directedPagerank    |  12 690 ms |            317 ns |            3.3e-14  | **OK** (Σ = 1 ± 1e-5) |
| bfs (from node 0)   |   1 503 ms |                 — |              n=1M   | **OK** (full reach)   |
| sssp Dijkstra (from 0) | 1 599 ms |                 — |          dist[0]=0  | **OK** (no NaN)       |

### Headline numbers

- **PageRank on 1M nodes / 10M edges in 27 seconds**, sum-to-1 invariant
  holds to 2.7e-14 (well under the 1e-6 tolerance the unit-test suite
  uses). Per node per iteration: 673 ns on a four-year-old laptop chip
  with concurrent agents stealing cores.
- **BFS / SSSP scale to 1M nodes in ~1.5 s.** Linear-in-|E|, no
  algorithm-level surprises crossing the 100K → 1M decade.
- **directedPageRank is ~2× faster** than undirected at scale because it
  walks each edge once instead of twice — consistent with the inner-
  loop cost being dominated by edge traversal.

## Invariants checked at scale

Each algorithm's bench block asserts the same invariant the unit test
suite uses, just over 100K- and 1M-node random graphs instead of the
6-node textbook graphs. If an invariant breaks, the bench process exits
non-zero — the bench doubles as a scale-correctness regression test.

| algorithm           | invariant checked                                        |
|---------------------|----------------------------------------------------------|
| `weightedDegree`    | `Σ wd = 2 · total_edge_weight` (every edge contributes to both endpoints in an undirected graph) |
| `pagerank`          | `\|Σ pr − 1\| < 1e-6` AND no NaN/Inf escapes             |
| `directedPagerank`  | `\|Σ pr − 1\| < 1e-5` AND no NaN/Inf escapes (looser bound — sink redistribution loses precision) |
| `bfs`               | `\|order\| ≤ n` AND `order[0] == source`                 |
| `sssp`              | `\|dist\| == n` AND `dist[source] == 0` AND no NaN       |

The 1e-6 tolerance for PageRank sum-to-1 matches the per-iteration
floating-point error budget Wikipedia + networkx publish for power
iteration on doubles. At 40 iterations on f64, the observed delta is
~14 orders of magnitude below the tolerance — a comfortable margin.

## Type-II annotations

These benchmark numbers DO NOT claim:

- **Power-law / scale-free behavior.** ER graphs have logarithmic
  diameter; web / social / road graphs have power-law degree
  distributions and longer diameter. PageRank convergence rate
  in particular is sensitive to the spectral gap, which is wider
  for ER than for power-law. A future bench targeting SNAP web-Google
  / road-CA would tighten this gap. The current bench documents the
  cost surface on the simpler distribution.
- **CSR-storage best case.** The current `Graph` uses `ArrayList(Edge)`
  storage with adjacency built per call. A CSR cache (`buildAdjacency`
  reused across multiple algorithm calls) would amortise the
  per-traversal `O(|V| + |E|)` build cost. The README's "Out of scope"
  section names this — the numbers above are the without-cache
  numbers, which is the conservative (slower) baseline.
- **Multi-core / SIMD.** Pure Zig sequential code, no `std.Thread.Pool`,
  no `@Vector` SIMD passes. Single-core PageRank at 1M nodes is the
  load-bearing measurement; multi-core would obviously go faster.
- **Cross-platform.** Numbers are Linux x86_64 only. The build itself
  works on macOS arm64 and Linux aarch64 (the CI matrix gates this)
  but bench results from those targets are not published here.

## Comparison vs networkx

The cross-validation suite in [`tests/crossval_test.zig`](../tests/crossval_test.zig)
already establishes numerical agreement vs networkx 3.6.1 on
the weighted Zachary karate club (4 algorithms, max |Δ| 9.6e-12 on
PageRank) and on 4 directed canonical graphs. Cross-validating the 1M-
node ER result against networkx is impractical (networkx-on-CPython at
1M nodes takes hours and would dominate this file with infrastructure
work). The unit-tested + invariant-fuzzed + 1M-scale-verified ladder is
the rung this bench actually climbs.

## Honest Type-I avoidance

This is wall-clock on a busy laptop running concurrent agents. The
numbers convey the SHAPE of the cost curve. For competitive comparison
against pure-C / Rust graph libraries, run on a quiet workstation,
publish your hardware + build flags, and report variance.
