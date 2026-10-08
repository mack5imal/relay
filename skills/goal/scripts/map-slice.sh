#!/usr/bin/env bash
# map-slice.sh — print a compact map of named symbols from this run's code graph, or
# file-name matches when no graph or Python is available.
#
# Why: map-slice.py does the real work but needs a Python and a graph.json. A phase must
# never block on either, so this launcher picks a runner and degrades instead of failing.
#
# Usage:
#   bash map-slice.sh <graph.json> SEED [SEED ...]       (commas also separate seeds)
#
#   Runner order: `uv run --no-project` -> python3 (>= 3.8) -> file-name fallback.
#   RELAY_MAP_RUNNER=uv|python3|none forces a runner; RELAY_MAP_BUDGET=<tokens> sets the
#   slice's token budget (default 5000). Exits 0 whenever the arguments are valid, even when
#   it falls back; exits 2 on a usage error.
#
# Copied into the run's <run-root>/ at Stage 7, together with map-slice.py.

set -uo pipefail

usage() {
  echo "usage: map-slice.sh <graph.json> SEED [SEED ...]" >&2
  exit 2
}

[ "$#" -ge 2 ] && [ -n "$1" ] || usage

graph="$1"
shift
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
py="$here/map-slice.py"
budget="${RELAY_MAP_BUDGET:-5000}"
runner="${RELAY_MAP_RUNNER:-auto}"

# Seeds may arrive as one comma-separated argument ("Map seeds: A, B") or as separate ones.
seeds=()
for arg in "$@"; do
  [ -n "$arg" ] || continue
  IFS=',' read -r -a parts <<< "$arg"
  [ "${#parts[@]}" -gt 0 ] || continue
  for seed in "${parts[@]}"; do
    seed="$(printf '%s' "$seed" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$seed" ] && seeds+=("$seed")
  done
done
[ "${#seeds[@]}" -gt 0 ] || usage

case "$runner" in
  auto|uv|python3|none) ;;
  *) echo "map-slice.sh: RELAY_MAP_RUNNER must be uv, python3, or none" >&2; exit 2 ;;
esac

list_files() {
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git ls-files --cached --others --exclude-standard 2>/dev/null
  else
    find . -type f -not -path './.git/*' -not -path './node_modules/*' -not -path './.relay/*' 2>/dev/null \
      | sed 's#^\./##'
  fi
}

fallback() {
  echo "## Map slice unavailable ($1) - file-name matches instead"
  local files matches total seed
  files="$(list_files)"
  for seed in "${seeds[@]}"; do
    echo
    echo "### $seed"
    matches="$(printf '%s\n' "$files" | grep -iF -- "$seed" || true)"
    if [ -z "$matches" ]; then
      echo "- (no file names match)"
      continue
    fi
    total="$(printf '%s\n' "$matches" | grep -c .)"
    printf '%s\n' "$matches" | head -n 15 | sed 's/^/- /'
    if [ "$total" -gt 15 ]; then
      echo "- (+$((total - 15)) more)"
    fi
  done
  exit 0
}

[ -f "$graph" ] || fallback "no graph at $graph"
[ -f "$py" ] || fallback "map-slice.py not found next to map-slice.sh"

python3_ok() {
  command -v python3 >/dev/null 2>&1 \
    && python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1
}

if [ "$runner" = auto ]; then
  if command -v uv >/dev/null 2>&1; then
    runner=uv
  elif python3_ok; then
    runner=python3
  else
    runner=none
  fi
fi

case "$runner" in
  uv)      cmd=(uv run --no-project --quiet "$py") ;;
  python3) cmd=(python3 "$py") ;;
  none)    fallback "no Python runner" ;;
esac

out="$("${cmd[@]}" --graph "$graph" --budget "$budget" "${seeds[@]}" 2>/dev/null < /dev/null)"
rc=$?
case "$rc" in
  0) printf '%s\n' "$out" ;;
  3) fallback "graph unreadable: $graph" ;;
  *) fallback "map-slice.py failed with exit $rc" ;;
esac
exit 0
