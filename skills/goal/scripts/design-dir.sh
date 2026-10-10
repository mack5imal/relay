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
# Then one `elsewhere: <path> — <n> images, <m> design docs` line per design that is not a Relay
# package — most apps that predate Relay keep theirs somewhere else (a design-tool export in
# `design_handoff_<app>/`, a `docs/mockups/` folder, a DESIGN.md with a token table). Left
# unnoticed, the run briefs the designer for a fresh look and the design checks read that
# material as the app's own code (a colour listed in an old README is "hard-coded outside the
# theme"). A candidate is the shallowest folder, at most three levels down, whose name says design
# (design, handoff, mockup, wireframe, figma, sketch, style guide, ui kit) and that holds a picture
# (png, jpg, jpeg, webp, pdf, fig, sketch — not svg: icon folders are app assets) or a markdown file
# with a "Design tokens" heading; a markdown file with that heading anywhere else is listed on its
# own. Tracked and untracked files only — gitignored ones, design/, .relay/, .git/ and
# node_modules/ never count. These are proposals: the owner confirms at Stage 1 which one is the
# app's current design, and the checks skip it (check-design.sh --ignore).
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

# files — every file a design could be in, relative to here: tracked + untracked, not ignored
files() {
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -c core.quotePath=false ls-files -co --exclude-standard 2>/dev/null
  else
    find . -type d \( -name .git -o -name node_modules \) -prune -o -type f -print 2>/dev/null | sed 's#^\./##'
  fi
}

# elsewhere — one `<path>\t<images>\t<docs>` line per design found outside design/
elsewhere() {
  local list docs
  list="$(mktemp)"; docs="$(mktemp)"
  files | awk '!/^(design|\.relay|\.git)\// && !/(^|\/)node_modules\//' > "$list"
  # markdown files with a "Design tokens" heading (any level) — read whole, never piped into -q
  grep -iE '\.(md|markdown)$' "$list" | while IFS= read -r f; do
    [[ -f "$f" ]] && grep -iE '^#{1,6}[[:space:]]+design tokens([[:space:]]|$)' "$f" >/dev/null 2>&1 && printf '%s\n' "$f"
  done > "$docs"
  awk -v docs="$docs" '
    BEGIN { while ((getline d < docs) > 0) tok[d] = 1 }
    {
      f = $0; n = split(f, part, "/"); cand = ""
      for (i = 1; i < n && i <= 3; i++) {
        if (tolower(part[i]) ~ /design|handoff|mockup|wireframe|figma|sketch|style-?guide|ui-?kit/) {
          cand = part[1]; for (j = 2; j <= i; j++) cand = cand "/" part[j]; break
        }
      }
      img = (tolower(f) ~ /\.(png|jpe?g|webp|pdf|fig|sketch)$/)
      if (cand == "" && (f in tok)) cand = f
      if (cand == "") next
      if (!(cand in seen)) { seen[cand] = 1; order[++k] = cand }
      if (img) imgs[cand]++
      if (f in tok) dcs[cand]++
    }
    END {
      for (i = 1; i <= k; i++) { c = order[i]; if (imgs[c] + dcs[c] > 0) printf "%s\t%d\t%d\n", c, imgs[c], dcs[c] }
    }' "$list" | sort
  rm -f "$list" "$docs"
}

plural() { [[ "$1" -eq 1 ]] && printf '%s %s' "$1" "$2" || printf '%s %ss' "$1" "$2"; }

if [[ ${#existing[@]} -eq 0 ]]; then
  echo "Design dir: design"
else
  target="design/$slug"
  if [[ -f "$target/HANDOFF.md" ]]; then
    echo "design-dir.sh: $target already holds a design package — pick another feature name" >&2
    exit 1
  fi
  echo "Design dir: $target"
  for d in "${existing[@]}"; do
    echo "existing: $d — $(screens "$d/HANDOFF.md") screens @ $(sha "$d")"
  done
fi
while IFS=$'\t' read -r p i m; do
  [[ -n "$p" ]] && echo "elsewhere: $p — $(plural "$i" image), $(plural "$m" "design doc")"
done < <(elsewhere)
exit 0
