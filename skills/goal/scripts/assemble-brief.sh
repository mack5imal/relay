#!/usr/bin/env bash
# assemble-brief.sh — build the self-contained brief a Relay subagent reads as its only manual.
#
# Why: each phase (and each fix and audit round) runs in a fresh context window. Everything
# that window needs — the spec, the executor contract, carryover memory from earlier phases,
# a precomputed code-map slice, the run state, and the exact transcript block formats — has
# to be on disk in one file before dispatch. Assembling it here, not in the orchestrator's
# context, means the orchestrator pays one summary line per phase, not the brief's ~7k tokens.
#
# Usage:
#   bash assemble-brief.sh <run-root> <N>                phase brief     -> phases/phase-N.brief.md
#   bash assemble-brief.sh <run-root> <N> --fix          fix brief       -> phases/phase-N.fix.brief.md
#   bash assemble-brief.sh <run-root> --audit <R>        audit brief     -> phases/audit-R.brief.md
#   bash assemble-brief.sh <run-root> --audit-fix <R>    audit-fix brief -> phases/audit-fix-R.brief.md
#   bash assemble-brief.sh <run-root> <N> --review       review brief    -> phases/phase-N.review.brief.md
#   bash assemble-brief.sh <run-root> <N> --review-fix   review-fix      -> phases/phase-N.review-fix.brief.md
#   bash assemble-brief.sh <run-root> --cleanup          tidy-up brief   -> phases/cleanup.brief.md
#   bash assemble-brief.sh <run-root> --security         security brief  -> phases/security.brief.md
#   bash assemble-brief.sh <run-root> --security-fix     security fix    -> phases/security-fix.brief.md
#
#   Reads <run-root>/PHASE-BRIEF.md (the template), <run-root>/MARKERS.md, <run-root>/STATE.md
#   (`Baseline ref:`, `Memory dir:`, `## Carryover`, `## Engineering check status`,
#   `## Failure log`), the spec, and — for phase/fix briefs whose spec has `Map seeds:` other
#   than `none` — refreshes the code graph via build-graph.sh and captures map-slice.sh output.
#
#   The review modes also compute {{DIFF_RANGE}} (phase N's commits, found in git by their
#   Relay-Phase trailer) and cleanup / security get {{COMMANDS}} (the deduplicated union of every
#   phase spec's `## Mandatory commands`). No git, or no commit for the phase, degrades to a note
#   the reviewer reports as a limit — never a failed dispatch.
#
#   Template mechanics: a line that is exactly {{SPEC}} / {{CARRYOVER}} / {{MAP_SLICE}} /
#   {{STATE_EXCERPT}} / {{MARKERS}} / {{COMMANDS}} is replaced by that section; `<!-- mode: a b -->` …
#   `<!-- /mode -->` fences keep their lines only when the current mode is listed; every
#   other {{NAME}} is substituted inline.
#
#   Carryover: phase / fix briefs inline the memories their `Depends on phases:` wrote (within
#   RELAY_CARRYOVER_KB, default 12) and index the rest; check briefs get the index only.
#
#   Prints one summary line on success. Exits 0 on success, 1 when a required input is
#   missing, 2 on a usage error. Missing carryover files and a missing graph are never
#   fatal — they degrade to a note in the brief.
#
# Copied into the run's <run-root>/ at Stage 7, next to the template it expands.

set -uo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: assemble-brief.sh <run-root> <N>              phase brief
       assemble-brief.sh <run-root> <N> --fix        fix brief for phase N
       assemble-brief.sh <run-root> --audit <R>      audit brief for round R
       assemble-brief.sh <run-root> --audit-fix <R>  audit-fix brief for round R
       assemble-brief.sh <run-root> <N> --review     correctness review of phase N
       assemble-brief.sh <run-root> <N> --review-fix fix for phase N's review findings
       assemble-brief.sh <run-root> --cleanup        tidy-up pass after the last phase
       assemble-brief.sh <run-root> --security       security pass before the audit
       assemble-brief.sh <run-root> --security-fix   fix for the security pass's findings
USAGE
  exit 2
}

die() { echo "assemble-brief.sh: $*" >&2; exit 1; }
is_int() { [[ "$1" =~ ^[0-9]+$ ]]; }

[ "$#" -ge 2 ] && [ -n "$1" ] || usage
runroot_arg="$1"; shift

mode=""; phase=""; round=""
case "${1:-}" in
  --audit)     [ "$#" -eq 2 ] && is_int "$2" || usage; mode="audit";     round="$2" ;;
  --audit-fix) [ "$#" -eq 2 ] && is_int "$2" || usage; mode="audit-fix"; round="$2" ;;
  --cleanup|--security|--security-fix)
               [ "$#" -eq 1 ] || usage; mode="${1#--}" ;;
  --*)         usage ;;
  *)
    is_int "$1" || usage; phase="$1"
    case "${2:-}" in
      "")           [ "$#" -eq 1 ] || usage; mode="phase" ;;
      --fix)        [ "$#" -eq 2 ] || usage; mode="fix" ;;
      --review)     [ "$#" -eq 2 ] || usage; mode="review" ;;
      --review-fix) [ "$#" -eq 2 ] || usage; mode="review-fix" ;;
      *)            usage ;;
    esac ;;
esac

[ -d "$runroot_arg" ] || die "run root not found: $runroot_arg"
runroot="${runroot_arg%/}"
template="$runroot/PHASE-BRIEF.md"
markers="$runroot/MARKERS.md"
state="$runroot/STATE.md"
phases="$runroot/phases"
for f in "$template" "$markers" "$state"; do
  [ -f "$f" ] || die "required file missing: $f"
done

# --- inputs per mode ----------------------------------------------------------------------
spec=""; original=""; out=""; evidence=""; report=""
case "$mode" in
  phase)     spec="$phases/phase-$phase.md";        out="$phases/phase-$phase.brief.md";     evidence="$runroot/phases/phase-$phase.evidence.md"; report="$runroot/phases/phase-$phase.report.md" ;;
  fix)       spec="$phases/phase-$phase.fix.md";    original="$phases/phase-$phase.md"
             out="$phases/phase-$phase.fix.brief.md"; evidence="$runroot/phases/phase-$phase.evidence.md"; report="$runroot/phases/phase-$phase.fix.report.md" ;;
  audit)     spec="";                               out="$phases/audit-$round.brief.md";     evidence="$runroot/phases/audit-$round.evidence.md"; report="$runroot/phases/audit-$round.report.md" ;;
  audit-fix) spec="$phases/audit-fix-$round.md";    out="$phases/audit-fix-$round.brief.md"; evidence="$runroot/phases/audit-$round.evidence.md"; report="$runroot/phases/audit-fix-$round.report.md" ;;
  review)    spec="$phases/phase-$phase.md"
             out="$phases/phase-$phase.review.brief.md"; evidence="$runroot/phases/phase-$phase.review.evidence.md"; report="$runroot/phases/phase-$phase.review.report.md" ;;
  review-fix) spec="$phases/phase-$phase.review-fix.md"; original="$phases/phase-$phase.md"
             out="$phases/phase-$phase.review-fix.brief.md"; evidence="$runroot/phases/phase-$phase.review.evidence.md"; report="$runroot/phases/phase-$phase.review-fix.report.md" ;;
  cleanup)   spec="";                               out="$phases/cleanup.brief.md";          evidence="$runroot/phases/cleanup.evidence.md";  report="$runroot/phases/cleanup.report.md" ;;
  security)  spec="";                               out="$phases/security.brief.md";         evidence="$runroot/phases/security.evidence.md"; report="$runroot/phases/security.report.md" ;;
  security-fix) spec="$phases/security-fix.md";     out="$phases/security-fix.brief.md";     evidence="$runroot/phases/security.evidence.md"; report="$runroot/phases/security-fix.report.md" ;;
esac
# where the window's command logs go (run-logged.sh), relative to the run root
case "$mode" in
  phase|fix|review|review-fix) logdir="logs/phase-$phase" ;;
  audit|audit-fix)             logdir="logs/audit-$round" ;;
  cleanup)                     logdir="logs/cleanup" ;;
  security|security-fix)       logdir="logs/security" ;;
esac
[ -z "$spec" ] || [ -f "$spec" ] || die "spec not found: $spec"
[ -z "$original" ] || [ -f "$original" ] || die "original phase spec not found: $original"
mkdir -p "$phases" || die "cannot create $phases"

# STATE.md fields: "**Baseline ref:** abc123    <!-- comment -->" -> abc123
state_field() {
  grep -m1 -E "^\*\*$1:\*\*" "$state" 2>/dev/null \
    | sed -E "s/^\*\*$1:\*\*[[:space:]]*//; s/[[:space:]]*<!--.*$//; s/[[:space:]]+$//"
}
baseline="$(state_field 'Baseline ref')"; baseline="${baseline:-unknown}"
memdir="$(state_field 'Memory dir')";     memdir="${memdir:-}"
[ -n "$memdir" ] && [[ "$memdir" == "~/"* ]] && memdir="$HOME/${memdir#\~/}"

# total phases = phase-<digits>.md files (not .fix/.brief/.evidence)
total=0
for f in "$phases"/phase-*.md; do
  [ -e "$f" ] || continue
  b="$(basename "$f")"
  [[ "$b" =~ ^phase-[0-9]+\.md$ ]] && total=$((total + 1))
done

# title: the spec's "Phase: N of T — name" line, else a mode label
title=""
if [ -n "$spec" ] && [ "$mode" != "audit-fix" ] && [ "$mode" != "security-fix" ]; then
  title="$(grep -m1 -E '^Phase:' "${original:-$spec}" | sed -E 's/^Phase:[[:space:]]*[0-9]+[[:space:]]+of[[:space:]]+[0-9]+[[:space:]]*[—-]+[[:space:]]*//')"
fi
case "$mode" in
  phase)        title="${title:-phase $phase}" ;;
  fix)          title="fix for phase $phase${title:+ — $title}" ;;
  review)       title="review of phase $phase${title:+ — $title}" ;;
  review-fix)   title="fix for phase $phase's review${title:+ — $title}" ;;
  cleanup)      title="tidy-up pass" ;;
  security)     title="security pass" ;;
  security-fix) title="fix for the security pass" ;;
  audit)        title="final audit, round $round" ;;
  audit-fix)    title="fix for audit round $round" ;;
esac

# The dispatch this brief is for: record-phase.sh's label and arguments (the same as this
# script's), PROTOCOL.md's Agent description, and the trailer relay-git.sh commits it under
# (none for the read-only review, security pass and audit).
case "$mode" in
  phase)        label="Phase $phase";            args="$phase";              desc="Relay phase $phase";            trailer="Relay-Phase: $phase" ;;
  fix)          label="Phase $phase fix";        args="$phase --fix";        desc="Relay phase $phase fix";        trailer="Relay-Phase: $phase" ;;
  review)       label="Phase $phase review";     args="$phase --review";     desc="Relay phase $phase review";     trailer="" ;;
  review-fix)   label="Phase $phase review fix"; args="$phase --review-fix"; desc="Relay phase $phase review fix"; trailer="Relay-Review-Fix: $phase" ;;
  cleanup)      label="Cleanup";                 args="--cleanup";           desc="Relay cleanup";                 trailer="Relay-Cleanup: 1" ;;
  security)     label="Security pass";           args="--security";          desc="Relay security pass";           trailer="" ;;
  security-fix) label="Security fix";            args="--security-fix";      desc="Relay security fix";            trailer="Relay-Security-Fix: 1" ;;
  audit)        label="Audit round $round";      args="--audit $round";      desc="Relay audit round $round";      trailer="" ;;
  audit-fix)    label="Audit fix $round";        args="--audit-fix $round";  desc="Relay audit fix $round";        trailer="Relay-Audit-Fix: $round" ;;
esac

tmp="$(mktemp -d)" || die "mktemp failed"
trap 'rm -rf "$tmp"' EXIT

# --- {{SPEC}} -----------------------------------------------------------------------------
: > "$tmp/spec"
if [ -n "$spec" ]; then
  cat "$spec" > "$tmp/spec"
  if [ -n "$original" ]; then
    { printf '\n---\n\n### Original phase spec (success gate — every criterion below must pass)\n\n'; cat "$original"; } >> "$tmp/spec"
  fi
fi

# --- {{MAP_SLICE}} ------------------------------------------------------------------------
seed_count=0; slice_note="none"
: > "$tmp/slice"
if [ "$mode" = "phase" ] || [ "$mode" = "fix" ] || [ "$mode" = "review" ] || [ "$mode" = "review-fix" ]; then
  seeds="$(grep -m1 -E '^Map seeds:' "${original:-$spec}" | sed -E 's/^Map seeds:[[:space:]]*//; s/[[:space:]]+$//')"
  if [ -z "$seeds" ]; then
    echo "(the spec has no \`Map seeds:\` line — no slice for this phase)" > "$tmp/slice"
  elif [ "$(printf '%s' "$seeds" | tr '[:upper:]' '[:lower:]')" = "none" ]; then
    echo "(\`Map seeds: none\` — no slice for this phase)" > "$tmp/slice"
  else
    seed_count="$(printf '%s\n' "$seeds" | tr ',' '\n' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' | grep -c .)"
    slice_note="$seed_count seeds"
    {
      if [ -f "$runroot/build-graph.sh" ]; then
        bash "$runroot/build-graph.sh" "$runroot" 2>&1 | head -1
      else
        echo "graph: skipped - build-graph.sh not in run root"
      fi
      echo "Map seeds: $seeds"
      echo
      if [ -f "$runroot/map-slice.sh" ]; then
        bash "$runroot/map-slice.sh" "$runroot/graph/graph.json" "$seeds" 2>&1
      else
        echo "(map-slice.sh not in run root — no slice; open the files the spec names)"
      fi
    } > "$tmp/slice"
  fi
fi

# --- {{CARRYOVER}} ------------------------------------------------------------------------
# Every memory a window saved is listed in STATE.md's `## Carryover` as "- <name> (phase N)".
# Inlining all of them made briefs grow without bound (tunez: 30 memories / 51 KB, phase briefs
# 28 → 85 KB, check briefs ~100 KB, the first Read cut short from phase 13 on). So:
#   phase / fix windows — full text of the memories written by the phases in the spec's
#     `Depends on phases:` (and phase N itself), nearest phase first, within RELAY_CARRYOVER_KB
#     (default 12); a line with no "(phase N)" counts as eligible, as before;
#   every other memory, and every memory for the check windows (review, review-fix, cleanup,
#     security, security-fix, audit, audit-fix) — one index line: name, phase, description (the
#     memory dir is named once above the list).
# Nothing is hidden: the window opens any file whose line touches its work.
carry_count=0; carry_idx=0
: > "$tmp/carry"; : > "$tmp/carry.full"; : > "$tmp/carry.idx"
budget=$(( ${RELAY_CARRYOVER_KB:-12} * 1024 ))
# "<name>\t<phase or empty>", one per memory, latest phase kept, in list order
awk '/^## Carryover/{f=1; next} /^## /{f=0}
     f && /^- / {
       l = $0; sub(/^- +/, "", l); sub(/[[:space:]]+$/, "", l)
       if (l == "" || tolower(l) == "(none yet)" || l == "..." || index(l, "{{")) next
       ph = ""
       if (match(l, / \(phase [0-9]+\)$/)) { ph = substr(l, RSTART + 8, RLENGTH - 9); l = substr(l, 1, RSTART - 1) }
       if (!(l in at)) { order[++n] = l; at[l] = ph }
       else if (ph != "" && (at[l] == "" || ph + 0 > at[l] + 0)) at[l] = ph
     }
     END { for (i = 1; i <= n; i++) print order[i] "\t" at[order[i]] }' "$state" > "$tmp/carry.list"

# The phases whose memories this window gets in full ("" for the check windows).
eligible=" "
if [ "$mode" = "phase" ] || [ "$mode" = "fix" ]; then
  deps="$(grep -m1 -E '^Depends on phases:' "$phases/phase-$phase.md" 2>/dev/null | sed -E 's/^Depends on phases:[[:space:]]*//')"
  for part in $(printf '%s' "$deps" | tr ',;' '  '); do
    if [[ "$part" =~ ^([0-9]+)[-–]([0-9]+)$ ]]; then
      i="${BASH_REMATCH[1]}"; while [ "$i" -le "${BASH_REMATCH[2]}" ]; do eligible="$eligible$i "; i=$((i + 1)); done
    elif [[ "$part" =~ ^[0-9]+$ ]]; then eligible="$eligible$part "
    fi
  done
  eligible="$eligible$phase "
fi

# mem_file <name> — the memory's path, or "" when it is not on disk
mem_file() {
  local cand
  [ -n "$memdir" ] || return 0
  for cand in "$memdir/$1.md" "$memdir/$1"; do [ -f "$cand" ] && { printf '%s' "$cand"; return 0; }; done
}
# mem_desc <file> — frontmatter description (quotes stripped), else the first body line; at most
# 160 characters, cut on a character boundary
mem_desc() {
  LC_ALL=C awk '
    BEGIN { for (i = 128; i < 256; i++) ord[sprintf("%c", i)] = i }
    function cut(s, max,   o, k, i, c, b) {
      o = ""; k = 0
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1); b = (c in ord) ? ord[c] : 0
        if (b < 128 || b >= 192) { if (++k > max) return o "…" }
        o = o c
      }
      return o
    }
    NR == 1 && $0 == "---" { fm = 1; next }
    fm && $0 == "---" { fm = 0; next }
    fm && /^description:/ { d = $0; sub(/^description:[[:space:]]*/, "", d); sub(/[[:space:]]+$/, "", d)
                            if (d ~ /^".*"$/ || d ~ /^\x27.*\x27$/) d = substr(d, 2, length(d) - 2)
                            gsub(/\\"/, "\"", d); desc = d; next }
    !fm && body == "" && $0 !~ /^[[:space:]]*$/ { body = $0; sub(/^#+[[:space:]]*/, "", body) }
    END { print cut(desc != "" ? desc : body, 160) }' "$1"
}

# Full text: eligible memories, nearest phase first (no recorded phase last), within the budget.
if [ "$eligible" != " " ]; then
  awk -F'\t' '{ print ($2 == "" ? -1 : $2) "\t" NR "\t" $0 }' "$tmp/carry.list" \
    | sort -t "$(printf '\t')" -k1,1nr -k2,2n | cut -f3- > "$tmp/carry.order"
else
  : > "$tmp/carry.order"
fi
used=0; : > "$tmp/carry.chosen"
while IFS="$(printf '\t')" read -r mname ph; do
  [ -n "$mname" ] || continue
  if [ -n "$ph" ]; then case "$eligible" in *" $ph "*) ;; *) continue ;; esac; fi
  mf="$(mem_file "$mname")"
  mlabel="$mname${ph:+ (phase $ph)}"
  if [ -z "$mf" ]; then
    printf '### %s\n\n(not found under %s)\n\n' "$mlabel" "${memdir:-<no Memory dir>}" >> "$tmp/carry.full"
    printf '%s\n' "$mname" >> "$tmp/carry.chosen"; continue
  fi
  sz="$(wc -c < "$mf" | tr -d ' ')"
  [ $((used + sz)) -le "$budget" ] || continue
  used=$((used + sz)); carry_count=$((carry_count + 1))
  { printf '### %s\n\n' "$mlabel"; cat "$mf"; printf '\n\n'; } >> "$tmp/carry.full"
  printf '%s\n' "$mname" >> "$tmp/carry.chosen"
done < "$tmp/carry.order"

# The index: everything not given in full, in the order it was saved.
while IFS="$(printf '\t')" read -r mname ph; do
  [ -n "$mname" ] || continue
  grep -qxF -- "$mname" "$tmp/carry.chosen" && continue
  mf="$(mem_file "$mname")"
  mlabel="$mname${ph:+ (phase $ph)}"
  if [ -n "$mf" ]; then printf -- '- %s — %s\n' "$mlabel" "$(mem_desc "$mf")" >> "$tmp/carry.idx"
  else printf -- '- %s — (no file for it)\n' "$mlabel" >> "$tmp/carry.idx"; fi
  carry_idx=$((carry_idx + 1))
done < "$tmp/carry.list"

cat "$tmp/carry.full" >> "$tmp/carry"
if [ -s "$tmp/carry.idx" ]; then
  if [ -s "$tmp/carry.full" ]; then hdr="### Other memories saved this run"; else hdr="### Memories saved this run"; fi
  { printf '%s\n\n' "$hdr"
    printf 'One line each; the file is `%s/<name>.md` — open (Read) it when its line touches your work.\n\n' "${memdir:-<no Memory dir>}"
    cat "$tmp/carry.idx"; printf '\n'; } >> "$tmp/carry"
fi
carry_full_kb="$(awk -v b="$used" 'BEGIN { printf "%.1f", b / 1024 }')"
if [ -f "$runroot/applied-memories.md" ]; then
  { printf '### Applied at planning (applied-memories.md)\n\n'; cat "$runroot/applied-memories.md"; printf '\n'; } >> "$tmp/carry"
fi
[ -s "$tmp/carry" ] || echo "(no carryover yet — this is the first phase, or earlier phases saved nothing)" > "$tmp/carry"

# --- {{SPEC_CRITERIA}} / {{SPEC_PLAN}} --------------------------------------------------
# The audit re-verifies the run against the agreed statement of intent, not only against the
# roadmap the planner compiled from it: {{SPEC_CRITERIA}} is SPEC.md's success criteria and
# prohibitions. The windows that decide what a check fixes (review, cleanup, security) get
# {{SPEC_PLAN}} — those two sections plus in scope, out of scope, constraints and assumptions —
# so a fix that goes against the plan is caught where it is chosen: deferred when the owner
# decided that line, made and flagged when relay did (commit 14's security fix changed a
# `(planner)` out-of-scope line and nothing noticed). Both come from one file, by mode.
# SPEC.md is optional: runs planned before 0.9, and hand-authored test run roots,
# have none. A missing spec degrades to a note, exactly as carryover does — it
# must never fail a dispatch.
spec_crit_count=0
: > "$tmp/speccrit"
specfile="$runroot/SPEC.md"
case "$mode" in
  audit)                  spec_sections='success criteria|prohibitions'
                          spec_none='(no SPEC.md for this run — verify against ROADMAP.md only; do not invent run-level criteria)' ;;
  review|cleanup|security) spec_sections='success criteria|prohibitions|in scope|out of scope|constraints|assumptions'
                          spec_none='(no SPEC.md for this run — the phase specs are the only plan to check a fix against)' ;;
  *)                      spec_sections="" ;;
esac
if [ -n "$spec_sections" ]; then
  if [ -f "$specfile" ]; then
    awk -v re="^##[[:space:]]+($spec_sections)" '
      /^##[[:space:]]/ { inside = (tolower($0) ~ re); if (inside) print; next }
      inside { print }
    ' "$specfile" > "$tmp/speccrit"
    spec_crit_count="$(grep -cE '^[[:space:]]*-[[:space:]]*\*\*S[0-9]+' "$tmp/speccrit" 2>/dev/null || true)"
  fi
  [ -s "$tmp/speccrit" ] || printf '%s\n' "$spec_none" > "$tmp/speccrit"
else
  printf '(not applicable in this mode)\n' > "$tmp/speccrit"
fi

# --- {{STATE_EXCERPT}} --------------------------------------------------------------------

# left_by_earlier_window — when an earlier dispatch of this same target did not finish (the
# session stopped mid-window, or the window returned no report), what it may have left: the
# uncommitted changes (the run root never counts) and any commit already carrying this
# target's trailer. PHASE-BRIEF.md §5 says what to do with them: keep and review, never
# restart blind — a re-run that redid committed work, or discarded half-done work, wastes the
# window. Prints nothing when no earlier dispatch of this target failed to finish.
left_by_earlier_window() {
  local earlier top rr rel dirty commits id
  earlier="$(L_PRE="- $label: dispatch " awk '/^## Failure log/{f=1; next} /^## /{f=0}
               f && index($0, ENVIRON["L_PRE"]) == 1 && /(interrupted|returned no report)/' "$state")"
  [ -n "$earlier" ] || return 0
  echo
  echo "### Left by an earlier window"
  echo
  echo "An earlier dispatch of this $(printf '%s' "$label" | tr '[:upper:]' '[:lower:]') did not finish (failure log above). What it may have left:"
  echo
  if ! git -C "$runroot" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "- (not a git repository — look for partial work in the files the spec names)"
    return 0
  fi
  top="$(git -C "$runroot" rev-parse --show-toplevel 2>/dev/null)"
  top="$(cd "$top" 2>/dev/null && pwd -P)"; rr="$(cd "$runroot" 2>/dev/null && pwd -P)"
  rel=""; case "$rr/" in "$top/"*) rel="${rr#"$top"/}" ;; esac
  if [ -n "$rel" ]; then dirty="$(git -C "$runroot" status --porcelain -- ':/' ":(exclude,top)$rel" 2>/dev/null)"
  else dirty="$(git -C "$runroot" status --porcelain 2>/dev/null)"; fi
  echo "Uncommitted changes (\`git status --porcelain\`, the run root left out):"
  if [ -n "$dirty" ]; then printf '%s\n' "$dirty" | head -30 | sed 's/^/    /'
  else echo "    (none — the working tree is clean)"; fi
  if [ -n "$trailer" ]; then
    id="$(basename "$runroot")"
    commits="$(git -C "$runroot" log --format='%h %s' --all-match --grep="^Relay-Run: $id\$" --grep="^$trailer\$" HEAD 2>/dev/null)"
    echo
    echo "Commits already carrying \`$trailer\`:"
    if [ -n "$commits" ]; then printf '%s\n' "$commits" | sed 's/^/    /'
    else echo "    (none)"; fi
  fi
}
{
  grep -E '^\*\*(Status|Current phase|Last update):\*\*' "$state" || true
  echo
  awk '/^## Engineering check status/{f=1} /^## /&&!/^## Engineering/{f=0} f' "$state"
  echo
  echo "### Failure log"
  if [ -n "$phase" ]; then
    awk '/^## Failure log/{f=1; next} /^## /{f=0} f && /^- /' "$state" | grep -E "Phase $phase([^0-9]|$)" || echo "- (no failures recorded for phase $phase)"
  else
    awk '/^## Failure log/{f=1; next} /^## /{f=0} f && /^- /' "$state" | grep -v '{{' || echo "- (no failures recorded)"
  fi
  left_by_earlier_window
} > "$tmp/state"

# --- {{MARKERS}} --------------------------------------------------------------------------
case "$mode" in
  phase|fix) awk '/^## Phase blocks/||/^## Failure blocks/{f=1; next} /^## /{f=0} f' "$markers" > "$tmp/markers" ;;
  audit|audit-fix) awk '/^## Audit blocks/{f=1; next} /^## /{f=0} f' "$markers" > "$tmp/markers" ;;
  *)         awk '/^## Review blocks/{f=1; next} /^## /{f=0} f' "$markers" > "$tmp/markers" ;;
esac
[ -s "$tmp/markers" ] || echo "(no block formats found in $markers — check its ## headings)" > "$tmp/markers"

# --- {{DIFF_RANGE}} -----------------------------------------------------------------------
# A review reads only what phase N changed: from the parent of its first commit to its last
# (a phase commit and, after an escalation, its fix commit — both carry Relay-Phase: N).
# relay-git.sh branch gives a repository with no commits an empty first commit, so a phase
# commit always has a parent. No git, or no commit for the phase: a note the reviewer reports.
diff_range="(not applicable in this mode)"
if [ "$mode" = "review" ] || [ "$mode" = "review-fix" ]; then
  if git -C "$runroot" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    run_id="$(basename "$runroot")"
    rbase="HEAD"
    if git -C "$runroot" rev-parse --verify -q "$baseline^{commit}" >/dev/null 2>&1; then rbase="$baseline..HEAD"; fi
    shas="$(git -C "$runroot" log --format=%h --all-match --grep="^Relay-Run: $run_id\$" \
            --grep="^Relay-Phase: $phase\$" $rbase 2>/dev/null)"
    if [ -n "$shas" ]; then
      last="$(printf '%s\n' "$shas" | head -1)"; first="$(printf '%s\n' "$shas" | tail -1)"
      diff_range="$first^..$last"
    else
      diff_range="none — no commit with Relay-Phase: $phase in git; review the files the evidence file lists under \`### Files changed\` and report the missing diff as a limit"
    fi
  else
    diff_range="none — not a git repository; review the files the evidence file lists under \`### Files changed\` and report the missing diff as a limit"
  fi
fi

# --- {{COMMANDS}} -------------------------------------------------------------------------
# The deduplicated union of every phase spec's `## Mandatory commands` — the gate a tidy-up
# must keep green, and what the security pass may run. A backtick-wrapped bullet yields only
# the text inside the backticks, any other bullet loses a trailing " — …" / " – …" description
# (tunez's "`npm run build` — vite build summary line; exit 0"). Same parse as preflight.sh's
# cmd_bullets — change both together.
: > "$tmp/commands"
cmd_count=0
if [ "$mode" = "cleanup" ] || [ "$mode" = "security" ] || [ "$mode" = "security-fix" ]; then
  for f in "$phases"/phase-*.md; do
    [ -e "$f" ] || continue
    [[ "$(basename "$f")" =~ ^phase-[0-9]+\.md$ ]] || continue
    awk '/^##[[:space:]]/ { inside = (tolower($0) ~ /^##[[:space:]]+mandatory commands/); next }
         inside && /^[[:space:]]*-[[:space:]]*[^[:space:]]/ {
           l = $0; sub(/^[[:space:]]*-[[:space:]]*/, "", l); sub(/[[:space:]]+$/, "", l)
           if (l == "...") next
           if (substr(l, 1, 1) == "`") { r = substr(l, 2); i = index(r, "`"); if (i > 1) l = substr(r, 1, i - 1) }
           else { i = index(l, " — "); if (i == 0) i = index(l, " – "); if (i > 0) l = substr(l, 1, i - 1) }
           sub(/[[:space:]]+$/, "", l)
           if (l != "") print l
         }' "$f"
  done | awk '!seen[$0]++' > "$tmp/commands.raw"
  cmd_count="$(grep -c . "$tmp/commands.raw" || true)"
  sed 's/.*/- `&`/' "$tmp/commands.raw" > "$tmp/commands"
fi
[ -s "$tmp/commands" ] || echo "(no mandatory commands found in the phase specs — run the project's build, typecheck, lint and test commands)" > "$tmp/commands"

# --- expand the template ------------------------------------------------------------------
keep=1
: > "$out"
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    "<!-- mode: "*" -->")
      list="${line#<!-- mode: }"; list="${list% -->}"
      keep=0
      for m in $list; do [ "$m" = "$mode" ] && keep=1; done
      continue ;;
    "<!-- /mode -->") keep=1; continue ;;
  esac
  [ "$keep" -eq 1 ] || continue
  case "$line" in
    "{{SPEC}}")          cat "$tmp/spec"    >> "$out"; continue ;;
    "{{CARRYOVER}}")     cat "$tmp/carry"   >> "$out"; continue ;;
    "{{MAP_SLICE}}")     cat "$tmp/slice"   >> "$out"; continue ;;
    "{{SPEC_CRITERIA}}"|"{{SPEC_PLAN}}") cat "$tmp/speccrit" >> "$out"; continue ;;
    "{{STATE_EXCERPT}}") cat "$tmp/state"   >> "$out"; continue ;;
    "{{MARKERS}}")       cat "$tmp/markers" >> "$out"; continue ;;
    "{{COMMANDS}}")      cat "$tmp/commands" >> "$out"; continue ;;
  esac
  line="${line//'{{RUN_ROOT}}'/$runroot}"
  line="${line//'{{MODE}}'/$mode}"
  line="${line//'{{PHASE_N}}'/$phase}"
  line="${line//'{{TOTAL}}'/$total}"
  line="${line//'{{ROUND}}'/$round}"
  line="${line//'{{TITLE}}'/$title}"
  line="${line//'{{BASELINE}}'/$baseline}"
  line="${line//'{{MEM_DIR}}'/${memdir:-<not set — see STATE.md Memory dir>}}"
  line="${line//'{{SPEC_PATH}}'/${spec:-none}}"
  line="${line//'{{EVIDENCE_PATH}}'/$evidence}"
  line="${line//'{{REPORT_PATH}}'/$report}"
  line="${line//'{{BRIEF_PATH}}'/$out}"
  line="${line//'{{DIFF_RANGE}}'/$diff_range}"
  line="${line//'{{LOG_DIR}}'/$runroot/$logdir}"
  printf '%s\n' "$line" >> "$out"
done < "$template"

# {{BRIEF_LINES}} — the brief's own length, so its reader knows when a Read stopped early (from
# phase 13 of a 19-phase run, the first Read of every brief came back cut short). Filled after
# assembly; the placeholder sits on an existing line, so the count it states stays true.
brief_lines="$(grep -c '' "$out")"
if grep -qF '{{BRIEF_LINES}}' "$out"; then
  awk -v n="$brief_lines" -v t='{{BRIEF_LINES}}' \
    '{ while ((i = index($0, t)) > 0) $0 = substr($0, 1, i - 1) n substr($0, i + length(t)) } 1' \
    "$out" > "$out.tmp" && mv "$out.tmp" "$out"
fi

# What is in flight: recover.sh reads this when the session stops before the window reports,
# to tell a dead dispatch (re-dispatch it) from a live one (keep waiting) by the Claude process
# that dispatched it. record-phase.sh removes it when it records this target. A separate file,
# so record-phase.sh stays the only writer of STATE.md.
claude_pid() {
  local p c
  if [ -n "${CLAUDE_PID:-}" ] && kill -0 "$CLAUDE_PID" 2>/dev/null; then echo "$CLAUDE_PID"; return 0; fi
  p="$$"
  while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do
    c="$(ps -o comm= -p "$p" 2>/dev/null)"; c="${c##*/}"
    [ "$c" = "claude" ] && { echo "$p"; return 0; }
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
  done
  return 0
}
cpid="$(claude_pid)"
cstart=""; [ -n "$cpid" ] && cstart="$(ps -o lstart= -p "$cpid" 2>/dev/null | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
{
  echo "mode: $mode"
  echo "target: $(printf '%s' "$label" | tr '[:upper:]' '[:lower:]')"
  echo "args: $args"
  echo "brief: phases/$(basename "$out")"
  echo "report: phases/$(basename "$report")"
  echo "description: $desc"
  echo "pid: $cpid"
  echo "started: $cstart"
} > "$phases/in-flight.new" && mv "$phases/in-flight.new" "$phases/in-flight"

lines="$(grep -c '' "$out")"
# sizes in KB (rounded) so a run can watch briefs and carryover grow phase over phase
kb() { echo $(( ($(wc -c < "$1") + 512) / 1024 )); }
spec_note=""
case "$mode" in
  audit)          spec_note=", spec: $spec_crit_count criteria" ;;
  review|review-fix) spec_note=", diff: ${diff_range%% —*}" ;;
  cleanup|security) spec_note=", commands: $cmd_count, spec: $spec_crit_count criteria" ;;
  security-fix)   spec_note=", commands: $cmd_count" ;;
esac
echo "brief: $out ($lines lines, $(kb "$out") KB, slice: $slice_note, carryover: $carry_count in full ($carry_full_kb KB), $carry_idx indexed / $(kb "$tmp/carry") KB$spec_note)"
exit 0
