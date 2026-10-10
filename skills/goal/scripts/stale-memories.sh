#!/usr/bin/env bash
# stale-memories.sh — find project memories that point at a Relay run which no longer exists
# (Stage 0, fix 17).
#
# Usage: stale-memories.sh <memory-dir>
#
# A memory with a `relay_run:` key, or any `.relay/<run-id>` path in its body, describes a plan
# or build whose artifacts are gone once that directory is deleted. The planner must not apply
# it; it lists each one in the intake as `Stale (run gone): <name>`. Run paths are resolved
# against the current directory (the repo root, where Stage 0 runs).
#
# Why a script (fix 23): the loop was inline in SKILL.md, and under zsh (the Bash tool's shell
# on macOS) an unmatched `"$MEM_DIR"/*.md` is an error rather than an empty loop.
#
# Prints one `STALE <name> (run gone: <path>)` line per stale memory, nothing otherwise.
# MEMORY.md (the index) is skipped. Always exits 0; a missing directory has no memories.
# Read-only. Planner-only (not copied at Stage 7).

set -u

dir="${1:-}"
[[ -n "$dir" && -d "$dir" ]] || exit 0
for m in "${dir%/}"/*.md; do
  [[ -f "$m" && "$(basename "$m")" != MEMORY.md ]] || continue
  for r in $(grep -oE '\.relay/[A-Za-z0-9._-]+' "$m" | sort -u); do
    [[ -d "$r" ]] || { echo "STALE $(basename "$m" .md) (run gone: $r)"; break; }
  done
done
exit 0
