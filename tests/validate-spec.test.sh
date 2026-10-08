#!/usr/bin/env bash
# validate-spec.test.sh — fixture tests for scripts/validate-spec.sh
#
# Proves the spec content gate: required sections, every success criterion carrying an
# Acceptance line and a measurable predicate, no edge dismissed without a reason, and the
# advisory tier (soft qualifiers, unresolved edges, optional sections) never failing a spec.
#
# Repo-only (not shipped in the plugin payload). Run from anywhere:
#   bash tests/validate-spec.test.sh
# Exits 0 if every assertion passes, 1 otherwise.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VS="$REPO_ROOT/skills/goal/scripts/validate-spec.sh"
TEMPLATE="$REPO_ROOT/skills/goal/templates/SPEC.md"

for f in "$VS" "$TEMPLATE"; do
  [ -f "$f" ] || { echo "FATAL: missing $f" >&2; exit 1; }
done

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  \033[31m✗\033[0m %s\n      %s\n' "$1" "$2"; }

assert_rc()       { if [ "$2" = "$RC" ]; then ok "$1"; else no "$1" "expected exit $2 got $RC (out: $OUT)"; fi; }
assert_contains() { case "$3" in *"$2"*) ok "$1";; *) no "$1" "missing substring [$2] in [$3]";; esac; }
assert_missing()  { case "$3" in *"$2"*) no "$1" "unexpectedly contains [$2]";; *) ok "$1";; esac; }

run() { OUT="$("$@" 2>&1)"; RC=$?; }

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

# spec <name> <criteria-block> [edge-rows]
spec() {
  local path="$W/$1.md"
  {
    printf '# Spec: sample\n\n## Goal\n\nDo the thing.\n\n'
    printf '## In scope\n\n- the thing\n\n## Out of scope\n\n- other things\n\n'
    printf '## Constraints\n\n- no new dependencies\n\n'
    printf '## Success criteria\n\n%s\n' "$2"
    printf '## Edge coverage\n\n| Criterion | Edge | Status | Reason / where covered |\n|---|---|---|---|\n%s\n' "${3:-}"
    printf '## Prohibitions (must-NOT)\n\n- none material\n\n'
    printf '## Ambiguity report\n\n**Ambiguity: 0.10** (gate: ≤ 0.15)\n\n'
    printf '## Interview log\n\n| Round | Focus | Asked about | Decision locked |\n|---|---|---|---|\n| 1 | x | y | z |\n'
  } > "$path"
  printf '%s' "$path"
}

GOOD_CRIT='- **S1 — JSON flag**: `relay report --json` emits one parseable object
  - Current: table only
  - Target: a flag
  - Acceptance: `relay report --json | jq -e .` exits 0
'
# The edges edge-probe.py raises for GOOD_CRIT (boundary, empty, encoding). Fixtures that are not
# about the floor cover them so the floor check stays out of their way.
FLOOR='| S1 | boundary, empty, encoding | resolved | covered by the acceptance check |'
REST='| S1 | empty, encoding | resolved | covered by the acceptance check |'

echo "validate-spec.test.sh — fixtures for $VS"
echo

# ---------------------------------------------------------------------------
echo "[1] A well-formed spec passes"
run bash "$VS" "$(spec good "$GOOD_CRIT" "$FLOOR")"
assert_rc "exits 0" 0
assert_contains "counts the criteria" "1 success criteria" "$OUT"
assert_missing "no errors" "❌" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[2] Every criterion needs an Acceptance line"
run bash "$VS" "$(spec noacc '- **S1 — Auth**: `npm test` exits 0
' '')"
assert_rc "missing Acceptance exits 1" 1
assert_contains "names the criterion" "S1 has no 'Acceptance:' line" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[3] A criterion with no measurable predicate is rejected"
run bash "$VS" "$(spec vague '- **S1 — Auth**: user authentication works properly
  - Acceptance: it is solid
' '')"
assert_rc "vibe criterion exits 1" 1
assert_contains "explains the rule" "no measurable predicate" "$OUT"
# The criterion id itself contains a digit; that must not count as a number.
assert_missing "id digit does not satisfy the check" "spec ok" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[4] Soft qualifiers are advisory, never fatal"
run bash "$VS" "$(spec soft '- **S1 — Report**: the report renders correctly
  - Acceptance: `npm test` exits 0
' '')"
assert_rc "soft wording still exits 0" 0
assert_contains "but is surfaced" "leans on" "$OUT"
assert_contains "names the qualifier" "correctly" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[5] A dismissed edge must carry a reason"
run bash "$VS" "$(spec nodismiss "$GOOD_CRIT" "$REST
| S1 | boundary | dismissed |  |")"
assert_rc "reasonless dismissal exits 1" 1
assert_contains "names the edge and criterion" "edge 'boundary' on S1 is dismissed with no reason" "$OUT"
run bash "$VS" "$(spec okdismiss "$GOOD_CRIT" "$REST
| S1 | boundary | dismissed | input is a bounded enum |")"
assert_rc "dismissal with a reason exits 0" 0

# ---------------------------------------------------------------------------
echo
echo "[6] Unresolved edges warn and are counted"
run bash "$VS" "$(spec unres "$GOOD_CRIT" "$REST
| S1 | boundary | unresolved | |")"
assert_rc "exits 0" 0
assert_contains "warns" "still 'unresolved'" "$OUT"
assert_contains "counts it" "1 unresolved edge" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[7] Required sections and usage"
printf '# Spec: bare\n\n## Goal\n\nx\n' > "$W/bare.md"
run bash "$VS" "$W/bare.md"
assert_rc "missing sections exits 1" 1
assert_contains "names a missing section" "missing section: ## Success criteria" "$OUT"
run bash "$VS" "$W/nope.md"
assert_rc "missing file exits 2" 2
run bash "$VS"
assert_rc "no args exits 2" 2

# ---------------------------------------------------------------------------
echo
echo "[8] The shipped template passes (placeholder entries are skipped, not judged)"
run bash "$VS" "$TEMPLATE"
assert_rc "template exits 0" 0
assert_missing "no errors on the template" "❌" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[9] The edge-probe floor is enforced (needs python3)"
if command -v python3 >/dev/null 2>&1; then
  run bash "$VS" "$(spec narrowed "$GOOD_CRIT" '| S1 | empty | resolved | covered by the acceptance check |')"
  assert_rc "a raised edge with no row exits 1" 1
  assert_contains "names the missing edge and criterion" "edge 'boundary' on S1 has no row" "$OUT"
  assert_contains "and the other one" "edge 'encoding' on S1 has no row" "$OUT"
  assert_contains "prints the row to paste" "| S1 | boundary — at the limit and one past it | unresolved | |" "$OUT"
  assert_missing "does not flag the covered edge" "edge 'empty' on S1 has no row" "$OUT"
  run bash "$VS" "$(spec allunres "$GOOD_CRIT" '| S1 | boundary, empty, encoding | unresolved | |')"
  assert_rc "unresolved rows satisfy the floor — the check cannot deadlock" 0
  # Session A's real shorthand: a range in the criterion cell, several categories in one row.
  TWO_CRIT="$GOOD_CRIT"'- **S2 — Paths**: `relay report --json out.json` writes the JSON file
  - Acceptance: `jq -e . out.json` exits 0
'
  run bash "$VS" "$(spec shorthand "$TWO_CRIT" '| S1–S2 | boundary, empty, encoding | resolved | covered by the acceptance checks |
| S1-S2 | idempotency — rerun overwrites | resolved | same bytes |
| S2 | concurrency | dismissed | single-process CLI |')"
  assert_rc "ranges and category lists expand" 0
else
  ok "skipped: python3 not available"
fi

# ---------------------------------------------------------------------------
echo
echo "[10] Planner-decided scope is counted, never fatal"
P="$(spec planner "$GOOD_CRIT" "$FLOOR")"
perl -0pi -e 's/- other things\n/- other things\n- a CSV export (planner)\n- per-user settings (planner)\n/' "$P"
run bash "$VS" "$P"
assert_rc "(planner) items still exit 0" 0
assert_contains "counts them" "2 out-of-scope item(s) were decided by the planner" "$OUT"
run bash "$VS" "$(spec noplanner "$GOOD_CRIT" "$FLOOR")"
assert_missing "no tag, no advisory" "decided by the planner" "$OUT"
run bash "$VS" "$TEMPLATE"
assert_missing "the template's placeholder example is not counted" "decided by the planner" "$OUT"

# ---------------------------------------------------------------------------
echo
echo
echo "[11] A recorded design package needs a reconciliation record"
dspec() {  # dspec <name> <design-line> <reconciliation-block>
  local path; path="$(spec "$1" "$GOOD_CRIT" "$FLOOR")"
  DL="$2" perl -0pi -e 's/^# Spec: sample\n/# Spec: sample\n\n$ENV{DL}\n/' "$path"
  [ -n "$3" ] && printf '\n%s\n' "$3" >> "$path"
  printf '%s' "$path"
}
RECON0='## Design reconciliation

Reconciled: 0 conflicts — screens, states and copy compared with S1 and the constraints'
RECON2='## Design reconciliation

| # | Area | Spec said | Design shows | Resolution |
|---|---|---|---|---|
| 1 | `copy: Done` | Done | Back to work | spec wins |
| 2 | trends rule | slope | halves | design wins |

Reconciled: 2 conflicts'
run bash "$VS" "$(dspec dnone '**Design:** design/HANDOFF.md @ cae5f3e' '')"
assert_rc "design recorded, no section: exits 1" 1
assert_contains "names the step" "no '## Design reconciliation' section" "$OUT"
run bash "$VS" "$(dspec dnoline '**Design:** design/HANDOFF.md @ cae5f3e' '## Design reconciliation

nothing here')"
assert_rc "section without Reconciled line: exits 1" 1
assert_contains "asks for the line" "no 'Reconciled: <n> conflicts' line" "$OUT"
run bash "$VS" "$(dspec dzero '**Design:** design/HANDOFF.md @ cae5f3e' "$RECON0")"
assert_rc "a recorded zero passes" 0
run bash "$VS" "$(dspec dtwo '**Design:** design/HANDOFF.md @ cae5f3e' "$RECON2")"
assert_rc "two rows, 'Reconciled: 2' passes" 0
assert_missing "counts agree: no warning" "reconciliation table has" "$OUT"
run bash "$VS" "$(dspec dmis '**Design:** design/HANDOFF.md @ cae5f3e' "${RECON2/Reconciled: 2/Reconciled: 3}")"
assert_rc "count mismatch only warns" 0
assert_contains "warns on the mismatch" "'Reconciled: 3' but the reconciliation table has 2 row(s)" "$OUT"
run bash "$VS" "$(dspec dskip '**Design:** skipped' '')"
assert_rc "no design package: no reconciliation needed" 0
run bash "$VS" "$(dspec dpend '**Design:** pending — Stage 2.7' '')"
assert_rc "pending design: not yet required" 0

echo "----------------------------------------"
printf 'Results: %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  exit 1
fi
echo "All fixture scenarios passed."
exit 0
