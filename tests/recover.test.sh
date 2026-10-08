#!/usr/bin/env bash
# recover.test.sh — fixture tests for skills/goal/scripts/recover.sh and the in-flight file
#
# Proves what an orchestrator reopened after a stop (crash, closed terminal, restart) is told:
# nothing in flight → carry on; the dispatching Claude process still running → keep waiting,
# never a second window; no process recorded → ask; process gone + a complete report on disk →
# echo and record it; process gone + no report → recorded as interrupted (never a strike) and
# re-dispatched, with the new brief listing what the cut-short window left — including the
# kill between a phase's commit and its recording. Also that assemble-brief.sh writes the
# in-flight file and record-phase.sh clears it.
#
# Repo-only (not shipped in the plugin payload).
#   bash tests/recover.test.sh
# Exits 0 if every assertion passes, 1 otherwise.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$REPO_ROOT/skills/goal/scripts"
T="$REPO_ROOT/skills/goal/templates"
for f in "$S/recover.sh" "$S/record-phase.sh" "$S/assemble-brief.sh"; do
  [ -f "$f" ] || { echo "FATAL: missing $f" >&2; exit 1; }
done

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  \033[31m✗\033[0m %s\n      %s\n' "$1" "$2"; }
assert_rc()       { if [ "$2" = "$RC" ]; then ok "$1"; else no "$1" "expected exit $2 got $RC (out: $OUT)"; fi; }
assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "expected [$2] got [$3]"; fi; }
assert_contains() { case "$3" in *"$2"*) ok "$1";; *) no "$1" "missing substring [$2] in [$3]";; esac; }
assert_missing()  { case "$3" in *"$2"*) no "$1" "unexpectedly contains [$2]";; *) ok "$1";; esac; }

W="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$W"' EXIT
export RELAY_DATE=2026-10-07
# The tests run inside whatever launched them — possibly a Claude session. Never let that
# session's process stand in for the "dispatching" one.
unset CLAUDE_PID

run() { OUT="$("$@" 2>&1)"; RC=$?; }
lstart() { ps -o lstart= -p "$1" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g'; }

# make_run <dir> — a run root with the scripts and templates Stage 7 copies, 3 phase specs
make_run() {
  local r="$1" i
  mkdir -p "$r/phases"
  cp "$S/recover.sh" "$S/record-phase.sh" "$S/assemble-brief.sh" "$r/"
  cp "$T/PHASE-BRIEF.md" "$T/MARKERS.md" "$r/"
  cat > "$r/STATE.md" <<'EOF'
# State: Add a sort key

**Status:** IN_PROGRESS
**Current phase:** 2
**Started:** 2026-10-01
**Last update:** 2026-10-01
**Baseline ref:** none
**Memory dir:** /tmp/none

## Phase progress

| # | Phase | Status | Started | Completed | Notes |
|---|-------|--------|---------|-----------|-------|
| 1 | Phase name 1 | completed | 2026-10-01 | 2026-10-01 | — |
| 2 | Phase name 2 | pending | — | — | — |
| 3 | Phase name 3 | pending | — | — | — |

## Engineering check status

- Tests: —

## Notable events

- 2026-10-01 — Plan locked, 3 phases.

## Failure log

- (none)

## Carryover

- (none yet)
EOF
  for i in 1 2 3; do
    printf 'RELAY_PHASE_START\nPhase: %s of 3 — Phase name %s\nMap seeds: none\n' "$i" "$i" > "$r/phases/phase-$i.md"
  done
}

# inflight <run-root> <mode> <args> <report> <pid> <started> — write the file as assemble-brief.sh would
inflight() {
  printf 'mode: %s\ntarget: %s\nargs: %s\nbrief: phases/x.brief.md\nreport: %s\ndescription: Relay %s\npid: %s\nstarted: %s\n' \
    "$2" "$2 $3" "$3" "$4" "$2" "$5" "$6" > "$1/phases/in-flight"
}

done_report() {
  printf 'RELAY_PHASE_START\nPhase: 2 of 3 — Phase name 2\n\nRELAY_PHASE_VERIFY\nAcceptance (evidence: x):\n- C1 a: pass\nEngineering: tests pass\nCleanliness: debug prints 0\nFiles changed: 1\n\nMEMORY_SAVED: none\n\nRELAY_PHASE_DONE\nPhase 2 complete.\nEvidence: x\n' > "$1"
}

DEAD=99999999          # no such process
OLD="Mon Jan  1 00:00:00 2001"

# ---------------------------------------------------------------------------
echo "[1] Nothing in flight"
R="$W/a/run"; make_run "$R"
run bash "$R/recover.sh" "$R"
assert_rc "exits 0" 0
assert_contains "says nothing was in flight" "nothing was in flight" "$OUT"
assert_contains "points at the last next:" "last \`next:\`" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[2] The dispatching process is still running → keep waiting, never re-dispatch"
R="$W/b/run"; make_run "$R"; before="$(cat "$R/STATE.md")"
inflight "$R" phase 2 phases/phase-2.report.md "$$" "$(lstart $$)"
run bash "$R/recover.sh" "$R"
assert_rc "exits 4" 4
assert_contains "says keep waiting" "Keep waiting for the hand-back. Do not re-dispatch" "$OUT"
assert_contains "another session, when it is not this one" "dispatched by another Claude session that is still running" "$OUT"
OUT="$(CLAUDE_PID=$$ bash "$R/recover.sh" "$R" 2>&1)"
assert_contains "this session, when CLAUDE_PID matches" "still in flight from this session" "$OUT"
assert_eq "STATE.md untouched" "$before" "$(cat "$R/STATE.md")"
[ -f "$R/phases/in-flight" ] && ok "in-flight kept" || no "in-flight kept" "removed"
done_report "$R/phases/phase-2.report.md"
run bash "$R/recover.sh" "$R"
assert_rc "a report on disk changes nothing while the process lives" 4

echo
echo "[3] A reused pid (same number, different start time) counts as gone"
R="$W/c/run"; make_run "$R"
inflight "$R" phase 2 phases/phase-2.report.md "$$" "$OLD"
run bash "$R/recover.sh" "$R"
assert_rc "exits 0" 0
assert_contains "recorded as interrupted" "dispatch interrupted → next: re-dispatch" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[4] No process recorded → ask the user"
R="$W/d/run"; make_run "$R"; before="$(cat "$R/STATE.md")"
inflight "$R" phase 2 phases/phase-2.report.md "" ""
run bash "$R/recover.sh" "$R"
assert_rc "exits 5" 5
assert_contains "asks whether the session was restarted" "Ask the user whether this session was restarted" "$OUT"
assert_eq "STATE.md untouched" "$before" "$(cat "$R/STATE.md")"
OUT="$(RELAY_RECOVER_FORCE=1 bash "$R/recover.sh" "$R" 2>&1)"; RC=$?
assert_rc "the user said restarted → proceeds" 0
assert_contains "… and re-dispatches" "Re-dispatch it:" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[5] Process gone, no report → interrupted (never a strike), re-dispatch"
R="$W/e/run"; make_run "$R"
inflight "$R" phase 2 phases/phase-2.report.md "$DEAD" "$OLD"
run bash "$R/recover.sh" "$R"
assert_rc "exits 0" 0
assert_contains "names the target" "the phase 2 window was cut short" "$OUT"
assert_contains "the assemble command" "assemble-brief.sh $R 2" "$OUT"
assert_contains "the description" 'description "Relay phase"' "$OUT"
[ -f "$R/phases/in-flight" ] && no "in-flight removed" "still there" || ok "in-flight removed"
ST="$(cat "$R/STATE.md")"
assert_contains "failure-log line" "- Phase 2: dispatch interrupted (the session stopped before the window reported) — re-dispatched" "$ST"
assert_contains "row in progress" "| 2 | Phase name 2 | in_progress |" "$ST"
assert_contains "event line" "Phase 2: dispatch interrupted (the session stopped before the window reported) — re-dispatching" "$ST"
assert_contains "still IN_PROGRESS" "**Status:** IN_PROGRESS" "$ST"
# two interruptions and then one no-report must not block: interruptions are not strikes
inflight "$R" phase 2 phases/phase-2.report.md "$DEAD" "$OLD"
bash "$R/record-phase.sh" "$R" 2 --interrupted "usage limit" >/dev/null
run bash "$R/record-phase.sh" "$R" 2 --no-report "window ran out of context"
assert_contains "first no-report after interruptions still re-dispatches" "dispatch 1 no report → next: re-dispatch" "$OUT"
run bash "$R/record-phase.sh" "$R" 2 --interrupted x --no-report y
assert_rc "--interrupted and --no-report together is a usage error" 2

echo
echo "[6] A truncated report (no terminal block) counts as no report"
R="$W/f/run"; make_run "$R"
inflight "$R" phase 2 phases/phase-2.report.md "$DEAD" "$OLD"
printf 'RELAY_PHASE_START\nPhase: 2 of 3 — Phase name 2\n\nRELAY_PHASE_VERIFY\n' > "$R/phases/phase-2.report.md"
run bash "$R/recover.sh" "$R"
assert_contains "re-dispatches" "Re-dispatch it:" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[7] Process gone, complete report on disk → echo it, then record"
R="$W/g/run"; make_run "$R"; before="$(cat "$R/STATE.md")"
inflight "$R" phase 2 phases/phase-2.report.md "$DEAD" "$OLD"
done_report "$R/phases/phase-2.report.md"
run bash "$R/recover.sh" "$R"
assert_rc "exits 0" 0
assert_contains "says it finished but was never recorded" "wrote its report before the session stopped; it was never recorded" "$OUT"
assert_contains "the record command" "bash $R/record-phase.sh $R 2" "$OUT"
assert_contains "prints the blocks to echo" "RELAY_PHASE_DONE" "$OUT"
assert_eq "STATE.md untouched until the orchestrator records" "$before" "$(cat "$R/STATE.md")"
run bash "$R/record-phase.sh" "$R" 2
assert_rc "recording it works" 0
[ -f "$R/phases/in-flight" ] && no "recording clears in-flight" "still there" || ok "recording clears in-flight"

echo
echo "[8] Recording a different target leaves the in-flight file alone"
R="$W/h/run"; make_run "$R"
inflight "$R" phase 3 phases/phase-3.report.md "$DEAD" "$OLD"
done_report "$R/phases/phase-2.report.md"
bash "$R/record-phase.sh" "$R" 2 >/dev/null
[ -f "$R/phases/in-flight" ] && ok "kept" || no "kept" "removed"

# ---------------------------------------------------------------------------
echo
echo "[9] Every dispatch kind maps to its record arguments and terminal blocks"
for spec in "fix|2 --fix|phases/phase-2.fix.report.md|Phase 2 fix" \
            "review|2 --review|phases/phase-2.review.report.md|Phase 2 review" \
            "review-fix|2 --review-fix|phases/phase-2.review-fix.report.md|Phase 2 review fix" \
            "cleanup|--cleanup|phases/cleanup.report.md|Cleanup" \
            "security|--security|phases/security.report.md|Security pass" \
            "security-fix|--security-fix|phases/security-fix.report.md|Security fix" \
            "audit|--audit 2|phases/audit-2.report.md|Audit round 2" \
            "audit-fix|--audit-fix 1|phases/audit-fix-1.report.md|Audit fix 1"; do
  IFS='|' read -r m a rp lab <<< "$spec"
  R="$W/m-$m/run"; make_run "$R"
  inflight "$R" "$m" "$a" "$rp" "$DEAD" "$OLD"
  run bash "$R/recover.sh" "$R"
  assert_contains "$m: interrupted under its own label" "- $lab: dispatch interrupted" "$(cat "$R/STATE.md")"
done
R="$W/m-audit2/run"; make_run "$R"
inflight "$R" audit "--audit 2" phases/audit-2.report.md "$DEAD" "$OLD"
printf 'AUDIT_START\nAUDIT_VERIFY\nAUDIT_GAPS\nGaps:\n- x\n' > "$R/phases/audit-2.report.md"
run bash "$R/recover.sh" "$R"
assert_contains "audit: AUDIT_GAPS counts as a complete report" "bash $R/record-phase.sh $R --audit 2" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[10] assemble-brief.sh writes the in-flight file"
R="$W/i/run"; make_run "$R"
(cd "$W/i" && CLAUDE_PID=$$ bash "$R/assemble-brief.sh" "$R" 2 >/dev/null)
F="$(cat "$R/phases/in-flight" 2>/dev/null)"
assert_contains "mode" "mode: phase" "$F"
assert_contains "target" "target: phase 2" "$F"
assert_contains "args" "args: 2" "$F"
assert_contains "brief" "brief: phases/phase-2.brief.md" "$F"
assert_contains "report" "report: phases/phase-2.report.md" "$F"
assert_contains "description" "description: Relay phase 2" "$F"
assert_contains "pid from CLAUDE_PID" "pid: $$" "$F"
assert_contains "its start time" "started: $(lstart $$)" "$F"
(cd "$W/i" && bash "$R/assemble-brief.sh" "$R" --audit-fix 1 >/dev/null 2>&1) || true
printf 'fix it\n' > "$R/phases/audit-fix-1.md"
(cd "$W/i" && bash "$R/assemble-brief.sh" "$R" --audit-fix 1 >/dev/null)
F="$(cat "$R/phases/in-flight")"
assert_contains "audit fix: args" "args: --audit-fix 1" "$F"
assert_contains "audit fix: description" "description: Relay audit fix 1" "$F"
assert_eq "no leftover section without an earlier failed dispatch" "0" "$(grep -c '^### Left by an earlier window' "$R/phases/phase-2.brief.md")"

# ---------------------------------------------------------------------------
echo
echo "[11] Killed between a phase's commit and its recording (git)"
P="$W/proj"; git init -q -b main "$P"
git -C "$P" config user.email t@example.com; git -C "$P" config user.name t; git -C "$P" config commit.gpgsign false
printf '/.relay/\n' >> "$P/.git/info/exclude"
printf 'x\n' > "$P/README.md"; git -C "$P" add README.md; git -C "$P" commit -qm init
R="$P/.relay/sort-key-Ab3"; make_run "$R"
printf 'phase two\n' > "$P/two.txt"; git -C "$P" add two.txt
git -C "$P" commit -qm "relay: phase 2 — Phase name 2" -m "Relay-Run: sort-key-Ab3
Relay-Phase: 2"
printf 'half-done\n' > "$P/three.txt"
inflight "$R" phase 2 phases/phase-2.report.md "$DEAD" "$OLD"
run bash "$R/recover.sh" "$R"
assert_contains "no report → re-dispatch, though the commit exists" "Re-dispatch it:" "$OUT"
(cd "$P" && bash "$R/assemble-brief.sh" "$R" 2 >/dev/null)
B="$(cat "$R/phases/phase-2.brief.md")"
assert_eq "the new brief has the leftover section" "1" "$(grep -c '^### Left by an earlier window' "$R/phases/phase-2.brief.md")"
assert_contains "it names the committed work" "relay: phase 2 — Phase name 2" "$B"
assert_contains "and the uncommitted file" "?? three.txt" "$B"
assert_missing "never the run root" ".relay/" "$(printf '%s\n' "$B" | sed -n '/### Left by an earlier window/,/^## /p' | grep '^    ')"
(cd "$P" && bash "$R/assemble-brief.sh" "$R" 3 >/dev/null)
assert_eq "another phase's brief has no leftover section" "0" "$(grep -c '^### Left by an earlier window' "$R/phases/phase-3.brief.md")"

# ---------------------------------------------------------------------------
echo
echo "[12] Usage and edge cases"
run bash "$S/recover.sh"
assert_rc "no args exits 2" 2
run bash "$S/recover.sh" "$W/none"
assert_rc "missing run root exits 1" 1
R="$W/j/run"; make_run "$R"; printf 'mode: phase\n' > "$R/phases/in-flight"
run bash "$R/recover.sh" "$R"
assert_rc "an incomplete in-flight file exits 1" 1
if command -v zsh >/dev/null 2>&1; then
  R="$W/k/run"; make_run "$R"
  inflight "$R" phase 2 phases/phase-2.report.md "$DEAD" "$OLD"
  OUT="$(zsh -c "bash '$R/recover.sh' '$R'" 2>&1)"; RC=$?
  assert_rc "called from zsh" 0
  assert_contains "… re-dispatches with the args split" "assemble-brief.sh $R 2" "$OUT"
else
  echo "  (zsh not installed — skipped)"
fi

# ---------------------------------------------------------------------------
echo
echo "----------------------------------------"
printf 'Results: %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  exit 1
fi
echo "All fixture scenarios passed."
exit 0
