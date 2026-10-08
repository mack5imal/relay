#!/usr/bin/env bash
# build-graph.sh — build or refresh this run's code graph with graphify, when it is installed.
#
# Why: map slices (map-slice.sh) read a tree-sitter code graph so a phase can see where the
# code it will touch lives. graphify builds that graph locally — no LLM, no network — in a
# few seconds. By default it writes graphify-out/ into the project (a directory some teams
# commit), so this script points GRAPHIFY_OUT at the run's own <run-root>/graph/ instead: a
# user's own graph is never touched. graphify's output goes to <run-root>/logs/graph-build.log
# and only one summary line is printed.
#
# Usage:
#   bash build-graph.sh <run-root>
#
#   Runs `graphify update . --no-cluster --force` from the repository top level (or the
#   current directory outside git). --no-cluster skips the only step that wants an LLM API
#   key; --force keeps the graph honest when a phase deletes code (graphify otherwise refuses
#   to shrink graph.json). Exits 0 whenever the argument is valid, even when graphify is
#   missing or the build fails — a missing graph degrades map slices, it never blocks a run.
#   Exits 2 on a usage error.
#
# Copied into the run's <run-root>/ at Stage 7, so the executor can refresh the graph at the
# start of each phase.

set -uo pipefail

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "usage: build-graph.sh <run-root>" >&2
  exit 2
fi

if ! command -v graphify >/dev/null 2>&1; then
  echo "graph: skipped - graphify not installed (map slices fall back to file-name matches)"
  exit 0
fi

if ! runroot="$(cd "$1" 2>/dev/null && pwd)"; then
  echo "graph: skipped - run root not found: $1"
  exit 0
fi

top="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
out="$runroot/graph"
log="$runroot/logs/graph-build.log"
mkdir -p "$runroot/logs"

( cd "$top" && GRAPHIFY_OUT="$out" GRAPHIFY_NO_TIPS=1 graphify update . --no-cluster --force ) \
  > "$log" 2>&1 < /dev/null
rc=$?

counts="$(grep -oE '[0-9]+ nodes, [0-9]+ edges' "$log" 2>/dev/null | tail -n 1)"
# A refresh with no code changes succeeds without printing counts ("No code-graph changes
# detected"); older graphify versions exit 1 with "Nothing to update". Both mean up to date.
if [ -f "$out/graph.json" ] && { [ "$rc" -eq 0 ] || grep -q 'Nothing to update' "$log" 2>/dev/null; }; then
  if [ -n "$counts" ]; then
    echo "graph: $out/graph.json ($counts)"
  else
    echo "graph: $out/graph.json (up to date)"
  fi
else
  echo "graph: build failed (exit $rc) - see $log"
fi
exit 0
