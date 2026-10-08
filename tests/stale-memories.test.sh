#!/usr/bin/env bash
# stale-memories.test.sh — fixture tests for scripts/stale-memories.sh
#
# Proves the Stage 0 stale-memory check (fix 17, moved to a script by fix 23): a memory naming a
# `.relay/<id>` that no longer exists is reported, one naming a live run is not, the MEMORY.md
# index is skipped, and an empty or missing memory dir prints nothing and exits 0 — including
# under zsh, where the old inline `"$MEM_DIR"/*.md` loop failed on no match.
#
# Repo-only (not shipped in the plugin payload). Run from anywhere:
#   bash tests/stale-memories.test.sh
# Exits 0 if every assertion passes, 1 otherwise.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SM="$REPO_ROOT/skills/goal/scripts/stale-memories.sh"
[ -f "$SM" ] || { echo "FATAL: missing $SM" >&2; exit 1; }

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  \033[31m✗\033[0m %s\n      %s\n' "$1" "$2"; }

assert_rc()       { if [ "$2" = "$RC" ]; then ok "$1"; else no "$1" "expected exit $2 got $RC (out: $OUT)"; fi; }
assert_contains() { case "$3" in *"$2"*) ok "$1";; *) no "$1" "missing substring [$2] in [$3]";; esac; }
assert_missing()  { case "$3" in *"$2"*) no "$1" "unexpectedly contains [$2]";; *) ok "$1";; esac; }
assert_empty()    { if [ -z "$2" ]; then ok "$1"; else no "$1" "expected no output, got [$2]"; fi; }

run() { OUT="$("$@" 2>&1)"; RC=$?; }

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
cd "$W" || exit 1
M="$W/memory"; mkdir -p "$M" ".relay/live-AAAAAA"

# ---------------------------------------------------------------------------
echo
echo "[1] Nothing to report"
run bash "$SM" "$M"
assert_rc "empty memory dir exits 0" 0
assert_empty "empty memory dir prints nothing" "$OUT"
run bash "$SM" "$W/nope"
assert_rc "missing memory dir exits 0" 0
assert_empty "missing memory dir prints nothing" "$OUT"
run bash "$SM"
assert_rc "no argument exits 0" 0
if command -v zsh >/dev/null 2>&1; then
  OUT="$(zsh -c "bash '$SM' '$M'" 2>&1)"; RC=$?
  assert_rc "called from zsh on an empty dir exits 0" 0
  assert_missing "no zsh glob error" "no matches found" "$OUT"
else
  ok "zsh not installed — zsh check skipped"
fi

# ---------------------------------------------------------------------------
echo
echo "[2] Stale vs live"
printf -- '---\nname: project_live\nmetadata:\n  relay_run: .relay/live-AAAAAA\n---\nlive\n' > "$M/project_live.md"
printf -- '---\nname: project_gone\nmetadata:\n  relay_run: .relay/gone-BBBBBB\n---\nold plan\n' > "$M/project_gone.md"
printf 'See .relay/gone-CCCCCC/ROADMAP.md for phase 3.\n' > "$M/feedback_path.md"
printf 'No run mentioned.\n' > "$M/user_role.md"
printf -- '- [x](project_gone.md) — .relay/gone-DDDDDD\n' > "$M/MEMORY.md"
run bash "$SM" "$M/"
assert_rc "exits 0" 0
assert_contains "relay_run naming a gone run" "STALE project_gone (run gone: .relay/gone-BBBBBB)" "$OUT"
assert_contains "a .relay/ path in the body" "STALE feedback_path (run gone: .relay/gone-CCCCCC)" "$OUT"
assert_missing "a live run is not stale" "project_live" "$OUT"
assert_missing "a memory with no run is not stale" "user_role" "$OUT"
assert_missing "MEMORY.md is skipped" "gone-DDDDDD" "$OUT"
n="$(printf '%s\n' "$OUT" | grep -c '^STALE')"
if [ "$n" = 2 ]; then ok "one line per stale memory"; else no "one line per stale memory" "got $n"; fi

# ---------------------------------------------------------------------------
echo
echo "----------------------------------------"
printf 'Results: %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  exit 1
fi
echo "All fixture scenarios passed."
exit 0
