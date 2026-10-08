#!/usr/bin/env bash
# claim-run.sh — atomically claim a unique per-run artifact directory under .relay/.
#
# Why this exists
# ---------------
# Two `/relay:goal` runs started in the same working tree both defaulted to a flat
# `.relay/` directory and clobbered each other's STATE.md / ROADMAP.md / phases/.
# The fix: every run claims its OWN namespaced subdirectory. `mktemp -d` creates the
# directory and claims the name in a single atomic step, failing if it already exists,
# so two simultaneous callers can never receive the same path. That removes the
# check-then-write race that caused the overwrite — even when both runs slugify to the
# same prefix, the random suffix keeps them distinct.
#
# This namespacing protects the PLANNING artifacts. It does NOT make two `/goal`
# executions in the same working tree safe — they still edit the same source files.
# For true parallel execution, use a separate `git worktree` per task.
#
# Usage:
#   claim-run.sh "<task description>"   -> prints the claimed run-root path on stdout,
#                                          e.g.  .relay/add-dark-mode-Ab3Kx9
#
# Nothing but the path is printed, so callers can capture it directly:
#   RELAY_ROOT="$(bash claim-run.sh "$ARGUMENTS")"
#
# Honours $RELAY_BASE (default ".relay") as the parent directory.
#
# Inside a git work tree, a base inside it is also added to $GIT_DIR/info/exclude (once,
# local-only, never committed) so run artifacts stay out of repo-state.sh's untracked-file
# checks and out of graphify's scan. Best effort: never fails the claim, never prints.

set -u

base="${RELAY_BASE:-.relay}"

# Slugify the task for a human-readable prefix: lowercase, every non-[a-z0-9] run becomes
# a single '-', trim leading/trailing '-', cap at 40 chars (then re-trim a dangling '-').
# Purely cosmetic — uniqueness comes from mktemp's suffix, not the slug.
slug="$(printf '%s' "${1:-}" \
  | tr '[:upper:]' '[:lower:]' \
  | tr -c 'a-z0-9' '-' \
  | sed -E 's/-+/-/g; s/^-//; s/-$//' \
  | cut -c1-40 \
  | sed -E 's/-$//')"
[ -n "$slug" ] || slug="run"

mkdir -p "$base" || { echo "claim-run.sh: cannot create base dir '$base'" >&2; exit 1; }

# mktemp -d is the load-bearing primitive: atomic create-or-fail under $base.
runroot="$(mktemp -d "$base/${slug}-XXXXXX" 2>/dev/null)" || {
  echo "claim-run.sh: mktemp failed to claim a run dir under '$base'" >&2; exit 1; }

# Keep run artifacts out of the repo's view. Specs, evidence files, logs, and graph builds
# under the base are untracked files: repo-state.sh would feed their full bodies to the
# cleanliness greps (an evidence file quoting a matched console.log counts as a new debug
# print), and graphify would scan them. $GIT_DIR/info/exclude is honoured by both.
# Concurrent claims may append the same line twice; a duplicate pattern is harmless.
# The pattern is the base's path from the top of the work tree, however $RELAY_BASE was given
# (relative, from a subdirectory, or absolute); a base outside the work tree needs none.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  top="$(git rev-parse --show-toplevel 2>/dev/null)"
  top="$(cd "$top" 2>/dev/null && pwd -P)"; abs="$(cd "$base" 2>/dev/null && pwd -P)"
  case "$abs" in
    "$top"/?*)
      exclude_file="$(git rev-parse --git-path info/exclude 2>/dev/null)"
      pattern="/${abs#"$top"/}/"
      if [ -n "$exclude_file" ] && mkdir -p "$(dirname "$exclude_file")" 2>/dev/null; then
        if ! grep -qxF -- "$pattern" "$exclude_file" 2>/dev/null; then
          # Don't glue the pattern onto a last line that lacks a trailing newline.
          if [ -s "$exclude_file" ] && [ -n "$(tail -c 1 "$exclude_file" 2>/dev/null)" ]; then
            printf '\n' >> "$exclude_file" 2>/dev/null
          fi
          printf '%s\n' "$pattern" >> "$exclude_file" 2>/dev/null
        fi
      fi
      ;;
  esac
fi

printf '%s\n' "$runroot"
