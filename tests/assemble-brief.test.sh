#!/usr/bin/env bash
# assemble-brief.test.sh — fixture tests for scripts/assemble-brief.sh
#
# Proves the brief a cold-started subagent reads is complete and mode-correct: the spec is
# inlined (fix briefs append the original spec as the gate), carryover memory files named in
# STATE.md are inlined (a missing one degrades to a note), the map slice is precomputed from
# the spec's `Map seeds:` (and skipped for `none` and for audits), the run-state excerpt is
# scoped to the phase, only the mode's marker formats are included, mode fences filter the
# template, and no placeholder survives. Uses the real map-slice.sh/.py against
# tests/fixtures/map-graph.json and a stub build-graph.sh, so graphify is never called.
#
# Repo-only (not shipped in the plugin payload). Run from anywhere:
#   bash tests/assemble-brief.test.sh
# Exits 0 if every assertion passes, 1 otherwise. Needs python3 (for the slice).

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$REPO_ROOT/skills/goal"
AB="$SKILL/scripts/assemble-brief.sh"
FX="$REPO_ROOT/tests/fixtures/map-graph.json"

for f in "$AB" "$SKILL/templates/PHASE-BRIEF.md" "$SKILL/templates/MARKERS.md" "$SKILL/scripts/map-slice.sh" "$SKILL/scripts/map-slice.py" "$FX"; do
  [ -f "$f" ] || { echo "FATAL: missing $f" >&2; exit 1; }
done

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  \033[31m✗\033[0m %s\n      %s\n' "$1" "$2"; }

assert_rc()       { if [ "$2" = "$RC" ]; then ok "$1"; else no "$1" "expected exit $2 got $RC (out: $OUT)"; fi; }
assert_contains() { case "$3" in *"$2"*) ok "$1";; *) no "$1" "missing substring [$2]";; esac; }
assert_missing()  { case "$3" in *"$2"*) no "$1" "unexpectedly contains [$2]";; *) ok "$1";; esac; }
assert_file()     { if [ -f "$2" ]; then ok "$1"; else no "$1" "no file at $2"; fi; }

run() { OUT="$("$@" 2>&1)"; RC=$?; }

# make_run <dir> — a fixture run root: template, markers, helpers, graph, STATE.md, two phase
# specs, a fix spec, an audit-fix spec, applied-memories.md, and a memory dir with one file.
make_run() {
  local r="$1"
  mkdir -p "$r/phases" "$r/graph" "$r/mem"
  cp "$SKILL/templates/PHASE-BRIEF.md" "$r/PHASE-BRIEF.md"
  cp "$SKILL/templates/MARKERS.md" "$r/MARKERS.md"
  cp "$SKILL/scripts/map-slice.sh" "$SKILL/scripts/map-slice.py" "$r/"
  cp "$FX" "$r/graph/graph.json"
  cat > "$r/build-graph.sh" <<'STUB'
#!/usr/bin/env bash
echo "stub-built $1" > "$1/graph-built"
echo "graph: stub rebuilt"
STUB
  cat > "$r/STATE.md" <<STATE
# State: Add dark mode

**Status:** IN_PROGRESS
**Current phase:** 1
**Started:** 2026-09-12
**Last update:** 2026-09-12
**Run root:** $r    <!-- namespaced -->
**Baseline ref:** abc1234    <!-- HEAD sha captured at Stage 7 -->
**Memory dir:** $r/mem    <!-- detected at Stage 0 -->

## Phase progress

| # | Phase | Status | Started | Completed | Notes |
|---|-------|--------|---------|-----------|-------|
| 1 | Build scheduler core | pending | — | — | — |
| 2 | Wire history | pending | — | — | — |

## Engineering check status

- Build: pass
- Typecheck: pass
- Lint: pre-existing
- Tests: 12 pass

## Notable events

- 2026-09-12 — Plan locked, 2 phases.

## Failure log

- Phase 1 (Build scheduler core): C3 failed — retried — see evidence
- Phase 2 (Wire history): unrelated failure line
- Phase 12 (Not ours): must not leak into phase 1

## Carryover

- movez-invariant
- missing-one
STATE
  cat > "$r/phases/phase-1.md" <<'SPEC'
RELAY_PHASE_START
Phase: 1 of 2 — Build scheduler core
Task: Make the scheduler tick
Type: brownfield
Mandatory commands: swift build, swift test
Acceptance criteria: 3
Evidence required: command results
Depends on phases: none
Map seeds: Scheduler, HistoryStore
Estimated files: 4

## Work

- SPEC-ONE-WORK-BULLET

## Acceptance criteria

- C1 builds
- C2 tests pass
- C3 no debug prints

## Exemplars

- Sources/App/Scheduler/Scheduler.swift — control pattern
SPEC
  cat > "$r/phases/phase-2.md" <<'SPEC'
RELAY_PHASE_START
Phase: 2 of 2 — Wire history
Task: Persist runs
Map seeds: none

## Work

- SPEC-TWO-WORK-BULLET
SPEC
  cat > "$r/phases/phase-1.fix.md" <<'SPEC'
# Fix spec — phase 1

FIX-SPEC-BODY: only C3 failed; remove the print in Scheduler.swift.
SPEC
  cat > "$r/phases/audit-fix-1.md" <<'SPEC'
# Audit fix — round 1

AUDIT-FIX-BODY: deliverable Sources/App/History/HistoryStore.swift missing.
SPEC
  cat > "$r/applied-memories.md" <<'AM'
- swift-testing-quirk — applies because the stack is Swift — use `swift test --parallel`
AM
  cat > "$r/mem/movez-invariant.md" <<'MEM'
---
name: movez-invariant
description: exactly four things move boutStartedAt
metadata:
  type: project
---

MEMORY-BODY: a short lock must be a true no-op.
MEM
}

# ---------------------------------------------------------------------------
echo "[1] Usage errors -> exit 2, nothing written"
w="$(mktemp -d)"; make_run "$w/run"
run bash "$AB"
assert_rc "no args" 2
run bash "$AB" "$w/run"
assert_rc "run root only" 2
run bash "$AB" "$w/run" one
assert_rc "non-numeric phase" 2
run bash "$AB" "$w/run" 1 --bogus
assert_rc "unknown flag" 2
run bash "$AB" "$w/run" --audit
assert_rc "--audit without round" 2
run bash "$AB" "$w/run" --audit x
assert_rc "--audit with non-numeric round" 2
run bash "$AB" "$w/run" 1 --fix extra
assert_rc "extra argument" 2
[ -e "$w/run/phases/phase-1.brief.md" ] && no "no brief on usage error" "brief written" || ok "no brief on usage error"
rm -rf "$w"

# ---------------------------------------------------------------------------
echo "[2] Missing inputs -> exit 1 with a named file"
w="$(mktemp -d)"; make_run "$w/run"
run bash "$AB" "$w/nope" 1
assert_rc "missing run root" 1
assert_contains "names the run root" "run root not found" "$OUT"
run bash "$AB" "$w/run" 3
assert_rc "missing spec" 1
assert_contains "names the spec" "phase-3.md" "$OUT"
run bash "$AB" "$w/run" 2 --fix
assert_rc "missing fix spec" 1
assert_contains "names the fix spec" "phase-2.fix.md" "$OUT"
rm "$w/run/PHASE-BRIEF.md"
run bash "$AB" "$w/run" 1
assert_rc "missing template" 1
assert_contains "names the template" "PHASE-BRIEF.md" "$OUT"
rm -rf "$w"

# ---------------------------------------------------------------------------
echo "[3] Phase brief: spec, slice, carryover, state excerpt, phase markers, no placeholders"
w="$(mktemp -d)"; make_run "$w/run"
run bash "$AB" "$w/run" 1
assert_rc "phase brief exits 0" 0
assert_contains "summary line" "brief: $w/run/phases/phase-1.brief.md (" "$OUT"
assert_contains "summary counts seeds" "slice: 2 seeds" "$OUT"
assert_contains "summary counts carryover" "carryover: 1 memories" "$OUT"
assert_contains "summary reports brief size in KB" " KB, slice: 2 seeds" "$OUT"
case "$OUT" in *"carryover: 1 memories / "[0-9]*" KB)"*) ok "summary reports carryover size in KB";; *) no "summary reports carryover size in KB" "[$OUT]";; esac
assert_file "brief written" "$w/run/phases/phase-1.brief.md"
B="$(cat "$w/run/phases/phase-1.brief.md")"
assert_contains "mode in title" "# Relay brief — phase: Build scheduler core" "$B"
assert_contains "phase row expanded" "| Phase | 1 of 2 — Build scheduler core |" "$B"
assert_contains "baseline expanded" "\`abc1234\`" "$B"
assert_contains "memory dir expanded" "| Memory dir | \`$w/run/mem\` |" "$B"
assert_contains "evidence path expanded" "phases/phase-1.evidence.md" "$B"
assert_contains "spec inlined" "SPEC-ONE-WORK-BULLET" "$B"
assert_contains "spec path named" "\`$w/run/phases/phase-1.md\`" "$B"
assert_contains "graph refreshed via run-root helper" "graph: stub rebuilt" "$B"
assert_file "stub build-graph.sh invoked with run root" "$w/run/graph-built"
assert_contains "slice: first seed header with file:line" "### Scheduler (Sources/App/Scheduler/Scheduler.swift:L8)" "$B"
assert_contains "slice: second seed header" "### HistoryStore (Sources/App/History/HistoryStore.swift:L72)" "$B"
assert_contains "carryover memory inlined" "MEMORY-BODY: a short lock must be a true no-op." "$B"
assert_contains "carryover heading" "### movez-invariant" "$B"
assert_contains "missing carryover degrades to a note" "### missing-one" "$B"
assert_contains "missing carryover names the dir" "(not found under $w/run/mem)" "$B"
assert_contains "applied-memories inlined" "swift-testing-quirk" "$B"
assert_contains "engineering status excerpt" "- Tests: 12 pass" "$B"
assert_contains "failure log scoped to phase 1" "C3 failed — retried" "$B"
assert_missing "phase 2 failure line excluded" "unrelated failure line" "$B"
assert_missing "phase 12 does not match phase 1" "must not leak" "$B"
assert_contains "phase marker format present" "### \`RELAY_PHASE_START\`" "$B"
assert_contains "failure marker format present" "### \`FAILURE_ESCALATE\`" "$B"
assert_missing "audit marker format absent" "### \`AUDIT_START\`" "$B"
assert_missing "audit-fix marker format absent" "AUDIT_FIX" "$B"
assert_contains "phase-mode failure protocol" "Never print \`FAILURE_HANDOFF\` from a phase window" "$B"
assert_missing "fix-mode prose filtered out" "This is a **fix attempt**" "$B"
assert_missing "audit-mode prose filtered out" "This is **audit round" "$B"
assert_missing "no mode fences survive" "<!-- mode:" "$B"
assert_missing "no closing fences survive" "<!-- /mode -->" "$B"
assert_missing "no placeholder survives" "{{" "$B"
assert_contains "run root substituted inline" "Never edit \`$w/run/STATE.md\`" "$B"
assert_contains "last-phase memory rule carries N of T" "(1 of 2)" "$B"
assert_contains "phase report path" "First write the report to \`$w/run/phases/phase-1.report.md\`" "$B"
assert_contains "phase context hygiene rules" "**Context hygiene.**" "$B"
assert_contains "no whole-file cat rule" "Never \`cat\` a whole source" "$B"
assert_contains "background-task rule" "was moved to the background" "$B"
assert_contains "permission denial rule" "A permission denial is an answer" "$B"
rm -rf "$w"

# ---------------------------------------------------------------------------
echo "[4] Map seeds: none -> no slice, graph not rebuilt"
w="$(mktemp -d)"; make_run "$w/run"
run bash "$AB" "$w/run" 2
assert_rc "phase 2 exits 0" 0
assert_contains "summary says no slice" "slice: none" "$OUT"
B="$(cat "$w/run/phases/phase-2.brief.md")"
assert_contains "none note in brief" "\`Map seeds: none\` — no slice" "$B"
[ -e "$w/run/graph-built" ] && no "graph not rebuilt for none" "stub was called" || ok "graph not rebuilt for none"
assert_contains "spec inlined" "SPEC-TWO-WORK-BULLET" "$B"
assert_contains "title falls back to spec name" "phase: Wire history" "$B"
assert_missing "phase 1 failure line excluded" "C3 failed" "$B"
assert_contains "phase 2 failure line included" "unrelated failure line" "$B"
rm -rf "$w"

# ---------------------------------------------------------------------------
echo "[5] Fix brief: fix spec + original spec as gate, seeds from the original"
w="$(mktemp -d)"; make_run "$w/run"
run bash "$AB" "$w/run" 1 --fix
assert_rc "fix brief exits 0" 0
assert_file "fix brief path" "$w/run/phases/phase-1.fix.brief.md"
B="$(cat "$w/run/phases/phase-1.fix.brief.md")"
assert_contains "fix title" "# Relay brief — fix: fix for phase 1 — Build scheduler core" "$B"
assert_contains "fix-mode prose" "This is a **fix attempt**" "$B"
assert_contains "fix spec inlined" "FIX-SPEC-BODY" "$B"
assert_contains "original spec appended as gate" "### Original phase spec (success gate" "$B"
assert_contains "original criteria present" "- C3 no debug prints" "$B"
assert_contains "slice from the original's seeds" "### Scheduler (Sources/App/Scheduler/Scheduler.swift:L8)" "$B"
assert_contains "fix-mode failure protocol" "there is no retry in a fix window" "$B"
assert_missing "phase-mode failure protocol absent" "Never print \`FAILURE_HANDOFF\` from a phase window" "$B"
assert_contains "fix report contract" "do not repeat \`RELAY_PHASE_START\`" "$B"
assert_contains "fix report path" "\`$w/run/phases/phase-1.fix.report.md\`" "$B"
assert_missing "no placeholder survives" "{{" "$B"
rm -rf "$w"

# ---------------------------------------------------------------------------
echo "[6] Audit brief: audit steps, audit markers only, no slice"
w="$(mktemp -d)"; make_run "$w/run"
run bash "$AB" "$w/run" --audit 2
assert_rc "audit brief exits 0" 0
assert_contains "summary" "brief: $w/run/phases/audit-2.brief.md (" "$OUT"
assert_contains "summary no slice" "slice: none" "$OUT"
B="$(cat "$w/run/phases/audit-2.brief.md")"
assert_contains "audit title" "# Relay brief — audit: final audit, round 2" "$B"
assert_contains "round row" "| Audit round | 2 of at most 3 |" "$B"
assert_contains "audit steps present" "This is **audit round 2**" "$B"
assert_contains "total phases in completeness step" "for each phase 1..2" "$B"
assert_contains "audit evidence path" "phases/audit-2.evidence.md" "$B"
assert_contains "audit markers present" "### \`AUDIT_START\`" "$B"
assert_contains "audit-fix marker present for reference" "### \`AUDIT_FIX\`" "$B"
assert_missing "phase markers absent" "### \`RELAY_PHASE_START\`" "$B"
assert_missing "failure markers absent" "### \`FAILURE_PROBE\`" "$B"
assert_contains "no code map for audits" "(No code map for audits" "$B"
assert_contains "audit report path" "\`$w/run/phases/audit-2.report.md\`" "$B"
assert_contains "audit context hygiene" "grep\` evidence files for \`Result:\` lines" "$B"
[ -e "$w/run/graph-built" ] && no "graph not rebuilt for audit" "stub was called" || ok "graph not rebuilt for audit"
assert_contains "whole failure log for audits" "unrelated failure line" "$B"
assert_missing "phase-row absent" "| Phase |" "$B"
assert_missing "no placeholder survives" "{{" "$B"
rm -rf "$w"

# ---------------------------------------------------------------------------
echo "[7] Audit-fix brief: fix spec inlined, AUDIT_FIX contract"
w="$(mktemp -d)"; make_run "$w/run"
run bash "$AB" "$w/run" --audit-fix 1
assert_rc "audit-fix brief exits 0" 0
assert_file "audit-fix brief path" "$w/run/phases/audit-fix-1.brief.md"
B="$(cat "$w/run/phases/audit-fix-1.brief.md")"
assert_contains "audit-fix title" "# Relay brief — audit-fix: fix for audit round 1" "$B"
assert_contains "audit-fix spec inlined" "AUDIT-FIX-BODY" "$B"
assert_contains "audit-fix contract" "exactly one \`AUDIT_FIX\` block" "$B"
assert_contains "audit-fix evidence path" "phases/audit-1.evidence.md" "$B"
assert_contains "audit-fix report path" "\`$w/run/phases/audit-fix-1.report.md\`" "$B"
assert_contains "audit-fix context hygiene" "Context hygiene: read this brief once" "$B"
assert_missing "no placeholder survives" "{{" "$B"
run bash "$AB" "$w/run" --audit-fix 2
assert_rc "missing audit-fix spec exits 1" 1
rm -rf "$w"

# ---------------------------------------------------------------------------
echo "[8] No carryover, no Memory dir -> notes, never fatal; trailing slash on run root"
w="$(mktemp -d)"; make_run "$w/run"
python3 - "$w/run/STATE.md" <<'PY'
import sys, re, pathlib
p = pathlib.Path(sys.argv[1]); t = p.read_text()
t = re.sub(r"\*\*Memory dir:\*\*.*\n", "", t)
t = t.split("## Carryover")[0] + "## Carryover\n\n- (none yet)\n"
p.write_text(t)
PY
rm "$w/run/applied-memories.md"
run bash "$AB" "$w/run/" 1
assert_rc "still exits 0" 0
assert_contains "summary zero carryover" "carryover: 0 memories" "$OUT"
assert_contains "trailing slash normalized in summary" "brief: $w/run/phases/phase-1.brief.md" "$OUT"
B="$(cat "$w/run/phases/phase-1.brief.md")"
assert_contains "no-carryover note" "(no carryover yet" "$B"
assert_contains "memory dir placeholder note" "<not set — see STATE.md Memory dir>" "$B"
assert_missing "no placeholder survives" "{{" "$B"
rm -rf "$w"

# ---------------------------------------------------------------------------
echo "[9] Helpers missing from the run root degrade to notes"
w="$(mktemp -d)"; make_run "$w/run"
rm "$w/run/build-graph.sh" "$w/run/map-slice.sh" "$w/run/map-slice.py"
run bash "$AB" "$w/run" 1
assert_rc "exits 0 without helpers" 0
B="$(cat "$w/run/phases/phase-1.brief.md")"
assert_contains "build-graph note" "build-graph.sh not in run root" "$B"
assert_contains "map-slice note" "map-slice.sh not in run root" "$B"
rm -rf "$w"

# ---------------------------------------------------------------------------
echo
echo "[12] Audit brief inlines SPEC.md — and a run without one still dispatches"
w="$(mktemp -d)"; make_run "$w/run"
run bash "$AB" "$w/run" --audit 1
assert_rc "no SPEC.md still exits 0" 0
B="$(cat "$w/run/phases/audit-1.brief.md")"
assert_contains "degrades to a note" "(no SPEC.md for this run" "$B"
assert_contains "and says not to invent criteria" "do not invent run-level criteria" "$B"
assert_contains "summary reports zero spec criteria" "spec: 0 criteria" "$OUT"

cat > "$w/run/SPEC.md" <<'SPEC'
# Spec: Add dark mode

## Goal

Ship a dark theme.

## Success criteria

- **S1 — Token set**: every colour resolves from a token
  - Acceptance: `npm run lint:tokens` exits 0
- **S2 — Persistence**: the choice survives a reload
  - Acceptance: `npm test -- theme` exits 0

## Prohibitions (must-NOT)

- Must not flash the light theme on load

## Assumptions

- (none)
SPEC
run bash "$AB" "$w/run" --audit 1
assert_rc "with SPEC.md exits 0" 0
B="$(cat "$w/run/phases/audit-1.brief.md")"
assert_contains "inlines the success criteria" "S1 — Token set" "$B"
assert_contains "inlines the acceptance line" 'npm run lint:tokens' "$B"
assert_contains "inlines prohibitions too" "Must not flash the light theme" "$B"
assert_missing "but not unrelated spec sections" "Ship a dark theme." "$B"
assert_contains "spec section header present" "## 3b. The run specification" "$B"
assert_contains "spec-check step present" "Spec check" "$B"
assert_contains "summary counts the criteria" "spec: 2 criteria" "$OUT"

run bash "$AB" "$w/run" 1
assert_rc "phase brief exits 0" 0
B="$(cat "$w/run/phases/phase-1.brief.md")"
assert_missing "phase briefs carry no spec section" "## 3b. The run specification" "$B"
assert_missing "phase summary reports no spec count" "spec:" "$OUT"
rm -rf "$w"

# ---------------------------------------------------------------------------
echo
echo "[12b] Review, tidy-up and security briefs get the plan (scope, constraints, assumptions) and who decided"
w="$(mktemp -d)"; make_run "$w/run"
run bash "$AB" "$w/run" --security
assert_rc "security brief without SPEC.md exits 0" 0
B="$(cat "$w/run/phases/security.brief.md")"
assert_contains "no SPEC.md → note for the checks" "the phase specs are the only plan to check a fix against" "$B"
cat > "$w/run/SPEC.md" <<'SPEC'
# Spec: Add dark mode

## Goal

GOAL-LINE-NOT-FOR-CHECKS

## In scope

- IN-SCOPE-LINE

## Out of scope

- OWNER-EXCLUSION-LINE
- PLANNER-EXCLUSION-LINE (planner)

## Constraints

- CONSTRAINT-LINE

## Success criteria

- **S1 — Token set**: every colour resolves from a token
  - Acceptance: `npm run lint:tokens` exits 0

## Edge coverage

EDGE-ROW-NOT-FOR-CHECKS

## Prohibitions (must-NOT)

- PROHIBITION-LINE

## Assumptions

- ASSUMPTION-LINE

## Interview log

INTERVIEW-NOT-FOR-CHECKS
SPEC
for m in review cleanup security; do
  if [ "$m" = review ]; then run bash "$AB" "$w/run" 1 --review; f="$w/run/phases/phase-1.review.brief.md"
  else run bash "$AB" "$w/run" --$m; f="$w/run/phases/$m.brief.md"; fi
  assert_rc "$m brief exits 0" 0
  B="$(cat "$f")"
  assert_contains "$m: plan section" "## 3b. The plan this run was approved with" "$B"
  for t in IN-SCOPE-LINE OWNER-EXCLUSION-LINE "PLANNER-EXCLUSION-LINE (planner)" CONSTRAINT-LINE "S1 — Token set" PROHIBITION-LINE ASSUMPTION-LINE; do
    assert_contains "$m: carries $t" "$t" "$B"
  done
  for t in GOAL-LINE-NOT-FOR-CHECKS EDGE-ROW-NOT-FOR-CHECKS INTERVIEW-NOT-FOR-CHECKS; do
    assert_missing "$m: leaves out $t" "$t" "$B"
  done
  assert_contains "$m: relay's call is fixed and flagged" "A fix may change it: make the fix, and flag it as a \`[plan]\` bullet" "$B"
  assert_contains "$m: the owner's call is never overridden" "A fix never overrides it" "$B"
  assert_contains "$m: [plan] bullet format" "- [plan] <file:line> — <what the fix changed> — changed: plan said" "$B"
done
run bash "$AB" "$w/run" --audit 1
B="$(cat "$w/run/phases/audit-1.brief.md")"
assert_missing "the audit still gets criteria + prohibitions only" "OWNER-EXCLUSION-LINE" "$B"
assert_missing "… and no who-decided rule" "The plan this run was approved with" "$B"
printf '# Security fix\n\n1. a.py:3 — mode widened. Changes the plan: "x" (relay'"'"'s call)\n' > "$w/run/phases/security-fix.md"
run bash "$AB" "$w/run" --security-fix
B="$(cat "$w/run/phases/security-fix.brief.md")"
assert_contains "fix window: keeps a plan change and flags it" "when you keep it, append a \`[plan]\` bullet" "$B"
assert_contains "fix window: undone → the plan stands" "the plan then stands as written" "$B"
rm -rf "$w"

# ---------------------------------------------------------------------------
echo
echo "[13] Review brief: phase spec, diff range from git by trailer, slice, review markers only"
w="$(mktemp -d)"; P="$w/proj"; RR="$P/.relay/add-dark-mode-Ab3Kx9"
git -C "$w" init -q -b main proj
gp() { git -C "$P" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false -c core.hooksPath=.git/no-hooks "$@"; }
echo ".relay/" >> "$P/.git/info/exclude"
printf 'x\n' > "$P/README.md"; gp add README.md; gp commit -qm init
make_run "$RR"
base="$(git -C "$P" rev-parse HEAD)"
perl -pi -e "s/^\*\*Baseline ref:\*\* abc1234/**Baseline ref:** $base/" "$RR/STATE.md"
tr1() { printf '%s\n' "$2" > "$P/$1"; gp add "$1"; gp commit -qm "$3" -m "Relay-Run: add-dark-mode-Ab3Kx9" -m "$4"; }
tr1 a.txt a "relay: phase 1 — Build scheduler core" "Relay-Phase: 1"
first="$(git -C "$P" rev-parse --short HEAD)"
tr1 b.txt b "relay: phase 1 — Build scheduler core (fix)" "Relay-Phase: 1"
last="$(git -C "$P" rev-parse --short HEAD)"
tr1 c.txt c "relay: phase 2 — Wire history" "Relay-Phase: 2"
run bash "$AB" "$RR" 1 --review
assert_rc "review brief exits 0" 0
assert_file "review brief path" "$RR/phases/phase-1.review.brief.md"
assert_contains "summary names the diff range" "diff: $first^..$last" "$OUT"
B="$(cat "$RR/phases/phase-1.review.brief.md")"
assert_contains "review title" "# Relay brief — review: review of phase 1 — Build scheduler core" "$B"
assert_contains "phase row for a review" "| Phase | 1 of 2 — review of phase 1" "$B"
assert_contains "review task prose" "This is the **correctness review of phase 1**" "$B"
assert_contains "range spans the phase's first to last commit (fix included)" "\`$first^..$last\`" "$B"
assert_missing "… and never phase 2's commit" "$(git -C "$P" rev-parse --short HEAD)" "$B"
assert_contains "phase spec inlined" "SPEC-ONE-WORK-BULLET" "$B"
assert_contains "slice from the phase's seeds" "### Scheduler (Sources/App/Scheduler/Scheduler.swift:L8)" "$B"
assert_contains "review evidence path" "phases/phase-1.review.evidence.md" "$B"
assert_contains "review report path" "\`$RR/phases/phase-1.review.report.md\`" "$B"
assert_contains "review logs under the phase's log dir" "$RR/logs/phase-1/review-stat.log" "$B"
assert_contains "review marker formats" "### \`REVIEW_FINDINGS\`" "$B"
assert_contains "FINDINGS.md format included" "### \`FINDINGS.md\`" "$B"
assert_missing "phase markers absent" "### \`RELAY_PHASE_START\`" "$B"
assert_missing "audit markers absent" "### \`AUDIT_START\`" "$B"
assert_contains "read-only rule" "**You change nothing.**" "$B"
assert_contains "never hands off" "these steps never hand off" "$B"
assert_contains "review report contract" "\`REVIEW_START\`, then **one** of \`REVIEW_CLEAN\` or \`REVIEW_FINDINGS\`" "$B"
assert_missing "phase-mode writeback absent" "Memory writeback" "$B"
assert_missing "no commit instruction in a read-only window" "relay-git.sh commit $RR" "$B"
assert_missing "no placeholder survives" "{{" "$B"
assert_missing "no mode fences survive" "<!-- mode:" "$B"

echo "[14] Review-fix brief: fix spec + original gate, commit instruction"
printf '# Review fix — phase 1\n\nREVIEW-FIX-BODY: 1. Scheduler.swift:12 — off-by-one.\n' > "$RR/phases/phase-1.review-fix.md"
run bash "$AB" "$RR" 1 --review-fix
assert_rc "review-fix brief exits 0" 0
B="$(cat "$RR/phases/phase-1.review-fix.brief.md")"
assert_contains "review-fix title" "# Relay brief — review-fix: fix for phase 1's review — Build scheduler core" "$B"
assert_contains "fix spec inlined" "REVIEW-FIX-BODY" "$B"
assert_contains "original spec appended as the gate" "### Original phase spec (success gate" "$B"
assert_contains "evidence appends to the review's file" "phases/phase-1.review.evidence.md" "$B"
assert_contains "review-fix report path" "\`$RR/phases/phase-1.review-fix.report.md\`" "$B"
assert_contains "commit with --review-fix" "relay-git.sh commit $RR 1 --review-fix" "$B"
assert_contains "undo on red" "undo that finding's changes" "$B"
assert_contains "review-fix report contract" "exactly one \`REVIEW_FIX\` block" "$B"
assert_missing "no placeholder survives" "{{" "$B"
run bash "$AB" "$RR" 2 --review-fix
assert_rc "missing review-fix spec exits 1" 1
assert_contains "… naming it" "phase-2.review-fix.md" "$OUT"

echo "[15] Review without git, and with no commit for the phase, degrades to a note"
w2="$(mktemp -d)"; make_run "$w2/run"
run bash "$AB" "$w2/run" 1 --review
assert_rc "no git still exits 0" 0
assert_contains "no-git note" "none — not a git repository" "$(cat "$w2/run/phases/phase-1.review.brief.md")"
rm -rf "$w2"
printf 'RELAY_PHASE_START\nPhase: 3 of 3 — Third\nMap seeds: none\n' > "$RR/phases/phase-3.md"
run bash "$AB" "$RR" 3 --review
assert_rc "no commit for the phase still exits 0" 0
assert_contains "no-commit note" "none — no commit with Relay-Phase: 3" "$(cat "$RR/phases/phase-3.review.brief.md")"
rm "$RR/phases/phase-3.md"

echo "[16] Cleanup brief: commands union, footprint, spec section, no slice"
cat >> "$RR/phases/phase-1.md" <<'MC'

## Mandatory commands

- `swift build`
- `swift test`
MC
cat >> "$RR/phases/phase-2.md" <<'MC'

## Mandatory commands

- `swift test`
- `swiftlint`
- ...
MC
rm -f "$RR/graph-built"
run bash "$AB" "$RR" --cleanup
assert_rc "cleanup brief exits 0" 0
assert_file "cleanup brief path" "$RR/phases/cleanup.brief.md"
assert_contains "summary counts deduplicated commands" "commands: 3" "$OUT"
B="$(cat "$RR/phases/cleanup.brief.md")"
assert_contains "cleanup title" "# Relay brief — cleanup: tidy-up pass" "$B"
assert_contains "fix-or-defer rules" "**Fix now only if all five hold**" "$B"
assert_contains "footprint command" "repo-state.sh changed-files $base" "$B"
assert_contains "commands union: build" "- \`swift build\`" "$B"
assert_contains "commands union: lint" "- \`swiftlint\`" "$B"
assert_eq_n() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "expected [$2] got [$3]"; fi; }
assert_eq_n "swift test listed once" "1" "$(grep -c '^- `swift test`$' "$RR/phases/cleanup.brief.md")"
assert_missing "continuation bullet dropped" "- ..." "$B"
assert_contains "cleanup commit" "relay-git.sh commit $RR --cleanup" "$B"
assert_contains "never a whole-tree restore" "never a whole-tree restore" "$B"
assert_contains "cleanup logs dir" "$RR/logs/cleanup/cleanup-" "$B"
assert_contains "cleanup report contract" "\`CLEANUP_START\`, \`CLEANUP_DONE\`" "$B"
assert_contains "no code map note" "(No code map — start from the run's footprint" "$B"
assert_contains "no SPEC.md → note" "(no SPEC.md for this run" "$B"
assert_missing "no phase row" "| Phase |" "$B"
assert_missing "no placeholder survives" "{{" "$B"
[ -e "$RR/graph-built" ] && no "graph not rebuilt for cleanup" "stub was called" || ok "graph not rebuilt for cleanup"

echo "[17] Security brief + security-fix brief"
printf '# Spec\n\n## Success criteria\n\n- **S1 — Login**: only signed-in users see history\n' > "$RR/SPEC.md"
run bash "$AB" "$RR" --security
assert_rc "security brief exits 0" 0
B="$(cat "$RR/phases/security.brief.md")"
assert_contains "security title" "# Relay brief — security: security pass" "$B"
assert_contains "checklist" "authentication and authorisation on every new route" "$B"
assert_contains "spec criteria inlined" "S1 — Login" "$B"
assert_contains "commands for confirming findings" "- \`swiftlint\`" "$B"
assert_contains "read-only rule" "**You change nothing.**" "$B"
assert_contains "security report contract" "\`SECURITY_START\`, then **one** of \`SECURITY_CLEAN\` or \`SECURITY_FINDINGS\`" "$B"
assert_contains "security evidence path" "phases/security.evidence.md" "$B"
assert_missing "no placeholder survives" "{{" "$B"
run bash "$AB" "$RR" --security-fix
assert_rc "missing security-fix spec exits 1" 1
printf '# Security fix\n\nSEC-FIX-BODY: 1. api.ts:4 — unescaped input.\n' > "$RR/phases/security-fix.md"
run bash "$AB" "$RR" --security-fix
assert_rc "security-fix brief exits 0" 0
B="$(cat "$RR/phases/security-fix.brief.md")"
assert_contains "security-fix title" "# Relay brief — security-fix: fix for the security pass" "$B"
assert_contains "security-fix spec inlined" "SEC-FIX-BODY" "$B"
assert_contains "gate is the commands union" "- \`swift build\`" "$B"
assert_contains "security-fix commit" "relay-git.sh commit $RR --security-fix" "$B"
assert_contains "security-fix report contract" "exactly one \`SECURITY_FIX\` block" "$B"
assert_contains "evidence shared with the pass" "phases/security.evidence.md" "$B"
assert_missing "no placeholder survives" "{{" "$B"

echo "[18] Audit brief treats FINDINGS.md as input; new-mode usage errors"
run bash "$AB" "$RR" --audit 1
assert_contains "audit step names FINDINGS.md" "It is **input, not a gap**" "$(cat "$RR/phases/audit-1.brief.md")"
run bash "$AB" "$RR" --cleanup extra
assert_rc "--cleanup takes no argument" 2
run bash "$AB" "$RR" --review 1
assert_rc "--review needs the phase first" 2
run bash "$AB" "$RR" 1 --review extra
assert_rc "nothing after --review" 2
rm -rf "$w"

# ---------------------------------------------------------------------------
echo
echo "----------------------------------------"
printf 'Results: %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  exit 1
fi
echo "All fixture scenarios passed."
exit 0
