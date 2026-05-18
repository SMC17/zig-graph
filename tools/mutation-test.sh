#!/usr/bin/env bash
# zig-graph / tools / mutation-test.sh
#
# Stylized mutation-testing harness for zig-graph. Adapted from the
# zig-cobs / zig-frame-protocol / sentinel-sbom templates.
#
# Numerical-algorithm code (PageRank, eigenvector centrality, Fiedler,
# Louvain, betweenness) is especially susceptible to "tolerance-blind"
# survivors: a mutation produces results that pass approximate-equality
# assertions because the existing test tolerances are too loose. Each
# survivor below is honestly classified as one of:
#   - equivalent mutant         (the post-mutation algorithm is mathematically identical)
#   - real-narrow gap           (the algorithm is wrong; tolerance hides it)
#   - real-bug-worth-fixing     (the algorithm is genuinely wrong and should be patched)
#
# Each mutation is applied to a fresh copy of the source, the full
# `zig build test` suite runs (incl. the networkx cross-validation), and
# the exit code determines killed/survived.

set -euo pipefail
cd "$(dirname "$0")/.."

declare -A SRC_BACKUPS=()
declare -a SRC_FILES=(
  "src/root.zig"
  "src/spectral.zig"
  "src/community.zig"
  "src/centrality.zig"
)

for f in "${SRC_FILES[@]}"; do
  SRC_BACKUPS["$f"]=$(mktemp)
  cp "$f" "${SRC_BACKUPS[$f]}"
done

restore_all() {
  for f in "${SRC_FILES[@]}"; do
    cp "${SRC_BACKUPS[$f]}" "$f"
    rm -f "${SRC_BACKUPS[$f]}"
  done
}
trap restore_all EXIT

# Format: "description|target_file|sed expression"
declare -a MUTATIONS=(
  # ─── Graph.addEdge node-index range check (src/root.zig) ──────────────────
  "M01 (root): addEdge range check >= -> > (off-by-one accepts node_count)|src/root.zig|s|source >= self.node_count or target >= self.node_count|source > self.node_count or target > self.node_count|"

  # ─── weightedDegree edge-direction handling ───────────────────────────────
  # Skip the target half of the degree contribution -> directed-degree bug.
  "M02 (root): weightedDegree drop target contribution (treat edges as directed)|src/root.zig|s|out\\[edge.target\\] += edge.weight;|/* mutated: out[edge.target] contribution removed */|"

  # ─── Eigenvector power-iteration norm check ───────────────────────────────
  # Flip the norm==0 sense so the zero-vector branch is taken whenever the
  # vector has *any* magnitude (catastrophic — should kill any non-trivial test).
  "M03 (root): eigenvectorCentrality norm-zero check == -> != (clamp on non-zero)|src/root.zig|s|if (norm == 0.0) {|if (norm != 0.0) {|"

  # ─── PageRank damping sign in base mass ───────────────────────────────────
  # Wrong direction in (1-d) teleport term: net mass becomes (1+d)/n base.
  "M04 (root): pagerank base-mass sign 1.0 - damping -> 1.0 + damping|src/root.zig|s|@memset(next, (1.0 - options.damping) \\* base);|@memset(next, (1.0 + options.damping) * base);|"

  # ─── Eigenvector power-iteration loop bound (under-iteration) ────────────
  # Halve the iteration budget for the FIRST `while (i < options.iterations)`
  # loop (line 147, inside eigenvectorCentrality — the loops in pagerank /
  # directedPagerank are later and untouched). Does the cross-val tolerance
  # of 1e-4 / 1e-5 catch eigenvector / pagerank under-convergence on the
  # karate club?
  "M05 (root): eigenvectorCentrality iterations halved (under-iterate by factor 2)|src/root.zig|0,/while (i < options.iterations) : (i += 1) {/ s#while (i < options.iterations) : (i += 1) {#while (i < options.iterations / 2) : (i += 1) {#"

  # ─── conductance: numerator vs denominator mix-up ─────────────────────────
  # @min(vol_s, vol_c) -> @max — denominator becomes the larger volume.
  "M06 (root): conductance denominator @min -> @max (wrong cut normalization)|src/root.zig|s|const denom = @min(vol_s, vol_complement);|const denom = @max(vol_s, vol_complement);|"

  # ─── cutEdges partition crossing check ────────────────────────────────────
  "M07 (root): cutEdges crossing check != -> == (count same-community edges)|src/root.zig|s|if (partition\\[edge.source\\] != partition\\[edge.target\\]) count += 1;|if (partition[edge.source] == partition[edge.target]) count += 1;|"

  # ─── Directed PageRank dangling-mass redistribution ───────────────────────
  # Drop the dangling-mass term entirely — mass leaks; sums no longer 1.
  "M08 (root): directedPagerank drop dangling-mass redistribution|src/root.zig|s|if (share != 0.0) {|if (share != 0.0 and false) {|"

  # ─── Fiedler tau spectrum-shift bound ─────────────────────────────────────
  # τ = 2·max_deg + 1 ensures M = τI - L has dominant eigenvalue = τ - 0 = τ
  # corresponding to L's zero mode. Drop the +1 → τ = 2·max_deg → M loses
  # spectral-radius guarantee for cases where λ_max(L) = 2·max_deg
  # (e.g. bipartite graphs with that exact upper bound).
  "M09 (spectral): tau shift drops +1 safety margin (boundary spectrum)|src/spectral.zig|s|const tau = 2.0 \\* max_deg + 1.0;|const tau = 2.0 * max_deg;|"

  # ─── Fiedler Rayleigh-quotient cross-term coefficient ─────────────────────
  # Rayleigh xᵀLx for undirected L sums each off-diagonal A_ij contribution
  # twice (once for ij, once for ji). Dropping factor 2 halves the off-diagonal
  # contribution → λ estimate too large.
  "M10 (spectral): Rayleigh-quotient off-diagonal coefficient 2.0 -> 1.0|src/spectral.zig|s|ray -= 2.0 \\* edge.weight \\* x\\[edge.source\\] \\* x\\[edge.target\\];|ray -= 1.0 * edge.weight * x[edge.source] * x[edge.target];|"

  # ─── Louvain modularity-gain strict-greater comparator ────────────────────
  # Flip > to >= → accept zero-gain swaps → ties can flip labels arbitrarily
  # and the algorithm may oscillate or take inferior partitions.
  "M11 (community): Louvain best-gain comparator > -> >= (tie-break flip)|src/community.zig|s|if (gain_rel > best_gain + options.tolerance) {|if (gain_rel >= best_gain + options.tolerance) {|"

  # ─── Louvain self-loop weighted-degree coefficient ────────────────────────
  # Self-loops contribute 2·w to weighted degree (undirected A_ii is symmetric).
  # Dropping the factor of 2 understates degree, distorting modularity.
  "M12 (community): self-loop degree contribution 2.0 -> 1.0|src/community.zig|s|deg\\[i\\] += 2.0 \\* self_loop\\[i\\];|deg[i] += 1.0 * self_loop[i];|"

  # ─── Brandes betweenness undirected halving ───────────────────────────────
  # Each shortest path is counted twice (once forward, once backward) in
  # the undirected accumulator. Dropping the 0.5 halving doubles every value.
  # NOTE: sed delimiter is '#' here because the source line contains literal
  # '|' (the Zig capture syntax `|*v|`) which would clash with '|' delimiter.
  "M13 (centrality): betweenness undirected halving 0.5 -> 1.0|src/centrality.zig|s#v.\\* \\*= 0.5;#v.* *= 1.0;#"

  # ─── Brandes backwards-accumulation +1.0 term ─────────────────────────────
  # The (1 + δ[w]) term is the Brandes recurrence — drop the "+1" and the
  # base case for leaves is lost; all betweenness collapses to zero.
  "M14 (centrality): Brandes recurrence (1.0 + delta) -> (0.0 + delta)|src/centrality.zig|s#delta\\[p\\] += (sigma\\[p\\] / sigma\\[w\\]) \\* (1.0 + delta\\[w\\]);#delta[p] += (sigma[p] / sigma[w]) * (0.0 + delta[w]);#"
)

n_total=${#MUTATIONS[@]}
n_killed=0
n_survived=0
declare -a SURVIVORS=()

echo "=== zig-graph mutation testing ==="
echo "src files: ${SRC_FILES[*]}"
echo "operators: $n_total stylized mutations"
echo "test cmd: zig build test"
echo

for mutation in "${MUTATIONS[@]}"; do
  desc="${mutation%%|*}"
  rest="${mutation#*|}"
  target_file="${rest%%|*}"
  sed_expr="${rest#*|}"

  # Restore all source files first, then apply this single mutation.
  for f in "${SRC_FILES[@]}"; do cp "${SRC_BACKUPS[$f]}" "$f"; done

  sed -i "$sed_expr" "$target_file"

  if cmp -s "${SRC_BACKUPS[$target_file]}" "$target_file"; then
    echo "  SKIPPED   $desc"
    echo "            (sed expression matched 0 lines — mutation is a no-op)"
    n_total=$((n_total - 1))
    continue
  fi

  if zig build test >/dev/null 2>&1; then
    n_survived=$((n_survived + 1))
    SURVIVORS+=("$desc")
    echo "  SURVIVED  $desc"
  else
    n_killed=$((n_killed + 1))
    echo "  KILLED    $desc"
  fi
done

for f in "${SRC_FILES[@]}"; do cp "${SRC_BACKUPS[$f]}" "$f"; done

echo
echo "=== summary ==="
echo "  total effective mutations: $n_total"
echo "  killed:                    $n_killed"
echo "  survived:                  $n_survived"

if [ "$n_total" -gt 0 ]; then
  score=$(awk -v k="$n_killed" -v t="$n_total" 'BEGIN{printf "%.1f", k/t*100}')
  echo "  mutation score:            $score%"
fi

if [ "$n_survived" -gt 0 ]; then
  echo
  echo "Survivors (test-suite blind spots):"
  for s in "${SURVIVORS[@]}"; do
    echo "  - $s"
  done
  exit 1
fi

exit 0
