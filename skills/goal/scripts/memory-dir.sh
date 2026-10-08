#!/usr/bin/env bash
# memory-dir.sh — print the memory directory a run reads and writes (Stage 0).
#
# Usage: memory-dir.sh [<run-root>]
#
# Claude Code keeps one auto-memory directory per git repository, shared by all its worktrees and
# subdirectories (code.claude.com/docs/en/memory): ~/.claude/projects/<project>/memory, where
# <project> is the repository's main checkout with every non-alphanumeric character turned into
# `-` (/home/me/projects/app → -home-me-projects-app). Outside a git repository it is the
# working directory.
#
# Why a script: SKILL.md used to derive <project> from `pwd`, which is wrong in a linked worktree
# (the commit 14 run planned in contextmeter-short, whose derived dir did not exist, while the
# memories lived under the main checkout's) and in any subdirectory of a repository.
#
# The derived directory comes first; $HOME/.claude/memory, $PWD/.claude/memory and
# <run-root>/memory are fallbacks, in that order. When none exists the derived path is printed
# anyway — it is recorded in STATE.md as `Memory dir:` and created on first write.
#
# Prints one path. Always exits 0. Read-only. Planner-only (not copied at Stage 7).

set -u

runroot="${1:-}"
runroot="${runroot%/}"

# The main checkout: the parent of the common git dir (shared by every worktree). A common dir
# not named .git (a submodule's .git/modules/<name>, a bare repository) falls back to this
# checkout's top level.
base=""
if common="$(git rev-parse --git-common-dir 2>/dev/null)" && [[ -n "$common" ]]; then
  common="$(cd "$common" 2>/dev/null && pwd -P)"
  if [[ "$common" == */.git ]]; then
    base="${common%/.git}"
  else
    base="$(git rev-parse --show-toplevel 2>/dev/null)"
  fi
fi
[[ -n "$base" ]] || base="$(pwd)"

project="$(printf '%s' "$base" | tr -c 'A-Za-z0-9' '-')"
derived="$HOME/.claude/projects/$project/memory"

for cand in "$derived" "$HOME/.claude/memory" "$PWD/.claude/memory" ${runroot:+"$runroot/memory"}; do
  if [[ -d "$cand" ]]; then
    printf '%s\n' "$cand"
    exit 0
  fi
done
printf '%s\n' "$derived"
exit 0
