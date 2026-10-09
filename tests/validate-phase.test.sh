#!/usr/bin/env bash
# validate-phase.test.sh — fixture tests for scripts/validate-phase.sh
#
# Proves the phase-spec gate: the structural markers/sections it hard-fails on, the two content
# checks added in 0.9 (a phase must declare its mandatory commands; the header's criterion count
# must agree with the bullets the runtime cross-checks it against), the 0.10 `Review:` line (yes,
# or skip with a mandatory reason), and that the shipped skeleton template still passes with
# advisories only.
#
# Repo-only (not shipped in the plugin payload). Run from anywhere:
#   bash tests/validate-phase.test.sh
# Exits 0 if every assertion passes, 1 otherwise.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VP="$REPO_ROOT/skills/goal/scripts/validate-phase.sh"
TEMPLATE="$REPO_ROOT/skills/goal/templates/phase-goal.txt"

for f in "$VP" "$TEMPLATE"; do
  [ -f "$f" ] || { echo "FATAL: missing $f" >&2; exit 1; }
done

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  \033[31m✗\033[0m %s\n      %s\n' "$1" "$2"; }

assert_rc()       { if [ "$2" = "$RC" ]; then ok "$1"; else no "$1" "expected exit $2 got $RC (out: $OUT)"; fi; }
assert_contains() { case "$3" in *"$2"*) ok "$1";; *) no "$1" "missing substring [$2] in [$3]";; esac; }
assert_missing()  { case "$3" in *"$2"*) no "$1" "unexpectedly contains [$2]";; *) ok "$1";; esac; }
assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "expected [$2] got [$3]"; fi; }

run() { OUT="$("$@" 2>&1)"; RC=$?; }

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

# spec <name> <criteria-header> <criteria-bullets> <command-bullets>
# The header's Review: line is "$REVIEW" (default yes); REVIEW=__none__ leaves it out.
REVIEW="yes"
spec() {
  local path="$W/$1.md" hdr="$2" crits="$3" cmds="$4"
  {
    printf 'RELAY_PHASE_START\nPhase: 1 of 2 — Sample\n'
    [ -n "$hdr" ] && printf 'Acceptance criteria: %s\n' "$hdr"
    printf 'Map seeds: none\nEstimated files: 3\n'
    [ "$REVIEW" = "__none__" ] || printf 'Review: %s\n' "$REVIEW"
    printf '\n## Why\n\nBecause.\n\n'
    printf '## Work\n\n- do the thing\n\n'
    printf '## Exemplars\n\n- src/a.ts — pattern\n\n'
    printf '## Acceptance criteria\n\n'
    printf '%s' "$crits"
    printf '\n## Mandatory commands\n\n'
    printf '%s' "$cmds"
    printf '\n## Evidence required\n\n- command exit codes\n'
  } > "$path"
  printf '%s' "$path"
}

TWO_CRITS='- `npm run build` exits 0
- `npm test` exits 0
'
TWO_CMDS='- `npm run build`
- `npm test`
'

echo "validate-phase.test.sh — fixtures for $VP"
echo

# ---------------------------------------------------------------------------
echo "[1] A well-formed spec passes cleanly"
run bash "$VP" "$(spec good 2 "$TWO_CRITS" "$TWO_CMDS")"
assert_rc "exits 0" 0
assert_contains "reports structure ok" "structure ok" "$OUT"
assert_missing "no errors" "❌" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[2] Mandatory commands must actually list commands"
run bash "$VP" "$(spec nocmds 2 "$TWO_CRITS" "")"
assert_rc "empty command section exits 1" 1
assert_contains "explains why it matters" "build/typecheck/lint/test gate" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[2b] A command bullet is the command alone (tunez's false pass)"
run bash "$VP" "$(spec bare 2 "$TWO_CRITS" '- npm run build
- npm test
')"
assert_rc "bare commands pass" 0
run bash "$VP" "$(spec described 2 "$TWO_CRITS" '- `npm run build` — vite build summary line; exit 0
- npm test — vitest: N passed
- npm run lint – eslint
- `npm run e2e`
')"
assert_rc "a described bullet exits 1" 1
assert_contains "names a backticked bullet with text after it" "bullet carries a description: '\`npm run build\` — vite build summary line; exit 0'" "$OUT"
assert_contains "… a bare one with an em dash" "'npm test — vitest: N passed'" "$OUT"
assert_contains "… and an en dash" "'npm run lint – eslint'" "$OUT"
assert_missing "a backticked command alone is fine" "'\`npm run e2e\`'" "$OUT"
assert_contains "says where the summary line goes" "under '## Evidence required'" "$OUT"
assert_eq "one error per bad bullet" "3" "$(printf '%s\n' "$OUT" | grep -c 'carries a description')"

# ---------------------------------------------------------------------------
echo
echo "[3] Header criterion count must agree with the bullets"
run bash "$VP" "$(spec badcount 5 "$TWO_CRITS" "$TWO_CMDS")"
assert_rc "mismatch exits 1" 1
assert_contains "names both numbers" "header says 'Acceptance criteria: 5' but" "$OUT"
run bash "$VP" "$(spec nocount "" "$TWO_CRITS" "$TWO_CMDS")"
assert_rc "a spec with no declared count still passes" 0

# ---------------------------------------------------------------------------
echo
echo "[4] Structural requirements still hard-fail"
printf 'Phase: 1\n\n## Work\n\n- x\n' > "$W/bare.md"
run bash "$VP" "$W/bare.md"
assert_rc "missing marker + sections exits 1" 1
assert_contains "names the marker" "RELAY_PHASE_START" "$OUT"
run bash "$VP" "$W/does-not-exist.md"
assert_rc "missing file exits 2" 2
run bash "$VP"
assert_rc "no args exits 2" 2

# ---------------------------------------------------------------------------
echo
echo "[5] The shipped skeleton template passes (placeholders warn, never fail)"
run bash "$VP" "$TEMPLATE"
assert_rc "template exits 0" 0
assert_contains "placeholders are flagged" "template placeholder" "$OUT"
assert_missing "but never as an error" "❌" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[6] Phase size: over 12 warns unless the line says why (fix 28)"
# sized <name> <Estimated files: value> — a clean spec with that sizing line
sized() { p="$(spec "$1" 2 "$TWO_CRITS" "$TWO_CMDS")"; perl -pi -e "s/^Estimated files: 3\$/Estimated files: $2/" "$p"; printf '%s' "$p"; }
run bash "$VP" "$(sized s12 12)"
assert_rc "12 passes" 0
assert_missing "12 does not warn" "exceeds" "$OUT"
run bash "$VP" "$(sized s13 13)"
assert_rc "13 still passes (advisory)" 0
assert_contains "13 warns and says how to clear it" "Estimated files: 13 exceeds 12 — split it at a seam, or keep it and say why" "$OUT"
run bash "$VP" "$(sized s14r '14 — one schema migration; every file changes together')"
assert_missing "a stated reason clears the warning" "exceeds" "$OUT"
run bash "$VP" "$(sized s14d '14 - generated clients, no seam')"
assert_missing "a hyphen before the reason works too" "exceeds" "$OUT"
OUT="$(RELAY_PHASE_FILE_LIMIT=8 bash "$VP" "$(sized s9 9)" 2>&1)"
assert_contains "RELAY_PHASE_FILE_LIMIT still overrides" "exceeds 8" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[7] Review: yes, or skip with a reason — a missing line or a bare skip fails"
rv() { REVIEW="$2"; p="$(spec "$1" 2 "$TWO_CRITS" "$TWO_CMDS")"; REVIEW="yes"; printf '%s' "$p"; }
run bash "$VP" "$(rv ryes 'yes')"
assert_rc "Review: yes passes" 0
run bash "$VP" "$(rv rskip 'skip — docs only, no code changes')"
assert_rc "Review: skip — <reason> passes" 0
assert_missing "… with no review warning" "Review" "$OUT"
run bash "$VP" "$(rv rlean 'skip — --lean')"
assert_rc "Review: skip — --lean passes" 0
run bash "$VP" "$(rv rhyph 'skip - config only')"
assert_rc "Review: skip - <reason> (hyphen) passes" 0
run bash "$VP" "$(rv rbare 'skip')"
assert_rc "a bare skip fails" 1
assert_contains "… and asks for the reason" "'Review: skip' needs a reason" "$OUT"
run bash "$VP" "$(rv rdash 'skip —')"
assert_rc "skip with only a dash fails" 1
run bash "$VP" "$(rv rnone '__none__')"
assert_rc "a missing Review: line fails" 1
assert_contains "… and says what to write" "no 'Review:' line" "$OUT"
run bash "$VP" "$(rv rjunk 'maybe')"
assert_rc "any other value fails" 1
assert_contains "… naming the allowed values" "must be 'yes' or 'skip — <reason>'" "$OUT"
run bash "$VP" "$(rv rph '{{YES_OR_SKIP_WITH_REASON}}')"
assert_rc "a placeholder only warns" 0
assert_contains "… with a placeholder warning" "'Review:' still holds a template placeholder" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "----------------------------------------"
printf 'Results: %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  exit 1
fi
echo "All fixture scenarios passed."
exit 0
