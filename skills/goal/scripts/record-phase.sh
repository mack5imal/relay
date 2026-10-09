#!/usr/bin/env bash
# record-phase.sh — record a Relay subagent's report in the run's STATE.md.
#
# Why: the orchestrator used to hand-edit STATE.md after every report — ~700 output tokens of
# inline Python per phase, and the place bookkeeping drifts (the first end-to-end run skipped
# a phase's echo in the same turn it spent editing STATE.md). The subagent now writes its
# report to a file; this script validates it and applies every STATE.md change for that
# outcome, so the orchestrator pays one command and one summary line.
#
# Usage:
#   bash record-phase.sh <run-root> <N>                phase report     <- phases/phase-N.report.md
#   bash record-phase.sh <run-root> <N> --fix          fix report       <- phases/phase-N.fix.report.md
#   bash record-phase.sh <run-root> --audit <R>        audit report     <- phases/audit-R.report.md
#   bash record-phase.sh <run-root> --audit-fix <R>    audit-fix report <- phases/audit-fix-R.report.md
#   bash record-phase.sh <run-root> <N> --review       review report    <- phases/phase-N.review.report.md
#   bash record-phase.sh <run-root> <N> --review-fix   review fix       <- phases/phase-N.review-fix.report.md
#   bash record-phase.sh <run-root> --cleanup          tidy-up report   <- phases/cleanup.report.md
#   bash record-phase.sh <run-root> --security         security report  <- phases/security.report.md
#   bash record-phase.sh <run-root> --security-fix     security fix     <- phases/security-fix.report.md
#
#   Options (after the mode):
#     --note "<text>"        appended to the Notable events line
#     --no-report "<reason>" the dispatch returned no usable report: log it instead of reading
#                            the report file. The first per dispatch target asks for a
#                            re-dispatch; the second sets Status: BLOCKED — except for the
#                            review / cleanup / security steps, whose second no-report skips the
#                            step (an event + a FINDINGS.md line) and the run carries on.
#     --interrupted "<reason>" the dispatch was cut short by something outside the window — the
#                            session stopped (recover.sh), or the hand-back was an API error,
#                            usage limit or rate limit: log it and ask for a re-dispatch. Never
#                            counted as a no-report, so an interruption can never block the run.
#
#   Recording a target removes <run-root>/phases/in-flight when it names that target
#   (assemble-brief.sh writes it; recover.sh reads it).
#
#   Validation mirrors PROTOCOL.md: a phase report needs RELAY_PHASE_START and exactly one of
#   RELAY_PHASE_DONE / FAILURE_ESCALATE; a fix report exactly one of RELAY_PHASE_DONE /
#   FAILURE_HANDOFF; an audit report AUDIT_START, AUDIT_VERIFY, and exactly one of
#   AUDIT_COMPLETE / AUDIT_GAPS / AUDIT_HANDOFF; an audit-fix report one AUDIT_FIX; a review
#   REVIEW_START and one of REVIEW_CLEAN / REVIEW_FINDINGS; a review fix one REVIEW_FIX; a
#   cleanup CLEANUP_START and one CLEANUP_DONE; a security pass SECURITY_START and one of
#   SECURITY_CLEAN / SECURITY_FINDINGS; a security fix one SECURITY_FIX.
#
#   Routing (0.10): a phase that completes goes to its review when its spec says `Review: yes`;
#   after the last phase (and its review) the run goes to the tidy-up when STATE.md says
#   `**Cleanup:** on`, then the security pass when `**Security pass:** yes`, then the audit. A
#   missing line or field means skip — runs planned before 0.10 route exactly as before.
#   FINDINGS → the fix window; a fix → the next step. These steps never set BLOCKED.
#
#   A report claiming RELAY_PHASE_DONE must also carry RELAY_PHASE_VERIFY, and its per-criterion
#   lines must match the "Acceptance criteria: <n>" count in the phase spec's header when the
#   spec declares one — otherwise a phase could pass by reporting nothing (recorded as 0/0).
#   FAILURE_ESCALATE is exempt; a spec without the header field stays permissive.
#
#   The audit round cap (RELAY_AUDIT_MAX_ROUNDS, default 3) is enforced here as well as in the
#   audit brief: AUDIT_GAPS or an audit fix at the final round sets BLOCKED rather than asking
#   for another round.
#
#   On RELAY_PHASE_DONE and on an audit fix, the commit relay-git.sh made is looked up in git by
#   its trailers (Relay-Run + Relay-Phase / Relay-Audit-Fix) and its sha recorded in the phase
#   row's Notes and the event line; a git repo with no such commit adds "no commit found" to the
#   event and the summary line (a warning, never an invalid report). Without git, nothing changes.
#
#   Recording the same report twice changes nothing the second time (safe on resume).
#   STATE.md is rewritten atomically (temp file + mv). RELAY_DATE overrides today's date.
#
#   Prints one summary line: "recorded: <what> → next: <step>" or "→ blocked" / "→ complete — next:
#   relay-git.sh push, then RELAY_RUN_COMPLETE" (the push is the orchestrator's one step left).
#   On AUDIT_COMPLETE it adds the lines RELAY_RUN_COMPLETE copies: "⚠ Unresolved: …" (when a
#   finding stayed open or a check was skipped), "Audit coverage: <re> re-verified, <tp>
#   trust-prior (<pct>% re-verified)." (always — the percentage computed here, with a "⚠ Audit
#   coverage: …" banner before it when trust-prior is over 30%), "Design captures: …" (from the
#   audit's line of that name; "⚠ Design captures: may be out of date …" when not retaken),
#   "Findings: …" (counted from FINDINGS.md) and "Checks: skipped (--lean) — …".
#   Exits 0 when recorded, 1 when STATE.md or the report file is missing, 2 on a usage error,
#   3 when the report is invalid (treat it as a no-report dispatch).
#
# Copied into the run's <run-root>/ at Stage 7, next to assemble-brief.sh.

set -uo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: record-phase.sh <run-root> <N> [--fix | --review | --review-fix]  [--note TEXT | --no-report REASON]
       record-phase.sh <run-root> --cleanup | --security | --security-fix   [--note TEXT | --no-report REASON]
       record-phase.sh <run-root> --audit <R>                              [--note TEXT | --no-report REASON]
       record-phase.sh <run-root> --audit-fix <R>                          [--note TEXT | --no-report REASON]
       (any mode)                                                          [--interrupted REASON]
USAGE
  exit 2
}

die() { echo "record-phase.sh: $*" >&2; exit "${2:-1}"; }
is_int() { [[ "$1" =~ ^[0-9]+$ ]]; }

[ "$#" -ge 2 ] && [ -n "$1" ] || usage
runroot_arg="$1"; shift

mode=""; phase=""; round=""
case "$1" in
  --audit)     [ "$#" -ge 2 ] && is_int "$2" || usage; mode="audit";     round="$2"; shift 2 ;;
  --audit-fix) [ "$#" -ge 2 ] && is_int "$2" || usage; mode="audit-fix"; round="$2"; shift 2 ;;
  --cleanup|--security|--security-fix) mode="${1#--}"; shift ;;
  --*)         usage ;;
  *)
    is_int "$1" || usage; phase="$1"; shift
    case "${1:-}" in
      --fix)        mode="fix"; shift ;;
      --review)     mode="review"; shift ;;
      --review-fix) mode="review-fix"; shift ;;
      *)            mode="phase" ;;
    esac ;;
esac
is_check() { case "$mode" in review|review-fix|cleanup|security|security-fix) return 0 ;; esac; return 1; }

note=""; no_report=""; have_no_report=0; interrupted=""; have_interrupted=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --note)        [ "$#" -ge 2 ] || usage; note="$2"; shift 2 ;;
    --no-report)   [ "$#" -ge 2 ] && [ -n "$2" ] || usage; no_report="$2"; have_no_report=1; shift 2 ;;
    --interrupted) [ "$#" -ge 2 ] && [ -n "$2" ] || usage; interrupted="$2"; have_interrupted=1; shift 2 ;;
    *)             usage ;;
  esac
done
[ $((have_no_report + have_interrupted)) -le 1 ] || usage

[ -d "$runroot_arg" ] || die "run root not found: $runroot_arg"
runroot="${runroot_arg%/}"
state="$runroot/STATE.md"
phases="$runroot/phases"
[ -f "$state" ] || die "required file missing: $state"

today="${RELAY_DATE:-$(date +%Y-%m-%d)}"

# PROTOCOL.md dispatches at most this many audit rounds.
AUDIT_MAX_ROUNDS="${RELAY_AUDIT_MAX_ROUNDS:-3}"

case "$mode" in
  phase)     report="$phases/phase-$phase.report.md";     label="Phase $phase" ;;
  fix)       report="$phases/phase-$phase.fix.report.md"; label="Phase $phase fix" ;;
  audit)     report="$phases/audit-$round.report.md";     label="Audit round $round" ;;
  audit-fix) report="$phases/audit-fix-$round.report.md"; label="Audit fix $round" ;;
  review)    report="$phases/phase-$phase.review.report.md";     label="Phase $phase review" ;;
  review-fix) report="$phases/phase-$phase.review-fix.report.md"; label="Phase $phase review fix" ;;
  cleanup)   report="$phases/cleanup.report.md";      label="Cleanup" ;;
  security)  report="$phases/security.report.md";     label="Security pass" ;;
  security-fix) report="$phases/security-fix.report.md"; label="Security fix" ;;
esac
findings="$runroot/FINDINGS.md"

tmp="$(mktemp -d)" || die "mktemp failed"
trap 'rm -rf "$tmp"' EXIT
work="$tmp/STATE.md"
cp "$state" "$work" || die "cannot copy $state"

# --- STATE.md edit primitives (all operate on $work) --------------------------------------

# set_field <Name> <value> — "**Name:** old    <!-- c -->" -> "**Name:** value    <!-- c -->"
set_field() {
  F_NAME="$1" F_VALUE="$2" awk '
    BEGIN { name = ENVIRON["F_NAME"]; val = ENVIRON["F_VALUE"]; pre = "**" name ":**" }
    !done && index($0, pre) == 1 {
      c = index($0, "<!--"); tail = ""
      if (c > 0) { tail = substr($0, c); sub(/^[ \t]+/, "", tail); tail = "    " tail }
      print pre " " val tail; done = 1; next
    }
    { print }' "$work" > "$work.new" && mv "$work.new" "$work"
}

get_field() {
  grep -m1 -F "**$1:**" "$work" 2>/dev/null \
    | sed -E "s/^\*\*$1:\*\*[[:space:]]*//; s/[[:space:]]*<!--.*$//; s/[[:space:]]+$//"
}

# section_add <heading> <line> — append "<line>" to the "## <heading>" list unless an
# identical line is already there; drops placeholder bullets ("- ...", "- (none)",
# "- (none yet)", anything with "{{"). Creates the section at EOF if it is missing.
section_add() { section_add_to "$work" "$1" "$2"; }
section_add_to() {
  local file="$1"; shift
  S_HEAD="$1" S_LINE="$2" awk '
    BEGIN { head = "## " ENVIRON["S_HEAD"]; add = ENVIRON["S_LINE"] }
    { line[++n] = $0 }
    END {
      start = 0
      for (i = 1; i <= n; i++) if (line[i] == head) { start = i; break }
      if (start == 0) {
        for (i = 1; i <= n; i++) print line[i]
        print ""; print head; print ""; print add
        exit
      }
      end = n + 1
      for (i = start + 1; i <= n; i++) if (line[i] ~ /^## /) { end = i; break }
      present = 0; last = 0
      for (i = start + 1; i < end; i++) {
        if (line[i] == "- ..." || line[i] == "- (none)" || line[i] == "- (none yet)" || \
            (line[i] ~ /^- / && index(line[i], "{{") > 0)) { skip[i] = 1; continue }
        if (line[i] == add) present = 1
        if (line[i] ~ /^- /) last = i
      }
      if (last == 0) { last = end - 1; while (last > start && line[last] == "") last-- }
      for (i = 1; i <= n; i++) {
        if (!skip[i]) print line[i]
        if (i == last && !present) print add
      }
    }' "$file" > "$file.new" && mv "$file.new" "$file"
}

# event_add <text> — "- <date> — <text>" under Notable events, unless the same text is there
# under any date (so re-recording on a later day stays idempotent).
event_add() {
  if awk -v t=" — $1" '/^## Notable events/{f=1; next} /^## /{f=0}
       f && /^- / && length($0) >= length(t) && substr($0, length($0) - length(t) + 1) == t {found=1}
       END{exit !found}' "$work"; then
    return 0
  fi
  section_add "Notable events" "- $today — $1"
}

# row_update <N> <status> <evidence-note or ""> — edit "| N | name | status | started | completed | notes |"
row_update() {
  R_N="$1" R_STATUS="$2" R_NOTE="$3" R_DATE="$today" awk '
    BEGIN { n = ENVIRON["R_N"]; st = ENVIRON["R_STATUS"]; note = ENVIRON["R_NOTE"]; d = ENVIRON["R_DATE"] }
    {
      if ($0 ~ ("^\\| *" n " *\\|") && split($0, c, "|") >= 8) {
        for (i = 2; i <= 7; i++) { gsub(/^ +| +$/, "", c[i]) }
        c[4] = st
        if (c[5] == "" || c[5] == "—" || c[5] == "-") c[5] = d
        if (st == "completed" && (c[6] == "" || c[6] == "—" || c[6] == "-")) c[6] = d
        if (note != "" && index(c[7], note) == 0) {
          c[7] = (c[7] == "" || c[7] == "—" || c[7] == "-") ? note : c[7] "; " note
        }
        printf "| %s | %s | %s | %s | %s | %s |\n", c[2], c[3], c[4], c[5], c[6], c[7]
        found = 1; next
      }
      print
    }
    END { exit !found }' "$work" > "$work.new"
  local rc=$?
  mv "$work.new" "$work"
  return "$rc"
}

# --- report parsing -----------------------------------------------------------------------

# count_block <NAME> — lines that open a block: optional indent, the name, then EOL or a non-word char
count_block() {
  grep -cE "^[[:space:]]*$1([^A-Za-z0-9_]|\$)" "$report" 2>/dev/null || true
}

# field_after <BLOCK> <Field> — the first "Field: value" line after the block opens
field_after() {
  B_NAME="$1" B_FIELD="$2" awk '
    BEGIN { b = ENVIRON["B_NAME"]; fld = ENVIRON["B_FIELD"] ":" }
    { s = $0; sub(/^[ \t]+/, "", s) }
    !f && (s == b || index(s, b " ") == 1 || index(s, b ":") == 1) { f = 1; next }
    f && index(s, fld) == 1 { v = substr(s, length(fld) + 1); sub(/^[ \t]+/, "", v); print v; exit }' "$report"
}

phase_name() {
  local n=""
  if [ -f "$report" ]; then
    n="$(grep -m1 -E "^[[:space:]]*Phase:[[:space:]]*$phase([^0-9]|\$)" "$report" \
         | sed -E 's/^[[:space:]]*Phase:[[:space:]]*[0-9]+([[:space:]]+of[[:space:]]+[0-9]+)?[[:space:]]*[—-]+[[:space:]]*//; s/[[:space:]]+$//')"
  fi
  if [ -z "$n" ]; then
    n="$(awk -v p="$phase" -F'|' '$2 ~ ("^ *" p " *$") { gsub(/^ +| +$/, "", $3); print $3; exit }' "$work")"
  fi
  printf '%s' "${n:-phase $phase}"
}

# spec_criteria_declared — the "Acceptance criteria: <n>" count from the phase spec's
# RELAY_PHASE_START header. Prints nothing when the spec or the field is absent (older
# specs, and hand-authored run roots, may not carry it).
spec_criteria_declared() {
  local f="$phases/phase-$phase.md"
  [ -f "$f" ] || return 0
  grep -m1 -E '^[[:space:]]*Acceptance criteria:[[:space:]]*[0-9]+' "$f" 2>/dev/null \
    | grep -oE '[0-9]+' | head -1
}

total_phases() {
  local t=0 f b
  for f in "$phases"/phase-*.md; do
    [ -e "$f" ] || continue
    b="$(basename "$f")"
    [[ "$b" =~ ^phase-[0-9]+\.md$ ]] && t=$((t + 1))
  done
  if [ "$t" -eq 0 ]; then
    t="$(awk -F'|' '/^## Phase progress/{f=1; next} /^## /{f=0} f && $2 ~ /^ *[0-9]+ *$/ {c++} END{print c+0}' "$work")"
  fi
  printf '%s' "$t"
}

set_status() {
  local cur; cur="$(get_field Status)"
  case "$1" in
    IN_PROGRESS) [ "$cur" = "COMPLETE" ] || set_field Status IN_PROGRESS ;;
    *)           set_field Status "$1" ;;
  esac
}

finish() {
  set_field "Last update" "$today"
  mv "$work" "$state" || die "cannot write $state"
  # this target is recorded: it is no longer in flight
  if [ -f "$phases/in-flight" ] && grep -qxF "report: phases/$(basename "$report")" "$phases/in-flight"; then
    rm -f "$phases/in-flight"
  fi
  echo "$1"
  exit 0
}

with_note() { if [ -n "$note" ]; then printf '%s — %s' "$1" "$note"; else printf '%s' "$1"; fi; }

# commit_lookup <trailer> — sets $commit to the short sha of this run's newest commit carrying
# "Relay-Run: <run-id>" and <trailer> (made by relay-git.sh commit), searched after the
# baseline when it resolves. $commit_state: "found", "missing" (a git repo, no such commit),
# or "" (no git — fixture run roots, or a project without git: nothing is recorded).
# Ground truth from git, not the subagent's claim. Runs against the run root's repository.
commit=""; commit_state=""
commit_lookup() {
  local id range=HEAD base
  git -C "$runroot" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  commit_state="missing"
  git -C "$runroot" rev-parse --verify -q HEAD >/dev/null 2>&1 || return 0
  id="$(basename "$runroot")"
  base="$(get_field 'Baseline ref')"
  if [ -n "$base" ] && git -C "$runroot" rev-parse --verify -q "$base^{commit}" >/dev/null 2>&1; then
    range="$base..HEAD"
  fi
  commit="$(git -C "$runroot" log -1 --format=%h --all-match \
    --grep="^Relay-Run: $id\$" --grep="^$1\$" "$range" 2>/dev/null)"
  [ -n "$commit" ] && commit_state="found"
  return 0
}

# --- routing through the checks (0.10) -----------------------------------------------------

# spec_review <N> — "yes" when phase N's spec says `Review: yes`; anything else, including a
# missing line or spec (runs planned before 0.10, hand-authored run roots), is "skip".
spec_review() {
  local v
  v="$(grep -m1 -E '^Review:' "$phases/phase-$1.md" 2>/dev/null \
       | sed -E 's/^Review:[[:space:]]*//; s/[[:space:]]+$//' | tr '[:upper:]' '[:lower:]')"
  [ "$v" = "yes" ] && echo yes || echo skip
}

# check_on <Cleanup|Security pass> — the STATE.md field turns the step on: "on" / "yes" (first
# word). Missing, a placeholder, "off — …" or "skip — …" is off.
check_on() {
  local v w; v="$(get_field "$1" | tr '[:upper:]' '[:lower:]')"; w="${v%% *}"
  case "$1" in
    Cleanup)         [ "$w" = "on" ] ;;
    "Security pass") [ "$w" = "yes" ] ;;
    *)               return 1 ;;
  esac
}

# route_after <phase:N | cleanup | security> — the step after the one just finished (phase N
# with its review, the tidy-up, the security pass): sets Current phase and $next.
next=""
route_after() {
  local n t
  case "$1" in
    phase:*)
      n="${1#phase:}"; t="$(total_phases)"
      if [ "$n" -lt "$t" ]; then set_field "Current phase" "$((n + 1))"; next="phase $((n + 1))"; return; fi
      if check_on Cleanup; then set_field "Current phase" "cleanup"; next="cleanup"; return; fi
      route_after cleanup ;;
    cleanup)
      if check_on "Security pass"; then set_field "Current phase" "security"; next="security"; return; fi
      route_after security ;;
    security)
      set_field "Current phase" "audit"; next="audit" ;;
  esac
}

# route_check_done — where the current check mode goes once it is finished (or skipped)
route_check_done() {
  case "$mode" in
    review|review-fix)     route_after "phase:$phase" ;;
    cleanup)               route_after cleanup ;;
    security|security-fix) route_after security ;;
  esac
}

# block_list_count <BLOCK> <Field> — "- " bullets under "Field:" inside the block
block_list_count() {
  B_NAME="$1" B_FIELD="$2" awk '
    BEGIN { b = ENVIRON["B_NAME"]; fld = ENVIRON["B_FIELD"] ":" }
    { s = $0; sub(/^[ \t]+/, "", s) }
    !f && (s == b || index(s, b " ") == 1) { f = 1; next }
    f && !g && index(s, fld) == 1 { g = 1; next }
    f && g && s ~ /^- / { c++; next }
    f && g { exit }
    END { print c + 0 }' "$report"
}

# findings_skip <text> — a "## Skipped steps" line in FINDINGS.md (created when missing)
findings_skip() {
  [ -f "$findings" ] || printf '# Findings\n' > "$findings"
  section_add_to "$findings" "Skipped steps" "- $1"
}

# --- interrupted dispatch -----------------------------------------------------------------
# The window was cut short from outside (the session stopped, or an API error / usage limit
# ended it): not the window's failure, so it is never a strike — the run re-dispatches it, and
# the new brief lists what the earlier window left (assemble-brief.sh).
if [ "$have_interrupted" -eq 1 ]; then
  { [ "$mode" = "phase" ] || [ "$mode" = "fix" ]; } && row_update "$phase" in_progress "" >/dev/null 2>&1
  section_add "Failure log" "- $label: dispatch interrupted ($interrupted) — re-dispatched"
  set_status IN_PROGRESS
  event_add "$(with_note "$label: dispatch interrupted ($interrupted) — re-dispatching")"
  finish "recorded: $(printf '%s' "$label" | tr '[:upper:]' '[:lower:]') dispatch interrupted → next: re-dispatch"
fi

# --- no-report dispatch -------------------------------------------------------------------
if [ "$have_no_report" -eq 1 ]; then
  prior="$(awk -v l="- $label: dispatch " '/^## Failure log/{f=1; next} /^## /{f=0}
            f && index($0, l) == 1 && /returned no report/ {c++} END{print c+0}' "$work")"
  k=$((prior + 1))
  # A dispatched phase is in progress even when its window returned nothing usable.
  { [ "$mode" = "phase" ] || [ "$mode" = "fix" ]; } && row_update "$phase" in_progress "" >/dev/null 2>&1
  section_add "Failure log" "- $label: dispatch $k returned no report ($no_report)"
  # A check never blocks the run (owner): its second no-report skips the step, and
  # RELAY_RUN_COMPLETE points the owner at FINDINGS.md.
  if [ "$k" -ge 2 ] && is_check; then
    findings_skip "$label: skipped — dispatch returned no report twice ($no_report)"
    set_status IN_PROGRESS
    route_check_done
    event_add "$(with_note "$label: dispatch $k returned no report ($no_report) — step skipped, run continues")"
    finish "recorded: $(printf '%s' "$label" | tr '[:upper:]' '[:lower:]') dispatch $k no report → skipped — next: $next"
  fi
  if [ "$k" -ge 2 ]; then
    set_status BLOCKED
    event_add "$(with_note "$label: dispatch $k returned no report ($no_report) — run BLOCKED")"
    finish "recorded: $(printf '%s' "$label" | tr '[:upper:]' '[:lower:]') dispatch $k no report → blocked"
  fi
  set_status IN_PROGRESS
  event_add "$(with_note "$label: dispatch $k returned no report ($no_report) — re-dispatching")"
  finish "recorded: $(printf '%s' "$label" | tr '[:upper:]' '[:lower:]') dispatch $k no report → next: re-dispatch"
fi

# --- validate the report ------------------------------------------------------------------
[ -f "$report" ] || die "report not found: $report"

invalid() { echo "record-phase.sh: invalid report: $report — $1" >&2; exit 3; }

case "$mode" in
  phase)
    [ "$(count_block RELAY_PHASE_START)" -ge 1 ] || invalid "no RELAY_PHASE_START"
    d="$(count_block RELAY_PHASE_DONE)"; e="$(count_block FAILURE_ESCALATE)"; h="$(count_block FAILURE_HANDOFF)"
    [ $((d + e)) -eq 1 ] && [ "$h" -eq 0 ] || invalid "needs exactly one of RELAY_PHASE_DONE / FAILURE_ESCALATE (found $d / $e, handoff $h)" ;;
  fix)
    d="$(count_block RELAY_PHASE_DONE)"; h="$(count_block FAILURE_HANDOFF)"
    [ $((d + h)) -eq 1 ] || invalid "needs exactly one of RELAY_PHASE_DONE / FAILURE_HANDOFF (found $d / $h)" ;;
  audit)
    [ "$(count_block AUDIT_START)" -ge 1 ]  || invalid "no AUDIT_START"
    [ "$(count_block AUDIT_VERIFY)" -ge 1 ] || invalid "no AUDIT_VERIFY"
    c="$(count_block AUDIT_COMPLETE)"; g="$(count_block AUDIT_GAPS)"; h="$(count_block AUDIT_HANDOFF)"
    [ $((c + g + h)) -eq 1 ] || invalid "needs exactly one of AUDIT_COMPLETE / AUDIT_GAPS / AUDIT_HANDOFF (found $c / $g / $h)" ;;
  audit-fix)
    [ "$(count_block AUDIT_FIX)" -eq 1 ] || invalid "needs exactly one AUDIT_FIX" ;;
  review)
    [ "$(count_block REVIEW_START)" -ge 1 ] || invalid "no REVIEW_START"
    c="$(count_block REVIEW_CLEAN)"; g="$(count_block REVIEW_FINDINGS)"
    [ $((c + g)) -eq 1 ] || invalid "needs exactly one of REVIEW_CLEAN / REVIEW_FINDINGS (found $c / $g)" ;;
  review-fix)
    [ "$(count_block REVIEW_FIX)" -eq 1 ] || invalid "needs exactly one REVIEW_FIX" ;;
  cleanup)
    [ "$(count_block CLEANUP_START)" -ge 1 ] || invalid "no CLEANUP_START"
    [ "$(count_block CLEANUP_DONE)" -eq 1 ] || invalid "needs exactly one CLEANUP_DONE" ;;
  security)
    [ "$(count_block SECURITY_START)" -ge 1 ] || invalid "no SECURITY_START"
    c="$(count_block SECURITY_CLEAN)"; g="$(count_block SECURITY_FINDINGS)"
    [ $((c + g)) -eq 1 ] || invalid "needs exactly one of SECURITY_CLEAN / SECURITY_FINDINGS (found $c / $g)" ;;
  security-fix)
    [ "$(count_block SECURITY_FIX)" -eq 1 ] || invalid "needs exactly one SECURITY_FIX" ;;
esac

# A completed phase must show its work. RELAY_PHASE_VERIFY carries the per-criterion
# pass/fail lines, so without it a report claiming RELAY_PHASE_DONE records 0/0 criteria
# and advances the run on no evidence at all. (The audit case above already required its
# own AUDIT_VERIFY; this restores the same symmetry for phases.) FAILURE_ESCALATE is
# exempt: a phase that escalated may never have reached a verify step.
if { [ "$mode" = "phase" ] || [ "$mode" = "fix" ]; } && [ "$(count_block RELAY_PHASE_DONE)" -eq 1 ]; then
  [ "$(count_block RELAY_PHASE_VERIFY)" -ge 1 ] \
    || invalid "RELAY_PHASE_DONE without RELAY_PHASE_VERIFY (no per-criterion results)"
  declared="$(spec_criteria_declared)"
  if [ -n "$declared" ]; then
    reported="$(grep -cE '^[[:space:]]*- C[0-9]+ .*:[[:space:]]*(pass|fail)[[:space:]]*$' "$report" || true)"
    [ "$reported" -eq "$declared" ] \
      || invalid "report lists $reported acceptance criteria, spec declares $declared"
  fi
fi

# --- phase / fix outcomes -----------------------------------------------------------------
if [ "$mode" = "phase" ] || [ "$mode" = "fix" ]; then
  name="$(phase_name)"
  total="$(total_phases)"
  what="phase $phase"; [ "$mode" = "fix" ] && what="phase $phase fix"
  evidence_note="Evidence: phases/phase-$phase.evidence.md"
  row_note=""

  if [ "$(count_block RELAY_PHASE_DONE)" -eq 1 ]; then
    crit_total="$(grep -cE '^[[:space:]]*- C[0-9]+ .*:[[:space:]]*(pass|fail)[[:space:]]*$' "$report" || true)"
    crit_pass="$(grep -cE '^[[:space:]]*- C[0-9]+ .*:[[:space:]]*pass[[:space:]]*$' "$report" || true)"
    files="$(grep -m1 -E '^[[:space:]]*Files changed:' "$report" | sed -E 's/^[[:space:]]*Files changed:[[:space:]]*//' | grep -oE '^[0-9]+' || true)"
    # "MEMORY_SAVED: a (why, with commas), b" -> "a b"; "none — …" -> ""
    memories="$(grep -m1 -E '^[[:space:]]*MEMORY_SAVED:' "$report" \
      | sed -E 's/^[[:space:]]*MEMORY_SAVED:[[:space:]]*//; s/\([^)]*\)//g' | tr ',' '\n' \
      | awk '{ n = $1; if (n ~ /^[A-Za-z0-9_.-]+$/ && tolower(n) != "none") print n }')"
    memory="$(printf '%s' "$memories" | paste -sd ',' - | sed 's/,/, /g')"

    row_update "$phase" completed "$evidence_note" || row_note=" (no row for phase $phase in STATE.md)"
    commit_lookup "Relay-Phase: $phase"
    [ "$commit_state" = "found" ] && row_update "$phase" completed "Commit: $commit" >/dev/null 2>&1
    set_status IN_PROGRESS
    if [ "$(spec_review "$phase")" = "yes" ]; then set_field "Current phase" "review $phase"; next="review $phase"
    else route_after "phase:$phase"; fi

    eng="$(grep -m1 -E '^[[:space:]]*Engineering:' "$report" | sed -E 's/^[[:space:]]*Engineering:[[:space:]]*//')"
    if [ -n "$eng" ]; then
      ENG="$eng" PH="$phase" awk '
        BEGIN {
          n = split(ENVIRON["ENG"], parts, / *· */)
          for (i = 1; i <= n; i++) {
            p = parts[i]; sub(/^ +/, "", p); sp = index(p, " ")
            if (sp == 0) continue
            k = substr(p, 1, sp - 1); v = substr(p, sp + 1)
            op = index(v, " (")
            if (op > 0 && v ~ /\)$/) key[k] = substr(v, 1, op + 1) "phase " ENVIRON["PH"] ", " substr(v, op + 2)
            else key[k] = v " (phase " ENVIRON["PH"] ")"
          }
          map["Build"] = "build"; map["Typecheck"] = "typecheck"; map["Lint"] = "lint"; map["Tests"] = "tests"
        }
        /^## Engineering check status/ { f = 1; print; next }
        /^## / { f = 0 }
        f && match($0, /^- (Build|Typecheck|Lint|Tests):/) {
          label = substr($0, 3, RLENGTH - 3)
          if (map[label] in key) { print "- " label ": " key[map[label]]; next }
        }
        { print }' "$work" > "$work.new" && mv "$work.new" "$work"
    fi

    if [ -n "$memories" ]; then
      while IFS= read -r m; do section_add "Carryover" "- $m (phase $phase)"; done <<< "$memories"
    fi

    detail="$crit_pass/$crit_total criteria pass"
    if [ "$(count_block FAILURE_PROBE)" -ge 1 ]; then
      detail="$detail after one probe retry"
      # An in-window retry that worked is still a failure worth seeing: the STATE.md template
      # promises one line per FAILURE_PROBE, and tunez's phase 10 retry was otherwise only in
      # run-report.py. section_add drops the template's placeholder and never adds a line twice.
      probed="$(field_after FAILURE_PROBE 'Failed criterion')"
      section_add "Failure log" "- Phase $phase ($name): ${probed:-unknown criterion} — attempt 1 failed — passed after the probe retry"
    fi
    [ -n "$files" ] && detail="$detail, $files files changed"
    [ -n "$memory" ] && detail="$detail, memory $memory"
    commit_warn=""
    case "$commit_state" in
      found)   detail="$detail, commit $commit" ;;
      missing) detail="$detail, no commit found"; commit_warn=" (no commit found)" ;;
    esac
    if [ "$mode" = "fix" ]; then event_add "$(with_note "Phase $phase complete via fix window: $detail")"
    else event_add "$(with_note "Phase $phase complete: $detail")"; fi

    summary="$crit_pass/$crit_total pass"; [ -n "$memory" ] && summary="$summary, memory $memory"
    [ "$commit_state" = "found" ] && summary="$summary, commit $commit"
    finish "recorded: $what done ($summary)$row_note$commit_warn → next: $next"
  fi

  failed="$(field_after FAILURE_ESCALATE 'Failed criterion')"
  if [ "$(count_block FAILURE_ESCALATE)" -eq 1 ]; then
    row_update "$phase" in_progress "" || row_note=" (no row for phase $phase in STATE.md)"
    set_status IN_PROGRESS
    set_field "Current phase" "$phase"
    section_add "Failure log" "- Phase $phase ($name): ${failed:-unknown criterion} — attempts 1–2 failed — fix spec dispatched"
    event_add "$(with_note "Phase $phase escalated: ${failed:-unknown criterion} — fix spec dispatched")"
    finish "recorded: $what escalated$row_note → next: fix phase $phase"
  fi

  failed="$(field_after FAILURE_HANDOFF 'Failed criterion')"
  set_status BLOCKED
  section_add "Failure log" "- Phase $phase ($name): ${failed:-unknown criterion} — fix window failed — BLOCKED, user intervention required"
  event_add "$(with_note "Phase $phase blocked: fix window failed (${failed:-unknown criterion}) — run BLOCKED")"
  finish "recorded: $what failed → blocked"
fi

# --- review / cleanup / security outcomes (never blocked) --------------------------------

# commit_note <trailer> <expected: 1|0> — ", commit <sha>" / ", no commit found" for the event
# and summary; "no commit found" only when the window says it changed something.
commit_note=""; commit_warn=""
commit_note_for() {
  commit_lookup "$1"
  commit_note=""; commit_warn=""
  case "$commit_state" in
    found)   commit_note=", commit $commit" ;;
    missing) if [ "$2" = "1" ]; then commit_note=", no commit found"; commit_warn=" (no commit found)"; fi ;;
  esac
}
first_int() { printf '%s' "$1" | grep -oE '[0-9]+' | head -1; }

if [ "$mode" = "review" ] || [ "$mode" = "security" ]; then
  if [ "$mode" = "review" ]; then clean=REVIEW_CLEAN; found=REVIEW_FINDINGS; what="phase $phase review"; ev="Phase $phase review"
  else clean=SECURITY_CLEAN; found=SECURITY_FINDINGS; what="security pass"; ev="Security pass"; fi
  set_status IN_PROGRESS
  if [ "$(count_block "$clean")" -eq 1 ]; then
    [ "$mode" = "review" ] && row_update "$phase" completed "Review: clean" >/dev/null 2>&1
    route_check_done
    event_add "$(with_note "$ev: clean")"
    finish "recorded: $what clean → next: $next"
  fi
  fl="$(field_after "$found" Findings)"
  n="$(first_int "$fl")"; n="${n:-?}"
  d="$(printf '%s' "$fl" | grep -oE '[0-9]+ deferred' | grep -oE '[0-9]+' || true)"
  dpart=""; [ -n "$d" ] && [ "$d" != "0" ] && dpart=", $d deferred to FINDINGS.md"
  nf="$n findings"; [ "$n" = "1" ] && nf="1 finding"
  if [ "$mode" = "review" ]; then
    row_update "$phase" completed "Review: $nf" >/dev/null 2>&1
    set_field "Current phase" "review $phase"; next="review fix $phase"
  else
    set_field "Current phase" "security"; next="security fix"
  fi
  event_add "$(with_note "$ev: $nf$dpart — fix dispatched")"
  finish "recorded: $what findings ($n) → next: $next"
fi

if [ "$mode" = "review-fix" ] || [ "$mode" = "security-fix" ]; then
  if [ "$mode" = "review-fix" ]; then blk=REVIEW_FIX; tr="Relay-Review-Fix: $phase"; what="phase $phase review fix"; ev="Phase $phase review fix"
  else blk=SECURITY_FIX; tr="Relay-Security-Fix: 1"; what="security fix"; ev="Security fix"; fi
  fixed="$(field_after "$blk" Fixed)"; fixed="${fixed:-?}"
  unres="$(block_list_count "$blk" Unresolved)"
  a="$(first_int "$fixed")"
  commit_note_for "$tr" "$([ "${a:-0}" -gt 0 ] 2>/dev/null && echo 1 || echo 0)"
  upart=""; [ "$unres" -gt 0 ] && upart=", $unres unresolved → FINDINGS.md"
  if [ "$mode" = "review-fix" ]; then
    row_update "$phase" completed "Review fix: $fixed fixed" >/dev/null 2>&1
    [ "$commit_state" = "found" ] && row_update "$phase" completed "Review-fix commit: $commit" >/dev/null 2>&1
  fi
  set_status IN_PROGRESS
  route_check_done
  event_add "$(with_note "$ev: $fixed fixed$upart$commit_note")"
  finish "recorded: $what ($fixed fixed$upart$commit_note)$commit_warn → next: $next"
fi

if [ "$mode" = "cleanup" ]; then
  result="$(field_after CLEANUP_DONE Result)"; result="${result:-?}"
  fx="$(field_after CLEANUP_DONE Fixed)"
  n="$(first_int "$fx")"
  m="$(printf '%s' "$fx" | sed -nE 's/.*[Dd]eferred:[[:space:]]*([0-9]+).*/\1/p')"
  applied=0; case "$result" in applied*) applied=1 ;; esac
  commit_note_for "Relay-Cleanup: 1" "$applied"
  set_status IN_PROGRESS
  route_check_done
  event_add "$(with_note "Cleanup: $result — ${n:-?} fixed, ${m:-?} deferred$commit_note")"
  finish "recorded: cleanup ($result — ${n:-?} fixed, ${m:-?} deferred$commit_note)$commit_warn → next: $next"
fi

# --- audit outcomes -----------------------------------------------------------------------

# count_before <text> <word> — the integer written just before <word> ("77 pass" → 77), or nothing
count_before() { printf '%s' "$1" | grep -oE "[0-9]+[[:space:]]*$2" | head -1 | grep -oE '^[0-9]+'; }
# count0 <text> <word> — count_before, 0 when absent
count0() { local v; v="$(count_before "$1" "$2")"; printf '%s' "${v:-0}"; }

# coverage_counts — "<re_verified> <trust_prior>" from AUDIT_COMPLETE: the two counts on its
# "Audit coverage:" line, or, when that line is missing or unreadable, the sums PHASE-BRIEF.md
# step 8 defines them as (criteria passed + deliverables present + spec criteria met; the
# trust-prior criteria and spec criteria). Prints nothing when the block carries no counts.
coverage_counts() {
  local cov crit deliv spec re tp
  cov="$(field_after AUDIT_COMPLETE 'Audit coverage')"
  re="$(count_before "$cov" 're-verified')"; tp="$(count_before "$cov" 'trust-prior')"
  if [ -n "$re" ] && [ -n "$tp" ]; then printf '%s %s' "$re" "$tp"; return 0; fi
  crit="$(field_after AUDIT_COMPLETE 'Acceptance criteria')"
  deliv="$(field_after AUDIT_COMPLETE 'Deliverables')"
  spec="$(field_after AUDIT_COMPLETE 'Spec criteria')"
  [ -n "$crit$deliv$spec" ] || return 0
  re=$(( $(count0 "$crit" pass) + $(count0 "$deliv" present) + $(count0 "$spec" met) ))
  tp=$(( $(count0 "$crit" trust-prior) + $(count0 "$spec" trust-prior) ))
  printf '%s %s' "$re" "$tp"
}

# coverage_line — "Audit coverage: <re> re-verified, <tp> trust-prior (<pct>% re-verified)."
# with the percentage computed here, not by the audit or the orchestrator (the lean run printed
# the trust-prior share as "(0%)"), preceded by the ⚠ banner when trust-prior is over 30%.
coverage_line() {
  local c re tp share cov ti eo depth=""
  c="$(coverage_counts)"
  if [ -z "$c" ]; then echo "Audit coverage: not reported — AUDIT_COMPLETE carried no counts."; return 0; fi
  re="${c% *}"; tp="${c#* }"
  # rounded down, so 100% only ever means nothing was taken on trust
  if [ $((re + tp)) -eq 0 ]; then share="nothing checked"; else share="$((re * 100 / (re + tp)))% re-verified"; fi
  # What "re-verified" rested on (PHASE-BRIEF.md audit step 8): tunez read "100% re-verified"
  # while 146 of its 323 checks only confirmed a file exists. An audit that reports the split
  # gets it said in plain words; one that does not (older runs) prints exactly as before.
  cov="$(field_after AUDIT_COMPLETE 'Audit coverage')"
  ti="$(count_before "$cov" 'tests inspected')"; eo="$(count_before "$cov" 'existence only')"
  if [ -n "$ti" ] && [ -n "$eo" ]; then
    depth=" — $ti spec criteria's tests inspected; $eo checks only confirmed a file exists"
  fi
  if [ $((tp * 100)) -gt $((30 * (re + tp))) ]; then
    echo "⚠ Audit coverage: $re re-verified, $tp trust-prior ($share). Eyeball UI/UX before merging."
  fi
  echo "Audit coverage: $re re-verified, $tp trust-prior ($share)$depth."
}

# completion_lines — the lines RELAY_RUN_COMPLETE copies, each on its own line after the summary:
# a ⚠ line when a correctness / security finding stayed open or a check was skipped, the audit
# coverage line (always; with its own ⚠ banner when trust-prior is over 30%), the findings counts
# from FINDINGS.md, and the --lean checks line.
completion_lines() {
  local dcl=0 k=0 sk=0 pc=0 an=0 lean="" nl=$'\n' out="" r=0 t=0 f v
  if [ -f "$findings" ]; then
    dcl="$(grep -cE '^- \[cleanup\]' "$findings" || true)"
    k="$(grep -cE '^- \[(correctness|security)\]' "$findings" || true)"
    pc="$(grep -cE '^- \[plan\]' "$findings" || true)"
    an="$(grep -cE '^- \[audit\]' "$findings" || true)"
    sk="$(awk '/^## Skipped steps/{f=1; next} /^## /{f=0} f && /^- /{c++} END{print c+0}' "$findings")"
  fi
  if [ $((k + sk)) -gt 0 ]; then
    out="$out${nl}⚠ Unresolved: $k correctness/security finding(s) open, $sk check(s) skipped — see $findings"
  fi
  # A [plan] bullet is a fix a check kept although it changed a line relay decided while planning
  # (PHASE-BRIEF.md §3b). The fix went in, so it is not "unresolved" — but the owner approved the
  # plan as written, so the run's last message must say it changed.
  if [ "$pc" -gt 0 ]; then
    out="$out${nl}⚠ Plan changed: $pc check fix(es) went against the plan summary — see $findings"
  fi
  out="$out${nl}$(coverage_line)"
  # The audit retakes the design screenshots (PHASE-BRIEF.md audit step 4b): the owner compares
  # them with the design after the run, and the checks after the polish phase can change screens.
  # A retake that could not run is not a gap, so it is said here. No line = no design capture.
  v="$(field_after AUDIT_COMPLETE 'Design captures')"
  case "$v" in
    "") ;;
    [Rr]etaken*) out="$out${nl}Design captures: retaken at the end — compare $runroot/design-check/<id>.png with design/screens/<id>.png" ;;
    [Nn]ot\ retaken*)
      v="$(printf '%s' "$v" | sed -E 's/^[Nn]ot retaken[[:space:]]*[—–-]*[[:space:]]*//')"
      out="$out${nl}⚠ Design captures: may be out of date — not retaken${v:+: $v}" ;;
    *) out="$out${nl}Design captures: $v" ;;
  esac
  if [ $((dcl + k + sk + pc + an)) -gt 0 ]; then
    v=""; [ "$pc" -gt 0 ] && v=" · $pc plan changes"
    [ "$an" -gt 0 ] && v="$v · $an audit notes"
    out="$out${nl}Findings: $dcl cleanup deferred · $k correctness/security open · $sk checks skipped$v — $findings"
  fi
  for f in "$phases"/phase-*.md; do
    [ -e "$f" ] || continue
    [[ "$(basename "$f")" =~ ^phase-[0-9]+\.md$ ]] || continue
    t=$((t + 1))
    grep -m1 -E '^Review:' "$f" | grep -iE '^Review:[[:space:]]*skip.*--lean' >/dev/null && r=$((r + 1))
  done
  if [ "$r" -gt 0 ]; then
    if [ "$r" -eq "$t" ]; then lean="phase reviews"; else lean="phase reviews ($r of $t)"; fi
  fi
  v="$(get_field Cleanup)"
  case "$v" in [Oo]ff*--lean*) lean="${lean:+$lean, }tidy-up" ;; esac
  v="$(get_field 'Security pass')"
  case "$v" in [Ss]kip*--lean*) lean="${lean:+$lean, }security pass" ;; esac
  [ -n "$lean" ] && out="$out${nl}Checks: skipped (--lean) — $lean"
  printf '%s' "$out"
}

if [ "$mode" = "audit" ]; then
  if [ "$(count_block AUDIT_COMPLETE)" -eq 1 ]; then
    crit="$(field_after AUDIT_COMPLETE 'Acceptance criteria')"
    deliv="$(field_after AUDIT_COMPLETE 'Deliverables')"
    spec="$(field_after AUDIT_COMPLETE 'Spec criteria')"
    cov="$(coverage_line | tail -1 | sed -E 's/^Audit coverage: //; s/\.$//')"
    set_status COMPLETE
    set_field "Current phase" "complete"
    spec_part=""
    [ -n "$spec" ] && spec_part="; spec ${spec}"
    event_add "$(with_note "Audit round $round: clean (criteria ${crit:-?}; deliverables ${deliv:-?}${spec_part}; coverage ${cov:-?}) — run COMPLETE")"
    finish "recorded: audit round $round clean → complete — next: relay-git.sh push, then RELAY_RUN_COMPLETE$(completion_lines)"
  fi
  if [ "$(count_block AUDIT_GAPS)" -eq 1 ]; then
    gaps="$(awk '/^[ \t]*AUDIT_GAPS/{f=1; next} f && /^[ \t]*Gaps:/{g=1; next}
                 f && g && /^[ \t]*- /{c++; next} f && g {exit} END{print c+0}' "$report")"
    # The cap is documented as the audit subagent's job (round 3 with gaps -> AUDIT_HANDOFF),
    # but nothing enforced it here: a round-3 AUDIT_GAPS used to print "next: audit fix 3",
    # and the audit-fix branch would then ask for round 4, looping indefinitely. Enforce it.
    if [ "$round" -ge "$AUDIT_MAX_ROUNDS" ]; then
      set_status BLOCKED
      section_add "Failure log" "- Audit round $round: $gaps gaps persist after $AUDIT_MAX_ROUNDS rounds — BLOCKED, user intervention required"
      event_add "$(with_note "Audit round $round: $gaps gaps at the final round — run BLOCKED")"
      finish "recorded: audit round $round gaps ($gaps) at final round → blocked"
    fi
    set_status IN_PROGRESS
    set_field "Current phase" "audit"
    event_add "$(with_note "Audit round $round: $gaps gaps — audit fix dispatched")"
    finish "recorded: audit round $round gaps ($gaps) → next: audit fix $round"
  fi
  set_status BLOCKED
  section_add "Failure log" "- Audit round $round: gaps persist after 3 rounds — BLOCKED, user intervention required"
  event_add "$(with_note "Audit round $round: gaps persist — run BLOCKED")"
  finish "recorded: audit round $round handoff → blocked"
fi

# --- audit-fix outcome --------------------------------------------------------------------
addressed="$(field_after AUDIT_FIX 'Gaps addressed')"
commit_lookup "Relay-Audit-Fix: $round"
fix_commit=""; commit_warn=""
case "$commit_state" in
  found)   fix_commit=", commit $commit" ;;
  missing) fix_commit=", no commit found"; commit_warn=" (no commit found)" ;;
esac
event_add "$(with_note "Audit fix $round: ${addressed:-?} gaps addressed$fix_commit")"
if [ "$round" -ge "$AUDIT_MAX_ROUNDS" ]; then
  set_status BLOCKED
  section_add "Failure log" "- Audit fix $round: no round remains after $AUDIT_MAX_ROUNDS audit rounds — BLOCKED, user intervention required"
  finish "recorded: audit fix $round (${addressed:-?} gaps addressed$fix_commit)$commit_warn → blocked ($AUDIT_MAX_ROUNDS audit rounds exhausted)"
fi
set_status IN_PROGRESS
finish "recorded: audit fix $round (${addressed:-?} gaps addressed$fix_commit)$commit_warn → next: audit round $((round + 1))"
