#!/usr/bin/env bash
# design-dir.sh — choose where this run's design package goes (Stage 1 / 2.7)
#
# Usage: design-dir.sh <feature-slug>        (run from the repository root)
#
# Why: the design stage assumed one package at design/. A project that already has one — the
# app an earlier run built, with design/HANDOFF.md and design/screens/ committed — gets new
# screens added by a later run, and that run's package must not land on top of the old one
# (prepare-design.sh only unpacks into a folder with no HANDOFF.md, so the export was committed
# raw and the old package verified instead). So:
#   - no package under design/ yet  → design            (greenfield, unchanged)
#   - a package at design/ or design/<x>/ → design/<feature-slug>, beside it; the earlier
#     package stays untouched as the record of the original screens
#
# Prints `Design dir: <path>`, then one `existing: <dir> — <n> screens @ <sha>` line per earlier
# package (<sha> is `uncommitted` or `no-git` when git cannot say). The planner records the path
# as STATE.md's `**Design dir:**` and passes it to every prepare-design.sh / check-design.sh call.
# A glob loop, so it lives in a script, not a SKILL.md bash block (zsh: an unmatched glob is an
# error).
#
# Exits 0 with a folder, 1 when design/<feature-slug> already holds a package, 2 on a usage
# error (missing or malformed slug: lowercase letters, digits and single hyphens, at most 40
# characters). Read-only. Planner-only (not copied at Stage 7).

set -u

usage() { echo "usage: design-dir.sh <feature-slug>   (lowercase letters, digits, single hyphens; at most 40 characters)" >&2; exit 2; }

[[ $# -eq 1 ]] || usage
slug="$1"
[[ "$slug" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ && ${#slug} -le 40 ]] || usage

# screens <handoff> — the body rows of the first table under `## Approved screens`
screens() {
  awk '
    /^##[[:space:]]/ && !/^###/ { on = (tolower($0) ~ /^##[[:space:]]+approved screens[[:space:]]*$/); seen = 0; next }
    on && /^[[:space:]]*\|/ {
      if (seen++ == 0 || $0 ~ /^[[:space:]]*\|[[:space:]:|-]+\|?[[:space:]]*$/) next
      n++
    }
    END { print n + 0 }' "$1"
}

# sha <dir> — the last commit that touched <dir>, or why there is none. The package at design/
# itself leaves out its sibling packages' folders (design/<x>/), and the folder this run is about
# to use, so a newer package or a fresh export does not make the old one read as changed.
sha() {
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then echo "no-git"; return; fi
  local spec=("$1") d s
  if [[ "$1" == design ]]; then
    for d in "${existing[@]}" "$target"; do [[ "$d" == design ]] || spec+=(":!$d"); done
  fi
  if [[ -n "$(git status --porcelain -- "${spec[@]}" 2>/dev/null)" ]]; then echo "uncommitted"; return; fi
  s="$(git log -1 --format=%h -- "${spec[@]}" 2>/dev/null)"
  echo "${s:-uncommitted}"
}

existing=()
for h in design/HANDOFF.md design/*/HANDOFF.md; do
  [[ -f "$h" ]] || continue
  existing+=("$(dirname "$h")")
done

if [[ ${#existing[@]} -eq 0 ]]; then
  echo "Design dir: design"
  exit 0
fi

target="design/$slug"
if [[ -f "$target/HANDOFF.md" ]]; then
  echo "design-dir.sh: $target already holds a design package — pick another feature name" >&2
  exit 1
fi

echo "Design dir: $target"
for d in "${existing[@]}"; do
  echo "existing: $d — $(screens "$d/HANDOFF.md") screens @ $(sha "$d")"
done
exit 0
