#!/usr/bin/env bash
# preflight.sh — Stage 6.5's pre-flight smoke check, start to finish: run every phase's
# mandatory commands once, check the working tree, log the outcome to STATE.md, and print the
# PREFLIGHT_GREEN / PREFLIGHT_RED block.
#
# Why a script: the planner used to write this as an inline loop in the user's zsh, where it
# broke on word splitting and `$pipestatus` (two runs, typos both times), and it never printed
# PREFLIGHT_GREEN — the event went to STATE.md and the owner saw nothing. What the owner must
# see is printed by the script, so it cannot be skipped.
#
# Usage:
#   preflight.sh <run-root> [--account '<status command>' '<login command>']...
#   preflight.sh <run-root> --bypass
#
#   Run from the project root. The commands are the deduplicated union of every
#   <run-root>/phases/phase-N.md `## Mandatory commands` bullet, then each --account status
#   command (`gh auth status`, `vercel whoami` — a red one prints `run: ! <login command>`).
#   Each runs once through run-logged.sh, its full output in <run-root>/logs/preflight/; the
#   block shows the exit code and the last 5 lines of any that failed. Then
#   `relay-git.sh preflight` checks the working tree — after the commands, so anything they
#   created is caught too — and its lines (the branch plan, warnings, a dirty tree's paths) go
#   into the block as they are.
#
#   Appends one line to STATE.md's `## Notable events`:
#     Pre-flight green: <N> command(s) clean.
#     Pre-flight red: working tree has <n> uncommitted changes.     (the tree decides first)
#     Pre-flight red: <command> exited <code>.                     (the first failing command)
#   --bypass only logs "Pre-flight bypassed by user." (the owner chose to dispatch on a red
#   command) and prints that line.
#
#   RELAY_DATE overrides today's date. Exits 0 green, 1 a command failed (tree clean),
#   3 the working tree is dirty, 2 usage error or no STATE.md.
#
# Planner-only (not copied at Stage 7). Tested by tests/preflight.test.sh.

set -uo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: preflight.sh <run-root> [--account '<status command>' '<login command>']...
       preflight.sh <run-root> --bypass
USAGE
  exit 2
}

[ "$#" -ge 1 ] && [ -n "$1" ] || usage
runroot="${1%/}"; shift
state="$runroot/STATE.md"
[ -f "$state" ] || { echo "preflight.sh: STATE.md not found: $state" >&2; exit 2; }
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
today="${RELAY_DATE:-$(date +%Y-%m-%d)}"

bypass=0
acct_cmds=(); acct_logins=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --bypass)  [ "$#" -eq 1 ] && [ "${#acct_cmds[@]}" -eq 0 ] || usage; bypass=1; shift ;;
    --account) [ "$#" -ge 3 ] && [ -n "$2" ] && [ -n "$3" ] || usage
               acct_cmds+=("$2"); acct_logins+=("$3"); shift 3 ;;
    *)         usage ;;
  esac
done

# event_add <text> — append "- <date> — <text>" to ## Notable events (after its last bullet;
# the section is created at EOF when missing). Atomic: temp file + mv.
event_add() {
  E_LINE="- $today — $1" awk '
    BEGIN { add = ENVIRON["E_LINE"] }
    { line[++n] = $0 }
    END {
      start = 0
      for (i = 1; i <= n; i++) if (line[i] == "## Notable events") { start = i; break }
      if (start == 0) {
        for (i = 1; i <= n; i++) print line[i]
        print ""; print "## Notable events"; print ""; print add
        exit
      }
      end = n + 1
      for (i = start + 1; i <= n; i++) if (line[i] ~ /^## /) { end = i; break }
      last = 0
      for (i = start + 1; i < end; i++) if (line[i] ~ /^- /) last = i
      if (last == 0) { last = end - 1; while (last > start && line[last] == "") last-- }
      for (i = 1; i <= n; i++) { print line[i]; if (i == last) print add }
    }' "$state" > "$state.new" && mv "$state.new" "$state"
}

if [ "$bypass" -eq 1 ]; then
  event_add "Pre-flight bypassed by user."
  echo "Pre-flight bypassed by user — logged to $state."
  exit 0
fi

# --- the commands ---------------------------------------------------------------------------
cmds=(); logins=()
while IFS= read -r c; do
  [ -n "$c" ] && { cmds+=("$c"); logins+=(""); }
done < <(
  for f in "$runroot"/phases/phase-*.md; do
    [ -e "$f" ] || continue
    [[ "$(basename "$f")" =~ ^phase-[0-9]+\.md$ ]] || continue
    awk '/^##[[:space:]]/ { inside = (tolower($0) ~ /^##[[:space:]]+mandatory commands/); next }
         inside && /^[[:space:]]*-[[:space:]]*[^[:space:]]/ { l = $0; sub(/^[[:space:]]*-[[:space:]]*/, "", l); sub(/[[:space:]]+$/, "", l); if (l != "...") print l }' "$f"
  done | awk '!seen[$0]++'
)
for i in "${!acct_cmds[@]}"; do cmds+=("${acct_cmds[$i]}"); logins+=("${acct_logins[$i]}"); done

lines=(); ok=0; failed=0; first_fail=""
for i in "${!cmds[@]}"; do
  c="${cmds[$i]}"
  slug="$(printf '%s' "$c" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-|-$//g' | cut -c1-60)"
  log="$runroot/logs/preflight/$((i + 1))-${slug:-command}.log"
  bash "$here/run-logged.sh" "$log" "$c" >/dev/null; rc=$?
  if [ "$rc" -eq 0 ]; then
    ok=$((ok + 1)); lines+=("- ok    $c")
  else
    failed=$((failed + 1)); [ -n "$first_fail" ] || first_fail="$c exited $rc"
    lines+=("- FAIL  $c — exit $rc (log: $log)")
    while IFS= read -r t; do lines+=("      $t"); done < <(tail -n 5 "$log" 2>/dev/null)
    [ -n "${logins[$i]}" ] && lines+=("      run: ! ${logins[$i]}")
  fi
done

# --- the working tree -----------------------------------------------------------------------
git_out="$(bash "$here/relay-git.sh" preflight "$runroot" 2>&1)"; git_rc=$?
dirty=0; n_dirty=0
if [ "$git_rc" -eq 1 ]; then
  dirty=1
  n_dirty="$(printf '%s\n' "$git_out" | grep -m1 -oE 'working tree has [0-9]+' | grep -oE '[0-9]+$')"
elif [ "$git_rc" -ne 0 ]; then
  echo "preflight.sh: relay-git.sh preflight failed (exit $git_rc):" >&2
  printf '%s\n' "$git_out" >&2
  exit 2
fi

# --- log and print --------------------------------------------------------------------------
total="${#cmds[@]}"
if [ "$total" -eq 1 ]; then noun="command"; else noun="commands"; fi
if [ "$dirty" -eq 1 ]; then
  event_add "Pre-flight red: working tree has ${n_dirty:-?} uncommitted changes."; rc=3
elif [ "$failed" -gt 0 ]; then
  event_add "Pre-flight red: $first_fail."; rc=1
else
  event_add "Pre-flight green: $total $noun clean."; rc=0
fi

if [ "$rc" -eq 0 ]; then echo "PREFLIGHT_GREEN"; else echo "PREFLIGHT_RED"; fi
if [ "$total" -eq 0 ]; then
  echo "Commands: none found in the phase specs"
elif [ "$failed" -eq 0 ]; then
  echo "Commands: $total clean"
else
  echo "Commands: $total run — $ok clean, $failed failed"
fi
[ "${#lines[@]}" -gt 0 ] && printf '%s\n' "${lines[@]}"
printf '%s\n' "$git_out"
exit "$rc"
