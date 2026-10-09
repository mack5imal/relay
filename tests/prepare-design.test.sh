#!/usr/bin/env bash
# prepare-design.test.sh — fixture tests for scripts/prepare-design.sh
#
# Proves the planner can settle and commit a returned design package without the owner touching
# git (fix 30): the export's contents placed directly, a lone .zip, or the export's wrapper folder
# all end up as design/HANDOFF.md + design/screens/; .DS_Store and __MACOSX are dropped; the
# commit holds only design/, so anything else the owner staged stays staged; an already-committed
# package makes no new commit; anything ambiguous changes nothing; no git is a warning.
#
# Repo-only (not shipped in the plugin payload). Needs python3 (to build zips). Run from anywhere:
#   bash tests/prepare-design.test.sh
# Exits 0 if every assertion passes, 1 otherwise.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PD="$REPO_ROOT/skills/goal/scripts/prepare-design.sh"
CD="$REPO_ROOT/skills/goal/scripts/check-design.sh"
FIX="$REPO_ROOT/tests/fixtures/check-design"

for f in "$PD" "$CD" "$FIX/HANDOFF.md"; do
  [ -e "$f" ] || { echo "FATAL: missing $f" >&2; exit 1; }
done
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is needed to build the zip fixtures" >&2; exit 1; }

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  \033[31m✗\033[0m %s\n      %s\n' "$1" "$2"; }

assert_rc()       { if [ "$2" = "$RC" ]; then ok "$1"; else no "$1" "expected exit $2 got $RC (out: $OUT)"; fi; }
assert_contains() { case "$3" in *"$2"*) ok "$1";; *) no "$1" "missing substring [$2] in [$3]";; esac; }
assert_missing()  { case "$3" in *"$2"*) no "$1" "unexpectedly contains [$2]";; *) ok "$1";; esac; }
assert_file()     { if [ -e "$2" ]; then ok "$1"; else no "$1" "no $2"; fi; }
assert_nofile()   { if [ -e "$2" ]; then no "$1" "$2 exists"; else ok "$1"; fi; }
assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "expected [$2] got [$3]"; fi; }

run() { OUT="$("$@" 2>&1)"; RC=$?; }

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

g() { git -C "$R" -c user.email=t@example.com -c user.name=t "$@"; }

# repo <name> — a git repo with one commit and an empty design/ (as Stage 2.7b leaves it); sets R
repo() {
  R="$W/$1"
  mkdir -p "$R/design"
  git -C "$R" init -q
  git -C "$R" config user.email t@example.com; git -C "$R" config user.name t
  printf 'x\n' > "$R/README.md"; g add README.md && g commit -qm init
}

# mkzip <zip> <dir> [<prefix>] — zip <dir>'s contents, under <prefix>/ when given
mkzip() {
  python3 - "$1" "$2" "${3:-}" <<'PY'
import os, sys, zipfile
out, src, prefix = sys.argv[1], sys.argv[2], sys.argv[3]
with zipfile.ZipFile(out, "w") as z:
    for root, _, files in os.walk(src):
        for f in files:
            p = os.path.join(root, f)
            z.write(p, os.path.join(prefix, os.path.relpath(p, src)))
    z.writestr(os.path.join(prefix, "__MACOSX/._HANDOFF.md") if prefix else "__MACOSX/._HANDOFF.md", "junk")
PY
}

commits() { git -C "$R" rev-list --count HEAD; }

# ---------------------------------------------------------------------------
echo
echo "[1] Contents placed directly in design/ — committed, and nothing else"
repo direct
cp -R "$FIX/." "$R/design/"
touch "$R/design/.DS_Store" "$R/design/screens/.DS_Store"
printf 'staged\n' > "$R/other.txt"; g add other.txt
run bash "$PD" "$R/design"
assert_rc "exits 0" 0
assert_contains "one line with the sha" "design: committed " "$OUT"
assert_nofile ".DS_Store removed" "$R/design/.DS_Store"
assert_nofile "nested .DS_Store removed" "$R/design/screens/.DS_Store"
assert_contains "design/ is in the commit" "design/HANDOFF.md" "$(g show --name-only --format= HEAD)"
assert_missing "the owner's staged file is not in the commit" "other.txt" "$(g show --name-only --format= HEAD)"
assert_contains "and is still staged" "other.txt" "$(g diff --cached --name-only)"
assert_contains "commit message" "design: handoff" "$(g log -1 --format=%s)"
run bash "$CD" "$R/design"
assert_rc "check-design.sh passes on the result" 0
assert_missing "not uncommitted" "uncommitted" "$OUT"
before="$(commits)"
run bash "$PD" "$R/design"
assert_rc "running again exits 0" 0
assert_contains "says already committed" "design: already committed @ " "$OUT"
if [ "$(commits)" = "$before" ]; then ok "no new commit"; else no "no new commit" "$(commits) vs $before"; fi

# ---------------------------------------------------------------------------
echo
echo "[2] A lone zip, flat or with a wrapper folder inside"
repo zipflat
mkzip "$R/design/design_handoff_demo.zip" "$FIX"
run bash "$PD" "$R/design"
assert_rc "flat zip exits 0" 0
assert_contains "says it unzipped" "unzipped design_handoff_demo.zip" "$OUT"
assert_file "HANDOFF.md at the top" "$R/design/HANDOFF.md"
assert_file "screens/ at the top" "$R/design/screens/overlay.png"
assert_nofile "the zip is gone" "$R/design/design_handoff_demo.zip"
assert_nofile "__MACOSX is gone" "$R/design/__MACOSX"
assert_missing "the zip was never committed" ".zip" "$(g log --name-only --format= -- design)"

repo zipwrapped
mkzip "$R/design/export.zip" "$FIX" design_handoff_demo
run bash "$PD" "$R/design"
assert_rc "zip with a wrapper folder exits 0" 0
assert_file "wrapper lifted: HANDOFF.md at the top" "$R/design/HANDOFF.md"
assert_nofile "no wrapper folder left" "$R/design/design_handoff_demo"
run bash "$CD" "$R/design"
assert_rc "check-design.sh passes" 0

repo zipjunk
mkdir -p "$W/junk"; printf 'hi\n' > "$W/junk/notes.txt"
mkzip "$R/design/wrong.zip" "$W/junk"
run bash "$PD" "$R/design"
assert_rc "a zip with no HANDOFF.md exits 1" 1
assert_contains "asks if it is the export" "has no HANDOFF.md at its top or in one folder" "$OUT"
assert_file "and the zip is left alone" "$R/design/wrong.zip"

# ---------------------------------------------------------------------------
echo
echo "[3] The export's wrapper folder dropped in whole"
repo wrapper
mkdir -p "$R/design/design_handoff_demo 2"
cp -R "$FIX/." "$R/design/design_handoff_demo 2/"
touch "$R/design/design_handoff_demo 2/.DS_Store"
run bash "$PD" "$R/design"
assert_rc "exits 0" 0
assert_contains "says it moved the folder up" "moved design_handoff_demo 2/ up" "$OUT"
assert_file "HANDOFF.md at the top" "$R/design/HANDOFF.md"
assert_nofile "wrapper removed" "$R/design/design_handoff_demo 2"

# ---------------------------------------------------------------------------
echo
echo "[4] Anything ambiguous changes nothing"
repo twozips
mkzip "$R/design/a.zip" "$FIX"; mkzip "$R/design/b.zip" "$FIX"
run bash "$PD" "$R/design"
assert_rc "two zips exit 1" 1
assert_contains "names both" "a.zip b.zip" "$OUT"
assert_nofile "nothing unzipped" "$R/design/HANDOFF.md"
if [ "$(commits)" = 1 ]; then ok "nothing committed"; else no "nothing committed" "$(commits) commits"; fi

repo zipandwrapper
mkzip "$R/design/a.zip" "$FIX"; mkdir -p "$R/design/pkg"; cp -R "$FIX/." "$R/design/pkg/"
run bash "$PD" "$R/design"
assert_rc "a zip and a wrapper exit 1" 1
assert_file "the wrapper is left alone" "$R/design/pkg/HANDOFF.md"

repo clash
mkdir -p "$R/design/screens" "$R/design/pkg"; cp -R "$FIX/." "$R/design/pkg/"
run bash "$PD" "$R/design"
assert_rc "a name that already exists exits 1" 1
assert_contains "names the clash" "already has screens" "$OUT"
assert_file "the wrapper is left whole" "$R/design/pkg/screens/overlay.png"

repo empty
run bash "$PD" "$R/design"
assert_rc "an empty design/ exits 1" 1
assert_contains "says what to put there" "no HANDOFF.md in" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[5] A replaced package, no git, usage"
repo replaced
cp -R "$FIX/." "$R/design/"; bash "$PD" "$R/design" >/dev/null 2>&1
rm "$R/design/screens/settings.png"; printf '\n<!-- rev 2 -->\n' >> "$R/design/HANDOFF.md"
run bash "$PD" "$R/design"
assert_rc "a changed package exits 0" 0
assert_contains "commits the change" "design: committed " "$OUT"
assert_contains "including the deletion" "design/screens/settings.png" "$(g show --name-only --format= HEAD)"

mkdir -p "$W/nogit/design"; cp -R "$FIX/." "$W/nogit/design/"
run env GIT_CEILING_DIRECTORIES="$W" bash "$PD" "$W/nogit/design"
assert_rc "no git exits 0" 0
assert_contains "warns" "not a git repository" "$OUT"

run bash "$PD" "$W/does-not-exist"
assert_rc "a missing design dir exits 1" 1
assert_contains "says to create it" "create it" "$OUT"
run bash "$PD"
assert_rc "no args exits 2" 2

# ---------------------------------------------------------------------------
echo
echo "[N] An addition: the new package's zip in design/<feature>/, beside the app's first package"
repo addition
cp -R "$FIX/." "$R/design/"; g add design && g commit -qm "design: handoff"
before="$(git -C "$R" rev-parse HEAD:design/HANDOFF.md)"
mkdir -p "$R/design/practice" "$W/addsrc"; cp -R "$FIX/." "$W/addsrc/"
printf '\n<!-- practice -->\n' >> "$W/addsrc/HANDOFF.md"
mkzip "$R/design/practice/design_handoff_practice.zip" "$W/addsrc" design_handoff_practice
run bash "$PD" "$R/design/practice"
assert_rc "exits 0" 0
assert_contains "commits the new folder" "design: committed " "$OUT"
assert_file "unzipped and lifted into design/practice" "$R/design/practice/HANDOFF.md"
assert_nofile "the zip is gone" "$R/design/practice/design_handoff_practice.zip"
assert_eq "the first package is untouched" "$before" "$(git -C "$R" rev-parse HEAD:design/HANDOFF.md)"
assert_eq "the commit holds only design/practice" "design/practice" "$(git -C "$R" show --name-only --format= HEAD | sed 's#/[^/]*$##; s#/screens$##' | sort -u)"

# ---------------------------------------------------------------------------
echo
echo "----------------------------------------"
printf 'Results: %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  exit 1
fi
echo "All fixture scenarios passed."
exit 0
