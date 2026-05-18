#!/usr/bin/env bash
# zig-graph / tools / doctest.sh
#
# Documentation tests adapted from the zig-cobs template (commit 111584d).
# Verifies README executable claims are load-bearing CI-gated artifacts.

set -euo pipefail
cd "$(dirname "$0")/.."

n_pass=0
n_fail=0
declare -a FAILURES=()

assert_match() {
  local name="$1" file_a="$2" file_b="$3"
  if diff -u "$file_a" "$file_b" >/dev/null 2>&1; then
    n_pass=$((n_pass + 1)); echo "  PASS  $name"
  else
    n_fail=$((n_fail + 1)); FAILURES+=("$name")
    echo "  FAIL  $name"
    diff -u "$file_a" "$file_b" | sed 's/^/        /' | head -30
  fi
}
assert_output() {
  local name="$1" regex="$2"; shift 2
  local out; out=$("$@" 2>&1 || true)
  if echo "$out" | grep -qE "$regex"; then
    n_pass=$((n_pass + 1)); echo "  PASS  $name"
  else
    n_fail=$((n_fail + 1)); FAILURES+=("$name: stdout did not match /$regex/")
    echo "  FAIL  $name"; echo "        got: $out" | head -5
  fi
}
assert_build_step() {
  local name="$1" step="$2"
  if zig build --help 2>&1 | grep -qE "  $step\b"; then
    n_pass=$((n_pass + 1)); echo "  PASS  $name"
  else
    n_fail=$((n_fail + 1)); FAILURES+=("$name: step '$step' missing")
    echo "  FAIL  $name (step '$step' missing)"
  fi
}

echo "=== zig-graph doctest ==="

# ─── Check 1: README Quickstart matches examples/quickstart.zig ─────────────
EXTRACTED=$(mktemp)
awk '
  /^```zig$/ { in_block = 1; lines = ""; has_main = 0; next }
  /^```$/ {
    if (in_block && has_main) { printf "%s", lines; exit }
    in_block = 0
  }
  in_block {
    if (/const std = / && /@import\("std"\)/) has_main = 1
    lines = lines $0 "\n"
  }
' README.md > "$EXTRACTED"

EX_STRIPPED=$(mktemp)
awk '
  /^const std = / && /@import\("std"\)/ { printing = 1 }
  printing { print }
' examples/quickstart.zig > "$EX_STRIPPED"

assert_match "README Quickstart block matches examples/quickstart.zig" "$EXTRACTED" "$EX_STRIPPED"
rm -f "$EXTRACTED" "$EX_STRIPPED"

# ─── Check 2: Quickstart binary prints expected output ──────────────────────
QUICKSTART_BIN=zig-out/bin/example-quickstart
if [ ! -x "$QUICKSTART_BIN" ]; then
  echo "  FAIL  example-quickstart binary missing (run \`zig build\` first)"
  n_fail=$((n_fail + 1)); FAILURES+=("example-quickstart binary missing")
else
  assert_output "Quickstart binary prints 'communities=N modularity=...'" \
    'communities=[0-9]+ modularity=[0-9.]+ fiedler=' "$QUICKSTART_BIN"
fi

# ─── Check 3: Documented build steps exist ─────────────────────────────────
assert_build_step "README documents 'zig build test'" "test"
assert_build_step "README documents 'zig build bench'" "bench"
assert_build_step "README documents 'zig build crossval'" "crossval"

echo
echo "=== summary ==="
echo "  pass: $n_pass"
echo "  fail: $n_fail"
if [ "$n_fail" -gt 0 ]; then
  echo; echo "Failures:"; for f in "${FAILURES[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0
