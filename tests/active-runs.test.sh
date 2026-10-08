#!/usr/bin/env bash
# active-runs.test.sh — fixture tests for scripts/active-runs.sh
#
# Proves the Stage 0 active-run scan (fix 23): empty and missing bases list nothing and exit 0 —
# including under zsh, whose "no matches found" on an empty .relay/ broke the old inline loop —
# a COMPLETE run is not active, the unfilled template's arrow line is, and the pre-0.7 flat
# layout is still found.
#
# Repo-only (not shipped in the plugin payload). Run from anywhere:
#   bash tests/active-runs.test.sh
# Exits 0 if every assertion passes, 1 otherwise.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AR="$REPO_ROOT/skills/goal/scripts/active-runs.sh"
[ -f "$AR" ] || { echo "FATAL: missing $AR" >&2; exit 1; }

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

# state <dir> <status line> — a run dir with a STATE.md carrying that Status line
state() { mkdir -p "$1"; printf '# State: x\n\n%s\n**Current phase:** —\n' "$2" > "$1/STATE.md"; }

# ---------------------------------------------------------------------------
echo
echo "[1] No runs: empty and missing bases"
mkdir -p "$W/empty/.relay"
cd "$W/empty" || exit 1
run bash "$AR"
assert_rc "empty .relay/ exits 0" 0
assert_contains "says none" "Active runs in this tree:
  (none)" "$OUT"
run bash "$AR" "$W/nope"
assert_rc "missing base exits 0" 0
assert_contains "missing base: none" "(none)" "$OUT"
if command -v zsh >/dev/null 2>&1; then
  OUT="$(zsh -c "bash '$AR' .relay" 2>&1)"; RC=$?
  assert_rc "called from zsh on an empty .relay/ exits 0" 0
  assert_missing "no zsh glob error" "no matches found" "$OUT"
  # The old inline loop, for contrast: zsh aborts on the unmatched glob.
  OUT="$(zsh -c 'for s in .relay/*/STATE.md; do :; done' 2>&1)"; RC=$?
  assert_contains "the old inline loop fails under zsh (why the script exists)" "no matches found" "$OUT"
else
  ok "zsh not installed — zsh checks skipped"
fi

# ---------------------------------------------------------------------------
echo
echo "[2] Active vs complete"
B="$W/tree/.relay"
state "$B/done-AAAAAA" '**Status:** COMPLETE'
state "$B/building-BBBBBB" '**Status:** IN_PROGRESS'
state "$B/template-CCCCCC" '**Status:** PLANNING → IN_PROGRESS → COMPLETE    <!-- … -->'
state "$B/parked-DDDDDD" '**Status:** AWAITING_DESIGN'
mkdir -p "$B/claimed-EEEEEE"   # claimed, no STATE.md yet
run bash "$AR" "$B/"
assert_rc "exits 0" 0
assert_missing "COMPLETE is not active" "done-AAAAAA" "$OUT"
assert_contains "IN_PROGRESS is active" "  $B/building-BBBBBB" "$OUT"
assert_contains "the template arrow line reads active" "template-CCCCCC" "$OUT"
assert_contains "AWAITING_DESIGN is active" "parked-DDDDDD" "$OUT"
assert_missing "a dir without STATE.md is not listed" "claimed-EEEEEE" "$OUT"
assert_missing "no (none) when runs exist" "(none)" "$OUT"
state "$W/lower/.relay/r-FFFFFF" 'status: complete'
run bash "$AR" "$W/lower/.relay"
assert_contains "COMPLETE is matched case-insensitively" "(none)" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[3] Legacy flat layout and \$RELAY_BASE"
mkdir -p "$W/legacy/.relay"
printf '**Status:** IN_PROGRESS\n' > "$W/legacy/.relay/STATE.md"
cd "$W/legacy" || exit 1
run bash "$AR"
assert_contains "pre-0.7 .relay/STATE.md is found" "  .relay" "$OUT"
state "$W/custom/runs/x-GGGGGG" '**Status:** PLANNING'
cd "$W/custom" || exit 1
OUT="$(RELAY_BASE=runs bash "$AR" 2>&1)"; RC=$?
assert_contains "honours \$RELAY_BASE" "runs/x-GGGGGG" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "----------------------------------------"
printf 'Results: %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  exit 1
fi
echo "All fixture scenarios passed."
exit 0
