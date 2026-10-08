#!/usr/bin/env bash
# resume-line.test.sh — fixture tests for scripts/resume-line.sh
#
# Proves the blocked-run escape hatch: the emitted /goal line targets only the phases that
# remain, never re-runs recorded ones, switches to an audit-only condition when the run stopped
# at the audit, stays read-only, and refuses to pretend a COMPLETE run needs resuming.
#
# Repo-only (not shipped in the plugin payload). Run from anywhere:
#   bash tests/resume-line.test.sh
# Exits 0 if every assertion passes, 1 otherwise.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RL="$REPO_ROOT/skills/goal/scripts/resume-line.sh"
[ -f "$RL" ] || { echo "FATAL: missing $RL" >&2; exit 1; }

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

# make_run <dir> <status> <current> <total>
make_run() {
  local r="$1" i
  mkdir -p "$r/phases"
  for i in $(seq 1 "$4"); do printf 'RELAY_PHASE_START\n' > "$r/phases/phase-$i.md"; done
  {
    printf '# State: sample\n\n**Status:** %s\n**Current phase:** %s\n**Run root:** %s\n\n' "$2" "$3" "$r"
    printf '## Phase progress\n\n| # | Phase | Status | Started | Completed | Notes |\n|---|---|---|---|---|---|\n'
    for i in $(seq 1 "$4"); do printf '| %s | Phase %s | pending | — | — | — |\n' "$i" "$i"; done
  } > "$r/STATE.md"
}

echo "resume-line.test.sh — fixtures for $RL"
echo

# ---------------------------------------------------------------------------
echo "[1] Blocked mid-run — the condition covers only the remaining phases"
make_run "$W/a" BLOCKED 3 5
run bash "$RL" "$W/a"
assert_rc "exits 0" 0
assert_contains "resumes at the blocked phase" "from phase 3" "$OUT"
assert_contains "phase resume opens by keeping the orchestrator in this directory" "/goal \"Working from this directory (never cd elsewhere), resume the Relay run in" "$OUT"
assert_contains "says which are already done" "phases 1 to 2 are already recorded complete" "$OUT"
assert_contains "end-state scoped to what remains" "RELAY_PHASE_DONE for each of phases 3 through 5" "$OUT"
assert_contains "still forbids handoffs" "no FAILURE_HANDOFF or AUDIT_HANDOFF this run" "$OUT"
assert_contains "still requires the audit" "AUDIT_COMPLETE printed before RELAY_RUN_COMPLETE" "$OUT"
assert_contains "warns the cause must be fixed first" "Fix what blocked the run first" "$OUT"

echo
echo "[1b] Interrupted, not blocked (a stop mid-run) — and the done-phases wording"
make_run "$W/i" IN_PROGRESS 2 3
run bash "$RL" "$W/i"
assert_contains "one phase done reads as one" "phase 1 is already recorded complete in STATE.md, do not re-run it" "$OUT"
assert_missing "never 'phases 1 to 1'" "phases 1 to 1" "$OUT"
assert_missing "no 'fix what blocked' when nothing blocked it" "Fix what blocked the run first" "$OUT"
assert_contains "says it was interrupted" "The run was interrupted, not blocked" "$OUT"
make_run "$W/j" IN_PROGRESS 1 3
run bash "$RL" "$W/j"
assert_contains "nothing done yet reads as such" "no phase is recorded complete yet" "$OUT"
assert_missing "never 'phases 1 to 0'" "phases 1 to 0" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[2] It is read-only"
before="$(cat "$W/a/STATE.md")"
run bash "$RL" "$W/a"
assert_eq "STATE.md untouched" "$before" "$(cat "$W/a/STATE.md")"

# ---------------------------------------------------------------------------
echo
echo "[3] The last phase resumes as a single phase, not a range"
make_run "$W/b" BLOCKED 4 4
run bash "$RL" "$W/b"
assert_contains "names one phase" "RELAY_PHASE_DONE for each of phase 4" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[4] Blocked at the audit — an audit-only condition"
make_run "$W/c" BLOCKED audit 4
run bash "$RL" "$W/c"
assert_rc "exits 0" 0
assert_contains "resumes at the audit" "at the final audit" "$OUT"
assert_contains "audit resume opens by keeping the orchestrator in this directory" "/goal \"Working from this directory (never cd elsewhere), resume the Relay run in" "$OUT"
assert_missing "drops the per-phase dispatch clause" "for each remaining phase" "$OUT"
assert_missing "drops the per-phase end-state clause" "RELAY_PHASE_DONE for each" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[5] A completed run is not resumable"
make_run "$W/d" COMPLETE complete 3
run bash "$RL" "$W/d"
assert_rc "exits 0" 0
assert_contains "says so" "already COMPLETE" "$OUT"
assert_missing "emits no /goal line" "/goal" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[6] Usage and unreadable state"
run bash "$RL"
assert_rc "no args exits 2" 2
run bash "$RL" "$W/missing"
assert_rc "missing run root exits 1" 1
mkdir -p "$W/e"
run bash "$RL" "$W/e"
assert_rc "missing STATE.md exits 1" 1
make_run "$W/f" BLOCKED "" 3
run bash "$RL" "$W/f"
assert_rc "unreadable current phase exits 1" 1
assert_contains "names the problem" "cannot read 'Current phase'" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[7] A handed-off run's uncommitted work is flagged (git)"
assert_missing "no git → no warning" "uncommitted change" "$(bash "$RL" "$W/a" 2>&1)"
P="$W/proj"; git -C "$W" init -q -b main proj
echo ".relay/" >> "$P/.git/info/exclude"
printf 'x\n' > "$P/README.md"
git -C "$P" add README.md
git -C "$P" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false -c core.hooksPath=.git/no-hooks commit -qm init
make_run "$P/.relay/run-Ab3" BLOCKED 2 3
run bash "$RL" "$P/.relay/run-Ab3"
assert_missing "clean tree → no warning (the run root is not counted)" "uncommitted change" "$OUT"
printf 'y\n' >> "$P/README.md"; printf 'p\n' > "$P/partial.py"
run bash "$RL" "$P/.relay/run-Ab3"
assert_rc "dirty tree still exits 0" 0
assert_contains "warns with the count and the phase" "⚠ 2 uncommitted change(s) — the resumed phase 2 commits whatever is in the tree" "$OUT"
make_run "$P/.relay/run-Cd4" BLOCKED audit 3
run bash "$RL" "$P/.relay/run-Cd4"
assert_contains "audit-only resume names the audit fix" "the next audit-fix window commits" "$OUT"
before="$(git -C "$P" status --porcelain)"
run bash "$RL" "$P/.relay/run-Ab3"
assert_eq "still read-only (tree untouched)" "$before" "$(git -C "$P" status --porcelain)"

echo
echo "[8] Resuming off the run's branch is flagged (git)"
git -C "$P" checkout -q -- README.md; rm -f "$P/partial.py"
printf '**Branch:** relay/run-Ab3 (created by relay)\n' >> "$P/.relay/run-Ab3/STATE.md"
run bash "$RL" "$P/.relay/run-Ab3"
assert_contains "HEAD on main, run on relay/run-Ab3 → warns with the command" "⚠ HEAD is on main, but this run commits to relay/run-Ab3 — run \`! git switch relay/run-Ab3\`" "$OUT"
git -C "$P" switch -q -c relay/run-Ab3
run bash "$RL" "$P/.relay/run-Ab3"
assert_missing "on the run's branch → no warning" "HEAD is on" "$OUT"
git -C "$P" checkout -q --detach HEAD
run bash "$RL" "$P/.relay/run-Ab3"
assert_contains "detached HEAD → warns" "HEAD is on a detached HEAD" "$OUT"
run bash "$RL" "$P/.relay/run-Cd4"
assert_missing "no Branch field (hand-authored run roots) → no warning" "HEAD is on" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[9] The 0.10 checks: resume at a review, the tidy-up, or the security pass"
DONE_PHASES="Done when RELAY_RUN_COMPLETE appears in the transcript with one RELAY_PHASE_DONE for each of"
DONE_AUDIT="Done when RELAY_RUN_COMPLETE appears in the transcript, AUDIT_COMPLETE printed before it, and no FAILURE_HANDOFF or AUDIT_HANDOFF this run."
make_run "$W/r1" IN_PROGRESS "review 2" 4
run bash "$RL" "$W/r1"
assert_rc "review mid-run exits 0" 0
assert_contains "resumes at the review" "at the review of phase 2" "$OUT"
assert_contains "review resume opens by keeping the orchestrator in this directory" "/goal \"Working from this directory (never cd elsewhere), resume the Relay run in" "$OUT"
assert_contains "phase 2 counts as done" "phases 1 to 2 are already recorded complete" "$OUT"
assert_contains "runs the review first" "run phase 2's review step first" "$OUT"
assert_contains "remaining phases are 3 through 4" "$DONE_PHASES phases 3 through 4, AUDIT_COMPLETE printed before RELAY_RUN_COMPLETE, and no FAILURE_HANDOFF or AUDIT_HANDOFF this run." "$OUT"
assert_contains "names the checks" "Run the review, cleanup and security steps PROTOCOL.md names" "$OUT"
make_run "$W/r2" IN_PROGRESS "review 3" 4
run bash "$RL" "$W/r2"
assert_contains "review of the second-last phase leaves one phase" "$DONE_PHASES phase 4," "$OUT"
make_run "$W/r3" IN_PROGRESS "review 4" 4
run bash "$RL" "$W/r3"
assert_contains "review of the last phase: no phases left" "at the review of phase 4 — every phase is already recorded complete" "$OUT"
assert_contains "… with the audit-only end-state, unchanged" "$DONE_AUDIT" "$OUT"
assert_missing "… and no RELAY_PHASE_DONE clause" "RELAY_PHASE_DONE for each" "$OUT"
make_run "$W/r4" IN_PROGRESS cleanup 3
run bash "$RL" "$W/r4"
assert_contains "resumes at the tidy-up" "at the cleanup step" "$OUT"
assert_contains "step resume opens by keeping the orchestrator in this directory" "/goal \"Working from this directory (never cd elsewhere), resume the Relay run in" "$OUT"
assert_contains "… audit-only end-state" "$DONE_AUDIT" "$OUT"
make_run "$W/r5" IN_PROGRESS security 3
run bash "$RL" "$W/r5"
assert_contains "resumes at the security pass" "at the security step" "$OUT"
assert_contains "… audit-only end-state" "$DONE_AUDIT" "$OUT"
make_run "$W/r6" BLOCKED 2 3
run bash "$RL" "$W/r6"
assert_contains "a plain phase resume names the checks too" "Run the review, cleanup and security steps PROTOCOL.md names" "$OUT"
assert_contains "… and keeps its end-state" "$DONE_PHASES phases 2 through 3, AUDIT_COMPLETE printed before RELAY_RUN_COMPLETE, and no FAILURE_HANDOFF or AUDIT_HANDOFF this run." "$OUT"
make_run "$W/r7" IN_PROGRESS "review x" 3
run bash "$RL" "$W/r7"
assert_rc "a malformed review value is refused" 1

# ---------------------------------------------------------------------------
echo
echo "----------------------------------------"
printf 'Results: %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  exit 1
fi
echo "All fixture scenarios passed."
exit 0
