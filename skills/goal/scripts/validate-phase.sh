#!/usr/bin/env bash
# validate-phase.sh — verify a phase spec has the required structure
#
# Usage: validate-phase.sh <path-to-phase-spec.md>
#
# Exits 0 if the file has the required markers and sections.
# Exits 1 with specific errors otherwise.

set -uo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: validate-phase.sh <path-to-phase-spec.md>" >&2
  exit 2
fi

f="$1"
if [[ ! -f "$f" ]]; then
  echo "validate-phase.sh: file not found: $f" >&2
  exit 2
fi

errors=0

check_marker() {
  local marker="$1"
  local label="$2"
  if ! grep -q "$marker" "$f"; then
    echo "❌ $f: missing $label ($marker)" >&2
    errors=$((errors + 1))
  fi
}

check_section() {
  local heading="$1"
  if ! grep -qi "^## $heading\|^\*\*$heading" "$f"; then
    echo "❌ $f: missing section: $heading" >&2
    errors=$((errors + 1))
  fi
}

# Required markers
check_marker "RELAY_PHASE_START" "phase-start marker"

# Required sections
check_section "Work"
check_section "Acceptance criteria"
check_section "Mandatory commands"
check_section "Evidence required"

# --- Content checks (hard) ---------------------------------------------------------------
#
# The sections above only had to *exist*. Two of them carry load-bearing content:
#
#  1. `## Mandatory commands` is how a phase catches a regression an earlier phase introduced
#     (phase-design.md requires build/typecheck/lint/test in every phase). An empty section
#     silently turns that off for the phase.
#  2. The header's `Acceptance criteria: <n>` is cross-checked at run time against the count of
#     per-criterion lines in the subagent's report, so a stale count would reject a good report.

# section_bullets <heading> [placeholders-only]
# Counts "- " bullets under "## <heading>". A bare "..." continuation line never counts.
# {{PLACEHOLDER}} bullets DO count as present: this file is also run against the skeleton
# template (templates/phase-goal.txt) as a pre-ship check, and an unfilled skeleton must not
# read as an empty section. Unreplaced placeholders get their own advisory below instead —
# the same convention `Estimated files:` already uses.
section_bullets() {
  awk -v want="$1" -v ph="${2:-0}" '
    BEGIN { IGNORECASE = 1 }
    /^##[[:space:]]/ { inside = (tolower($0) ~ tolower("^## " want)) ? 1 : 0; next }
    inside && /^[[:space:]]*-[[:space:]]*[^[:space:]]/ {
      line = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      if (line ~ /^\.\.\.$/) next
      is_ph = (line ~ /\{\{/)
      if (ph == "1") { if (is_ph) c++ } else c++
    }
    END { print c + 0 }' "$f"
}

cmd_bullets="$(section_bullets 'Mandatory commands')"
if [[ "$cmd_bullets" -eq 0 ]]; then
  echo "❌ $f: '## Mandatory commands' has no commands — every phase must run its build/typecheck/lint/test gate" >&2
  errors=$((errors + 1))
fi

for sect in 'Mandatory commands' 'Acceptance criteria'; do
  n="$(section_bullets "$sect" 1)"
  if [[ "$n" -gt 0 ]]; then
    echo "⚠️  $f: '## $sect' still holds $n template placeholder(s) — fill them in" >&2
  fi
done

crit_bullets="$(section_bullets 'Acceptance criteria')"
crit_declared="$(grep -m1 -E '^[[:space:]]*Acceptance criteria:[[:space:]]*[0-9]+' "$f" | grep -oE '[0-9]+' | head -1 || true)"
if [[ -n "$crit_declared" && "$crit_bullets" -gt 0 && "$crit_declared" -ne "$crit_bullets" ]]; then
  echo "❌ $f: header says 'Acceptance criteria: $crit_declared' but '## Acceptance criteria' lists $crit_bullets" >&2
  errors=$((errors + 1))
fi

# Hard: `Review:` decides whether a separate subagent reviews this phase's diff for correctness
# after it passes (record-phase.sh routes on it). `yes`, or `skip — <reason>` — the reason is
# mandatory, as for edge-probe dismissals, so a skipped review is always a stated decision
# (`skip — --lean` under --lean). A missing line fails: record-phase.sh reads a missing line as
# a skip, which is right for runs planned before 0.10 but must never be how a new plan skips one.
review_line="$(grep -m1 -E '^Review:' "$f" || true)"
review_val="$(printf '%s' "$review_line" | sed -E 's/^Review:[[:space:]]*//; s/[[:space:]]+$//')"
if [[ -z "$review_line" ]]; then
  echo "❌ $f: no 'Review:' line — write 'Review: yes', or 'Review: skip — <reason>' for a docs/config-only phase" >&2
  errors=$((errors + 1))
elif [[ "$review_val" == *'{{'* ]]; then
  echo "⚠️  $f: 'Review:' still holds a template placeholder — write 'yes' or 'skip — <reason>'" >&2
elif printf '%s' "$review_val" | grep -qiE '^yes$'; then
  :
elif printf '%s' "$review_val" | grep -qiE '^skip([[:space:]]|$|—|-|:)'; then
  reason="$(printf '%s' "$review_val" | sed -E 's/^[Ss][Kk][Ii][Pp][[:space:]]*//; s/^(—|--|-|:)[[:space:]]*//')"
  if [[ -z "$reason" ]]; then
    echo "❌ $f: 'Review: skip' needs a reason — 'Review: skip — <why this phase needs no review>'" >&2
    errors=$((errors + 1))
  fi
else
  echo "❌ $f: 'Review: $review_val' — must be 'yes' or 'skip — <reason>'" >&2
  errors=$((errors + 1))
fi

# Advisory: `Map seeds:` drives the phase's code-map slice. Warn only — "none" is valid and
# specs written before map slices existed lack the line.
if ! grep -q '^Map seeds:' "$f"; then
  echo "⚠️  $f: no 'Map seeds:' line — the executor will skip the code map for this phase" >&2
fi

# Advisory: `Estimated files:` is the phase-sizing gate (a phase must fit one subagent
# window). Warn when missing or over the threshold; never fail — old specs lack the line.
# Over the threshold is fine with a stated reason — `Estimated files: 14 — one migration, no
# clean seam` — because a split at no real seam makes the design worse (fix 28: tunez phase 1
# dropped its shared test setup to fit the old limit of 8, set before any window was measured).
SIZE_LIMIT="${RELAY_PHASE_FILE_LIMIT:-12}"
est_line="$(grep -m1 -E '^Estimated files:' "$f" || true)"
if [[ -z "$est_line" ]]; then
  echo "⚠️  $f: no 'Estimated files:' line — add the phase-sizing estimate (new + modified files)" >&2
else
  est="$(printf '%s' "$est_line" | sed -E 's/^Estimated files:[[:space:]]*//' | grep -oE '^[0-9]+' || true)"
  if [[ "$est_line" == *'{{'* ]]; then
    echo "⚠️  $f: 'Estimated files:' still holds a template placeholder — write the count of files touched" >&2
  elif [[ -z "$est" ]]; then
    echo "⚠️  $f: 'Estimated files:' is not a number — write the count of files touched" >&2
  elif (( est > SIZE_LIMIT )); then
    reason="$(printf '%s' "$est_line" | sed -E 's/^Estimated files:[[:space:]]*[0-9]+[[:space:]]*//; s/^(—|--|-|:)[[:space:]]*//')"
    if [[ -z "$reason" ]]; then
      echo "⚠️  $f: Estimated files: $est exceeds $SIZE_LIMIT — split it at a seam, or keep it and say why on the line ('Estimated files: $est — <why it can't split>')" >&2
    fi
  fi
fi

# Advisory: `## Exemplars` names the existing files a cold subagent should pattern-match.
if ! grep -qiE '^## Exemplars' "$f"; then
  echo "⚠️  $f: no '## Exemplars' section — name 2–3 existing files whose patterns the phase should match" >&2
fi

# Sanity check: at least one criterion line
crits=$(grep -cE '^[[:space:]]*-' "$f" || true)
if [[ "$crits" -lt 3 ]]; then
  echo "⚠️  $f: only $crits bullet lines — acceptance criteria look thin" >&2
fi

if (( errors > 0 )); then
  echo "✗ $f: $errors structural error(s)" >&2
  exit 1
fi

lines=$(wc -l < "$f" | tr -d ' ')
echo "✓ $f: structure ok ($lines lines, $crits bullets)"
exit 0
