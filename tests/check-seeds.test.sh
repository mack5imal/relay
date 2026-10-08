#!/usr/bin/env bash
# check-seeds.test.sh — fixture tests for scripts/check-seeds.sh
#
# Proves fix 12's rule: a `Map seeds:` entry must exist when its phase runs — either in the
# plan-time graph (brownfield) or named verbatim by an earlier phase's spec, outside that phase's
# own `Map seeds:` line (a symbol an earlier phase creates). Also the degrade paths: a graph that
# cannot be queried warns instead of failing, and no graph without graphify warns to use `none`.
#
# Repo-only (not shipped in the plugin payload). Run from anywhere:
#   bash tests/check-seeds.test.sh
# Exits 0 if every assertion passes, 1 otherwise. The graph cases need python3 (via map-slice.sh).

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CS="$REPO_ROOT/skills/goal/scripts/check-seeds.sh"
GRAPH="$REPO_ROOT/tests/fixtures/map-graph.json"

for f in "$CS" "$GRAPH"; do
  [ -f "$f" ] || { echo "FATAL: missing $f" >&2; exit 1; }
done

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  \033[31m✗\033[0m %s\n      %s\n' "$1" "$2"; }

assert_rc()       { if [ "$2" = "$RC" ]; then ok "$1"; else no "$1" "expected exit $2 got $RC (out: $OUT)"; fi; }
assert_contains() { case "$3" in *"$2"*) ok "$1";; *) no "$1" "missing substring [$2] in [$3]";; esac; }
assert_missing()  { case "$3" in *"$2"*) no "$1" "unexpectedly contains [$2]";; *) ok "$1";; esac; }

run() { OUT="$("$@" 2>&1)"; RC=$?; }

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

# A PATH with a stub graphify, and one without — so the graphify warning is deterministic.
mkdir -p "$W/bin-with" "$W/bin-without"
printf '#!/bin/sh\nexit 0\n' > "$W/bin-with/graphify"
chmod +x "$W/bin-with/graphify"
for tool in bash python3 uv; do
  p="$(command -v "$tool" 2>/dev/null)" || continue
  ln -sf "$p" "$W/bin-with/$tool"
  ln -sf "$p" "$W/bin-without/$tool"
done
WITH="$W/bin-with:/usr/bin:/bin"
WITHOUT="$W/bin-without:/usr/bin:/bin"

# newroot <name> [graph] — an empty run root, optionally with the fixture graph
newroot() {
  R="$W/$1"
  mkdir -p "$R/phases"
  if [ "${2:-}" = graph ]; then mkdir -p "$R/graph"; cp "$GRAPH" "$R/graph/graph.json"; fi
}

# phase <n> <seeds> <work text> — writes $R/phases/phase-<n>.md
phase() {
  {
    printf 'RELAY_PHASE_START\nPhase: %s of 12 — Sample\nMap seeds: %s\nEstimated files: 3\n\n' "$1" "$2"
    printf '## Work\n\n%s\n\n## Acceptance criteria\n\n- `make test` exits 0\n' "$3"
  } > "$R/phases/phase-$1.md"
}

# ---------------------------------------------------------------------------
echo
echo "[1] Greenfield, no graph: a seed an earlier phase creates resolves"
newroot green
phase 1 none '- scaffold the package'
phase 2 none '- create `TrackStore` and `Playlist` in Sources/Model/'
phase 3 'TrackStore, Playlist' '- build the library view over the model'
run env PATH="$WITH" bash "$CS" "$R"
assert_rc "exits 0" 0
assert_contains "counts both as future" "seeds: 2 ok (0 graph, 2 future), 0 unresolved" "$OUT"
assert_missing "no graphify warning when graphify is installed" "graphify not installed" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[2] A seed only a later phase names is unresolved"
newroot later
phase 1 none '- scaffold'
phase 2 'TrackStore' '- use the store'
phase 3 none '- create `TrackStore`'
run env PATH="$WITH" bash "$CS" "$R"
assert_rc "exits 1" 1
assert_contains "names phase and seed" "phase 2 seed 'TrackStore'" "$OUT"
assert_contains "says why" "no earlier phase names it" "$OUT"
assert_contains "summary counts it" "1 unresolved" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[3] An earlier phase's own Map seeds: line does not count as creating the symbol"
newroot seedline
phase 1 none '- scaffold'
phase 2 'Ghost' '- nothing about it here'
phase 3 'Ghost' '- still nothing'
run env PATH="$WITH" bash "$CS" "$R"
assert_rc "exits 1" 1
assert_contains "phase 3's Ghost unresolved" "phase 3 seed 'Ghost'" "$OUT"
assert_contains "both unresolved" "2 unresolved" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[4] Matching is whole-word and case-sensitive"
newroot word
phase 1 none '- create `HistoryStore` and `player`'
phase 2 'Store, Player' '- use them'
run env PATH="$WITH" bash "$CS" "$R"
assert_rc "exits 1" 1
assert_contains "Store is not satisfied by HistoryStore" "phase 2 seed 'Store'" "$OUT"
assert_contains "Player is not satisfied by player" "phase 2 seed 'Player'" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[5] Brownfield: seeds in the graph resolve, a typo does not"
newroot brown graph
phase 1 'Scheduler, HistoryStore' '- change the scheduler'
run env PATH="$WITH" bash "$CS" "$R"
assert_rc "graph seeds exit 0" 0
assert_contains "counted as graph" "seeds: 2 ok (2 graph, 0 future), 0 unresolved" "$OUT"
phase 1 'HistoryStor' '- change the history store'
run env PATH="$WITH" bash "$CS" "$R"
assert_rc "typo exits 1" 1
assert_contains "says not in the graph" "not in the graph and no earlier phase names it" "$OUT"
assert_contains "relays the suggestion" "suggestions: HistoryStore" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[6] Brownfield + future seeds mix"
newroot mix graph
phase 1 'Scheduler' '- add `ReminderQueue` beside the scheduler'
phase 2 'Scheduler, ReminderQueue, HistoryStore' '- wire reminders into history'
run env PATH="$WITH" bash "$CS" "$R"
assert_rc "exits 0" 0
assert_contains "3 graph + 1 future" "seeds: 4 ok (3 graph, 1 future), 0 unresolved" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[7] Graph present but not queryable: unresolved seeds warn, never fail"
newroot noquery graph
phase 1 'Scheduler, Mystery' '- work'
run env PATH="$WITH" RELAY_MAP_RUNNER=none bash "$CS" "$R"
assert_rc "exits 0" 0
assert_contains "warns per seed" "graph could not be queried" "$OUT"
assert_contains "summary counts unverified" "0 unresolved, 2 unverified" "$OUT"
assert_missing "no ❌" "❌" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[8] No graph and no graphify: warn to prefer none"
newroot nographify
phase 1 none '- scaffold'
run env PATH="$WITHOUT" bash "$CS" "$R"
assert_rc "exits 0" 0
assert_contains "graphify warning" "graphify not installed" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[9] Derived files are ignored; phase 10 sorts after phase 9"
newroot order
for n in 1 2 3 4 5 6 7 8; do phase "$n" none '- step'; done
phase 9 none '- create `LateType`'
phase 10 'LateType' '- use it'
printf 'Map seeds: Bogus\n' > "$R/phases/phase-10.fix.md"
printf 'Map seeds: Bogus\n' > "$R/phases/phase-2.brief.md"
run env PATH="$WITH" bash "$CS" "$R"
assert_rc "exits 0" 0
assert_contains "phase 10 sees phase 9" "seeds: 1 ok (0 graph, 1 future), 0 unresolved" "$OUT"
assert_missing "fix/brief files never checked" "Bogus" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[10] Usage errors"
run bash "$CS"
assert_rc "no args exits 2" 2
run bash "$CS" "$W/does-not-exist"
assert_rc "missing run root exits 2" 2
mkdir -p "$W/nophases"
run bash "$CS" "$W/nophases"
assert_rc "no phases/ exits 2" 2

# ---------------------------------------------------------------------------
echo
echo "----------------------------------------"
printf 'Results: %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  exit 1
fi
echo "All fixture scenarios passed."
exit 0
