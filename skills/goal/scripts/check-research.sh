#!/usr/bin/env bash
# check-research.sh — validate a run's plan-time research and print what the planner reads
#
# Usage: check-research.sh <run-root> [--digest]
#        check-research.sh <run-root> --only <slug>
#
# Why this exists: Stage 2.6 dispatches one researcher subagent per approved question, and each
# writes <run-root>/research/<slug>.md. The planner must not read those files whole — a
# researcher's findings, sources and caveats would fill the planning window — and must not plan
# on a finding nobody can trace. So this checks every answer has the shape the plan relies on,
# and --digest prints only the parts the planner needs (Answer, Implications, Contradicts).
#
# The index, <run-root>/research/README.md, is either a table of questions
#
#   | # | Slug | Question | Why it matters | Status |
#
# where Status is `answered` or `unanswered — <reason>` (a researcher that failed twice: a known
# gap, not a blocker), or a single `No research: <reason>` line — zero questions is a recorded
# decision, never a silent skip.
#
# Each answered <slug>.md needs `## Question`, `## Answer` (over 120 words warns — it is what the
# digest carries), `## Findings` (every bullet cites an http(s) source, says `derived: <from
# what>` for a result worked out from sourced findings, or says `unverified (training
# knowledge)`), `## Implications for this plan`
# (at least one bullet), `## Confidence` (high | medium | low), and a `Contradicts:` line
# (`none`, or the S<k> ids it conflicts with). Format: templates/RESEARCH-BRIEF.md.
#
# A `derived:` or `unverified (training knowledge…)` marker may carry a note inside the
# parentheses; "same source" is not a source (fix 24: 5 of 6 researchers in the Tunez run wrote
# one of these and failed their first check).
#
# --only <slug>  check one answer file whatever its index Status, and skip the index — the
#                researcher's own check before it returns (RESEARCH-BRIEF.md), so a format slip
#                is fixed in its window instead of costing the planner a round trip.
#
# Planner-only — research stays in the run root; phases read it by section, via their specs.
# Prints `research: <n> questions, <a> answered, <u> unverified finding(s), <c> contradict the
# spec` (or `research: none — <reason>`). Exits 0 when usable, 1 on a problem, 2 on usage.

set -uo pipefail

usage() { echo "usage: check-research.sh <run-root> [--digest | --only <slug>]" >&2; exit 2; }
[[ $# -ge 1 && -n "$1" ]] || usage
root="${1%/}"; shift
digest=0; only=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --digest) digest=1; shift ;;
    --only) [[ $# -ge 2 && -n "$2" ]] || usage; only="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -d "$root" ]] || { echo "check-research.sh: no run root at $root" >&2; exit 2; }

dir="$root/research"
index="$dir/README.md"
errors=0
err()  { echo "❌ $*"; errors=$((errors + 1)); }
warn() { echo "⚠  $*"; }

[[ $digest -eq 0 || -z "$only" ]] || usage
[[ -z "$only" || -f "$dir/$only.md" ]] || { err "$only: no $dir/$only.md"; exit 1; }
[[ -n "$only" || -f "$index" ]] || { err "no $index — write the question index (or 'No research: <reason>')"; echo "research: not recorded"; exit 1; }

# section <file> <heading> — the body under `## <heading>` up to the next `## `
section() {
  awk -v want="$2" '
    /^##[[:space:]]/ && !/^###/ {
      h = $0; sub(/^##[[:space:]]+/, "", h); sub(/[[:space:]]+$/, "", h)
      on = (tolower(h) == tolower(want)); next
    }
    on { print }
  ' "$1"
}

# --- zero questions ------------------------------------------------------------------------
if [[ -n "$only" ]]; then
  none_line=""; rows="$only"$'\t'"answered"
else
none_line="$(grep -m1 -E '^No research:' "$index" || true)"
rows="$(awk -F'|' '
  /^[[:space:]]*\|/ {
    n++
    if (n == 1 || $0 ~ /^[[:space:]]*\|[[:space:]:|-]+\|?[[:space:]]*$/) next
    slug = $3; status = $6
    gsub(/`/, "", slug); gsub(/^[[:space:]]+|[[:space:]]+$/, "", slug)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", status)
    if (slug != "") print slug "\t" status
  }' "$index")"
fi

if [[ -n "$none_line" && -z "$rows" ]]; then
  reason="$(printf '%s' "$none_line" | sed -E 's/^No research:[[:space:]]*//')"
  if [[ -z "$reason" ]]; then
    err "'No research:' has no reason — zero questions must say why"
    echo "research: none — (no reason)"; exit 1
  fi
  echo "research: none — $reason"
  exit 0
fi
[[ -n "$rows" ]] || { err "$index lists no questions and no 'No research: <reason>' line"; echo "research: not recorded"; exit 1; }

# --- each question ---------------------------------------------------------------------------
total=0; answered=0; unverified=0; contradicts=0; gaps=0
digest_out=""
while IFS=$'\t' read -r slug status; do
  total=$((total + 1))
  st="$(printf '%s' "$status" | tr '[:upper:]' '[:lower:]')"
  if [[ "$st" == unanswered* ]]; then
    why="$(printf '%s' "$status" | sed -E 's/^[Uu]nanswered[[:space:]]*(—|-|:)?[[:space:]]*//')"
    if [[ -z "$why" ]]; then err "$slug: 'unanswered' with no reason"; else warn "$slug: unanswered — $why (a known gap)"; fi
    gaps=$((gaps + 1)); continue
  fi
  [[ "$st" == answered* ]] || { err "$slug: status '$status' — use 'answered' or 'unanswered — <reason>'"; continue; }

  f="$dir/$slug.md"
  [[ -f "$f" ]] || { err "$slug: no $f"; continue; }
  bad=0
  for s in "Question" "Answer" "Findings" "Implications for this plan" "Confidence"; do
    grep -qiE "^##[[:space:]]+$s[[:space:]]*$" "$f" || { err "$slug: missing '## $s'"; bad=1; }
  done
  [[ $bad -eq 0 ]] || continue

  ans="$(section "$f" "Answer" | sed '/^[[:space:]]*$/d')"
  [[ -n "$ans" ]] || err "$slug: '## Answer' is empty"
  words="$(printf '%s' "$ans" | wc -w | tr -d ' ')"
  [[ "$words" -le 120 ]] || warn "$slug: '## Answer' is $words words (aim for 2–4 sentences, under 120) — it is what the digest carries"

  fb="$(section "$f" "Findings" | grep -E '^[[:space:]]*[-*][[:space:]]')"
  if [[ -z "$fb" ]]; then
    err "$slug: '## Findings' has no bullets"
  else
    while IFS= read -r b; do
      if printf '%s' "$b" | grep -iE 'unverified \(training knowledge[^)]*\)' >/dev/null; then
        unverified=$((unverified + 1))
      elif printf '%s' "$b" | grep -iE 'https?://|derived:' >/dev/null; then
        :
      elif printf '%s' "$b" | grep -iE 'same source|ibid' >/dev/null; then
        err "$slug: finding cites 'same source' — repeat the URL; a back-reference can't be checked: $(printf '%s' "$b" | sed -E 's/^[[:space:]]*[-*][[:space:]]*//' | cut -c1-80)"
      else
        err "$slug: finding with no source — cite a URL, mark it 'derived: <from what>', or mark it 'unverified (training knowledge)': $(printf '%s' "$b" | sed -E 's/^[[:space:]]*[-*][[:space:]]*//' | cut -c1-80)"
      fi
    done <<< "$fb"
  fi

  imp="$(section "$f" "Implications for this plan" | grep -E '^[[:space:]]*[-*][[:space:]]')"
  [[ -n "$imp" ]] || err "$slug: '## Implications for this plan' has no bullets — research the plan cannot use is not done"

  conf="$(section "$f" "Confidence" | sed '/^[[:space:]]*$/d' | head -1)"
  printf '%s' "$conf" | grep -iE '^[[:space:]]*(high|medium|low)\b' >/dev/null \
    || err "$slug: '## Confidence' must start with high, medium or low"

  cline="$(grep -m1 -E '^Contradicts:' "$f" || true)"
  cval="$(printf '%s' "$cline" | sed -E 's/^Contradicts:[[:space:]]*//')"
  if [[ -z "$cline" ]]; then
    err "$slug: no 'Contradicts:' line — write 'Contradicts: none' when nothing conflicts"
  elif [[ "$(printf '%s' "$cval" | tr '[:upper:]' '[:lower:]')" != none* ]]; then
    contradicts=$((contradicts + 1))
  fi

  answered=$((answered + 1))
  digest_out="$digest_out
### $slug ($(printf '%s' "$conf" | awk '{print tolower($1)}'))
$ans
Implications:
$imp
${cline:-Contradicts: (missing)}
"
done <<< "$rows"

[[ $digest -eq 1 && -n "$digest_out" ]] && printf '%s\n' "$digest_out"

if [[ -n "$only" ]]; then
  if [[ $errors -eq 0 ]]; then echo "research $only: ok ($unverified unverified finding(s))"; else echo "research $only: $errors problem(s) — fix each ❌ above"; fi
  [[ $errors -eq 0 ]]; exit
fi
summary="research: $total questions, $answered answered, $unverified unverified finding(s), $contradicts contradict the spec"
[[ $gaps -gt 0 ]] && summary="$summary, $gaps unanswered"
echo "$summary"
[[ $errors -eq 0 ]]
