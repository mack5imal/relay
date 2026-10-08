#!/usr/bin/env bash
# edge-probe.test.sh — fixture tests for scripts/edge-probe.py
#
# Proves the completeness probe: shape classification per criterion kind, the relevance filter
# (the property that makes an unresolved edge meaningful), SPEC.md parsing, the loud warnings
# when nothing is probed, and that the taxonomy stays closed.
#
# Repo-only (not shipped in the plugin payload). Needs python3. Run from anywhere:
#   bash tests/edge-probe.test.sh
# Exits 0 if every assertion passes, 1 otherwise.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EP="$REPO_ROOT/skills/goal/scripts/edge-probe.py"
TEMPLATE="$REPO_ROOT/skills/goal/templates/SPEC.md"

[ -f "$EP" ] || { echo "FATAL: missing $EP" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not available" >&2; exit 0; }

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  \033[31m✗\033[0m %s\n      %s\n' "$1" "$2"; }

assert_rc()       { if [ "$2" = "$RC" ]; then ok "$1"; else no "$1" "expected exit $2 got $RC (out: $OUT)"; fi; }
assert_contains() { case "$3" in *"$2"*) ok "$1";; *) no "$1" "missing substring [$2] in [$3]";; esac; }
assert_missing()  { case "$3" in *"$2"*) no "$1" "unexpectedly contains [$2]";; *) ok "$1";; esac; }
assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "expected [$2] got [$3]"; fi; }

run() { OUT="$("$@" 2>&1)"; RC=$?; }

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

# edges_for <criterion text> — the edge names raised for one criterion, space separated
edges_for() {
  printf '[{"id":"S1","text":%s}]\n' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1")" > "$W/c.json"
  python3 "$EP" --criteria "$W/c.json" --json 2>/dev/null \
    | python3 -c 'import json,sys; print(" ".join(e["edge"] for e in json.load(sys.stdin)["edges"]))'
}

echo "edge-probe.test.sh — fixtures for $EP"
echo

# ---------------------------------------------------------------------------
echo "[1] Shape classification raises the right edges"
E="$(edges_for 'the endpoint responds in under 200ms at p95')"
assert_contains "numeric range -> boundary" "boundary" "$E"
assert_contains "numeric range -> adjacency" "adjacency" "$E"
assert_contains "numeric range -> precision" "precision" "$E"

E="$(edges_for 'the page shows a sorted list of items')"
assert_contains "collection -> empty" "empty" "$E"
assert_contains "collection -> ordering" "ordering" "$E"

E="$(edges_for 'the CLI parses the JSON input string')"
assert_contains "text -> encoding" "encoding" "$E"
assert_contains "text -> empty" "empty" "$E"

E="$(edges_for 'running the migration again leaves state unchanged')"
assert_contains "stateful -> idempotency" "idempotency" "$E"
assert_contains "stateful -> concurrency" "concurrency" "$E"

# ---------------------------------------------------------------------------
echo
echo "[2] The relevance filter — this is what makes an unresolved edge mean something"
E="$(edges_for 'the banner uses the brand accent colour')"
assert_eq "a criterion with no shape raises nothing" "" "$E"
E="$(edges_for 'the CLI parses the JSON input string')"
assert_missing "a pure-text criterion is never asked about precision" "precision" "$E"
assert_missing "nor about numeric adjacency" "adjacency" "$E"
E="$(edges_for 'the report writes results to a file')"
assert_missing "io alone does not raise encoding (that belongs to the text shape)" "encoding" "$E"

# ---------------------------------------------------------------------------
echo
echo "[3] The taxonomy is closed"
printf '[{"id":"S1","text":"the endpoint parses a sorted list of files again within 5s"}]\n' > "$W/all.json"
run python3 "$EP" --criteria "$W/all.json" --json
assert_rc "exits 0" 0
UNKNOWN="$(printf '%s' "$OUT" | python3 -c '
import json,sys
known={"boundary","adjacency","empty","encoding","ordering","precision","idempotency","concurrency"}
print(" ".join(sorted({e["edge"] for e in json.load(sys.stdin)["edges"]} - known)))')"
assert_eq "no edge outside the eight categories" "" "$UNKNOWN"

# ---------------------------------------------------------------------------
echo
echo "[4] SPEC.md parsing folds the Acceptance line into the classified text"
cat > "$W/spec.md" <<'EOF'
# Spec: x

## Success criteria

- **S1 — Colour**: the banner matches the brand
  - Acceptance: the swatch equals the token value
- **S2 — Latency**: the endpoint is quick
  - Acceptance: responds in under 200ms at p95

## Assumptions
EOF
run python3 "$EP" --from-spec "$W/spec.md"
assert_rc "exits 0" 0
assert_contains "counts both criteria" "across 2 criterion" "$OUT"
assert_contains "S2 gets numeric edges from its Acceptance line" "| S2 | boundary" "$OUT"
assert_missing "S1 stays clean" "| S1 |" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[5] Nothing probed is a loud warning, not a clean bill of health"
run python3 "$EP" --from-spec "$TEMPLATE"
assert_rc "an unfilled template exits 0" 0
assert_contains "warns that placeholders were skipped" "no success criteria found" "$OUT"
assert_contains "and says so plainly" "not a clean bill of health" "$OUT"
printf '[{"id":"S1","text":"the banner uses the brand accent colour"}]\n' > "$W/none.json"
run python3 "$EP" --criteria "$W/none.json"
assert_contains "criteria with no shape also warn" "none matched a known shape" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[6] Usage and input errors"
run python3 "$EP"
assert_rc "no source exits 2" 2
run python3 "$EP" --criteria "$W/missing.json"
assert_rc "missing file exits 1" 1
printf 'not json\n' > "$W/bad.json"
run python3 "$EP" --criteria "$W/bad.json"
assert_contains "malformed JSON is named" "not valid JSON" "$OUT"
printf '{"id":"S1"}\n' > "$W/obj.json"
run python3 "$EP" --criteria "$W/obj.json"
assert_contains "a non-array is rejected" "expected a JSON array" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[7] --check enforces the floor against the spec's own Edge coverage table"
# floorspec <name> <edge rows> — two criteria whose raised edges are known:
#   S1 (speed, numeric) -> boundary adjacency precision; S2 (sorted list) -> empty ordering boundary
floorspec() {
  {
    printf '# Spec: x\n\n## Success criteria\n\n'
    printf -- '- **S1 — Speed**: the page is quick\n  - Acceptance: responds in under 200ms at p95\n'
    printf -- '- **S2 — Listing**: the page shows a sorted list of items\n  - Acceptance: rows appear in alphabetical order\n\n'
    printf '## Edge coverage\n\n| Criterion | Edge | Status | Reason / where covered |\n|---|---|---|---|\n%s\n\n' "$2"
    printf '<!-- | S2 | ordering | resolved | a commented-out row must not count | -->\n\n## Prohibitions (must-NOT)\n\n- none\n'
  } > "$W/$1.md"
  printf '%s' "$W/$1.md"
}
run python3 "$EP" --criteria <(printf '[{"id":"S1","text":"Speed the page is quick responds in under 200ms at p95"},{"id":"S2","text":"Listing the page shows a sorted list of items rows appear in alphabetical order"}]') --json
RAISED="$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(" ".join(e["criterion"]+":"+e["edge"] for e in json.load(sys.stdin)["edges"]))')"
assert_contains "fixture premise: S1 raises precision" "S1:precision" "$RAISED"
assert_contains "fixture premise: S2 raises ordering" "S2:ordering" "$RAISED"
assert_eq "fixture premise: exactly six edges" "6" "$(printf '%s' "$RAISED" | wc -w | tr -d ' ')"

run python3 "$EP" --check "$(floorspec full '| S1 | boundary — 200ms and 201ms | resolved | tested |
| S1 | adjacency, precision | resolved | tested |
| S2 | empty — no items | resolved | empty state |
| S2 | ordering | resolved | name order |
| S2 | boundary | dismissed | unbounded list is fine |')"
assert_rc "a complete table exits 0" 0
assert_contains "and says so" "floor ok" "$OUT"

run python3 "$EP" --check "$(floorspec gap '| S1 | boundary, adjacency, precision | resolved | tested |
| S2 | empty | resolved | empty state |')"
assert_rc "a raised edge with no row exits 1" 1
assert_contains "names the count" "2 of 6 raised edge(s)" "$OUT"
assert_contains "prints a ready-to-paste row for the gap" "| S2 | ordering — sequence or out-of-order arrival | unresolved | |" "$OUT"
assert_contains "and the other gap" "| S2 | boundary — at the limit and one past it | unresolved | |" "$OUT"
assert_missing "a covered edge is not reported" "| S1 |" "$OUT"

run python3 "$EP" --check "$(floorspec unres '| S1–S2 | boundary | unresolved | |
| S1 | adjacency, precision | unresolved | |
| S2 | empty, ordering | unresolved | |')"
assert_rc "unresolved counts as covered (an honest gap is always a legal answer)" 0

run python3 "$EP" --check "$(floorspec shorthand '| S1-S2 | boundary — both limits | resolved | tested |
| S1, S2 | precision, ordering | resolved | x |
| S1 | adjacency | resolved | x |
| S2 | empty | resolved | x |')"
assert_rc "ranges (S1-S2), lists (S1, S2) and category lists all expand" 0

run python3 "$EP" --check "$(floorspec dashdesc '| S1 | boundary — ordering of limits does not matter | resolved | x |
| S1 | adjacency, precision | resolved | x |
| S2 | empty, boundary | resolved | x |')"
assert_rc "a category named after the dash is description, not coverage" 1
assert_contains "so S2 ordering is still missing" "| S2 | ordering" "$OUT"
assert_contains "even though a commented-out row names it" "floor NOT met — 1 of 6" "$OUT"

run python3 "$EP" --check "$TEMPLATE"
assert_rc "the unfilled template exits 0" 0
run python3 "$EP" --check "$(floorspec js '| S1 | boundary |  resolved | x |')" --json
assert_rc "--json exits 1 on a gap" 1
MISSING="$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["missing"]))')"
assert_eq "--json lists every missing pair" "5" "$MISSING"

# ---------------------------------------------------------------------------
echo
echo "----------------------------------------"
printf 'Results: %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  exit 1
fi
echo "All fixture scenarios passed."
exit 0
