#!/usr/bin/env bash
# prepare-design.sh — settle the returned design package in <design-dir> and commit it (Stage 2.7d)
#
# Usage: prepare-design.sh <design-dir>
#
# Why this exists (fix 30): the design stage used to end with the owner running
# `git add design && git commit` by hand — friction at the one moment they just want to get back
# to planning. design/ must be committed (repo-state.sh counts untracked files as run changes, and
# SPEC.md records the package's sha for the audit), so the planner commits it. The planner
# creates design/ at Stage 2.7b and the owner puts the export there; this never searches anywhere
# else (~/Downloads may hold several exports, and a sandbox may not reach it).
#
# Touches only <design-dir>:
#   1. No HANDOFF.md, and exactly one .zip → unzip it in place (then delete the zip).
#      No HANDOFF.md, and exactly one subfolder holding one (the export's wrapper folder, e.g.
#      design_handoff_tunez/) → move that folder's contents up. The same wrapper rule applies
#      inside the zip. Anything ambiguous — two zips, two wrapper folders, a zip and a wrapper, or
#      a name that already exists — is an ❌ and nothing is changed.
#   2. Deletes .DS_Store files and __MACOSX folders.
#   3. `git add -A -- <dir>`, then `git commit -- <dir>`: the commit holds only <dir>, so anything
#      else the owner has staged stays staged and uncommitted.
#
# Prints one line: `design: committed <sha> (<n> files changed)`, `design: already committed @
# <sha>`, or a ⚠ when there is no git. Exits 0 when the package is in place (committed, or no
# git), 1 on a problem (❌ says what), 2 on a usage error. check-design.sh verifies the contents.

set -uo pipefail

[[ $# -eq 1 && -n "$1" ]] || { echo "usage: prepare-design.sh <design-dir>" >&2; exit 2; }
dir="${1%/}"
[[ -d "$dir" ]] || { echo "❌ no $dir/ — create it and put the design export's contents there (HANDOFF.md, screens/)"; exit 1; }

# wrappers <root> — subfolders of <root> (not __MACOSX) with a HANDOFF.md at their top
wrappers() {
  local d
  for d in "$1"/*/; do
    [[ -d "$d" && "$(basename "$d")" != __MACOSX && -f "$d/HANDOFF.md" ]] && printf '%s\n' "${d%/}"
  done
}

# lift <from> <to> — move every entry of <from> (dotfiles included) into <to>; refuse on a clash
lift() {
  local from="$1" to="$2" e clash=""
  for e in "$from"/* "$from"/.[!.]*; do
    [[ -e "$e" ]] || continue
    [[ "$(basename "$e")" == __MACOSX ]] && continue
    [[ -e "$to/$(basename "$e")" ]] && clash="$clash $(basename "$e")"
  done
  [[ -z "$clash" ]] || { echo "❌ $to/ already has$clash — remove it (or the export) and say design ready again"; return 1; }
  for e in "$from"/* "$from"/.[!.]*; do
    [[ -e "$e" ]] || continue
    [[ "$(basename "$e")" == __MACOSX ]] && continue
    mv "$e" "$to/"
  done
}

unzip_to() {  # unzip_to <zip> <dest>
  if command -v unzip >/dev/null 2>&1; then
    unzip -q "$1" -d "$2"
  else
    python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$1" "$2"
  fi
}

if [[ ! -f "$dir/HANDOFF.md" ]]; then
  zips=(); for z in "$dir"/*.zip; do [[ -f "$z" ]] && zips+=("$z"); done
  wraps=(); while IFS= read -r w; do [[ -n "$w" ]] && wraps+=("$w"); done < <(wrappers "$dir")
  nz=${#zips[@]}; nw=${#wraps[@]}
  if [[ $((nz + nw)) -gt 1 ]]; then
    found=""; for x in ${zips[@]+"${zips[@]}"} ${wraps[@]+"${wraps[@]}"}; do found="$found $(basename "$x")"; done
    echo "❌ $dir/ has no HANDOFF.md and more than one candidate:$found — leave just the one export and say design ready again"
    exit 1
  elif [[ $nz -eq 1 ]]; then
    tmp="$(mktemp -d)"
    unzip_to "${zips[0]}" "$tmp" || { rm -rf "$tmp"; echo "❌ could not unzip $(basename "${zips[0]}")"; exit 1; }
    src="$tmp"
    if [[ ! -f "$tmp/HANDOFF.md" ]]; then
      inner=(); while IFS= read -r w; do [[ -n "$w" ]] && inner+=("$w"); done < <(wrappers "$tmp")
      if [[ ${#inner[@]} -ne 1 ]]; then
        rm -rf "$tmp"; echo "❌ $(basename "${zips[0]}") has no HANDOFF.md at its top or in one folder — is it the design export?"; exit 1
      fi
      src="${inner[0]}"
    fi
    lift "$src" "$dir" || { rm -rf "$tmp"; exit 1; }
    rm -rf "$tmp"; rm -f "${zips[0]}"
    echo "unzipped $(basename "${zips[0]}") into $dir/"
  elif [[ $nw -eq 1 ]]; then
    lift "${wraps[0]}" "$dir" || exit 1
    rm -rf "${wraps[0]}"   # lift moved everything but __MACOSX
    echo "moved $(basename "${wraps[0]}")/ up into $dir/"
  else
    echo "❌ no HANDOFF.md in $dir/ — put the design export's contents here (HANDOFF.md, screens/, …), or its .zip"
    exit 1
  fi
fi

find "$dir" -name .DS_Store -type f -delete 2>/dev/null
find "$dir" -name __MACOSX -type d -prune -exec rm -rf {} + 2>/dev/null

if ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "⚠  not a git repository — the design package is in place but not committed"
  exit 0
fi
top="$(git -C "$dir" rev-parse --show-toplevel)"
rel="$(cd "$dir" && pwd -P)"; rel="${rel#"$(cd "$top" && pwd -P)"/}"

git -C "$top" add -A -- "$rel" || { echo "❌ git add failed for $rel/"; exit 1; }
if git -C "$top" diff --cached --quiet -- "$rel"; then
  echo "design: already committed @ $(git -C "$top" log -1 --format=%h -- "$rel" 2>/dev/null)"
  exit 0
fi
n="$(git -C "$top" diff --cached --name-only -- "$rel" | grep -c .)"
if ! out="$(git -C "$top" commit -q -m "design: handoff" -- "$rel" 2>&1)"; then
  echo "❌ git commit failed: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
  exit 1
fi
echo "design: committed $(git -C "$top" rev-parse --short HEAD) ($n files changed)"
exit 0
