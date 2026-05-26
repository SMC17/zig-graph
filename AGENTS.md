# zig-graph Agent Entry Point

Read `~/AGENT_HARNESS.md`, `~/AGENT_RESPONSE_LENS.md`,
`~/HARNESS_AUDIT.md`, `~/HARNESS_MANIFEST.md`, and
`~/AGENT_OPERATING_DOCTRINE.md` before editing this repo.

Zig 0.16 graph algorithms (Louvain, PageRank, Fiedler, betweenness, etc.).
Benchmarks live in `bench/`; `zig build bench -Doptimize=ReleaseFast`.

## Experiment register — pre-register claims before testing

  stax-experiment register --lane zig-graph --hypothesis H --falsifier F [--proof-required P]
  stax-experiment verdict --id ID --result {confirmed|refuted|inconclusive} [--evidence E]
  stax-experiment bench --lane zig-graph --command "zig build bench" --data-size N --hardware-class X --result R
  stax-experiment list --lane zig-graph --since 7d

Source: ~/stax-experiment/ (Zig 0.16, AGPL-3.0). Public:
https://github.com/SMC17/stax-experiment
