#!/usr/bin/env bash
# repo-state.sh — evaluate the COMPLETE working-tree state relative to a baseline commit.
#
# Why this exists
# ---------------
# Relay's final audit and per-phase cleanliness checks must see every change an
# autonomous run produced — whether it was committed or left sitting in the working
# tree. A plain `git diff <baseline>..HEAD` only compares two commits, so a run that
# never commits looks completely empty: deliverables read as "missing" and cleanliness
# greps read as "0 debug prints" no matter what was actually written. This helper is the
# single source of truth for the corrected comparison (see
# references/repo-state-comparison.md).
#
# The strategy (complete state vs baseline)
# -----------------------------------------
#   tracked changes (committed + staged + unstaged + deleted)
#       = git diff <baseline>            # single revision, NOT <baseline>..HEAD
#         -> diffs the WORKING TREE against the baseline commit, so it already
#            includes staged, unstaged, and any post-baseline commits.
#   untracked deliverables (new files never `git add`-ed)
#       = git ls-files --others --exclude-standard
#         -> untracked files are diff-invisible, so they are detected separately.
#   invalid / unavailable baseline ("no-git" sentinel, bogus sha, or non-repo)
#       -> degrade gracefully to a filesystem existence test.
#
# This script never mutates the repository or the index. All output is for the audit
# transcript. Paths containing spaces are handled (callers must quote the path argument).
#
# Usage:
#   repo-state.sh deliverable   <baseline> <path>
#       -> "present — <evidence>" (exit 0) | "missing" (exit 1)
#          A glob <path> matches as git's default pathspec or as `:(glob)` (so `**/` works).
#   repo-state.sh changed-files <baseline>
#       -> newline-delimited paths changed since baseline (tracked + untracked + deleted)
#   repo-state.sh added-lines   <baseline>
#       -> every added/new line since baseline: tracked-diff '+' lines plus the full body
#          of each untracked file (every line is "new"). Feed to grep for cleanliness counts.

set -uo pipefail

in_git_repo() { git rev-parse --is-inside-work-tree >/dev/null 2>&1; }

# baseline_ok <ref> — true only when <ref> resolves to a real commit in this repo.
baseline_ok() {
  local b="${1:-}"
  [ -n "$b" ] || return 1
  [ "$b" = "no-git" ] && return 1
  git rev-parse --verify --quiet "${b}^{commit}" >/dev/null 2>&1
}

# is_glob <path> — true when <path> is a glob (and not already a `:(magic)` pathspec).
is_glob() {
  case "$1" in :*) return 1 ;; *[*?[]*) return 0 ;; esac
  return 1
}

# on_disk <path> — the path exists, or (a glob) some file under . matches it. Bash 3.2 has no
# globstar, so a glob goes to find, whose `*` already crosses `/`: `**/` collapses to `*`.
on_disk() {
  local p="$1" pat
  if ! is_glob "$p"; then [ -e "$p" ]; return; fi
  pat="./${p#./}"
  while :; do
    case "$pat" in *'**/'*) pat="${pat%%\*\*/*}*${pat#*\*\*/}" ;; *) break ;; esac
  done
  pat="${pat//\*\*/*}"
  [ -n "$(find . -name .git -prune -o -path "$pat" -print 2>/dev/null | head -1)" ]
}

cmd_deliverable() {
  local baseline="$1" path="$2"
  # A glob is tried as git reads it by default (`*` crosses `/`) and as a `:(glob)` pathspec
  # (`**/` is zero or more directories; `*` stops at `/`). Either match counts: `:(glob)` alone
  # would turn `src/*.ts` with only nested files into "missing"; the default alone misses
  # `test/**/*.ts` with files directly under test/.
  local specs=("$path")
  is_glob "$path" && specs+=(":(glob)$path")

  if in_git_repo && baseline_ok "$baseline"; then
    # 1) tracked change vs baseline: committed, staged, unstaged, or deleted.
    local stat="" untracked="" tracked="" s
    for s in "${specs[@]}"; do
      stat="$(git diff --stat "$baseline" -- "$s" 2>/dev/null || true)"
      [ -n "$stat" ] && break
    done
    if [ -n "$stat" ]; then
      printf 'present — changed vs baseline (%s)\n' \
        "$(printf '%s' "$stat" | tail -1 | sed 's/^[[:space:]]*//')"
      return 0
    fi
    # 2) brand-new untracked deliverable (diff-invisible).
    for s in "${specs[@]}"; do
      untracked="$(git ls-files --others --exclude-standard -- "$s" 2>/dev/null | head -1 || true)"
      [ -n "$untracked" ] && break
    done
    if [ -n "$untracked" ]; then
      printf 'present — untracked new file (%s)\n' "$untracked"
      return 0
    fi
    # 3) backward-compat net: the path exists / is tracked but is unchanged this run.
    for s in "${specs[@]}"; do
      tracked="$(git ls-files -- "$s" 2>/dev/null | head -1 || true)"
      [ -n "$tracked" ] && break
    done
    if on_disk "$path" || [ -n "$tracked" ]; then
      printf 'present — exists, unchanged since baseline\n'
      return 0
    fi
    printf 'missing\n'
    return 1
  fi

  # Fallback: baseline missing/invalid or not a git repo — existence only.
  if on_disk "$path"; then
    printf 'present — exists on disk (baseline unavailable)\n'
    return 0
  fi
  if in_git_repo; then
    local s
    for s in "${specs[@]}"; do
      if [ -n "$(git ls-files -- "$s" 2>/dev/null | head -1 || true)" ]; then
        printf 'present — tracked (baseline unavailable)\n'
        return 0
      fi
    done
  fi
  printf 'missing\n'
  return 1
}

cmd_changed_files() {
  local baseline="$1"
  if in_git_repo && baseline_ok "$baseline"; then
    {
      git diff --name-only "$baseline" 2>/dev/null || true   # modified/staged/deleted
      git ls-files --others --exclude-standard 2>/dev/null || true   # untracked
    } | LC_ALL=C sort -u | sed '/^$/d'
  fi
  return 0
}

cmd_added_lines() {
  local baseline="$1"
  if in_git_repo && baseline_ok "$baseline"; then
    # Added lines from tracked changes (strip the leading '+', skip the '+++' file header).
    git diff "$baseline" 2>/dev/null | grep '^+' | grep -v '^+++' | sed 's/^+//' || true
    # Full body of every untracked file — each line counts as newly added.
    # Skip binaries: added-lines feeds text greps, so binary bodies are only noise.
    git ls-files --others --exclude-standard -z 2>/dev/null | while IFS= read -r -d '' f; do
      [ -f "$f" ] && LC_ALL=C grep -Iq . "$f" 2>/dev/null && cat -- "$f"
    done
  fi
  return 0
}

sub="${1:-}"
shift 2>/dev/null || true
case "$sub" in
  deliverable)
    [ "$#" -ge 2 ] || { echo "usage: repo-state.sh deliverable <baseline> <path>" >&2; exit 2; }
    cmd_deliverable "$1" "$2"
    ;;
  changed-files)
    [ "$#" -ge 1 ] || { echo "usage: repo-state.sh changed-files <baseline>" >&2; exit 2; }
    cmd_changed_files "$1"
    ;;
  added-lines)
    [ "$#" -ge 1 ] || { echo "usage: repo-state.sh added-lines <baseline>" >&2; exit 2; }
    cmd_added_lines "$1"
    ;;
  ""|-h|--help|help)
    cat >&2 <<'EOF'
repo-state.sh — evaluate the complete working-tree state vs a baseline commit.

  repo-state.sh deliverable   <baseline> <path>   present|missing (+ evidence), exit 0|1
  repo-state.sh changed-files <baseline>          paths changed since baseline
  repo-state.sh added-lines   <baseline>          added/new lines since baseline

<baseline> is a commit sha (or "no-git" / any invalid ref to force the filesystem
fallback). Compares the working tree — not just HEAD — so uncommitted, staged, and
untracked work is included. See references/repo-state-comparison.md.
EOF
    exit 2
    ;;
  *)
    echo "repo-state.sh: unknown subcommand '$sub' (try deliverable|changed-files|added-lines)" >&2
    exit 2
    ;;
esac
