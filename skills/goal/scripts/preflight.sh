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
#   <run-root>/phases/phase-N.md `## Mandatory commands` bullet (in phase order; a bullet's
#   backtick wrapping or trailing " — description" is dropped), then each --account status
#   command (`gh auth status`, `vercel whoami` — a red one prints `run: ! <login command>`; a
#   phase command identical to one runs only as the account check).
#   A phase command that needs what only the build will create — npm/pnpm/yarn/bun with no
#   package.json or without the named script, cargo/go/make/poetry/swift/mvn with no manifest, a
#   script path that does not exist, check-design.sh --verify — is not run: it is listed as
#   `- later <command> — <why>; first used by phase N` and never turns the block red. The list is
#   fixed here, never chosen by the planner, so a broken baseline still shows as FAIL (the tunez
#   run's greenfield pre-flight was 13 of 16 red, and "skip pre-flight" became a planned step).
#   Every other command runs once through run-logged.sh, its full output in
#   <run-root>/logs/preflight/; the block shows the exit code and the last 5 lines of any that
#   failed. Then
#   `relay-git.sh preflight` checks the working tree — after the commands, so anything they
#   created is caught too — and its lines (the branch plan, warnings, a dirty tree's paths) go
#   into the block as they are.
#
#   Appends one line to STATE.md's `## Notable events`:
#     Pre-flight green: <N> command(s) clean.
#     Pre-flight green: <N> command(s) clean, <M> not runnable yet.
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
# cmd_bullets — "<phase N><TAB><command>" for every `## Mandatory commands` bullet, in phase
# order. A bullet is the command alone, but tunez's planner wrote "`npm run build` — vite build
# summary line; exit 0", which ran as command substitution plus `; exit 0` (a false pass): a
# backtick-wrapped bullet yields only the text inside the backticks, any other bullet loses a
# trailing " — …" / " – …" description. validate-phase.sh rejects both shapes in new specs.
# The same parse is in assemble-brief.sh ({{COMMANDS}}) — change both together.
cmd_bullets() {
  local f n
  for f in "$runroot"/phases/phase-*.md; do
    [ -e "$f" ] || continue
    [[ "$(basename "$f")" =~ ^phase-([0-9]+)\.md$ ]] || continue
    n="${BASH_REMATCH[1]}"
    awk -v n="$n" '/^##[[:space:]]/ { inside = (tolower($0) ~ /^##[[:space:]]+mandatory commands/); next }
         inside && /^[[:space:]]*-[[:space:]]*[^[:space:]]/ {
           l = $0; sub(/^[[:space:]]*-[[:space:]]*/, "", l); sub(/[[:space:]]+$/, "", l)
           if (l == "...") next
           if (substr(l, 1, 1) == "`") { r = substr(l, 2); i = index(r, "`"); if (i > 1) l = substr(r, 1, i - 1) }
           else { i = index(l, " — "); if (i == 0) i = index(l, " – "); if (i > 0) l = substr(l, 1, i - 1) }
           sub(/[[:space:]]+$/, "", l)
           if (l != "") print n "\t" l
         }' "$f"
  done | sort -t "$tab" -k1,1n -s
}

# not_yet <command> — prints why the command cannot run before the build starts, and succeeds,
# when it needs something no file in the project provides yet: a package manager with no
# package.json or without the named script, a build tool with no manifest, a script path that
# does not exist, or check-design.sh --verify (it checks screens the build has not made yet).
# A closed list on purpose — the planner cannot mark a command "not yet", so a red baseline
# cannot be waved through. Anything else (and any command starting with `cd `) runs.
not_yet() {
  local c="$1" w=() i=0 prog sub x
  case "$c" in "cd "*) return 1 ;; esac
  read -ra w <<< "$c"
  for x in "${w[@]}"; do
    case "$x" in */check-design.sh|check-design.sh)
      case " $c " in *" --verify "*) echo "checks the built screens, so it runs during the build"; return 0 ;; esac ;;
    esac
  done
  while [ "$i" -lt "${#w[@]}" ] && [[ "${w[$i]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do i=$((i + 1)); done
  prog="${w[$i]:-}"; sub="${w[$((i + 1))]:-}"
  [ -n "$prog" ] || return 1
  case "$prog" in
    bash|sh|zsh|python|python3|node|ruby|perl)
      for x in "${w[@]:$((i + 1))}"; do
        case "$x" in
          -c|-m|-e|-) return 1 ;;
          -*) continue ;;
        esac
        case "$x" in */*|*.sh|*.py|*.js|*.mjs|*.cjs|*.ts|*.rb|*.pl)
          [ -e "$x" ] || { echo "$x doesn't exist yet"; return 0 ;}
        esac
        return 1
      done
      return 1 ;;
    */*) [ -e "$prog" ] || { echo "$prog doesn't exist yet"; return 0; }; return 1 ;;
    npm|pnpm|yarn|bun)
      [ -f package.json ] || { echo "no package.json yet"; return 0; }
      x=""
      case "$prog:$sub" in
        *:run|*:run-script)                  x="${w[$((i + 2))]:-}" ;;
        npm:test|npm:t|npm:tst)              x="test" ;;
        npm:start)                           x="start" ;;
        npm:*|bun:*)                         return 1 ;;
        *:-*|*:)                             return 1 ;;
        pnpm:install|pnpm:i|pnpm:add|pnpm:remove|pnpm:rm|pnpm:update|pnpm:up|pnpm:link|pnpm:unlink|pnpm:import|pnpm:rebuild|pnpm:prune|pnpm:fetch|pnpm:audit|pnpm:list|pnpm:ls|pnpm:outdated|pnpm:why|pnpm:licenses|pnpm:exec|pnpm:dlx|pnpm:create|pnpm:init|pnpm:publish|pnpm:pack|pnpm:store|pnpm:env|pnpm:config|pnpm:root|pnpm:bin|pnpm:doctor) return 1 ;;
        yarn:install|yarn:add|yarn:remove|yarn:up|yarn:upgrade|yarn:dlx|yarn:exec|yarn:why|yarn:info|yarn:init|yarn:workspace|yarn:workspaces|yarn:config|yarn:cache|yarn:set|yarn:plugin|yarn:node|yarn:pack|yarn:npm|yarn:version|yarn:link|yarn:unlink|yarn:rebuild|yarn:bin|yarn:global|yarn:create|yarn:audit|yarn:outdated|yarn:list|yarn:licenses|yarn:help) return 1 ;;
        *)                                   x="$sub" ;;
      esac
      [ -n "$x" ] || return 1
      python3 - "$x" <<'PY' >/dev/null 2>&1
import json, sys
try:
    scripts = json.load(open("package.json")).get("scripts") or {}
except Exception:
    sys.exit(2)
sys.exit(0 if sys.argv[1] in scripts else 1)
PY
      [ "$?" -eq 1 ] && { echo "package.json has no \"$x\" script yet"; return 0; }
      return 1 ;;
    cargo) case "$sub" in build|test|check|clippy|fmt|run|bench|doc) [ -f Cargo.toml ] || { echo "no Cargo.toml yet"; return 0; } ;; esac; return 1 ;;
    go)    case "$sub" in build|test|vet|run|generate|list|mod) [ -f go.mod ] || { echo "no go.mod yet"; return 0; } ;; esac; return 1 ;;
    make)  [ -f Makefile ] || [ -f makefile ] || [ -f GNUmakefile ] || { echo "no Makefile yet"; return 0; }; return 1 ;;
    poetry) [ -f pyproject.toml ] || { echo "no pyproject.toml yet"; return 0; }; return 1 ;;
    swift) case "$sub" in build|test|run) [ -f Package.swift ] || { echo "no Package.swift yet"; return 0; } ;; esac; return 1 ;;
    mvn)   [ -f pom.xml ] || { echo "no pom.xml yet"; return 0; }; return 1 ;;
  esac
  return 1
}

tab="$(printf '\t')"
cmds=(); logins=(); firsts=()
while IFS="$tab" read -r n c; do
  [ -n "$c" ] || continue
  for x in "${cmds[@]+"${cmds[@]}"}" "${acct_cmds[@]+"${acct_cmds[@]}"}"; do [ "$x" = "$c" ] && continue 2; done
  cmds+=("$c"); logins+=(""); firsts+=("$n")
done < <(cmd_bullets)
for i in "${!acct_cmds[@]}"; do cmds+=("${acct_cmds[$i]}"); logins+=("${acct_logins[$i]}"); firsts+=(""); done

lines=(); ok=0; failed=0; later=0; first_fail=""
for i in "${!cmds[@]}"; do
  c="${cmds[$i]}"
  if [ -n "${firsts[$i]}" ] && why="$(not_yet "$c")"; then
    later=$((later + 1)); lines+=("- later $c — $why; first used by phase ${firsts[$i]}")
    continue
  fi
  slug="$(printf '%s' "$c" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-|-$//g' | cut -c1-60)"
  log="$runroot/logs/preflight/$((i + 1))-${slug:-command}.log"
  bash "$here/run-logged.sh" "$log" "$c" >/dev/null; rc=$?
  if [ "$rc" -eq 0 ]; then
    ok=$((ok + 1)); lines+=("- ok    $c")
  else
    failed=$((failed + 1)); [ -n "$first_fail" ] || first_fail="$c exited $rc"
    lines+=("- FAIL  $c — exit $rc (log: $log)")
    while IFS= read -r t; do lines+=("      $t"); done < <(grep -v '^\[run-logged\] exit:' "$log" 2>/dev/null | tail -n 5)
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
if [ "$ok" -eq 1 ]; then oknoun="command"; else oknoun="commands"; fi
if [ "$dirty" -eq 1 ]; then
  event_add "Pre-flight red: working tree has ${n_dirty:-?} uncommitted changes."; rc=3
elif [ "$failed" -gt 0 ]; then
  event_add "Pre-flight red: $first_fail."; rc=1
elif [ "$later" -gt 0 ]; then
  event_add "Pre-flight green: $ok $oknoun clean, $later not runnable yet."; rc=0
else
  event_add "Pre-flight green: $total $noun clean."; rc=0
fi

if [ "$rc" -eq 0 ]; then echo "PREFLIGHT_GREEN"; else echo "PREFLIGHT_RED"; fi
yet="$later not runnable yet (what they need comes from the build)"
if [ "$total" -eq 0 ]; then
  echo "Commands: none found in the phase specs"
elif [ "$later" -gt 0 ] && [ "$failed" -eq 0 ]; then
  echo "Commands: $total — $ok clean, $yet"
elif [ "$later" -gt 0 ]; then
  echo "Commands: $total — $ok clean, $failed failed, $yet"
elif [ "$failed" -eq 0 ]; then
  echo "Commands: $total clean"
else
  echo "Commands: $total run — $ok clean, $failed failed"
fi
[ "${#lines[@]}" -gt 0 ] && printf '%s\n' "${lines[@]}"
printf '%s\n' "$git_out"
exit "$rc"
