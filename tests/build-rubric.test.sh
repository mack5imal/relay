#!/usr/bin/env bash
# build-rubric.test.sh — fixture tests for scripts/build-rubric.sh
#
# Proves the Stage 6 rubric: every phase's acceptance criteria and mandatory commands land in one
# RUBRIC.md, the S<k> ids each phase serves are collected, both flag classes (human eye, outside the
# repo) fire and the obvious false positives do not, briefs and evidence files are ignored, missing
# phases and empty phases fail loudly, and re-running is byte-identical.
#
# Repo-only (not shipped in the plugin payload). Run from anywhere:
#   bash tests/build-rubric.test.sh
# Exits 0 if every assertion passes, 1 otherwise.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BR="$REPO_ROOT/skills/goal/scripts/build-rubric.sh"
FIX="$REPO_ROOT/tests/fixtures/build-rubric"

for f in "$BR" "$FIX/phases/phase-1.md"; do
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
cp -R "$FIX" "$W/run"

echo "build-rubric.test.sh — fixtures for $BR"
echo

# ---------------------------------------------------------------------------
echo "[1] One line out, RUBRIC.md written into the run root"
run bash "$BR" "$W/run"
assert_rc "exits 0" 0
assert_contains "summary counts criteria, phases and flags" "rubric: 8 criteria across 3 phases, 2 flagged" "$OUT"
[ -f "$W/run/RUBRIC.md" ] && ok "writes <run-root>/RUBRIC.md" || no "writes <run-root>/RUBRIC.md" "file missing"
R="$(cat "$W/run/RUBRIC.md" 2>/dev/null)"
assert_contains "titled from ROADMAP.md" "# Rubric — sample widget app" "$R"
assert_contains "states what completes the run" "Nothing else ends the run." "$R"

# ---------------------------------------------------------------------------
echo
echo "[2] Every phase's criteria and commands, with the spec ids it serves"
assert_contains "phase heading carries the name" "## Phase 2 — Ship the site" "$R"
assert_contains "S-ids sorted numerically across the file" "Serves: S1, S2, S10" "$R"
assert_contains "commands from the section" "Mandatory commands: npm test, npm run lint" "$R"
assert_contains "falls back to the header when the section is empty" "Mandatory commands: npm test, npm run build" "$R"
assert_contains "criteria listed verbatim" "- every error state renders its message (unit tested)" "$R"
assert_missing "briefs and other phase-N.* files are ignored" "must never appear" "$R"

# ---------------------------------------------------------------------------
echo
echo "[3] Flags: the handful worth a human look, and not the false positives"
assert_contains "a deploy is outside the repo" "**Phase 2** (outside the repo): \`vercel deploy --prod\`" "$R"
assert_contains "a screenshot needs a human eye" "**Phase 2** (human eye): a \`/browse\` screenshot" "$R"
assert_missing "a .vercel gitignore entry is not a deploy" "(outside the repo): \`.gitignore\`" "$R"
case "$R" in *"\`npm test\` exits 0 with the widget suite passing  _("*) no "unflagged criteria carry no tag" "tagged";; *) ok "unflagged criteria carry no tag";; esac
cp -R "$FIX" "$W/clean"
for f in "$W"/clean/phases/phase-2.md; do
  perl -0pi -e 's/- `vercel deploy[^\n]*\n//; s/- a `\/browse`[^\n]*\n//' "$f"
done
run bash "$BR" "$W/clean"
assert_contains "no flags reads as none" "None — every criterion is one the run can check" "$(cat "$W/clean/RUBRIC.md")"
# Commit 14: "publish" and "account" flagged ordinary in-repo criteria.
cp -R "$FIX" "$W/words"
perl -0pi -e 's/(- the parser returns 3 rows[^\n]*\n)/$1- Publish (S1): `write_atomic` of a new target writes exactly `data`\n- per-thread totals match the sidechain accounting\n- `npm publish --dry-run` lists the package files\n- the release is published to PyPI\n/' "$W/words/phases/phase-1.md"
run bash "$BR" "$W/words"
assert_contains "the added criteria are counted" "rubric: 12 criteria across 3 phases, 4 flagged" "$OUT"
RW="$(cat "$W/words/RUBRIC.md")"
assert_missing "an atomic publish of a local file is not outside the repo" "(outside the repo): Publish (S1)" "$RW"
assert_missing "\"accounting\" is not an account" "(outside the repo): per-thread totals" "$RW"
assert_contains "npm publish is outside the repo" "(outside the repo): \`npm publish --dry-run\`" "$RW"
assert_contains "publishing to a registry is outside the repo" "(outside the repo): the release is published to PyPI" "$RW"

# ---------------------------------------------------------------------------
echo
echo "[4] Deterministic: a re-run is byte-identical"
cp "$W/run/RUBRIC.md" "$W/first.md"
run bash "$BR" "$W/run"
if cmp -s "$W/first.md" "$W/run/RUBRIC.md"; then ok "same bytes on a second run"; else no "same bytes on a second run" "diff: $(diff "$W/first.md" "$W/run/RUBRIC.md")"; fi
run bash "$BR" "$W/run" --out "$W/elsewhere.md"
assert_rc "--out exits 0" 0
[ -f "$W/elsewhere.md" ] && ok "--out writes where told" || no "--out writes where told" "file missing"

# ---------------------------------------------------------------------------
echo
echo "[5] Missing or empty phases fail loudly"
cp -R "$FIX" "$W/gap" && rm "$W/gap/phases/phase-2.md"
run bash "$BR" "$W/gap"
assert_rc "a missing phase exits 1" 1
assert_contains "names the missing phase" "phase 2 of 3 has no spec file" "$OUT"
cp -R "$FIX" "$W/empty"
perl -0pi -e 's/(## Acceptance criteria[^\n]*\n\n)(- [^\n]*\n)+/$1/' "$W/empty/phases/phase-3.md"
run bash "$BR" "$W/empty"
assert_rc "a phase with no criteria exits 1" 1
assert_contains "names the empty phase" "phase 3 has no acceptance criteria" "$OUT"
mkdir -p "$W/nophases"
run bash "$BR" "$W/nophases"
assert_rc "no phases/ directory exits 1" 1
run bash "$BR"
assert_rc "no args exits 2" 2
run bash "$BR" "$W/run" --bogus
assert_rc "unknown flag exits 2" 2

# ---------------------------------------------------------------------------
echo
echo "----------------------------------------"
printf 'Results: %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  exit 1
fi
echo "All fixture scenarios passed."
exit 0
