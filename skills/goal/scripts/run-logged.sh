#!/usr/bin/env bash
# run-logged.sh — run a command with its full output captured to a log file, printing
# only a compact summary.
#
# Why: command output enters the agent's context window the moment the command runs,
# no matter what the agent later chooses to print. A many-phase build that runs its test
# suite every phase burns tens of thousands of tokens on output nobody re-reads. Relay
# writes the full output to disk and lets only the exit code and a short tail through;
# the agent opens the log only when diagnosing a failure.
#
# Usage:
#   bash run-logged.sh <log-file> '<shell command>'
#
#   Runs the command with `bash -c` in the current directory, stdin closed. stdout and
#   stderr both go to <log-file> (overwritten; parent dirs created). Prints:
#
#     $ <command>
#     exit: <code>
#     log: <log-file> (<N> lines)
#     --- last <K> lines ---
#     <tail>
#
#   K is 3 when the command exits 0 and 20 otherwise; set RUN_LOGGED_TAIL=<n> to override.
#   Exits with the command's own exit code (2 on a usage error).
#
# Copied into the run's <run-root>/ at Stage 7, next to repo-state.sh.

set -uo pipefail

if [ "$#" -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
  echo "usage: run-logged.sh <log-file> '<shell command>'" >&2
  exit 2
fi

log="$1"
cmd="$2"

if ! mkdir -p "$(dirname "$log")" 2>/dev/null; then
  echo "run-logged.sh: cannot create log directory for $log" >&2
  exit 2
fi

bash -c "$cmd" > "$log" 2>&1 < /dev/null
rc=$?

lines="$(wc -l < "$log" | tr -d ' ')"

if [[ "${RUN_LOGGED_TAIL:-}" =~ ^[0-9]+$ ]]; then
  k="$RUN_LOGGED_TAIL"
elif [ "$rc" -eq 0 ]; then
  k=3
else
  k=20
fi

echo "\$ $cmd"
echo "exit: $rc"
echo "log: $log ($lines lines)"
echo "--- last $k lines ---"
tail -n "$k" "$log"

exit "$rc"
