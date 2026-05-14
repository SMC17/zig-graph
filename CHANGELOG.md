## v1.0.0 — 2026-05-13

**Production-grade hygiene milestone.**

- Added SECURITY.md (coordinated disclosure policy).
- Verified LICENSE, README, CONTRIBUTING, CODE_OF_CONDUCT, CI workflow all in place and accurate.
- API surface declared stable for the v1.x cycle. Breaking changes will bump to v2.x.
- Engineering posture: Virgil work-in-progress convention adapted for OSS — v1.0 means we stand behind the existing surface; v1.x patches refine implementation without breaking the API.

# Changelog

All notable changes to `zig-graph` are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project adheres to [Semantic Versioning](https://semver.org/).

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
- 15 tests covering correctness on canonical small graphs (triangle, star,
  cycle, barbell) plus error-path validation.

### Notes
- No allocator-hidden state. Every algorithm allocates its result through
  the caller-provided allocator; caller owns the slice and frees it.
- `Graph` deinit only releases the edge list; `node_count` is a scalar.
