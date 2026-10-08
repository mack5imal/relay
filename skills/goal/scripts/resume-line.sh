#!/usr/bin/env bash
# resume-line.sh — print the ready-to-paste /goal line that resumes a stopped run
#
# Usage: resume-line.sh <run-root>
#
# Why: FAILURE_HANDOFF and AUDIT_HANDOFF make this run's /goal end-state permanently
# unsatisfiable — the condition forbids them and a printed block cannot be retracted — so a
# blocked run cannot be continued in its own session. Everything needed to continue it in a
# FRESH session already exists: record-phase.sh is idempotent, STATE.md records which phases
# completed, and PROTOCOL.md's loop starts from `Current phase`. The only missing piece was an
# end-state condition scoped to the phases that remain. That is what this prints.
#
# This is a read-only helper: it never edits STATE.md. The run's `Status: BLOCKED` clears on
# the first phase the resumed session records.
#
# Exits 0 and prints the block, 1 when STATE.md is missing or unreadable, 2 on a usage error.
# Prints nothing but a note when the run is already COMPLETE.
#
# Copied into the run's <run-root>/ at Stage 7, next to record-phase.sh.

set -uo pipefail

if [[ $# -lt 1 || -z "${1:-}" ]]; then
  echo "usage: resume-line.sh <run-root>" >&2
  exit 2
fi

runroot="${1%/}"
state="$runroot/STATE.md"
[[ -d "$runroot" ]] || { echo "resume-line.sh: run root not found: $runroot" >&2; exit 1; }
[[ -f "$state"   ]] || { echo "resume-line.sh: required file missing: $state" >&2; exit 1; }

field() {
  grep -m1 -F "**$1:**" "$state" 2>/dev/null \
    | sed -E "s/^\*\*$1:\*\*[[:space:]]*//; s/[[:space:]]*<!--.*$//; s/[[:space:]]+$//"
}

status="$(field Status)"
current="$(field 'Current phase')"

# Total phases: the phase specs on disk, falling back to the numbered rows in STATE.md.
total=0
for f in "$runroot/phases"/phase-*.md; do
  [[ -e "$f" ]] || continue
  [[ "$(basename "$f")" =~ ^phase-[0-9]+\.md$ ]] && total=$((total + 1))
done
if [[ "$total" -eq 0 ]]; then
  total="$(awk -F'|' '/^## Phase progress/{f=1; next} /^## /{f=0} f && $2 ~ /^ *[0-9]+ *$/ {c++} END{print c+0}' "$state")"
fi

if [[ "$status" == "COMPLETE" ]]; then
  echo "resume-line.sh: run is already COMPLETE — nothing to resume."
  exit 0
fi

# Which phases still have to run. A phase that escalated or was left in_progress is re-run
# from the top: its fix window failed, so its work is not trusted. The 0.10 checks resume at
# their own step: "review N" (phase N done, its review not yet recorded), "cleanup", "security".
audit_only=0; step=""; review_n=""
case "$current" in
  audit|complete) audit_only=1 ;;
  cleanup)        audit_only=1; step="the cleanup step" ;;
  security)       audit_only=1; step="the security step" ;;
  "review "*)
    review_n="${current#review }"
    if [[ ! "$review_n" =~ ^[0-9]+$ ]]; then
      echo "resume-line.sh: cannot read 'Current phase' from $state (got '$current')" >&2
      exit 1
    fi
    if [[ "$review_n" -ge "$total" ]]; then audit_only=1; fi
    step="the review of phase $review_n" ;;
  ''|*[!0-9]*)
    echo "resume-line.sh: cannot read 'Current phase' from $state (got '${current:-<empty>}')" >&2
    exit 1 ;;
esac

# done_clause <n> — what is already recorded complete, in words that read right for 0, 1 or more
done_clause() {
  case "$1" in
    0) printf 'no phase is recorded complete yet' ;;
    1) printf 'phase 1 is already recorded complete in STATE.md, do not re-run it' ;;
    *) printf 'phases 1 to %s are already recorded complete in STATE.md, do not re-run them' "$1" ;;
  esac
}

checks_clause="Run the review, cleanup and security steps PROTOCOL.md names whenever record-phase.sh routes to them, echoing their blocks verbatim."
audit_clause="run the FINAL AUDIT in $runroot/PROTOCOL.md (re-verify against $runroot/ROADMAP.md and, if present, $runroot/SPEC.md; re-run aggregated mandatory commands; spot-check criteria; on gaps, write $runroot/phases/audit-fix-<round>.md and dispatch it to a fresh subagent). Only after AUDIT_COMPLETE, print RELAY_RUN_COMPLETE."

if [[ "$audit_only" -eq 1 && -n "$step" ]]; then
  line="$(printf '/goal "Working from this directory (never cd elsewhere), resume the Relay run in %s at %s — every phase is already recorded complete in STATE.md, do not re-run them. Following %s/PROTOCOL.md: run that step and the checks after it that record-phase.sh routes to, echoing their blocks verbatim; then %s Done when RELAY_RUN_COMPLETE appears in the transcript, AUDIT_COMPLETE printed before it, and no FAILURE_HANDOFF or AUDIT_HANDOFF this run."' \
    "$runroot" "$step" "$runroot" "$audit_clause")"
elif [[ "$audit_only" -eq 1 ]]; then
  line="$(printf '/goal "Working from this directory (never cd elsewhere), resume the Relay run in %s at the final audit, following %s/PROTOCOL.md: %s Done when RELAY_RUN_COMPLETE appears in the transcript, AUDIT_COMPLETE printed before it, and no FAILURE_HANDOFF or AUDIT_HANDOFF this run."' \
    "$runroot" "$runroot" "$audit_clause")"
elif [[ -n "$review_n" ]]; then
  first=$((review_n + 1))
  if [[ "$first" -ge "$total" ]]; then remaining="phase $total"; else remaining="phases $first through $total"; fi
  line="$(printf '/goal "Working from this directory (never cd elsewhere), resume the Relay run in %s at the review of phase %s — %s. Following %s/PROTOCOL.md: run phase %s'"'"'s review step first; then for each remaining phase, assemble its brief and dispatch it to a subagent, then echo the subagent'"'"'s marker blocks (RELAY_PHASE_VERIFY then RELAY_PHASE_DONE) verbatim into this transcript; follow PROTOCOL.md'"'"'s failure-recovery protocol if any criterion fails. %s After the last phase and its checks, %s Done when RELAY_RUN_COMPLETE appears in the transcript with one RELAY_PHASE_DONE for each of %s, AUDIT_COMPLETE printed before RELAY_RUN_COMPLETE, and no FAILURE_HANDOFF or AUDIT_HANDOFF this run."' \
    "$runroot" "$review_n" "$(done_clause "$review_n")" "$runroot" "$review_n" "$checks_clause" "$audit_clause" "$remaining")"
else
  if [[ "$current" -ge "$total" ]]; then remaining="phase $total"; else remaining="phases $current through $total"; fi
  line="$(printf '/goal "Working from this directory (never cd elsewhere), resume the Relay run in %s from phase %s — %s. Following %s/PROTOCOL.md: for each remaining phase, assemble its brief and dispatch it to a subagent, then echo the subagent'"'"'s marker blocks (RELAY_PHASE_VERIFY then RELAY_PHASE_DONE) verbatim into this transcript; follow PROTOCOL.md'"'"'s failure-recovery protocol if any criterion fails. %s After the last phase and its checks, %s Done when RELAY_RUN_COMPLETE appears in the transcript with one RELAY_PHASE_DONE for each of %s, AUDIT_COMPLETE printed before RELAY_RUN_COMPLETE, and no FAILURE_HANDOFF or AUDIT_HANDOFF this run."' \
    "$runroot" "$current" "$(done_clause "$((current - 1))")" "$runroot" "$checks_clause" "$audit_clause" "$remaining")"
fi

echo "Resume this run by pasting the line below into a new Claude Code session"
echo "started in the same working directory:"
echo
echo '```'
printf '%s\n' "$line"
echo '```'
echo
if [[ "$status" == "BLOCKED" ]]; then
  echo "Fix what blocked the run first — resuming without changing anything will fail the same way."
else
  echo "The run was interrupted, not blocked: nothing needs fixing first. The window that was cut short is re-run, and keeps and reviews what it left."
fi

# The blocked phase's partial work is left uncommitted for the owner. Whatever is still in the
# tree when the resumed run commits (relay-git.sh commit stages everything) lands in that commit.
# And the run's commits belong on its recorded branch: after a handoff the owner may have checked
# out another one to look around, and relay-git.sh commit refuses to commit anywhere else.
if git -C "$runroot" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  want="$(field Branch)"; want="${want%% *}"
  case "$want" in ""|"—"|"-"|no-git|"{{BRANCH}}") want="" ;; esac
  here="$(git -C "$runroot" symbolic-ref -q --short HEAD 2>/dev/null || true)"
  if [[ -n "$want" && "$here" != "$want" ]]; then
    echo
    echo "⚠ HEAD is on ${here:-a detached HEAD}, but this run commits to $want — run \`! git switch $want\` before pasting, or every phase that passes will fail to commit."
  fi
  dirty="$(git -C "$runroot" status --porcelain 2>/dev/null | grep -c . || true)"
  if [[ "$dirty" -gt 0 ]]; then
    if [[ -n "$step" ]]; then who="$step commits"; whose="that step's"
    elif [[ "$audit_only" -eq 1 ]]; then who="the next audit-fix window commits"; whose="the audit fix's"
    else who="the resumed phase $current commits"; whose="phase $current's"; fi
    echo
    echo "⚠ $dirty uncommitted change(s) — $who whatever is in the tree when it passes; commit or discard anything that isn't $whose work first."
  fi
fi

# /goal's argument limit is 4000 characters (references/goal-format.md). A deeply nested run
# root can push a resume line past it, and a truncated condition is worse than no line at all.
n=${#line}
if [[ "$n" -gt 4000 ]]; then
  echo >&2
  echo "resume-line.sh: WARNING — that line is $n characters, over /goal's 4000-character limit." >&2
  echo "Shorten it by running from the directory holding $runroot so the paths are relative." >&2
fi
exit 0
