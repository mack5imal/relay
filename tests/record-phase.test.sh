#!/usr/bin/env bash
# record-phase.test.sh — fixture tests for scripts/record-phase.sh
#
# Proves the orchestrator's bookkeeping helper: a subagent's report file is validated the way
# PROTOCOL.md validates a report, and every STATE.md change for its outcome is applied —
# phase row, Status, Current phase, engineering lines, Notable events, Failure log, Carryover —
# idempotently, atomically, with one summary line. Includes the real reports from the first
# end-to-end run (contextmeter) as regression fixtures.
#
# Repo-only (not shipped in the plugin payload). Run from anywhere:
#   bash tests/record-phase.test.sh
# Exits 0 if every assertion passes, 1 otherwise.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RP="$REPO_ROOT/skills/goal/scripts/record-phase.sh"
FX="$REPO_ROOT/tests/fixtures/record-phase"

for f in "$RP" "$FX/contextmeter-phase-3.report.md" "$FX/contextmeter-phase-7.report.md" \
         "$FX/contextmeter-audit-1.report.md" "$FX/sabotage-phase-escalate.report.md" \
         "$FX/sabotage-fix-done.report.md" "$FX/sabotage-fix-handoff.report.md" \
         "$FX/sabotage-audit-gaps.report.md" "$FX/sabotage-audit-fix.report.md"; do
  [ -f "$f" ] || { echo "FATAL: missing $f" >&2; exit 1; }
done

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  \033[31m✗\033[0m %s\n      %s\n' "$1" "$2"; }

assert_rc()       { if [ "$2" = "$RC" ]; then ok "$1"; else no "$1" "expected exit $2 got $RC (out: $OUT)"; fi; }
assert_contains() { case "$3" in *"$2"*) ok "$1";; *) no "$1" "missing substring [$2] in [$3]";; esac; }
assert_missing()  { case "$3" in *"$2"*) no "$1" "unexpectedly contains [$2]";; *) ok "$1";; esac; }
assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "expected [$2] got [$3]"; fi; }

export RELAY_DATE=2026-09-20
run() { OUT="$("$@" 2>&1)"; RC=$?; }
count() { grep -cF -- "$1" "$2" || true; }

# make_run <dir> [total] — a fixture run root: STATE.md in the Stage 7 shape plus phase specs.
make_run() {
  local r="$1" total="${2:-3}" i
  mkdir -p "$r/phases"
  {
    cat <<'HEAD'
# State: Add dark mode

**Status:** READY_TO_DISPATCH
**Current phase:** 1
**Started:** 2026-09-12
**Last update:** 2026-09-12
**Run root:** .relay/add-dark-mode-Ab3Kx9    <!-- namespaced -->
**Baseline ref:** abc1234    <!-- HEAD sha captured at Stage 7 -->
**Memory dir:** /tmp/mem    <!-- detected at Stage 0 -->

## Phase progress

| # | Phase | Status | Started | Completed | Notes |
|---|-------|--------|---------|-----------|-------|
HEAD
    for i in $(seq 1 "$total"); do echo "| $i | Phase name $i | pending | — | — | — |"; done
    cat <<'TAIL'

## Engineering check status

Updated by each phase as it runs.

- Build: —
- Typecheck: —
- Lint: —
- Tests: —

## Notable events

- 2026-09-12 — Plan locked, 3 phases.
- ...

## Failure log

If a phase hits FAILURE_PROBE, record it here:

- Phase {{N}} ({{NAME}}): {{WHAT_FAILED}} — {{WHAT_WAS_TRIED}} — {{NEXT_MOVE}}

## Carryover

Memory files written this run.

- (none yet)
TAIL
  } > "$r/STATE.md"
  for i in $(seq 1 "$total"); do printf 'RELAY_PHASE_START\nPhase: %s of %s — Phase name %s\n' "$i" "$total" "$i" > "$r/phases/phase-$i.md"; done
}

# done_report <path> <N> <total> [memory] [probe] — a successful phase report
done_report() {
  local p="$1" n="$2" t="$3" mem="${4:-none — nothing non-obvious this phase}" probe="${5:-}"
  {
    printf 'RELAY_PHASE_START\nPhase: %s of %s — Phase name %s\nTask: do it\n\n' "$n" "$t" "$n"
    if [ -n "$probe" ]; then
      printf 'FAILURE_PROBE\nPhase: %s — Phase name %s\nFailed criterion: C2 lint\nTried: x\nHypothesis: y\nNext: auto-retry with probe injected\n\n' "$n" "$n"
    fi
    printf 'RELAY_PHASE_VERIFY\nAcceptance (evidence: x):\n- C1 first thing: pass\n- C2 second: thing: pass\n- C3 third: pass\n'
    printf 'Engineering: build pass · typecheck pass · lint pre-existing · tests pass (12 passed)\n'
    printf 'Cleanliness: debug prints 0 · TODO/FIXME 0 · dead imports 0\nFiles changed: 4\n\n'
    printf 'MEMORY_SAVED: %s\n\nRELAY_PHASE_DONE\nPhase %s complete.\nEvidence: x\n' "$mem" "$n"
  } > "$p"
}

escalate_report() {
  printf 'RELAY_PHASE_START\nPhase: %s of 3 — Phase name %s\n\nFAILURE_PROBE\nPhase: %s — Phase name %s\nFailed criterion: C1 probe text\n\nFAILURE_ESCALATE\nPhase: %s — Phase name %s\nFailed criterion: C2 tests green\nRetry probe history:\n  attempt 1: a\n  attempt 2: b\nWriting fix spec at x\n' \
    "$2" "$2" "$2" "$2" "$2" "$2" > "$1"
}

echo "record-phase.test.sh — fixtures for $RP"
echo

# ---------------------------------------------------------------------------
echo "[1] Phase done — row, status, current phase, engineering, event, carryover"
w="$(mktemp -d)"; make_run "$w/run"
done_report "$w/run/phases/phase-1.report.md" 1 3 "dark-mode-tokens"
run bash "$RP" "$w/run" 1
assert_rc "exits 0" 0
assert_eq "one summary line" "recorded: phase 1 done (3/3 pass, memory dark-mode-tokens) → next: phase 2" "$OUT"
S="$(cat "$w/run/STATE.md")"
assert_contains "row completed with dates + evidence" "| 1 | Phase name 1 | completed | 2026-09-20 | 2026-09-20 | Evidence: phases/phase-1.evidence.md |" "$S"
assert_contains "other rows untouched" "| 2 | Phase name 2 | pending | — | — | — |" "$S"
assert_contains "status IN_PROGRESS" "**Status:** IN_PROGRESS" "$S"
assert_contains "current phase advanced" "**Current phase:** 2" "$S"
assert_contains "last update" "**Last update:** 2026-09-20" "$S"
assert_contains "comment on a field kept" "**Baseline ref:** abc1234    <!-- HEAD sha captured at Stage 7 -->" "$S"
assert_contains "build line" "- Build: pass (phase 1)" "$S"
assert_contains "lint pre-existing" "- Lint: pre-existing (phase 1)" "$S"
assert_contains "tests parenthetical merged" "- Tests: pass (phase 1, 12 passed)" "$S"
assert_contains "event line" "- 2026-09-20 — Phase 1 complete: 3/3 criteria pass, 4 files changed, memory dark-mode-tokens" "$S"
assert_missing "event placeholder dropped" "- ..." "$S"
assert_contains "carryover appended with the phase that wrote it" "- dark-mode-tokens (phase 1)" "$S"
assert_missing "carryover placeholder dropped" "(none yet)" "$S"
assert_contains "failure-log placeholder kept when nothing is logged" "{{WHAT_FAILED}}" "$S"
assert_eq "no temp files left in run root" "" "$(find "$w/run" -name '*.new' -o -name '*.tmp')"

# ---------------------------------------------------------------------------
echo
echo "[2] Idempotent — the same report twice (even on a later day) changes nothing"
cp "$w/run/STATE.md" "$w/once.md"
RELAY_DATE=2026-09-20 run bash "$RP" "$w/run" 1
assert_rc "exits 0 again" 0
assert_eq "STATE.md identical" "" "$(diff "$w/once.md" "$w/run/STATE.md")"
RELAY_DATE=2026-09-21 run bash "$RP" "$w/run" 1
assert_eq "one event line after a later-day re-record" "1" "$(count 'Phase 1 complete:' "$w/run/STATE.md")"
assert_eq "one carryover line" "1" "$(count '- dark-mode-tokens' "$w/run/STATE.md")"
assert_contains "row keeps first completion date" "| completed | 2026-09-20 | 2026-09-20 |" "$(cat "$w/run/STATE.md")"
rm -rf "$w"

# ---------------------------------------------------------------------------
echo
echo "[3] Probe retry, none memory, note, last phase -> audit"
w="$(mktemp -d)"; make_run "$w/run"
done_report "$w/run/phases/phase-3.report.md" 3 3 "none — nothing non-obvious this phase" probe
run bash "$RP" "$w/run" 3 --note "commit c03f71b"
assert_rc "exits 0" 0
assert_contains "summary says audit next" "→ next: audit" "$OUT"
S="$(cat "$w/run/STATE.md")"
assert_contains "current phase audit" "**Current phase:** audit" "$S"
assert_contains "probe + note in event" "Phase 3 complete: 3/3 criteria pass after one probe retry, 4 files changed — commit c03f71b" "$S"
assert_contains "none memory not carried" "- (none yet)" "$S"
rm -rf "$w"

# ---------------------------------------------------------------------------
echo
echo "[4] Escalate — failure log, row in_progress, next fix"
w="$(mktemp -d)"; make_run "$w/run"
escalate_report "$w/run/phases/phase-2.report.md" 2
run bash "$RP" "$w/run" 2
assert_rc "exits 0" 0
assert_eq "summary" "recorded: phase 2 escalated → next: fix phase 2" "$OUT"
S="$(cat "$w/run/STATE.md")"
assert_contains "failure line uses the ESCALATE criterion" "- Phase 2 (Phase name 2): C2 tests green — attempts 1–2 failed — fix spec dispatched" "$S"
assert_missing "failure placeholder dropped" "{{WHAT_FAILED}}" "$S"
assert_contains "row in_progress, no completion" "| 2 | Phase name 2 | in_progress | 2026-09-20 | — | — |" "$S"
assert_contains "current phase stays" "**Current phase:** 2" "$S"
assert_contains "event" "Phase 2 escalated: C2 tests green — fix spec dispatched" "$S"

echo
echo "[5] Fix done, then fix handoff in a second run"
done_report "$w/run/phases/phase-2.fix.report.md" 2 3 "fix-lesson"
sed -i.bak '/^RELAY_PHASE_START$/,/^$/d' "$w/run/phases/phase-2.fix.report.md" && rm -f "$w/run/phases/phase-2.fix.report.md.bak"
run bash "$RP" "$w/run" 2 --fix
assert_rc "fix done exits 0" 0
assert_eq "fix summary" "recorded: phase 2 fix done (3/3 pass, memory fix-lesson) → next: phase 3" "$OUT"
S="$(cat "$w/run/STATE.md")"
assert_contains "row completed" "| 2 | Phase name 2 | completed | 2026-09-20 | 2026-09-20 | Evidence: phases/phase-2.evidence.md |" "$S"
assert_contains "fix event" "Phase 2 complete via fix window: 3/3 criteria pass" "$S"
assert_contains "a fix window's memory carries its phase" "- fix-lesson (phase 2)" "$S"
assert_contains "phase name from STATE row when report has none" "- Phase 2 (Phase name 2)" "$S"
rm -rf "$w"

w="$(mktemp -d)"; make_run "$w/run"
printf 'FAILURE_HANDOFF\nPhase: 1 — Phase name 1\nFailed criterion: C4 perf budget\nThree attempts tried:\n  1. a\n  2. b\n  3. c\nSuggested next move: z\nUser intervention required.\n' > "$w/run/phases/phase-1.fix.report.md"
run bash "$RP" "$w/run" 1 --fix
assert_rc "fix handoff exits 0" 0
assert_eq "blocked summary" "recorded: phase 1 fix failed → blocked" "$OUT"
S="$(cat "$w/run/STATE.md")"
assert_contains "status BLOCKED" "**Status:** BLOCKED" "$S"
assert_contains "handoff failure line" "- Phase 1 (Phase name 1): C4 perf budget — fix window failed — BLOCKED, user intervention required" "$S"
rm -rf "$w"

# ---------------------------------------------------------------------------
echo
echo "[6] Audit — complete, gaps, handoff; audit fix"
w="$(mktemp -d)"; make_run "$w/run"
cp "$FX/contextmeter-audit-1.report.md" "$w/run/phases/audit-1.report.md"
run bash "$RP" "$w/run" --audit 1
assert_rc "complete exits 0" 0
assert_eq "complete summary names the push step" "recorded: audit round 1 clean → complete — next: relay-git.sh push, then RELAY_RUN_COMPLETE" "$(printf '%s\n' "$OUT" | head -1)"
S="$(cat "$w/run/STATE.md")"
assert_contains "status COMPLETE" "**Status:** COMPLETE" "$S"
assert_contains "current phase complete" "**Current phase:** complete" "$S"
assert_contains "audit event carries coverage" "coverage 107 re-verified, 0 trust-prior (100% re-verified)) — run COMPLETE" "$S"
done_report "$w/run/phases/phase-1.report.md" 1 3
run bash "$RP" "$w/run" 1
assert_contains "a late phase re-record never downgrades COMPLETE" "**Status:** COMPLETE" "$(cat "$w/run/STATE.md")"
rm -rf "$w"

w="$(mktemp -d)"; make_run "$w/run"
printf 'AUDIT_START\nRound: 1\n\nAUDIT_VERIFY\nSummary: x\n\nAUDIT_GAPS\nRound: 1\nGaps:\n- gap one: a\n- gap two: b\nWriting fix spec at x for a fresh window.\n' > "$w/run/phases/audit-1.report.md"
run bash "$RP" "$w/run" --audit 1
assert_rc "gaps exits 0" 0
assert_eq "gaps summary counts bullets" "recorded: audit round 1 gaps (2) → next: audit fix 1" "$OUT"
printf 'AUDIT_FIX\nRound: 1\nGaps addressed: 2 of 2\nEvidence: x\n' > "$w/run/phases/audit-fix-1.report.md"
run bash "$RP" "$w/run" --audit-fix 1
assert_rc "audit fix exits 0" 0
assert_eq "audit fix summary" "recorded: audit fix 1 (2 of 2 gaps addressed) → next: audit round 2" "$OUT"
assert_contains "audit fix event" "Audit fix 1: 2 of 2 gaps addressed" "$(cat "$w/run/STATE.md")"
printf 'AUDIT_START\nRound: 3\n\nAUDIT_VERIFY\nSummary: x\n\nAUDIT_HANDOFF\nRound: 3\nPersistent gaps:\n- g\n' > "$w/run/phases/audit-3.report.md"
run bash "$RP" "$w/run" --audit 3
assert_eq "handoff summary" "recorded: audit round 3 handoff → blocked" "$OUT"
assert_contains "handoff blocks" "**Status:** BLOCKED" "$(cat "$w/run/STATE.md")"
rm -rf "$w"

# ---------------------------------------------------------------------------
echo
echo "[7] Invalid and missing reports"
w="$(mktemp -d)"; make_run "$w/run"
cp "$w/run/STATE.md" "$w/before.md"
printf 'I finished the phase, everything passed.\n' > "$w/run/phases/phase-1.report.md"
run bash "$RP" "$w/run" 1
assert_rc "prose-only report exits 3" 3
assert_contains "names the problem" "no RELAY_PHASE_START" "$OUT"
printf 'RELAY_PHASE_START\nPhase: 1 of 3 — x\n\nRELAY_PHASE_DONE\n\nFAILURE_ESCALATE\n' > "$w/run/phases/phase-1.report.md"
run bash "$RP" "$w/run" 1
assert_rc "DONE + ESCALATE exits 3" 3
printf 'RELAY_PHASE_START\nPhase: 1 of 3 — x\nRELAY_PHASE_VERIFY\n' > "$w/run/phases/phase-1.report.md"
run bash "$RP" "$w/run" 1
assert_rc "no terminal block exits 3" 3
printf 'RELAY_PHASE_START\nRELAY_PHASE_DONE\n' > "$w/run/phases/phase-1.fix.report.md"
run bash "$RP" "$w/run" 1 --fix
assert_rc "fix DONE without VERIFY exits 3" 3
assert_contains "names the missing verify" "without RELAY_PHASE_VERIFY" "$OUT"
printf 'RELAY_PHASE_START\nRELAY_PHASE_VERIFY\nRELAY_PHASE_DONE\n' > "$w/run/phases/phase-1.fix.report.md"
run bash "$RP" "$w/run" 1 --fix
assert_rc "fix report ok with VERIFY + DONE" 0
cp "$w/before.md" "$w/run/STATE.md"
printf 'AUDIT_START\nAUDIT_COMPLETE\n' > "$w/run/phases/audit-1.report.md"
run bash "$RP" "$w/run" --audit 1
assert_rc "audit without AUDIT_VERIFY exits 3" 3
printf 'AUDIT_FIX\nAUDIT_FIX\n' > "$w/run/phases/audit-fix-1.report.md"
run bash "$RP" "$w/run" --audit-fix 1
assert_rc "two AUDIT_FIX blocks exit 3" 3
run bash "$RP" "$w/run" 2
assert_rc "missing report exits 1" 1
assert_contains "names the path" "report not found" "$OUT"
assert_eq "STATE.md untouched by failures" "" "$(diff "$w/before.md" "$w/run/STATE.md")"
run bash "$RP" "$w/nope" 1
assert_rc "missing run root exits 1" 1
rm -rf "$w"

# ---------------------------------------------------------------------------
echo
echo "[8] No-report dispatches — first re-dispatches, second blocks"
w="$(mktemp -d)"; make_run "$w/run"
run bash "$RP" "$w/run" 2 --no-report "ended with prose"
assert_rc "first exits 0" 0
assert_eq "first summary" "recorded: phase 2 dispatch 1 no report → next: re-dispatch" "$OUT"
S="$(cat "$w/run/STATE.md")"
assert_contains "failure line" "- Phase 2: dispatch 1 returned no report (ended with prose)" "$S"
assert_contains "row marked in_progress" "| 2 | Phase name 2 | in_progress | 2026-09-20 | — | — |" "$S"
run bash "$RP" "$w/run" 2 --no-report "context exhausted"
assert_eq "second summary" "recorded: phase 2 dispatch 2 no report → blocked" "$OUT"
S="$(cat "$w/run/STATE.md")"
assert_contains "second line" "- Phase 2: dispatch 2 returned no report (context exhausted)" "$S"
assert_contains "blocked" "**Status:** BLOCKED" "$S"
run bash "$RP" "$w/run" --audit 1 --no-report "tool error"
assert_eq "audit no-report counted separately" "recorded: audit round 1 dispatch 1 no report → next: re-dispatch" "$OUT"
run bash "$RP" "$w/run" 2 --fix --no-report "tool error"
assert_eq "fix no-report counted separately" "recorded: phase 2 fix dispatch 1 no report → next: re-dispatch" "$OUT"
rm -rf "$w"

# ---------------------------------------------------------------------------
echo
echo "[9] Regression — real contextmeter reports (pre-commit-6 marker wording, indents, lists)"
w="$(mktemp -d)"; make_run "$w/run" 7
cp "$FX/contextmeter-phase-3.report.md" "$w/run/phases/phase-3.report.md"
run bash "$RP" "$w/run" 3
assert_rc "phase 3 exits 0" 0
assert_eq "phase 3 summary" "recorded: phase 3 done (10/10 pass, memory real-fixture-shape) → next: phase 4" "$OUT"
S="$(cat "$w/run/STATE.md")"
assert_contains "probe retry noticed, 15 files" "10/10 criteria pass after one probe retry, 15 files changed" "$S"
assert_eq "parenthetical with commas is not a memory name" "1" "$(awk '/^## Carryover/{f=1;next} f && /^- /{c++} END{print c+0}' "$w/run/STATE.md")"
cp "$FX/contextmeter-phase-7.report.md" "$w/run/phases/phase-7.report.md"
run bash "$RP" "$w/run" 7
assert_contains "phase 7 → audit" "→ next: audit" "$OUT"
S="$(cat "$w/run/STATE.md")"
assert_contains "comma list: first memory" "- project_contextmeter" "$S"
assert_contains "comma list: second memory" "- contextmeter-verification-grep-traps" "$S"
assert_contains "files changed keeps the leading count" "12/12 criteria pass, 2 files changed" "$S"
assert_contains "tests detail merged" "- Tests: pass (phase 7, 154 passed)" "$S"
sed 's/^/  /' "$FX/contextmeter-phase-3.report.md" > "$w/run/phases/phase-3.report.md"
run bash "$RP" "$w/run" 3
assert_rc "harness-indented report still valid" 0
rm -rf "$w"

# ---------------------------------------------------------------------------
echo
echo "[10] Regression — the real recovery-path reports from the sabotage runs (commit 7)"
w="$(mktemp -d)"; make_run "$w/run" 2
cp "$FX/sabotage-phase-escalate.report.md" "$w/run/phases/phase-1.report.md"
run bash "$RP" "$w/run" 1
assert_rc "escalate report exits 0" 0
assert_contains "escalate summary" "recorded: phase 1 escalated → next: fix phase 1" "$OUT"
assert_contains "harness criterion in the failure log" "sabotage/fix-window.ok" "$(cat "$w/run/STATE.md")"
cp "$FX/sabotage-fix-done.report.md" "$w/run/phases/phase-1.fix.report.md"
run bash "$RP" "$w/run" 1 --fix
assert_rc "fix-done report exits 0" 0
assert_contains "fix done summary (6 criteria, no MEMORY name)" "recorded: phase 1 fix done (6/6 pass) → next: phase 2" "$OUT"
S="$(cat "$w/run/STATE.md")"
assert_contains "engineering line from the real report" "- Build: pass (phase 1)" "$S"
assert_contains "row completed" "| 1 | Phase name 1 | completed |" "$S"
cp "$FX/sabotage-audit-gaps.report.md" "$w/run/phases/audit-1.report.md"
run bash "$RP" "$w/run" --audit 1
assert_eq "audit gaps counts the real gap list" "recorded: audit round 1 gaps (1) → next: audit fix 1" "$OUT"
cp "$FX/sabotage-audit-fix.report.md" "$w/run/phases/audit-fix-1.report.md"
run bash "$RP" "$w/run" --audit-fix 1
assert_eq "audit fix summary" "recorded: audit fix 1 (1 of 1 gaps addressed) → next: audit round 2" "$OUT"
rm -rf "$w"

w="$(mktemp -d)"; make_run "$w/run" 1
cp "$FX/sabotage-fix-handoff.report.md" "$w/run/phases/phase-1.fix.report.md"
run bash "$RP" "$w/run" 1 --fix
assert_rc "handoff report exits 0" 0
assert_eq "handoff summary" "recorded: phase 1 fix failed → blocked" "$OUT"
S="$(cat "$w/run/STATE.md")"
assert_contains "status BLOCKED" "**Status:** BLOCKED" "$S"
assert_contains "handoff failure line keeps the criterion" "fix window failed — BLOCKED, user intervention required" "$S"
rm -rf "$w"

# ---------------------------------------------------------------------------
echo
echo "[11] Usage errors"
run bash "$RP"
assert_rc "no args exits 2" 2
run bash "$RP" /tmp
assert_rc "run root only exits 2" 2
run bash "$RP" /tmp abc
assert_rc "non-integer phase exits 2" 2
run bash "$RP" /tmp --audit
assert_rc "audit without round exits 2" 2
run bash "$RP" /tmp 1 --bogus
assert_rc "unknown option exits 2" 2
run bash "$RP" /tmp 1 --no-report ""
assert_rc "empty no-report reason exits 2" 2

# ---------------------------------------------------------------------------
echo
echo "[12] Audit round cap is enforced by the script, not only by the subagent"
w="$(mktemp -d)"; make_run "$w/run"
gaps_report() {
  printf 'AUDIT_START\nRound: %s of 3\n\nAUDIT_VERIFY\nPhases: ok\n\nAUDIT_GAPS\nGaps:\n- one\n- two\n' "$1" \
    > "$w/run/phases/audit-$1.report.md"
}
gaps_report 1
run bash "$RP" "$w/run" --audit 1
assert_rc "round 1 gaps exits 0" 0
assert_contains "round 1 dispatches a fix" "→ next: audit fix 1" "$OUT"
gaps_report 3
run bash "$RP" "$w/run" --audit 3
assert_rc "round 3 gaps exits 0" 0
assert_contains "round 3 gaps blocks instead of asking for fix 3" "→ blocked" "$OUT"
S="$(cat "$w/run/STATE.md")"
assert_contains "status BLOCKED at the cap" "**Status:** BLOCKED" "$S"
assert_contains "failure log records the cap" "gaps persist after 3 rounds" "$S"
printf 'AUDIT_FIX\nGaps addressed: 2 of 2\n' > "$w/run/phases/audit-fix-3.report.md"
run bash "$RP" "$w/run" --audit-fix 3
assert_rc "audit fix at the cap exits 0" 0
assert_missing "never asks for a 4th audit round" "audit round 4" "$OUT"
assert_contains "audit fix at the cap blocks" "→ blocked" "$OUT"
printf 'AUDIT_FIX\nGaps addressed: 1 of 2\n' > "$w/run/phases/audit-fix-1.report.md"
run bash "$RP" "$w/run" --audit-fix 1
assert_contains "audit fix below the cap still advances" "→ next: audit round 2" "$OUT"
rm -rf "$w"

# ---------------------------------------------------------------------------
echo
echo "[13] Report criteria count is cross-checked against the spec header"
w="$(mktemp -d)"; make_run "$w/run"
# done_report writes exactly 3 "- C<k> ...: pass" lines.
printf 'RELAY_PHASE_START\nPhase: 1 of 3 — Phase name 1\nAcceptance criteria: 3\n' > "$w/run/phases/phase-1.md"
done_report "$w/run/phases/phase-1.report.md" 1 3
run bash "$RP" "$w/run" 1
assert_rc "matching count exits 0" 0
printf 'RELAY_PHASE_START\nPhase: 2 of 3 — Phase name 2\nAcceptance criteria: 6\n' > "$w/run/phases/phase-2.md"
done_report "$w/run/phases/phase-2.report.md" 2 3
run bash "$RP" "$w/run" 2
assert_rc "under-reported criteria exits 3" 3
assert_contains "names both counts" "report lists 3 acceptance criteria, spec declares 6" "$OUT"
# A spec with no declared count (pre-0.9 specs, hand-authored run roots) stays permissive.
printf 'RELAY_PHASE_START\nPhase: 3 of 3 — Phase name 3\n' > "$w/run/phases/phase-3.md"
done_report "$w/run/phases/phase-3.report.md" 3 3
run bash "$RP" "$w/run" 3
assert_rc "spec without a declared count still records" 0
# An escalating phase never reached VERIFY — it must stay valid.
escalate_report "$w/run/phases/phase-1.report.md" 1
run bash "$RP" "$w/run" 1
assert_rc "escalate without VERIFY is still valid" 0
rm -rf "$w"

# ---------------------------------------------------------------------------
echo
echo "[14] Commit sha — looked up in git by relay-git.sh's trailers, never taken from the report"
RG="$REPO_ROOT/skills/goal/scripts/relay-git.sh"
w="$(mktemp -d)"; P="$w/proj"; RR="$P/.relay/add-dark-mode-Ab3Kx9"
git -C "$w" init -q -b main proj
gp() { git -C "$P" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false -c core.hooksPath=.git/no-hooks "$@"; }
echo ".relay/" >> "$P/.git/info/exclude"
printf 'x\n' > "$P/README.md"; gp add README.md; gp commit -qm init
make_run "$RR"
base="$(git -C "$P" rev-parse HEAD)"
sed -i.bak "s/^\*\*Baseline ref:\*\* abc1234/**Baseline ref:** $base/" "$RR/STATE.md" && rm -f "$RR/STATE.md.bak"
rgc() { (cd "$P" && GIT_CONFIG_COUNT=3 GIT_CONFIG_KEY_0=user.email GIT_CONFIG_VALUE_0=t@example.com \
  GIT_CONFIG_KEY_1=user.name GIT_CONFIG_VALUE_1=t GIT_CONFIG_KEY_2=core.hooksPath GIT_CONFIG_VALUE_2=.git/no-hooks \
  bash "$RG" commit "$@" >/dev/null 2>&1); }

printf 'a\n' > "$P/a.txt"; rgc "$RR" 1
sha1="$(git -C "$P" rev-parse --short HEAD)"
done_report "$RR/phases/phase-1.report.md" 1 3
run bash "$RP" "$RR" 1
assert_rc "records with a commit" 0
assert_contains "summary names the commit" "commit $sha1" "$OUT"
assert_contains "row notes carry the sha" "| Evidence: phases/phase-1.evidence.md; Commit: $sha1 |" "$(grep '^| 1 |' "$RR/STATE.md")"
assert_contains "event line carries the sha" "Phase 1 complete: 3/3 criteria pass, 4 files changed, commit $sha1" "$(cat "$RR/STATE.md")"
cp "$RR/STATE.md" "$w/before"
run bash "$RP" "$RR" 1
assert_eq "re-recording is idempotent" "" "$(diff "$w/before" "$RR/STATE.md")"

done_report "$RR/phases/phase-2.report.md" 2 3
run bash "$RP" "$RR" 2
assert_rc "missing commit is not an invalid report" 0
assert_contains "summary warns" "(no commit found)" "$OUT"
assert_contains "event says so" "no commit found" "$(grep 'Phase 2 complete' "$RR/STATE.md")"
assert_missing "row has no Commit: for phase 2" "Commit:" "$(grep '^| 2 |' "$RR/STATE.md")"

printf 'b\n' > "$P/b.txt"; rgc "$RR" 2 --fix
sha2="$(git -C "$P" rev-parse --short HEAD)"
done_report "$RR/phases/phase-2.fix.report.md" 2 3
run bash "$RP" "$RR" 2 --fix
assert_contains "fix window's commit is found" "commit $sha2" "$OUT"

# Phase 3's trailer on a commit from a different run must not match.
printf 'c\n' > "$P/c.txt"; gp add c.txt
gp commit -qm "relay: phase 3 — other" -m "Relay-Run: other-run-Zz9" -m "Relay-Phase: 3"
done_report "$RR/phases/phase-3.report.md" 3 3
run bash "$RP" "$RR" 3
assert_contains "another run's commit is not this run's" "(no commit found)" "$OUT"

printf 'd\n' > "$P/d.txt"; rgc "$RR" --audit-fix 1
sha3="$(git -C "$P" rev-parse --short HEAD)"
cp "$FX/sabotage-audit-fix.report.md" "$RR/phases/audit-fix-1.report.md"
run bash "$RP" "$RR" --audit-fix 1
assert_contains "audit fix commit in the summary" "commit $sha3" "$OUT"
assert_contains "audit fix commit in the event" "gaps addressed, commit $sha3" "$(cat "$RR/STATE.md")"
rm -rf "$w"

# ---------------------------------------------------------------------------
# The 0.10 checks: review after a phase, tidy-up, security pass.

# review_line <run> <N> <value> — add "Review: <value>" to phase N's spec header
review_line() { printf 'Review: %s\n' "$3" >> "$1/phases/phase-$2.md"; }
# check_fields <run> <cleanup|-> <security|-> — add the STATE.md fields ("-" leaves one out)
check_fields() {
  local r="$1" c="$2" s="$3"
  awk -v c="$c" -v s="$s" '{ print }
    index($0, "**Baseline ref:**") == 1 {
      if (c != "-") print "**Cleanup:** " c "    <!-- tidy-up -->"
      if (s != "-") print "**Security pass:** " s "    <!-- security -->"
    }' "$r/STATE.md" > "$r/STATE.tmp" && mv "$r/STATE.tmp" "$r/STATE.md"
}
cur() { get_cur "$1"; }
get_cur() { grep -m1 -F '**Current phase:**' "$1/STATE.md" | sed -E 's/^\*\*Current phase:\*\*[[:space:]]*//; s/[[:space:]]*<!--.*$//'; }

echo
echo "[15] Routing: Review yes → review; skip or missing → next phase; review clean → next phase"
w="$(mktemp -d)"; make_run "$w/run"
review_line "$w/run" 1 "yes"; review_line "$w/run" 2 "skip — docs only"
done_report "$w/run/phases/phase-1.report.md" 1 3
run bash "$RP" "$w/run" 1
assert_eq "phase 1 done → its review" "recorded: phase 1 done (3/3 pass) → next: review 1" "$OUT"
assert_eq "Current phase names the review" "review 1" "$(cur "$w/run")"
cp "$FX/review-clean.report.md" "$w/run/phases/phase-1.review.report.md"
run bash "$RP" "$w/run" 1 --review
assert_rc "review exits 0" 0
assert_eq "review clean → next phase" "recorded: phase 1 review clean → next: phase 2" "$OUT"
assert_eq "Current phase advanced" "2" "$(cur "$w/run")"
S="$(cat "$w/run/STATE.md")"
assert_contains "row notes the review" "| Evidence: phases/phase-1.evidence.md; Review: clean |" "$(grep '^| 1 |' "$w/run/STATE.md")"
assert_contains "review event" "- 2026-09-20 — Phase 1 review: clean" "$S"
cp "$w/run/STATE.md" "$w/before"
run bash "$RP" "$w/run" 1 --review
assert_eq "re-recording a review is idempotent" "" "$(diff "$w/before" "$w/run/STATE.md")"
done_report "$w/run/phases/phase-2.report.md" 2 3
run bash "$RP" "$w/run" 2
assert_contains "Review: skip — reason → next phase" "→ next: phase 3" "$OUT"
done_report "$w/run/phases/phase-3.report.md" 3 3
run bash "$RP" "$w/run" 3
assert_contains "no Review: line and no STATE fields → audit, as before 0.10" "→ next: audit" "$OUT"
rm -rf "$w"

echo
echo "[16] After the last phase: Cleanup on/off/missing × Security yes/skip/missing"
for c in "on" "off — --lean" "-"; do
  for s in "yes" "skip — docs only" "-"; do
    w="$(mktemp -d)"; make_run "$w/run" 1; check_fields "$w/run" "$c" "$s"
    done_report "$w/run/phases/phase-1.report.md" 1 1
    run bash "$RP" "$w/run" 1
    if [ "$c" = "on" ]; then want="cleanup"; elif [ "$s" = "yes" ]; then want="security"; else want="audit"; fi
    assert_contains "cleanup [$c] × security [$s] → $want" "→ next: $want" "$OUT"
    assert_eq "… and Current phase says $want" "$want" "$(cur "$w/run")"
    if [ "$c" = "on" ]; then
      cp "$FX/cleanup-done.report.md" "$w/run/phases/cleanup.report.md"
      run bash "$RP" "$w/run" --cleanup
      if [ "$s" = "yes" ]; then want2="security"; else want2="audit"; fi
      assert_contains "… cleanup done → $want2" "→ next: $want2" "$OUT"
    fi
    rm -rf "$w"
  done
done
w="$(mktemp -d)"; make_run "$w/run" 2; check_fields "$w/run" "on" "yes"; review_line "$w/run" 2 "yes"
done_report "$w/run/phases/phase-2.report.md" 2 2
run bash "$RP" "$w/run" 2
assert_contains "last phase with Review: yes → its review first" "→ next: review 2" "$OUT"
cp "$FX/review-clean.report.md" "$w/run/phases/phase-2.review.report.md"
run bash "$RP" "$w/run" 2 --review
assert_contains "… then the tidy-up" "→ next: cleanup" "$OUT"
rm -rf "$w"

echo
echo "[17] Findings → fix → advance; a fix window's DONE → the review; security findings → fix → audit"
w="$(mktemp -d)"; make_run "$w/run"; check_fields "$w/run" "on" "yes"
review_line "$w/run" 1 "yes"; review_line "$w/run" 2 "yes"
done_report "$w/run/phases/phase-1.report.md" 1 3
run bash "$RP" "$w/run" 1
cp "$FX/review-findings.report.md" "$w/run/phases/phase-1.review.report.md"
run bash "$RP" "$w/run" 1 --review
assert_eq "findings → the review fix" "recorded: phase 1 review findings (2) → next: review fix 1" "$OUT"
assert_eq "Current phase stays on the review" "review 1" "$(cur "$w/run")"
S="$(cat "$w/run/STATE.md")"
assert_contains "row notes the findings" "Review: 2 findings" "$(grep '^| 1 |' "$w/run/STATE.md")"
assert_contains "event names the deferral" "Phase 1 review: 2 findings, 1 deferred to FINDINGS.md — fix dispatched" "$S"
assert_missing "a review never blocks" "BLOCKED" "$(grep -F '**Status:**' "$w/run/STATE.md")"
cp "$FX/review-fix.report.md" "$w/run/phases/phase-1.review-fix.report.md"
run bash "$RP" "$w/run" 1 --review-fix
assert_rc "review fix exits 0" 0
assert_eq "review fix → next phase, unresolved counted" "recorded: phase 1 review fix (1 of 2 fixed, 1 unresolved → FINDINGS.md) → next: phase 2" "$OUT"
assert_contains "row notes the fix" "Review fix: 1 of 2 fixed" "$(grep '^| 1 |' "$w/run/STATE.md")"
assert_contains "event line" "Phase 1 review fix: 1 of 2 fixed, 1 unresolved → FINDINGS.md" "$(cat "$w/run/STATE.md")"
escalate_report "$w/run/phases/phase-2.report.md" 2
run bash "$RP" "$w/run" 2
done_report "$w/run/phases/phase-2.fix.report.md" 2 3
run bash "$RP" "$w/run" 2 --fix
assert_contains "a phase completed by its fix window is reviewed too" "→ next: review 2" "$OUT"
cp "$FX/security-findings.report.md" "$w/run/phases/security.report.md"
run bash "$RP" "$w/run" --security
assert_eq "security findings → security fix" "recorded: security pass findings (1) → next: security fix" "$OUT"
assert_eq "Current phase: security" "security" "$(cur "$w/run")"
assert_contains "one finding reads singular in the event" "Security pass: 1 finding — fix dispatched" "$(cat "$w/run/STATE.md")"
cp "$FX/security-fix.report.md" "$w/run/phases/security-fix.report.md"
run bash "$RP" "$w/run" --security-fix
assert_eq "security fix → audit" "recorded: security fix (1 of 1 fixed) → next: audit" "$OUT"
assert_eq "Current phase: audit" "audit" "$(cur "$w/run")"
cp "$FX/cleanup-restored.report.md" "$w/run/phases/cleanup.report.md"
run bash "$RP" "$w/run" --cleanup
assert_contains "a restored cleanup is recorded, not failed" "recorded: cleanup (restored — checks could not stay green — 0 fixed, 4 deferred) → next: security" "$OUT"
printf 'SECURITY_START\nFootprint: 2 files\nSurfaces: secrets\n\nSECURITY_CLEAN\nEvidence: x\n' > "$w/run/phases/security.report.md"
run bash "$RP" "$w/run" --security
assert_eq "security clean → audit" "recorded: security pass clean → next: audit" "$OUT"
rm -rf "$w"

echo
echo "[18] A check's second no-report skips the step instead of blocking"
w="$(mktemp -d)"; make_run "$w/run" 2; check_fields "$w/run" "on" "skip — no surfaces"; review_line "$w/run" 1 "yes"
done_report "$w/run/phases/phase-1.report.md" 1 2
run bash "$RP" "$w/run" 1
run bash "$RP" "$w/run" 1 --review --no-report "context exhausted"
assert_eq "first → re-dispatch" "recorded: phase 1 review dispatch 1 no report → next: re-dispatch" "$OUT"
assert_contains "the phase row stays completed" "| 1 | Phase name 1 | completed |" "$(cat "$w/run/STATE.md")"
run bash "$RP" "$w/run" 1 --review --no-report "tool error"
assert_eq "second → skipped, run continues" "recorded: phase 1 review dispatch 2 no report → skipped — next: phase 2" "$OUT"
assert_missing "not BLOCKED" "BLOCKED" "$(grep -F '**Status:**' "$w/run/STATE.md")"
assert_contains "FINDINGS.md records the skipped step" "- Phase 1 review: skipped — dispatch returned no report twice (tool error)" "$(cat "$w/run/FINDINGS.md")"
assert_contains "… under its own heading" "## Skipped steps" "$(cat "$w/run/FINDINGS.md")"
assert_contains "event says the run continues" "step skipped, run continues" "$(cat "$w/run/STATE.md")"
done_report "$w/run/phases/phase-2.report.md" 2 2
run bash "$RP" "$w/run" 2
run bash "$RP" "$w/run" --cleanup --no-report "x"
run bash "$RP" "$w/run" --cleanup --no-report "y"
assert_eq "a skipped cleanup goes on to the audit (security skipped)" "recorded: cleanup dispatch 2 no report → skipped — next: audit" "$OUT"
assert_eq "two skipped-step lines" "2" "$(grep -c '^- .*skipped — dispatch returned no report twice' "$w/run/FINDINGS.md")"
rm -rf "$w"

echo
echo "[19] Invalid check reports exit 3"
w="$(mktemp -d)"; make_run "$w/run"
{ cat "$FX/review-clean.report.md"; printf '\nREVIEW_FINDINGS\nFindings: 1 to fix\n'; } > "$w/run/phases/phase-1.review.report.md"
run bash "$RP" "$w/run" 1 --review
assert_rc "clean and findings together" 3
printf 'REVIEW_CLEAN\nPhase: 1\n' > "$w/run/phases/phase-1.review.report.md"
run bash "$RP" "$w/run" 1 --review
assert_rc "no REVIEW_START" 3
printf 'CLEANUP_START\nFootprint: 1 files\n' > "$w/run/phases/cleanup.report.md"
run bash "$RP" "$w/run" --cleanup
assert_rc "cleanup without CLEANUP_DONE" 3
printf 'nothing here\n' > "$w/run/phases/security-fix.report.md"
run bash "$RP" "$w/run" --security-fix
assert_rc "security fix without its block" 3
run bash "$RP" "$w/run" 1 --review-fix
assert_rc "missing review-fix report" 1
run bash "$RP" "$w/run" --cleanup extra
assert_rc "--cleanup takes no argument" 2
rm -rf "$w"

echo
echo "[20] AUDIT_COMPLETE: findings lines, the ⚠ line, and the --lean checks line"
audit_done() { cp "$FX/contextmeter-audit-1.report.md" "$1/phases/audit-1.report.md"; run bash "$RP" "$1" --audit 1; }
w="$(mktemp -d)"; make_run "$w/run"
audit_done "$w/run"
assert_eq "no FINDINGS.md, no --lean → the summary and coverage lines only" "recorded: audit round 1 clean → complete — next: relay-git.sh push, then RELAY_RUN_COMPLETE
Audit coverage: 107 re-verified, 0 trust-prior (100% re-verified)." "$OUT"
cat > "$w/run/FINDINGS.md" <<'F'
# Findings

## Review — phase 1
- [correctness] src/a.ts:4 — null read — unresolved: fix broke C2 — next: guard upstream

## Cleanup
- [cleanup] src/b.ts:9 — duplicate helper — deferred: public interface — next: merge in a follow-up
- [cleanup] src/c.ts:1 — dead export — deferred: named by S3 — next: ask the owner

## Skipped steps

- Security pass: skipped — dispatch returned no report twice (x)
F
audit_done "$w/run"
assert_contains "⚠ line counts open findings and skipped checks" "⚠ Unresolved: 1 correctness/security finding(s) open, 1 check(s) skipped — see $w/run/FINDINGS.md" "$OUT"
assert_contains "Findings line" "Findings: 2 cleanup deferred · 1 correctness/security open · 1 checks skipped — $w/run/FINDINGS.md" "$OUT"
assert_eq "summary line stays first" "recorded: audit round 1 clean → complete — next: relay-git.sh push, then RELAY_RUN_COMPLETE" "$(printf '%s\n' "$OUT" | head -1)"
printf '# Findings\n\n## Cleanup\n- [cleanup] x:1 — y — deferred: z — next: w\n' > "$w/run/FINDINGS.md"
audit_done "$w/run"
assert_missing "cleanup deferrals alone raise no ⚠" "⚠ Unresolved" "$OUT"
assert_contains "… but are counted" "Findings: 1 cleanup deferred · 0 correctness/security open · 0 checks skipped" "$OUT"
assert_missing "… with no plan-changes count when there are none" "plan changes" "$OUT"
cat > "$w/run/FINDINGS.md" <<'F'
# Findings

## Security
- [plan] src/out.py:41 — a --force replacement keeps the old file's mode — changed: plan said "the replacement gets the umask mode" — next: keep it, or revert 1a2b3c4
- [plan] src/out.py:60 — temp file created 0600 — changed: plan said "new files get the umask mode" — next: keep it, or revert 1a2b3c4
F
audit_done "$w/run"
assert_contains "[plan] bullets → the ⚠ Plan changed line" "⚠ Plan changed: 2 check fix(es) went against the plan summary — see $w/run/FINDINGS.md" "$OUT"
assert_missing "… a plan change is not unresolved" "⚠ Unresolved" "$OUT"
assert_contains "… and the Findings line counts them" "Findings: 0 cleanup deferred · 0 correctness/security open · 0 checks skipped · 2 plan changes — $w/run/FINDINGS.md" "$OUT"
printf '# Findings\n\n## Security\n- [security] a:1 — b — unresolved: c — next: d\n- [plan] e:2 — f — changed: plan said "g" — next: h\n' > "$w/run/FINDINGS.md"
audit_done "$w/run"
assert_eq "⚠ Unresolved comes first, then ⚠ Plan changed" "⚠ Unresolved: 1 correctness/security finding(s) open, 0 check(s) skipped — see $w/run/FINDINGS.md
⚠ Plan changed: 1 check fix(es) went against the plan summary — see $w/run/FINDINGS.md" "$(printf '%s\n' "$OUT" | grep '^⚠')"
rm -rf "$w"

w="$(mktemp -d)"; make_run "$w/run" 2; check_fields "$w/run" "off — --lean" "skip — --lean"
review_line "$w/run" 1 "skip — --lean"; review_line "$w/run" 2 "skip — --lean"
audit_done "$w/run"
assert_contains "all three --lean → the full list" "Checks: skipped (--lean) — phase reviews, tidy-up, security pass" "$OUT"
assert_missing "… not a ⚠" "⚠" "$OUT"
rm -rf "$w"
w="$(mktemp -d)"; make_run "$w/run" 2; check_fields "$w/run" "on" "skip — --lean"
review_line "$w/run" 1 "skip — --lean"; review_line "$w/run" 2 "yes"
audit_done "$w/run"
assert_contains "a check switched back on drops from the list" "Checks: skipped (--lean) — phase reviews (1 of 2), security pass" "$OUT"
rm -rf "$w"
w="$(mktemp -d)"; make_run "$w/run" 1; check_fields "$w/run" "off — no code changes" "skip — docs only"
review_line "$w/run" 1 "skip — docs only"
audit_done "$w/run"
assert_missing "skips for other reasons → no Checks line" "Checks:" "$OUT"
rm -rf "$w"

echo
echo "[21] Check commits are found in git by their own trailers"
w="$(mktemp -d)"; P="$w/proj"; RR="$P/.relay/add-dark-mode-Ab3Kx9"
git -C "$w" init -q -b main proj
echo ".relay/" >> "$P/.git/info/exclude"
printf 'x\n' > "$P/README.md"; gp add README.md; gp commit -qm init
make_run "$RR" 1; check_fields "$RR" "on" "yes"; review_line "$RR" 1 "yes"
base="$(git -C "$P" rev-parse HEAD)"
sed -i.bak "s/^\*\*Baseline ref:\*\* abc1234/**Baseline ref:** $base/" "$RR/STATE.md" && rm -f "$RR/STATE.md.bak"
printf 'a\n' > "$P/a.txt"; rgc "$RR" 1
done_report "$RR/phases/phase-1.report.md" 1 1
run bash "$RP" "$RR" 1
printf 'b\n' > "$P/b.txt"; rgc "$RR" 1 --review-fix
shr="$(git -C "$P" rev-parse --short HEAD)"
cp "$FX/review-fix.report.md" "$RR/phases/phase-1.review-fix.report.md"
run bash "$RP" "$RR" 1 --review-fix
assert_contains "review-fix commit found by Relay-Review-Fix" "commit $shr" "$OUT"
assert_contains "… and noted on the row" "Review-fix commit: $shr" "$(grep '^| 1 |' "$RR/STATE.md")"
cp "$FX/cleanup-done.report.md" "$RR/phases/cleanup.report.md"
run bash "$RP" "$RR" --cleanup
assert_contains "an applied cleanup with no commit warns" "(no commit found)" "$OUT"
printf 'c\n' > "$P/c.txt"; rgc "$RR" --cleanup
shc="$(git -C "$P" rev-parse --short HEAD)"
run bash "$RP" "$RR" --cleanup
assert_contains "cleanup commit found by Relay-Cleanup" "commit $shc" "$OUT"
printf 'd\n' > "$P/d.txt"; rgc "$RR" --security-fix
shs="$(git -C "$P" rev-parse --short HEAD)"
cp "$FX/security-fix.report.md" "$RR/phases/security-fix.report.md"
run bash "$RP" "$RR" --security-fix
assert_contains "security-fix commit found by Relay-Security-Fix" "commit $shs" "$OUT"
cp "$FX/cleanup-restored.report.md" "$RR/phases/cleanup.report.md"
git -C "$P" reset -q --hard "$base"
run bash "$RP" "$RR" --cleanup
assert_missing "a restored cleanup with no commit does not warn" "no commit found" "$OUT"
rm -rf "$w"

echo
echo "[22] AUDIT_COMPLETE: record-phase.sh computes the coverage line, not the orchestrator"
# cov_run <coverage line or ""> [extra AUDIT_COMPLETE lines] — records a clean audit whose
# "Audit coverage:" line is replaced (or dropped, for ""); sets OUT
cov_run() {
  local w; w="$(mktemp -d)"; make_run "$w/run"
  { sed '/^Audit coverage:/d' "$FX/contextmeter-audit-1.report.md"
    [ -n "$1" ] && printf '%s\n' "$1"; shift; for l in "$@"; do printf '%s\n' "$l"; done
  } > "$w/run/phases/audit-1.report.md"
  run bash "$RP" "$w/run" --audit 1
  rm -rf "$w"
}
cov_run "Audit coverage: 31 re-verified / 0 trust-prior (0%)"
assert_contains "the lean run's 31/0 reads 100%, whatever the audit wrote" "Audit coverage: 31 re-verified, 0 trust-prior (100% re-verified)." "$OUT"
assert_missing "… with no banner" "⚠" "$OUT"
cov_run "Audit coverage: 60 re-verified / 40 trust-prior (60%)"
assert_contains "40% trust-prior → the ⚠ banner" "⚠ Audit coverage: 60 re-verified, 40 trust-prior (60% re-verified). Eyeball UI/UX before merging." "$OUT"
assert_contains "… then the plain line" "Audit coverage: 60 re-verified, 40 trust-prior (60% re-verified)." "$(printf '%s\n' "$OUT" | tail -1)"
cov_run "Audit coverage: 70 re-verified / 30 trust-prior (70%)"
assert_missing "exactly 30% trust-prior → no banner" "⚠" "$OUT"
cov_run "Audit coverage: 2 re-verified / 1 trust-prior"
assert_contains "the percentage rounds down, never up to 100%" "(66% re-verified)" "$OUT"
cov_run "" "Spec criteria: 5 met / 0 not met / 2 trust-prior"
assert_contains "no coverage line → derived from criteria, deliverables and spec" "Audit coverage: 112 re-verified, 2 trust-prior (98% re-verified)." "$OUT"
cov_run "Audit coverage: 0 re-verified / 0 trust-prior"
assert_contains "nothing checked → says so, not a division by zero" "Audit coverage: 0 re-verified, 0 trust-prior (nothing checked)." "$OUT"
w="$(mktemp -d)"; make_run "$w/run"
printf 'AUDIT_START\nAUDIT_VERIFY\nAUDIT_COMPLETE\nRounds: 1\n' > "$w/run/phases/audit-1.report.md"
run bash "$RP" "$w/run" --audit 1
assert_contains "no counts at all → says so" "Audit coverage: not reported — AUDIT_COMPLETE carried no counts." "$OUT"
rm -rf "$w"
# the audit retakes the design screenshots (audit step 4b); its line reaches RELAY_RUN_COMPLETE
cov_run "Audit coverage: 31 re-verified / 0 trust-prior" "Design captures: retaken — 14 screens"
assert_contains "retaken → the compare line" "/run/design-check/<id>.png with design/screens/<id>.png" "$OUT"
assert_contains "… worded as retaken at the end" "Design captures: retaken at the end — compare " "$OUT"
assert_missing "… with no warning" "⚠" "$OUT"
assert_contains "… after the coverage line" "Design captures: retaken" "$(printf '%s\n' "$OUT" | tail -1)"
cov_run "Audit coverage: 31 re-verified / 0 trust-prior" "Design captures: not retaken — exit 1; run: RELAY_DESIGN_CHECK_DIR=/r/design-check npx playwright test e2e/capture.spec.ts"
assert_contains "not retaken → the ⚠ line with the reason and command" "⚠ Design captures: may be out of date — not retaken: exit 1; run: RELAY_DESIGN_CHECK_DIR=/r/design-check npx playwright test e2e/capture.spec.ts" "$OUT"
cov_run "Audit coverage: 31 re-verified / 0 trust-prior"
assert_missing "no Design captures field (no design, or a pre-change run) → no line" "Design captures" "$OUT"

echo
echo "[23] --interrupted: cut short from outside — logged, re-dispatched, never a strike"
w="$(mktemp -d)"; make_run "$w/run"
run bash "$RP" "$w/run" 2 --interrupted "usage limit"
assert_rc "exits 0" 0
assert_contains "asks for a re-dispatch" "recorded: phase 2 dispatch interrupted → next: re-dispatch" "$OUT"
assert_contains "failure-log line" "- Phase 2: dispatch interrupted (usage limit) — re-dispatched" "$(cat "$w/run/STATE.md")"
run bash "$RP" "$w/run" 2 --interrupted "usage limit"
assert_rc "recording it again is harmless" 0
assert_eq "… and adds no second line" "1" "$(count 'dispatch interrupted (usage limit) — re-dispatched' "$w/run/STATE.md")"
run bash "$RP" "$w/run" 2 --interrupted "session stopped"
run bash "$RP" "$w/run" 2 --no-report "empty"
assert_contains "interruptions are not strikes: the first no-report still re-dispatches" "dispatch 1 no report → next: re-dispatch" "$OUT"
run bash "$RP" "$w/run" --security --interrupted "overloaded"
assert_contains "a check: re-dispatch, not skipped" "recorded: security pass dispatch interrupted → next: re-dispatch" "$OUT"
run bash "$RP" "$w/run" --audit 3 --interrupted "overloaded"
assert_contains "the audit at its last round: re-dispatch, not blocked" "audit round 3 dispatch interrupted → next: re-dispatch" "$OUT"
assert_missing "… never BLOCKED" "**Status:** BLOCKED" "$(cat "$w/run/STATE.md")"
run bash "$RP" "$w/run" 2 --interrupted ""
assert_rc "an empty reason is a usage error" 2
printf 'report: phases/phase-3.report.md\n' > "$w/run/phases/in-flight"
bash "$RP" "$w/run" 3 --interrupted "x" >/dev/null
[ -f "$w/run/phases/in-flight" ] && no "recording its target clears in-flight" "still there" || ok "recording its target clears in-flight"
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
