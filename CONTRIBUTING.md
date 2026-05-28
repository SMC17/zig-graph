# Contributing to zig-graph

Issues and pull requests welcome. The code surface is intentionally small;
changes that grow it should justify why.

## Ground rules

- **Caller-owned allocation.** Every algorithm takes an `Allocator` and
  returns memory the caller frees with `allocator.free` or `.deinit()`.
  No internal pools, no thread-local cache, no global state.
- **No external dependencies.** Pure `std`-only Zig.
- **Correctness before speed.** A new algorithm must ship with at least
  one closed-form unit test against a canonical small graph (path, cycle,
  star, clique, barbell, etc.) and, where a reference exists, a
  cross-validation entry in `tests/crossval_test.zig` against networkx
  3.6.1 or a closed-form analytic result.
- **Invariant fuzz for numerical algorithms.** Random-graph fuzz that
  asserts the algorithm-level invariant (PageRank Σ = 1, betweenness ≥ 0
  and ≤ (n-1)(n-2)/2, Louvain Q ∈ [-0.5, 1], Fiedler λ₁ ≥ -1e-8, etc.)
  runs on every `zig build test`.
- **No LLM-generated code shipped without human review and editing.**
  AI as research aid is fine; AI-as-final-author is not.

## Testing

```sh
zig fmt --check src/ build.zig
zig build test
```

CI runs the same on every push and pull request. Don't merge unless CI is
green. The default `test` step includes the cross-validation suite, so
any future regression vs networkx 3.6.1 fails CI loudly.

New behavior must come with a test that would fail without the change.
See `src/root.zig`, `src/community.zig`, etc. for the existing pattern.

## Versioning

Pre-1.0 in semver spirit; Zig itself is on 0.16. The `v1.x` git tags are
preserved for changelog continuity; see [`STATUS.md`](STATUS.md) for the
gates that would justify a stronger claim.

## Reporting issues

Bug reports should include:
- Zig version (`zig version`)
- A minimal reproduction graph (edge list) + the algorithm + expected vs
  actual output (or expected-vs-observed delta against networkx).
- Whether your platform uses LLD or self-hosted linker.

## License

By contributing, you agree your contribution is licensed under AGPL-3.0,
the same license as the rest of the project.
