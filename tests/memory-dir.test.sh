#!/usr/bin/env bash
# memory-dir.test.sh — fixture tests for scripts/memory-dir.sh
#
# Proves the Stage 0 memory-dir detection (commit 14 fix): a repository's main checkout, its
# subdirectories and its linked worktrees all resolve to one directory, as Claude Code keeps one
# auto-memory directory per repository; outside git the working directory is used; every
# non-alphanumeric character becomes `-`; the fallbacks keep their order; and the derived path
# is printed when nothing exists. Uses a fake $HOME and real temporary repositories.
#
# Repo-only (not shipped in the plugin payload). Run from anywhere:
#   bash tests/memory-dir.test.sh
# Exits 0 if every assertion passes, 1 otherwise.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MD="$REPO_ROOT/skills/goal/scripts/memory-dir.sh"
[ -f "$MD" ] || { echo "FATAL: missing $MD" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git not installed" >&2; exit 1; }

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  \033[31m✗\033[0m %s\n      %s\n' "$1" "$2"; }

assert_rc() { if [ "$2" = "$RC" ]; then ok "$1"; else no "$1" "expected exit $2 got $RC (out: $OUT)"; fi; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "expected [$2] got [$3]"; fi; }

# run <dir> [args…] — memory-dir.sh from <dir> with the fake HOME
run() { local d="$1"; shift; OUT="$(cd "$d" && HOME="$H" bash "$MD" "$@" 2>&1)"; RC=$?; }

W="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$W"' EXIT
H="$W/home"
mkdir -p "$H"

# name <path> — the <project> name Claude Code derives
name() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '-'; }

git init -q "$W/app"
git -C "$W/app" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$W/app/src/deep"
git -C "$W/app" worktree add -q --detach "$W/app-wt" 2>/dev/null
APP_MEM="$H/.claude/projects/$(name "$W/app")/memory"

# ---------------------------------------------------------------------------
echo
echo "[1] Nothing exists yet: the derived path is printed"
run "$W/app"
assert_rc "exits 0" 0
assert_eq "main checkout → its derived dir" "$APP_MEM" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[2] One directory per repository"
mkdir -p "$APP_MEM"
run "$W/app"
assert_eq "main checkout" "$APP_MEM" "$OUT"
run "$W/app/src/deep"
assert_eq "a subdirectory → the repository's dir, not its own" "$APP_MEM" "$OUT"
run "$W/app-wt"
assert_eq "a linked worktree → the main checkout's dir (the commit 14 bug)" "$APP_MEM" "$OUT"
WT_OLD="$H/.claude/projects/$(name "$W/app-wt")/memory"
[ "$OUT" != "$WT_OLD" ] && ok "not the worktree's own pwd-derived dir" || no "not the worktree's own pwd-derived dir" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[3] Outside git, and names with other characters"
mkdir -p "$W/plain dir/my.proj_x"
run "$W/plain dir/my.proj_x"
assert_eq "outside git → the working directory, every non-alphanumeric → -" \
  "$H/.claude/projects/$(name "$W/plain dir/my.proj_x")/memory" "$OUT"
case "$OUT" in *" "*|*.proj*|*_x*) no "no space, dot or underscore survives" "$OUT";; *) ok "no space, dot or underscore survives";; esac

# ---------------------------------------------------------------------------
echo
echo "[4] Fallbacks, in order, only when the derived dir is missing"
mkdir -p "$W/other/r/memory" "$W/other/.claude/memory"
run "$W/other" "$W/other/r/"
assert_eq "\$PWD/.claude/memory before the run root" "$W/other/.claude/memory" "$OUT"
rm -rf "$W/other/.claude"
run "$W/other" "$W/other/r/"
assert_eq "<run-root>/memory last (trailing slash ok)" "$W/other/r/memory" "$OUT"
mkdir -p "$H/.claude/memory"
run "$W/other" "$W/other/r"
assert_eq "\$HOME/.claude/memory before \$PWD and the run root" "$H/.claude/memory" "$OUT"
run "$W/app-wt" "$W/other/r"
assert_eq "an existing derived dir wins over every fallback" "$APP_MEM" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[5] Called from zsh (the Bash tool's shell)"
if command -v zsh >/dev/null 2>&1; then
  OUT="$(cd "$W/app-wt" && HOME="$H" zsh -c "bash '$MD'" 2>&1)"; RC=$?
  assert_rc "exits 0 under zsh" 0
  assert_eq "same answer under zsh" "$APP_MEM" "$OUT"
else
  ok "zsh not installed — zsh check skipped"
fi

echo
echo "----------------------------------------"
printf 'Results: %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  exit 1
fi
echo "All fixture scenarios passed."
exit 0
