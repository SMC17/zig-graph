# zig-graph status

Last touched: 2026-05-15

## Honest version posture

Despite the `v1.1.0` git tag (and the earlier-same-day `v1.0.0`
hygiene-only tag), this project is **pre-1.0 in semver spirit** for
two independent reasons:

1. **Zig itself is on 0.16, not 1.0.** Until the Zig language hits 1.0,
   no Zig library can credibly claim API stability beyond "stable on
   Zig 0.16 today." Tagging v1.x against a pre-1.0 substrate is a
   vanity claim — the language guarantees aren't there yet.
2. **No production deployment exists.** This library has zero
   real-traffic operation, zero soak time, zero production-incident
   history. "Production-grade hygiene milestone" describes shipping
   process (LICENSE / SECURITY / CONTRIBUTING / CI / CODE_OF_CONDUCT)
   — necessary but **not sufficient** for "production-grade." The
   numerical-algorithm surface in particular has had non-trivial gaps
   found by mutation testing (one real-narrow-tolerance survivor on
   `eigenvectorCentrality` and one Louvain self-loop weighted-degree
   regression closed in `3324185`) within the same commit window the
   v1.x tags were cut.

The hygiene work is real. The v1.x tags will be honored for changelog
continuity. But every reader should treat this as a pre-1.0 substrate
until both gates above close.

## Proof-vocabulary index (per `~/AGENT_HARNESS.md`)

| component                       | proof level                       | evidence                                                                 |
|---------------------------------|-----------------------------------|--------------------------------------------------------------------------|
| `pagerank` (undirected)         | `unit-tested` + `audited`         | `src/root.zig` correctness tests on cycle / star / dangling-node / weighted graphs; cross-validated vs networkx 3.6.1 on weighted Zachary karate (delta 9.6e-12), P_5 (tol 1e-6), C_6 (uniform), K_5 (uniform) in `tests/crossval_test.zig` |
| `directedPagerank`              | `unit-tested` + `audited`         | `src/root.zig` directed hub/spoke + pure-sink tests; cross-validated vs networkx on directed star (delta 1.02e-12), C_5 (closed-form, 0), 7-node asymmetric (5.09e-13), directed binary tree (1.92e-13) |
| `eigenvectorCentrality`         | `unit-tested` + `audited` (narrow) | `src/root.zig` regular-triangle / star / disconnected-graph / heavy-edge tests; cross-validated vs networkx `eigh` on weighted karate (delta 1.1e-15, tol 1e-4 / 256 iters) and on Petersen + K_5 closed-form. Mutation harness flagged `M05 (iterations halved)` as a real-narrow-tolerance survivor — not a real algorithm bug but the cross-val tolerance is loose enough to admit half the default iterations |
| `betweennessCentrality` (Brandes) | `unit-tested` + `audited`        | `src/centrality.zig` line / barbell / star / normalised-star / weighted-path tests + non-negative-and-sum-bounded fuzz; cross-validated against the closed-form (0,3,4,3,0) on P_5 |
| `closenessCentrality`           | `unit-tested` + `audited`         | `src/centrality.zig` star / cycle / isolated-node tests; cross-validated vs networkx closed-form on P_5 (tol 1e-9) |
| `fiedlerValue` / `fiedlerVector` | `unit-tested`                    | `src/spectral.zig` 8 tests against closed-form λ₁ on P_4, P_10, C_6, K_{1,4}, K_4, barbell, disconnected, plus a non-negative + bounded-by-n random-graph fuzz. No external-reference cross-val yet (closed forms only) |
| `louvain` modularity            | `unit-tested` + `audited`         | `src/community.zig` 6 tests including the heavy-self-loop singleton regression added 2026-05-15; cross-validated vs networkx weighted-louvain best-of-50-seeds Q = 0.444904 on Zachary karate, single-community-on-K_5 |
| `bfs` / `dfs` / `sssp` / `bfsPath` | `unit-tested`                  | `src/traversal.zig` 9 tests covering path-order, disconnected components, weighted cumulative distances, unreachable=inf, parallel-path tie-break, out-of-range rejection, CSR fan-out, shortest-path-or-null |
| Cross-validation suite (external) | `audited`                       | `tests/crossval_test.zig` — 19 tests vs networkx 3.6.1 + closed-form references on karate / Petersen / P_5 / C_6 / K_5 + 4 directed canonical graphs; wired into `zig build test` so the external contract holds in CI |
| Mutation surface (numerics)     | `audited` (78.6%)                 | `tools/mutation-test.sh` — 14 operators across `root`/`spectral`/`community`/`centrality`: **11 killed / 3 survived** (M05 real-narrow tolerance, M09 equivalent mutant on Fiedler τ, M11 equivalent mutant on Louvain best-gain comparator). Survivors honestly classified, not hidden |
| Throughput                      | `compiled`                        | 6 benches under `bench/` (pagerank, centrality, construct, betweenness, louvain, fiedler) build under `zig build bench` (ReleaseFast). **No published `bench/RESULTS.md` exists yet** — the benches run, but no pinned-hardware numbers have been committed |
| README/code drift               | `unit-tested`                     | `tools/doctest.sh`: 5 checks — Quickstart README block diff vs `examples/quickstart.zig`, quickstart binary stdout-regex `communities=N modularity=… fiedler=…`, three `zig build --help` step presence checks (`test`, `bench`, `crossval`) |

## Gates that would justify a stronger claim

- **G1 — Scale-tested throughput on real-world graphs.** Run the bench
  surface on canonical large graphs (SNAP `email-Enron`, `web-Google`,
  `roadNet-CA`; Stanford `wiki-Topcats`) and commit `bench/RESULTS.md`
  with pinned-hardware throughput + memory numbers. Until then,
  "fast" is unverified beyond the canonical-small-graph tests. Status:
  `NOT YET CLOSED`.
- **G2 — Soak time + downstream user.** ≥30 days of the library being
  imported by a real downstream system (a sovereign-stack research
  pipeline, the `steam` NYISO engine, a `Work/stax` graph job — anything
  that runs `pagerank` / `louvain` / `fiedler` in anger), with the
  numerics holding up under non-toy inputs. Status: `NOT YET CLOSED`.
- **G3 — Independent numerics review.** A second pair of eyes —
  ideally someone with a network-science or numerical-linear-algebra
  background — on the Fiedler deflation choice, the Louvain
  aggregation phase, the Brandes weighted-Dijkstra variant, and the
  power-iteration termination criteria. Status: `NOT YET CLOSED`.
- **G4 — Cross-validate Fiedler against an external reference.**
  Closed-form λ₁ on canonical graphs is necessary but not sufficient.
  Compare `fiedlerValue` / `fiedlerVector` against networkx /
  scipy.sparse.linalg.eigsh on the same weighted karate / Petersen /
  road-network inputs the rest of the suite uses. Status:
  `NOT YET CLOSED`.
- **G5 — Zig 1.0 reaches stable.** The language-level guarantee that
  makes the v1.x tag mean what it says in any other ecosystem.
  Status: `NOT YET CLOSED` (out of this repo's control).

Only after G5 + at least one of G1 / G2 / G3 / G4 do the words
"production-grade" or "stable v1" honestly fit.
