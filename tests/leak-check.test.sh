#!/usr/bin/env bash
# leak-check.test.sh — fixture tests for tools/leak-check.sh
#
# Proves the public-repo leak check: a clean tree with placeholder addresses passes; each private
# shape in a tracked file (macOS home path, a projects-folder or Desktop path under ~, a
# project-dir key, a UUID, a personal email) fails and is named; an untracked file is ignored; a
# commit after the base with a non-noreply author or committer fails while the upstream commits
# before it are ignored; a base outside the history is a usage error; and the script and this
# test do not flag themselves.
# Planted strings are assembled from fragments so this file passes the check too.
#
# Repo-only (not shipped in the plugin payload). Run from anywhere:
#   bash tests/leak-check.test.sh
# Exits 0 if every assertion passes, 1 otherwise.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LC="$REPO_ROOT/tools/leak-check.sh"
[ -f "$LC" ] || { echo "FATAL: missing $LC" >&2; exit 1; }

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

UP_EMAIL='upstream@gm''ail.com'
ME_EMAIL='1+me@users.noreply.github.com'

# A repository whose first commit stands for the public upstream history (a personal address,
# allowed before the base); prints the base sha. Later commits use the noreply identity.
mk_repo() {
  local r="$1"
  git init -q "$r"
  git -C "$r" config user.name me
  git -C "$r" config user.email "$ME_EMAIL"
  git -C "$r" config commit.gpgsign false
  printf 'upstream\n' > "$r/README.md"
  git -C "$r" add -A
  GIT_AUTHOR_EMAIL="$UP_EMAIL" GIT_COMMITTER_EMAIL="$UP_EMAIL" git -C "$r" commit -qm upstream
  git -C "$r" rev-parse HEAD
}
commit_all() { git -C "$1" add -A && git -C "$1" commit -qm "${2:-change}"; }

# ---------------------------------------------------------------------------
echo
echo "[1] A clean tree passes"
R="$W/clean"; BASE="$(mk_repo "$R")"
cat > "$R/notes.md" <<'EOF'
Test identity t@example.com, a fake remote git@gitlab.example.invalid:x/y.git,
a trailer noreply@anthropic.com, a remote git@github.com:owner/repo.git, a home path
/home/me/projects/app and ~/.claude/projects/<project>/memory.
EOF
commit_all "$R"
run bash "$LC" --base "$BASE" "$R"
assert_rc "clean tree exits 0" 0
assert_contains "says clean" "leak-check: clean" "$OUT"
assert_contains "counts only the commits after the base" "1 commits after" "$OUT"
assert_missing "upstream's personal address before the base is ignored" "leak:" "$OUT"
printf '%s\n' "/Use""rs/alice/app" > "$R/untracked.txt"
run bash "$LC" --base "$BASE" "$R"
assert_rc "an untracked file is not scanned" 0
rm -f "$R/untracked.txt"

# ---------------------------------------------------------------------------
echo
echo "[2] Each private shape in a tracked file fails"
check_shape() {  # <label> <content>
  local r="$W/shape-$RANDOM$RANDOM" b
  b="$(mk_repo "$r")"
  printf 'see %s here\n' "$2" > "$r/doc.md"
  commit_all "$r"
  run bash "$LC" --base "$b" "$r"
  assert_rc "$1 exits 1" 1
  assert_contains "$1 names the file and line" "leak: doc.md:1:" "$OUT"
}
check_shape "a macOS home path"     "/Use""rs/alice/projects/app"
check_shape "a projects-folder path" "~/pro""jects/app"
check_shape "a Desktop path"        "~/Desk""top/evidence"
check_shape "a project-dir key"     "-Use""rs-alice-projects-app"
check_shape "a UUID"                "49933d53-1a2b-4c3d-8e9f-""0a1b2c3d4e5f"
check_shape "a personal email"      "alice@gm""ail.com"

R="$W/count"; BASE="$(mk_repo "$R")"
printf '%s\n%s\n' "/Use""rs/a" "bob@outl""ook.com" > "$R/two.md"
commit_all "$R"
run bash "$LC" --base "$BASE" "$R"
assert_contains "the summary counts every leak" "2 leak(s)" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[3] Commits after the base"
R="$W/author"; BASE="$(mk_repo "$R")"
printf 'x\n' > "$R/a.txt"; git -C "$R" add -A
GIT_AUTHOR_EMAIL="$UP_EMAIL" git -C "$R" commit -qm "personal author"
run bash "$LC" --base "$BASE" "$R"
assert_rc "a personal author address exits 1" 1
assert_contains "names the author" "author email is not a noreply address" "$OUT"
assert_missing "the committer was noreply" "committer email" "$OUT"

R="$W/committer"; BASE="$(mk_repo "$R")"
printf 'x\n' > "$R/a.txt"; git -C "$R" add -A
GIT_COMMITTER_EMAIL="$UP_EMAIL" git -C "$R" commit -qm "personal committer"
run bash "$LC" --base "$BASE" "$R"
assert_rc "a personal committer address exits 1" 1
assert_contains "names the committer" "committer email is not a noreply address" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[4] Usage errors"
R="$W/usage"; BASE="$(mk_repo "$R")"
run bash "$LC" --base 0123456789012345678901234567890123456789 "$R"
assert_rc "a base not in the history exits 2" 2
assert_contains "says the base is missing" "is not in the history" "$OUT"
mkdir -p "$W/plain"
run bash "$LC" --base "$BASE" "$W/plain"
assert_rc "not a repository exits 2" 2
run bash "$LC" --bogus
assert_rc "an unknown option exits 2" 2

# ---------------------------------------------------------------------------
echo
echo "[5] The check does not flag itself"
R="$W/self"; BASE="$(mk_repo "$R")"
mkdir -p "$R/tools" "$R/tests"
cp "$LC" "$R/tools/leak-check.sh"
cp "$REPO_ROOT/tests/leak-check.test.sh" "$R/tests/leak-check.test.sh"
commit_all "$R"
run bash "$LC" --base "$BASE" "$R"
assert_rc "leak-check.sh and its test pass their own check" 0
if command -v zsh >/dev/null 2>&1; then
  OUT="$(zsh -c "bash '$LC' --base '$BASE' '$R'" 2>&1)"; RC=$?
  assert_rc "called from zsh, still clean" 0
else
  ok "zsh not installed — zsh check skipped"
fi

# ---------------------------------------------------------------------------
echo
echo "----------------------------------------"
printf 'Results: %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  exit 1
fi
echo "All fixture scenarios passed."
exit 0
