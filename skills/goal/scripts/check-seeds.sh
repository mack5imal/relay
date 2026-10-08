#!/usr/bin/env bash
# check-seeds.sh — check every phase's `Map seeds:` against what will exist when the phase runs
#
# Usage: check-seeds.sh <run-root>
#
# Why this exists: a phase's map slice is built at dispatch, from a graph `assemble-brief.sh`
# refreshes before every phase — so a seed only has to exist when its phase runs, not when the
# plan is written. Judged from plan time instead, a greenfield plan has nothing to seed and turns
# the map off for the whole run (all 14 tunez phases said `Map seeds: none`). A seed resolves when
#
#   graph  — it is in the plan-time graph (<run-root>/graph/graph.json): it exists today
#   future — an earlier phase's spec names it verbatim (whole word, case-sensitive), outside that
#            phase's own `Map seeds:` line: an earlier phase creates it
#
# Anything else is a typo or a symbol the phase creates itself (seed its neighbors instead).
# Greenfield phase 1 therefore can only say `Map seeds: none`.
#
# Degrades rather than fails: when the graph exists but cannot be queried (no Python), an
# unresolved seed is a warning; when there is no graph and graphify is not installed, it warns
# that slices will be file-name matches only. Planner-only — not copied into the run at Stage 7.
#
# Prints one line per problem, then: seeds: <N> ok (<G> graph, <F> future), <U> unresolved
# Exits 0 when every seed resolves (or only warnings), 1 on any unresolved seed, 2 on a usage error.

set -uo pipefail

usage() { echo "usage: check-seeds.sh <run-root>" >&2; exit 2; }

[[ $# -eq 1 && -n "$1" ]] || usage
root="${1%/}"
[[ -d "$root/phases" ]] || { echo "check-seeds.sh: no phases/ directory under $root" >&2; exit 2; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
slicer="$here/map-slice.sh"
graph="$root/graph/graph.json"

# Only the phase specs themselves (phase-N.md, not .brief/.evidence/.fix), in numeric order.
specs=()
while IFS= read -r n; do
  specs+=("$root/phases/phase-$n.md")
done < <(
  for f in "$root"/phases/phase-[0-9]*.md; do
    b="$(basename "$f")"
    [[ "$b" =~ ^phase-([0-9]+)\.md$ ]] && echo "${BASH_REMATCH[1]}"
  done | sort -n
)

graph_ok=0
if [[ -f "$graph" ]]; then
  graph_ok=1
elif ! command -v graphify >/dev/null 2>&1; then
  echo "⚠  graphify not installed — no graph at plan or run time, so slices will be file-name matches; prefer \`Map seeds: none\`"
fi

ok_graph=0; ok_future=0; unresolved=0; warned=0

for ((i = 0; i < ${#specs[@]}; i++)); do
  spec="${specs[$i]}"
  n="$(basename "$spec" .md)"; n="${n#phase-}"
  line="$(grep -m1 -E '^Map seeds:' "$spec" | sed -E 's/^Map seeds:[[:space:]]*//; s/[[:space:]]+$//')"
  [[ -n "$line" ]] || continue
  [[ "$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')" == "none" ]] && continue

  seeds=()
  IFS=',' read -r -a parts <<< "$line"
  [[ ${#parts[@]} -gt 0 ]] || continue
  for s in "${parts[@]}"; do
    s="$(printf '%s' "$s" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    [[ -n "$s" ]] && seeds+=("$s")
  done
  [[ ${#seeds[@]} -gt 0 ]] || continue

  slice=""; queryable=0
  if [[ $graph_ok -eq 1 ]]; then
    slice="$(bash "$slicer" "$graph" "$line" 2>/dev/null)"
    case "$slice" in "## Map slice unavailable"*) queryable=0 ;; *) queryable=1 ;; esac
  fi

  for s in "${seeds[@]}"; do
    if [[ $queryable -eq 1 ]] && ! printf '%s\n' "$slice" | grep -qxF -- "### $s - no match"; then
      ok_graph=$((ok_graph + 1)); continue
    fi
    found=""
    for ((j = 0; j < i; j++)); do
      if grep -vE '^Map seeds:' "${specs[$j]}" | grep -qwF -- "$s"; then
        found="$(basename "${specs[$j]}" .md)"; break
      fi
    done
    if [[ -n "$found" ]]; then
      ok_future=$((ok_future + 1)); continue
    fi
    if [[ $graph_ok -eq 1 && $queryable -eq 0 ]]; then
      echo "⚠  phase $n seed '$s': graph could not be queried and no earlier phase names it — not verified"
      warned=$((warned + 1)); continue
    fi
    where="no earlier phase names it"
    [[ $queryable -eq 1 ]] && where="not in the graph and $where"
    echo "❌ phase $n seed '$s': $where — fix the name, seed a neighbor this phase uses, or drop it (\`Map seeds: none\` if nothing is left)"
    if [[ $queryable -eq 1 ]]; then
      sugg="$(printf '%s\n' "$slice" | grep -A3 -xF -- "### $s - no match" | grep -m1 '^suggestions:')"
      [[ -n "$sugg" && "$sugg" != "suggestions: none" ]] && echo "   $sugg"
    fi
    unresolved=$((unresolved + 1))
  done
done

summary="seeds: $((ok_graph + ok_future)) ok ($ok_graph graph, $ok_future future), $unresolved unresolved"
[[ $warned -gt 0 ]] && summary="$summary, $warned unverified"
echo "$summary"
[[ $unresolved -eq 0 ]]
