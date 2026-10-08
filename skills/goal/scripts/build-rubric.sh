#!/usr/bin/env bash
# build-rubric.sh — compile every phase's acceptance criteria into one reviewable RUBRIC.md
#
# Usage: build-rubric.sh <run-root> [--out <file>]
#
# Why this exists: a run ends when every phase's acceptance criteria pass and the final audit
# re-verifies SPEC.md. The Stage 6 summary prints SPEC.md's criteria in full, but the phase-level
# criteria — 5–10 per phase, ~130 on a 14-phase plan — gate every phase and are re-checked by the
# audit, yet lived only in phases/phase-N.md where nobody reads them before dispatch. A criterion
# that is too strict hands the run off hours in; one that is too weak passes what the spec meant
# to fail. This compiles them into one file the owner can read at Stage 6, and flags the handful
# worth a human look:
#
#   human eye — screenshots, visual or manual checks, real devices: the audit will likely mark
#               these trust-prior-verify, i.e. it cannot re-check them itself
#   outside   — deploys, network, accounts, publishing: they depend on something not in the repo
#
# Deterministic: generated from the phase files, never hand-edited, re-run after every revision,
# so it cannot drift from what the subagents will actually be held to. Planner-only — it is not
# copied into the run at Stage 7 and nothing in the run reads it.
#
# Prints one summary line: rubric: <N> criteria across <M> phases, <K> flagged → <path>
# Exits 0 on success, 1 when a phase file is missing or has no criteria, 2 on a usage error.

set -uo pipefail

usage() { echo "usage: build-rubric.sh <run-root> [--out <file>]" >&2; exit 2; }

[[ $# -ge 1 ]] || usage
root="${1%/}"; shift
out="$root/RUBRIC.md"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) [[ $# -ge 2 ]] || usage; out="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -d "$root/phases" ]] || { echo "build-rubric.sh: no phases/ directory under $root" >&2; exit 1; }

shopt -s nullglob
files=("$root"/phases/phase-[0-9]*.md)
shopt -u nullglob
# Only the phase specs themselves: phase-N.md, not phase-N.brief.md / .evidence.md / .fix.md.
specs=()
for f in "${files[@]}"; do
  [[ "$(basename "$f")" =~ ^phase-[0-9]+\.md$ ]] && specs+=("$f")
done
[[ ${#specs[@]} -gt 0 ]] || { echo "build-rubric.sh: no phases/phase-N.md files under $root" >&2; exit 1; }

# The declared total comes from the headers ("Phase: 2 of 5"); every phase up to it must exist.
total="$(grep -h -m1 -E '^Phase:[[:space:]]*[0-9]+[[:space:]]+of[[:space:]]+[0-9]+' "${specs[@]}" \
  | sed -E 's/^Phase:[[:space:]]*[0-9]+[[:space:]]+of[[:space:]]+([0-9]+).*/\1/' | sort -n | tail -1)"
[[ -n "$total" ]] || total="${#specs[@]}"
missing=0
for ((n = 1; n <= total; n++)); do
  if [[ ! -f "$root/phases/phase-$n.md" ]]; then
    echo "build-rubric.sh: phase $n of $total has no spec file ($root/phases/phase-$n.md)" >&2
    missing=$((missing + 1))
  fi
done
(( missing == 0 )) || exit 1

tmp="$(mktemp)"; trap 'rm -f "$tmp" "$tmp".*' EXIT

# One pass per phase file. Emits tab-separated records:
#   P <n> <name> <serves> <commands>      — one per phase
#   C <n> <flag> <criterion>              — one per acceptance criterion (flag: "", human, outside)
extract() {
  awk -v n="$1" '
    function flag(t,   l) {
      l = tolower(t)
      if (l ~ /screenshot|visual|manual|looks right|looks good|by eye|real device|on (a|the|your) (real )?phone|subjective|\/browse/) return "human eye"
      # "(^|[^.a-z])" keeps `.vercel` (a gitignore entry) and `netlify.toml`-style paths from matching.
      # "publish" only as a registry release (commit 14: an "atomic publish" of a local file
      # matched), and "account" only as a word ("sidechain accounting" matched).
      if (l ~ /deploy|(^|[^.a-z])(vercel|netlify|heroku)([^.a-z]|$)|https?:\/\/|<prod-url>|network|whoami|(^|[^a-z])accounts?([^a-z]|$)|app store|git push|remote/) return "outside the repo"
      if (l ~ /(npm|pnpm|yarn|cargo|gem|poetry|dart|flutter) publish|twine upload|publish(es|ed|ing)? (it |the [a-z]+ )?(to|on) (npm|pypi|crates|the (app|play) store|testflight|a registry|the registry)/) return "outside the repo"
      return ""
    }
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    NR == 1 { name = ""; cmds_hdr = ""; sect = ""; serves = "" }
    /^Phase:[ \t]*[0-9]+/ && name == "" { s = $0; sub(/^Phase:[ \t]*[0-9]+[ \t]+of[ \t]+[0-9]+[ \t]*[—–-]?[ \t]*/, "", s); name = trim(s) }
    /^Mandatory commands:/ && cmds_hdr == "" { s = $0; sub(/^Mandatory commands:[ \t]*/, "", s); cmds_hdr = trim(s) }
    /^## / {
      h = tolower($0)
      sect = (h ~ /^## acceptance criteria/) ? "crit" : (h ~ /^## mandatory commands/) ? "cmd" : "other"
      next
    }
    {
      line = $0
      while (match(line, /S[0-9]+/)) { id = substr(line, RSTART, RLENGTH); if (!(id in seen)) { seen[id] = 1; order[++ns] = id }; line = substr(line, RSTART + RLENGTH) }
    }
    sect == "crit" && /^[ \t]*- / {
      c = $0; sub(/^[ \t]*- (\[[ xX]\] )?/, "", c); c = trim(c)
      if (c != "" && c !~ /\{\{/ && c != "...") { crit[++nc] = c }
    }
    sect == "cmd" && /^[ \t]*- / {
      c = $0; sub(/^[ \t]*- /, "", c); c = trim(c)
      if (c != "" && c !~ /\{\{/ && c != "...") { cmd = (cmd == "" ? c : cmd ", " c) }
    }
    END {
      # Numeric sort of the S-ids so "S2, S10" reads in order.
      for (i = 1; i <= ns; i++) for (j = i + 1; j <= ns; j++)
        if (substr(order[j], 2) + 0 < substr(order[i], 2) + 0) { t = order[i]; order[i] = order[j]; order[j] = t }
      for (i = 1; i <= ns; i++) serves = serves (i > 1 ? ", " : "") order[i]
      if (cmd == "") cmd = cmds_hdr
      printf "P\t%s\t%s\t%s\t%s\n", n, name, serves, cmd
      for (i = 1; i <= nc; i++) printf "C\t%s\t%s\t%s\n", n, flag(crit[i]), crit[i]
    }
  ' "$2"
}

empty=0
for ((n = 1; n <= total; n++)); do
  extract "$n" "$root/phases/phase-$n.md" >> "$tmp"
  if ! grep -q "^C	$n	" "$tmp"; then
    echo "build-rubric.sh: phase $n has no acceptance criteria ($root/phases/phase-$n.md)" >&2
    empty=$((empty + 1))
  fi
done
(( empty == 0 )) || exit 1

ncrit="$(grep -c '^C	' "$tmp")"
nflag="$(awk -F'\t' '$1 == "C" && $3 != ""' "$tmp" | wc -l | tr -d ' ')"
title="$(grep -m1 -E '^# ' "$root/ROADMAP.md" 2>/dev/null | sed -E 's/^# (Roadmap:[[:space:]]*)?//')"
[[ -n "$title" ]] || title="$(basename "$root")"

{
  echo "# Rubric — $title"
  echo
  echo "Generated by \`build-rubric.sh\` from \`phases/phase-*.md\`. Do not edit — change the phase"
  echo "specs and re-run it."
  echo
  echo "**$ncrit acceptance criteria across $total phases · $nflag worth a human look.**"
  echo
  echo "**Done when:** every phase's acceptance criteria below pass, and the final audit re-verifies"
  echo "\`SPEC.md\`'s success criteria and every phase's mandatory commands. Nothing else ends the run."
  echo
  echo "## Worth your eye"
  echo
  if [[ "$nflag" -eq 0 ]]; then
    echo "None — every criterion is one the run can check for itself inside the repo."
  else
    awk -F'\t' '$1 == "C" && $3 != "" { printf "- **Phase %s** (%s): %s\n", $2, $3, $4 }' "$tmp"
  fi
  awk -F'\t' '
    $1 == "P" {
      printf "\n## Phase %s — %s\n\n", $2, $3
      if ($4 != "") printf "Serves: %s\n", $4
      printf "Mandatory commands: %s\n\n", ($5 == "" ? "(none)" : $5)
    }
    $1 == "C" { printf "- %s%s\n", $4, ($3 == "" ? "" : "  _(" $3 ")_") }
  ' "$tmp"
} > "$out"

echo "rubric: $ncrit criteria across $total phases, $nflag flagged → $out"
exit 0
