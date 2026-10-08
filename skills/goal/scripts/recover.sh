#!/usr/bin/env bash
# recover.sh — after an interruption, settle the dispatch that was in flight and say what to do.
#
# Usage: recover.sh <run-root>
#
# Why: when the /goal session stops (a crash, a closed terminal, a restart) and is reopened with
# `claude --resume`, the goal comes back but the subagent it was waiting on does not — it died
# with the process, so its hand-back never arrives and the orchestrator would wait forever. The
# disk says what happened: assemble-brief.sh writes <run-root>/phases/in-flight for every
# dispatch (the target, its record-phase.sh arguments, and the Claude process that dispatched
# it), and record-phase.sh removes it when the target is recorded.
#
# Outcomes, each printed as instructions for the orchestrator:
#   - Nothing in flight: the stop came between recording one step and assembling the next.
#     Continue from the last `next:` record-phase.sh printed. Exit 0.
#   - The dispatching Claude process is still running (same pid and start time): the subagent
#     is working, or its hand-back is on its way. Keep waiting; never re-dispatch — a second
#     window on the same files is the one outcome worse than waiting. Exit 4.
#   - It cannot tell (no process was recorded): ask the user whether the session was
#     restarted. Exit 5.
#   - The process is gone and the window's report is complete on disk (it wrote its report,
#     then the session stopped before the orchestrator recorded it): prints the report's blocks
#     and the record-phase.sh command — echo, then record. Exit 0.
#   - The process is gone and there is no complete report: records the dispatch as
#     interrupted (record-phase.sh --interrupted, never a strike) and prints how to re-dispatch.
#     The new brief lists what the earlier window left (assemble-brief.sh). Exit 0.
#
# Exits 1 when the run root, STATE.md or a script it calls fails, 2 on a usage error.
# Changes STATE.md only through record-phase.sh. Copied into the run's <run-root>/ at Stage 7.

set -uo pipefail

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "usage: recover.sh <run-root>" >&2
  exit 2
fi
runroot="${1%/}"
[ -d "$runroot" ] || { echo "recover.sh: run root not found: $runroot" >&2; exit 1; }
[ -f "$runroot/STATE.md" ] || { echo "recover.sh: required file missing: $runroot/STATE.md" >&2; exit 1; }
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
inflight="$runroot/phases/in-flight"

if [ ! -f "$inflight" ]; then
  echo "recover: nothing was in flight — the session stopped between recording one step and assembling the next."
  echo "Continue the loop from the last \`next:\` that record-phase.sh printed in this conversation."
  exit 0
fi

field() { grep -m1 "^$1: " "$inflight" | sed "s/^$1: //"; }
mode="$(field mode)"; target="$(field target)"; args="$(field args)"
brief="$(field brief)"; report="$(field report)"; desc="$(field description)"
pid="$(field pid)"; started="$(field started)"
if [ -z "$mode" ] || [ -z "$args" ] || [ -z "$report" ]; then
  echo "recover.sh: $inflight is incomplete — ask the user how to continue" >&2
  exit 1
fi

# --- is the session that dispatched it still running? ---------------------------------------
if [ -z "$pid" ]; then
  echo "recover: $target was dispatched, but no Claude process was recorded for it, so I cannot tell whether its subagent is still running."
  echo "Ask the user whether this session was restarted since the dispatch. Restarted → run this again with RELAY_RECOVER_FORCE=1. Not restarted → keep waiting for the hand-back."
  [ "${RELAY_RECOVER_FORCE:-}" = "1" ] || exit 5
else
  now="$(ps -o lstart= -p "$pid" 2>/dev/null | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
  if [ -n "$now" ] && [ "$now" = "$started" ]; then
    if [ "${CLAUDE_PID:-}" = "$pid" ]; then
      echo "recover: $target is still in flight from this session (process $pid is running) — its subagent is working, or its hand-back is on its way."
    else
      echo "recover: $target was dispatched by another Claude session that is still running (process $pid) — this run is live elsewhere."
    fi
    echo "Keep waiting for the hand-back. Do not re-dispatch: a second window would edit the same files."
    exit 4
  fi
fi

# --- the dispatching process is gone ---------------------------------------------------------
case "$mode" in
  phase)        done_re='RELAY_PHASE_DONE|FAILURE_ESCALATE' ;;
  fix)          done_re='RELAY_PHASE_DONE|FAILURE_HANDOFF' ;;
  audit)        done_re='AUDIT_COMPLETE|AUDIT_GAPS|AUDIT_HANDOFF' ;;
  audit-fix)    done_re='AUDIT_FIX' ;;
  review)       done_re='REVIEW_CLEAN|REVIEW_FINDINGS' ;;
  review-fix)   done_re='REVIEW_FIX' ;;
  cleanup)      done_re='CLEANUP_DONE' ;;
  security)     done_re='SECURITY_CLEAN|SECURITY_FINDINGS' ;;
  security-fix) done_re='SECURITY_FIX' ;;
  *) echo "recover.sh: unknown mode in $inflight: $mode" >&2; exit 1 ;;
esac

# shellcheck disable=SC2086  # args is "N", "N --fix", "--audit R", … — word splitting intended
if [ -f "$runroot/$report" ] && grep -qE "^[[:space:]]*($done_re)([^A-Za-z0-9_]|\$)" "$runroot/$report"; then
  echo "recover: the $target window finished and wrote its report before the session stopped; it was never recorded."
  echo "Echo the blocks below verbatim (skip the echo only if your last message before the stop already shows them), then record:"
  echo "  bash $runroot/record-phase.sh $runroot $args"
  echo "and follow its \`next:\`."
  echo
  cat "$runroot/$report"
  exit 0
fi

out="$(bash "$here/record-phase.sh" "$runroot" $args --interrupted "the session stopped before the window reported")"; rc=$?
if [ "$rc" -ne 0 ]; then
  echo "recover.sh: record-phase.sh failed (exit $rc): $out" >&2
  exit 1
fi
echo "recover: the $target window was cut short when the session stopped. $out"
echo "Re-dispatch it:"
echo "  bash $runroot/assemble-brief.sh $runroot $args"
echo "then the Agent tool, as in PROTOCOL.md, with description \"$desc\" and the brief $runroot/$brief."
echo "The new brief lists what the cut-short window left; the new window keeps and reviews it."
exit 0
