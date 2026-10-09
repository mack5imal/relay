#!/usr/bin/env bash
# validate-spec.sh — verify a run's SPEC.md is structurally sound and actually checkable
#
# Usage: validate-spec.sh <path-to-SPEC.md>
#
# Why this exists: SPEC.md's `## Success criteria` is the rubric the final audit re-verifies
# the whole run against. A criterion phrased as a vibe ("auth works") cannot be re-verified, so
# the audit falls back to `trust-prior-verify` and the run's honesty guarantee quietly erodes.
# validate-phase.sh is content-blind by design (it counts bullets); this is the content gate.
#
# Hard errors (exit 1):
#   - a required section is missing
#   - a success criterion has no `Acceptance:` line
#   - a success criterion has no measurable predicate anywhere (a vibe, not a test)
#   - an edge-coverage row is `dismissed` with no reason — silence is not a disposition
#   - an edge edge-probe.py raises for a current criterion has no row at all — the probe's
#     output is a floor, and narrowing it silently is the failure it exists to prevent
#   - a design package is recorded (`**Design:** … @ <sha>`) but there is no
#     `## Design reconciliation` section with a `Reconciled: <n>` line — Stage 2.7e compares the
#     design against the spec, and zero conflicts must be a recorded result, not an omission
# Advisories (exit 0): unresolved edges, an empty prohibitions list, a missing interview log,
# out-of-scope items tagged `(planner)`, and the edge floor itself when python3 is unavailable.
#
# Exits 0 when the spec is usable, 1 on structural errors, 2 on a usage error.

set -uo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: validate-spec.sh <path-to-SPEC.md>" >&2
  exit 2
fi

f="$1"
if [[ ! -f "$f" ]]; then
  echo "validate-spec.sh: file not found: $f" >&2
  exit 2
fi

errors=0
err()  { echo "❌ $f: $1" >&2; errors=$((errors + 1)); }
warn() { echo "⚠️  $f: $1" >&2; }

# The template carries illustrative counter-examples ("The system should be fast") inside HTML
# comments. Strip comments before any content check so a spec is never judged on its own
# guidance text.
body="$(mktemp)"; trap 'rm -f "$body"' EXIT
perl -0777 -pe 's/<!--.*?-->//gs' "$f" > "$body"

# --- required sections -------------------------------------------------------------------
for s in "Goal" "In scope" "Out of scope" "Constraints" "Success criteria" \
         "Edge coverage" "Ambiguity report"; do
  grep -qiE "^##[[:space:]]+$s[[:space:]]*$" "$body" || err "missing section: ## $s"
done
for s in "Prohibitions" "Interview log"; do
  grep -qiE "^##[[:space:]]+$s" "$body" || warn "no '## $s' section — recommended, not required"
done

# --- design reconciliation (only when a design package was recorded) ----------------------
if grep -qE '^\*\*Design:\*\*.*@[[:space:]]*[0-9a-f]{6,40}' "$body"; then
  recon="$(awk '
    /^##[[:space:]]/ { inside = (tolower($0) ~ /^##[[:space:]]+design reconciliation[[:space:]]*$/); next }
    inside { print }
  ' "$body")"
  if ! grep -qiE '^##[[:space:]]+design reconciliation[[:space:]]*$' "$body"; then
    err "a design package is recorded (**Design:** … @ <sha>) but there is no '## Design reconciliation' section — compare the design against every criterion, constraint and prohibition (Stage 2.7e) and record the result, 'Reconciled: 0 conflicts — <what was compared>' included"
  elif ! printf '%s\n' "$recon" | grep -E '^Reconciled:[[:space:]]*[0-9]+' >/dev/null; then
    err "'## Design reconciliation' has no 'Reconciled: <n> conflicts' line — a zero must be recorded, not implied"
  else
    n_recon="$(printf '%s\n' "$recon" | grep -m1 -oE '^Reconciled:[[:space:]]*[0-9]+' | grep -oE '[0-9]+$')"
    n_rows="$(printf '%s\n' "$recon" | grep -E '^[[:space:]]*\|' | grep -vE '^[[:space:]]*\|[[:space:]:|-]+\|?[[:space:]]*$' | tail -n +2 | grep -c .)"
    [[ "$n_rows" -eq "$n_recon" ]] || warn "'Reconciled: $n_recon' but the reconciliation table has $n_rows row(s)"
  fi
fi

# --- success criteria --------------------------------------------------------------------
# Extract the section, then walk each "- **S<k> ...**" entry with its indented sub-bullets.
awk '
  /^##[[:space:]]/ { inside = (tolower($0) ~ /^##[[:space:]]+success criteria[[:space:]]*$/); next }
  inside { print }
' "$body" > "$body.crit"

crit_count=0
while IFS= read -r line; do
  [[ "$line" =~ ^[[:space:]]*-[[:space:]]*\*\*(S[0-9]+) ]] || continue
  crit_count=$((crit_count + 1))
done < "$body.crit"

if [[ "$crit_count" -eq 0 ]]; then
  err "'## Success criteria' lists no S<k> entries — the audit would have nothing to check"
fi

# Per-criterion checks, done in awk so an entry keeps its sub-bullets together.
awk -v OFS='\t' '
  # POSIX awk (macOS) has no \b word boundary, so verbs are matched against a copy in which
  # every non-letter has become a space and the whole string is space-padded. Matching " exits "
  # then means a whole word without needing the GNU extension.
  function has_verb(t,   words, v, n, i) {
    t = " " tolower(t) " "
    gsub(/[^a-z]+/, " ", t)
    n = split("exits exit returns return responds respond equals equal matches match " \
              "contains contain renders render prints print emits emit exists exist " \
              "appears appear rejects reject accepts accept logs log fails fail passes pass", words, " ")
    for (i = 1; i <= n; i++) if (index(t, " " words[i] " ") > 0) return 1
    return 0
  }
  # A criterion can clear the hard check (it has a verb or a number) and still hide a vibe in
  # a qualifier: "renders correctly", "works properly". Those are advisory, not errors -- the
  # hard check must stay free of false positives to be worth obeying.
  function soft_word(t,   words, n, i) {
    t = " " tolower(t) " "
    gsub(/[^a-z]+/, " ", t)
    n = split("works work working good correct correctly ready properly nice polished " \
              "right fine reasonable appropriate sensible clean smooth", words, " ")
    for (i = 1; i <= n; i++) if (index(t, " " words[i] " ") > 0) return words[i]
    return ""
  }
  function flush(   hay) {
    if (id == "") return
    hay = tolower(text)
    if (hay ~ /\{\{/) { id = ""; text = ""; acc = 0; return }   # unfilled template entry
    if (!acc) print "NOACC", id
    # A measurable predicate: a literal/command in backticks, a number, a comparison, or an
    # explicit observable verb. Absence of ALL of these means nothing can settle it.
    if (index(hay, "`") == 0 && hay !~ /[0-9]/ && hay !~ /[<>]=?|≤|≥/ && !has_verb(hay))
      print "VAGUE", id
    else if (soft_word(hay) != "")
      print "SOFT", id, soft_word(hay)
    id = ""; text = ""; acc = 0
  }
  /^[[:space:]]*-[[:space:]]*\*\*S[0-9]+/ {
    flush()
    line = $0
    match(line, /S[0-9]+/); id = substr(line, RSTART, RLENGTH)
    # Drop the "- **S1 - Label**:" prefix before storing the text. The id itself contains a
    # digit, so leaving it in would satisfy the "has a number" measurability signal for every
    # criterion and make the vagueness check permanently inert.
    text = line
    sub(/^[[:space:]]*-[[:space:]]*\*\*[^*]*\*\*[[:space:]]*:?/, "", text)
    next
  }
  id != "" && /^[[:space:]]{2,}-[[:space:]]*[Aa]cceptance[[:space:]]*:/ { acc = 1; text = text " " $0; next }
  id != "" && /^[[:space:]]{2,}-/ { text = text " " $0; next }
  id != "" && /^[[:space:]]*$/ { next }
  { flush() }
  END { flush() }
' "$body.crit" > "$body.findings"

while read -r kind id extra; do
  case "$kind" in
    NOACC) err "success criterion $id has no 'Acceptance:' line — the audit cannot re-verify it" ;;
    VAGUE) err "success criterion $id has no measurable predicate (no command, number, comparison, or observable verb) — rewrite it as a test, not a vibe" ;;
    SOFT)  warn "success criterion $id leans on '$extra' — check a verifier can settle it without judgement" ;;
  esac
done < "$body.findings"

# --- edge coverage -----------------------------------------------------------------------
# Rows look like: | S1 | boundary — ... | dismissed | N/A, input is a bounded enum |
unresolved=0
while IFS= read -r row; do
  case "$row" in \|*) ;; *) continue ;; esac
  printf '%s' "$row" | grep -iE '^\|[[:space:]]*(criterion|-+)' >/dev/null && continue
  printf '%s' "$row" | grep -F '{{' >/dev/null && continue
  status="$(printf '%s' "$row" | awk -F'|' '{ gsub(/^[ \t]+|[ \t]+$/, "", $4); print tolower($4) }')"
  reason="$(printf '%s' "$row" | awk -F'|' '{ gsub(/^[ \t]+|[ \t]+$/, "", $5); print $5 }')"
  crit="$(printf '%s' "$row" | awk -F'|' '{ gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2 }')"
  edge="$(printf '%s' "$row" | awk -F'|' '{ gsub(/^[ \t]+|[ \t]+$/, "", $3); print $3 }')"
  case "$status" in
    *dismissed*)
      [[ -z "$reason" ]] && err "edge '$edge' on $crit is dismissed with no reason — a dismissal needs an audit trail" ;;
    *unresolved*) unresolved=$((unresolved + 1)) ;;
  esac
done < <(awk '
  /^##[[:space:]]/ { inside = (tolower($0) ~ /^##[[:space:]]+edge coverage[[:space:]]*$/); next }
  inside { print }
' "$body")

[[ "$unresolved" -gt 0 ]] && warn "$unresolved edge(s) still 'unresolved' — each becomes a known gap the plan inherits"

# --- planner-decided scope ---------------------------------------------------------------
# An `## Out of scope` item nobody asked the user about is an assumption. It is tagged
# `(planner)` so Stage 6 can list it for correction; count them so the planner cannot forget.
planner_scope="$(awk '
  /^##[[:space:]]/ { inside = (tolower($0) ~ /^##[[:space:]]+out of scope/); next }
  inside && /^[[:space:]]*-/ && /\(planner\)[[:space:]]*$/ && !/\{\{/ { n++ }
  END { print n + 0 }
' "$body")"
[[ "$planner_scope" -gt 0 ]] && warn "$planner_scope out-of-scope item(s) were decided by the planner, not the user — list them under 'Scope I decided' in the Stage 6 summary"

# --- edge floor --------------------------------------------------------------------------
# The probe's output is a floor: every edge it raises for the spec's *current* criteria needs a
# row. Re-probing here also catches criteria reworded after the probe first ran. Any status
# clears a pair — `unresolved` is always an honest answer — so this can never deadlock.
probe="$(dirname "${BASH_SOURCE[0]}")/edge-probe.py"
if command -v python3 >/dev/null 2>&1 && [[ -f "$probe" ]]; then
  while IFS= read -r row; do
    crit="$(printf '%s' "$row" | awk -F'|' '{ gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2 }')"
    edge="$(printf '%s' "$row" | awk -F'|' '{ split($3, a, " — "); gsub(/^[ \t]+|[ \t]+$/, "", a[1]); print a[1] }')"
    err "edge '$edge' on $crit has no row in ## Edge coverage (edge-probe.py raises it) — add it resolved, dismissed with a reason, or unresolved: $row"
  done < <(python3 "$probe" --check "$f" 2>/dev/null | grep '^| S')
else
  warn "edge floor not checked (needs python3 and edge-probe.py beside this script)"
fi

# --- summary -----------------------------------------------------------------------------
if (( errors > 0 )); then
  echo "✗ $f: $errors structural error(s)" >&2
  exit 1
fi

echo "✓ $f: spec ok ($crit_count success criteria, $unresolved unresolved edge(s))"
exit 0
