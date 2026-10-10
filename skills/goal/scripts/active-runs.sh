#!/usr/bin/env bash
# active-runs.sh — list the Relay runs in this working tree that are not COMPLETE (Stage 0).
#
# Usage: active-runs.sh [<relay-base>]     (default: $RELAY_BASE, else .relay)
#
# Why a script (fix 23): the scan used to be an inline loop in SKILL.md, and the Bash tool runs
# the user's shell. Under zsh an unmatched glob is an error, so on an empty .relay/ the loop
# exited 1 with "no matches found: .relay/*/STATE.md" before listing anything. bash leaves an
# unmatched pattern as literal text, which the -f test skips.
#
# Scans per-run dirs AND the legacy flat layout (.relay/STATE.md from pre-0.7 runs). A run is
# active unless its STATE.md Status is COMPLETE; the unfilled template's
# "PLANNING → IN_PROGRESS → COMPLETE" arrow line is not a terminal COMPLETE, so it reads active.
#
# Prints `Active runs in this tree:` then one run dir per line, or `  (none)`. Always exits 0
# (a missing base simply has no runs). Read-only. Planner-only (not copied at Stage 7).

set -u

base="${1:-${RELAY_BASE:-.relay}}"
base="${base%/}"
active=""
for s in "$base"/*/STATE.md "$base"/STATE.md; do
  [[ -f "$s" ]] || continue
  grep -Eqi 'status:\**[[:space:]]*complete[[:space:]]*$' "$s" && continue
  active="${active}  $(dirname "$s")"$'\n'
done
printf 'Active runs in this tree:\n%s' "${active:-  (none)$'\n'}"
exit 0
