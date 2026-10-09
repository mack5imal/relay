#!/usr/bin/env bash
# design-dir.test.sh — fixture tests for scripts/design-dir.sh
#
# Proves where a run's design package goes: design/ when the project has none (greenfield,
# unchanged), design/<feature>/ beside an earlier package (an app that already has a design),
# a taken or malformed name refused, and the existing packages listed with their screen counts
# and commits. Includes a zsh check: the scan is a glob loop, and an unmatched glob is an error
# under zsh.
#
# Repo-only (not shipped in the plugin payload). Needs git. Run from anywhere:
#   bash tests/design-dir.test.sh
# Exits 0 if every assertion passes, 1 otherwise.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DD="$REPO_ROOT/skills/goal/scripts/design-dir.sh"
FIX="$REPO_ROOT/tests/fixtures/check-design"
[ -f "$DD" ] || { echo "FATAL: missing $DD" >&2; exit 1; }

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

# proj <name> — a git repository with one commit; cd into it
proj() {
  mkdir -p "$W/$1" && cd "$W/$1" || exit 1
  git init -q . && git config user.email t@example.com && git config user.name t
  printf 'x\n' > README.md && git add README.md && git commit -qm init
}

echo
echo "[1] No design package yet: design/ (greenfield, unchanged)"
proj green
run bash "$DD" practice
assert_rc "exits 0" 0
assert_eq "design" "Design dir: design" "$OUT"
mkdir -p design
run bash "$DD" practice
assert_eq "an empty design/ (a parked run's) is still design" "Design dir: design" "$OUT"

echo
echo "[2] An earlier package at design/: the new one goes beside it"
proj brown
cp -R "$FIX" design && git add design && git commit -qm "design: handoff"
sha="$(git log -1 --format=%h -- design)"
run bash "$DD" practice-mode
assert_rc "exits 0" 0
assert_contains "the run's folder" "Design dir: design/practice-mode" "$OUT"
assert_contains "lists the earlier package with its screens and commit" "existing: design — 3 screens @ $sha" "$OUT"
mkdir -p design/practice-mode
run bash "$DD" practice-mode
assert_rc "an empty folder this run made is fine (resume)" 0
cp -R "$FIX/." design/practice-mode/
run bash "$DD" drills
assert_contains "an uncommitted package is said to be" "existing: design/practice-mode — 3 screens @ uncommitted" "$OUT"
assert_contains "… without making the committed one read as changed" "existing: design — 3 screens @ $sha" "$OUT"
assert_contains "and the next feature gets its own folder" "Design dir: design/drills" "$OUT"
git add design && git commit -qm "design: practice"
run bash "$DD" practice-mode
assert_rc "a folder that holds a package is taken" 1
assert_contains "and says so" "already holds a design package" "$OUT"
run bash "$DD" drills
assert_contains "two earlier packages are both listed (top)" "existing: design — 3 screens" "$OUT"
assert_contains "… and nested" "existing: design/practice-mode — 3 screens" "$OUT"
assert_contains "… and the new one goes beside them" "Design dir: design/drills" "$OUT"

echo
echo "[3] A package only in a subfolder still counts"
proj nested
mkdir -p design/first && cp -R "$FIX/." design/first/ && git add design && git commit -qm d
run bash "$DD" second
assert_contains "design/second" "Design dir: design/second" "$OUT"
assert_contains "lists design/first" "existing: design/first" "$OUT"

echo
echo "[4] Without git"
mkdir -p "$W/nogit" && cd "$W/nogit" && cp -R "$FIX" design
run bash "$DD" extra
assert_contains "still finds the package" "existing: design — 3 screens @ no-git" "$OUT"

echo
echo "[5] Usage errors"
run bash "$DD"
assert_rc "no slug exits 2" 2
for bad in "Practice" "practice mode" "practice--mode" "-practice" "practice/x" "$(printf 'a%.0s' $(seq 1 41))"; do
  run bash "$DD" "$bad"
  assert_rc "malformed slug '${bad:0:20}' exits 2" 2
done

echo
echo "[6] zsh: no design/ at all is not an error"
if command -v zsh >/dev/null 2>&1; then
  proj zshgreen
  OUT="$(zsh -c "bash '$DD' practice" 2>&1)"; RC=$?
  assert_rc "exits 0 under zsh" 0
  assert_eq "design" "Design dir: design" "$OUT"
  cd "$W/brown" || exit 1
  OUT="$(zsh -c "bash '$DD' extra" 2>&1)"; RC=$?
  assert_contains "brownfield under zsh" "Design dir: design/extra" "$OUT"
else
  echo "  (zsh not installed — skipped)"
fi

echo
echo "----------------------------------------"
printf 'Results: %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  exit 1
fi
echo "All fixture scenarios passed."
exit 0
