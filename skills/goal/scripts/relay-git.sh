#!/usr/bin/env bash
# relay-git.sh — every git write a Relay run makes: pre-flight, the run branch, per-phase
# commits, and the one push after the audit.
#
# Why: a run used to leave its work uncommitted unless the planner happened to write a commit
# bullet into a phase spec (contextmeter did; tunez said "do not commit"). Relay now commits at
# the verified boundary itself — one commit per phase, per fix window and per audit-fix round —
# which the cleanup pass needs for per-phase diffs. The git logic lives here, in one tested
# place, rather than as prose each subagent re-derives.
#
# Usage:
#   relay-git.sh preflight <run-root>                  Stage 6.5 (planner)
#   relay-git.sh branch    <run-root>                  Stage 7 (planner), before Baseline ref
#   relay-git.sh commit    <run-root> <N> [--fix]      phase / fix subagent, after verify passes
#   relay-git.sh commit    <run-root> <N> --review-fix review-fix subagent (phase N's review findings)
#   relay-git.sh commit    <run-root> --cleanup        tidy-up subagent, after its checks stay green
#   relay-git.sh commit    <run-root> --security-fix   security-fix subagent
#   relay-git.sh commit    <run-root> --audit-fix <R>  audit-fix subagent
#   relay-git.sh push      <run-root>                  orchestrator, after AUDIT_COMPLETE
#
# preflight — the working tree must be clean: anything `git status --porcelain` shows, tracked
#   or untracked, is the owner's work and would be swept into phase 1's commit (and counted as
#   run changes by repo-state.sh). It honours .gitignore, and the run root itself never counts
#   (left out by path, whether or not claim-run.sh's info/exclude entry hides it). Also reports the branch plan and warns (never blocks) about commit
#   signing and, when relay will push, an unreachable remote — with STATE.md's **Push:** off the
#   remote is never contacted. Exit 0 = OK (or no git), 1 = dirty.
# branch — on the default branch (the remote's HEAD, init.defaultBranch, main or master),
#   a detached HEAD or an unborn branch, creates and switches to relay/<run-id>; on any other
#   branch leaves HEAD alone. A repository with no commits gets an empty first commit on the
#   run branch, so Stage 7's baseline is a real sha. Exit 1, with the reason on stderr: a dirty
#   tree ("working tree is not clean"), the run branch already existing elsewhere, or git
#   refusing the switch / first commit. Prints the value for STATE.md's **Branch:** field.
# commit — stages everything (`git add -A`, the run root excluded) and commits with the subject
#   `relay: phase N — <name>` (`… (fix)`, `… (review fix)`, `relay: cleanup`, `relay: security
#   fix`, `relay: audit fix R`) and the trailers `Relay-Run: <run-id>` + `Relay-Phase: N` /
#   `Relay-Review-Fix: N` / `Relay-Cleanup: 1` / `Relay-Security-Fix: 1` / `Relay-Audit-Fix: R`,
#   which record-phase.sh uses to find the sha. Refuses (exit 3, index restored, working tree untouched) when a newly added
#   path is a secret or generated file (.env, .envrc, private keys, *.pem / *.key / *.p12,
#   node_modules/, .venv/, __pycache__/, …); an already-tracked one that changed is only warned
#   about. Nothing to commit is exit 0 — "already committed" when HEAD is this phase's commit
#   (a re-dispatch after a no-report), else "none". A failing hook or signing error is exit 1,
#   and so is a commit still running after RELAY_COMMIT_TIMEOUT (default 300 s): nothing is
#   committed and the subagent treats it like a failed criterion. Exit 4: HEAD is not on the
#   branch STATE.md's **Branch:** names (a resumed run after the owner switched) — nothing is
#   committed. Never amends, pushes or switches branch.
# push — pushes the run branch only when relay created it (STATE.md's **Branch:** says so) and
#   STATE.md's **Push:** is on: `git push -u <remote> <branch>`, never --force, never the
#   owner's branch. **Push:** off (the default since 0.11) prints `push: skipped — push is off
#   for this run; run: <command>`; a missing field (runs planned before 0.11) pushes. A failed push must
#   never stop a run (owner): every failure — auth, rejected, network, no remote, a hang killed
#   at RELAY_PUSH_TIMEOUT (default 120 s) — prints one `push: failed — …; run: <command>` line
#   and exits 0, so the orchestrator reports it and the owner pushes later.
#
# Every subcommand without git (not a repository) prints a note and exits 0 — relay then never
# commits. Exit 2 is a usage error. Copied into the run's <run-root>/ at Stage 7.

set -uo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: relay-git.sh preflight <run-root>
       relay-git.sh branch    <run-root>
       relay-git.sh commit    <run-root> <N> [--fix | --review-fix]
       relay-git.sh commit    <run-root> --cleanup | --security-fix
       relay-git.sh commit    <run-root> --audit-fix <R>
       relay-git.sh push      <run-root>
USAGE
  exit 2
}

[ "$#" -ge 2 ] && [ -n "$2" ] || usage
cmd="$1"; runroot="${2%/}"; shift 2
[ -d "$runroot" ] || { echo "relay-git.sh: run root not found: $runroot" >&2; exit 2; }
runid="$(basename "$runroot")"
run_branch="relay/$runid"

in_git() { git rev-parse --is-inside-work-tree >/dev/null 2>&1; }
has_head() { git rev-parse --verify -q HEAD >/dev/null 2>&1; }
current_branch() { git symbolic-ref -q --short HEAD 2>/dev/null || true; }

# state_field <Name> — "**Name:** value    <!-- c -->" from <run-root>/STATE.md
state_field() {
  grep -m1 -F "**$1:**" "$runroot/STATE.md" 2>/dev/null \
    | sed -E "s/^\*\*$1:\*\*[[:space:]]*//; s/[[:space:]]*<!--.*$//; s/[[:space:]]+$//"
}

# push_off — STATE.md's **Push:** starts with "off". A missing field is not off: runs planned
# before 0.11 have none and keep the old push-after-the-audit behaviour.
push_off() {
  case "$(state_field Push | tr '[:upper:]' '[:lower:]')" in off*) return 0 ;; *) return 1 ;; esac
}

# run_rel — the run root relative to the top of the work tree ("" when it lies outside it). The
# run root is never the owner's work, even when no info/exclude entry hides it (claim-run.sh
# writes none for an absolute $RELAY_BASE), so every status / add below leaves it out by path.
run_rel() {
  local top rr
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || return 0
  top="$(cd "$top" 2>/dev/null && pwd -P)"; rr="$(cd "$runroot" 2>/dev/null && pwd -P)"
  case "$rr" in "$top"/*) printf '%s' "${rr#"$top"/}" ;; esac
}

# default_branch — the remote's HEAD branch, else init.defaultBranch. A clone records the
# remote's HEAD as refs/remotes/<r>/HEAD, but `git init` + `remote add` + `push -u` never does,
# so without that ref the push remote is asked (bounded; unreachable → no answer).
default_branch() {
  local r ref out
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    ref="$(git symbolic-ref -q --short "refs/remotes/$r/HEAD" 2>/dev/null)" && { printf '%s' "${ref#"$r"/}"; return; }
  done < <(git remote 2>/dev/null)
  r="$(push_remote)"
  if [ -n "$r" ]; then
    net_env
    out="$(mktemp)"
    if with_timeout 20 "$out" git ls-remote --symref "$r" HEAD; then
      ref="$(sed -n -E 's#^ref: refs/heads/([^[:space:]]+)[[:space:]]+HEAD$#\1#p' "$out" | head -1)"
      rm -f "$out"
      [ -n "$ref" ] && { printf '%s' "$ref"; return; }
    fi
    rm -f "$out"
  fi
  git config --get init.defaultBranch 2>/dev/null || true
}

# on_default — true on the default branch, main/master, a detached HEAD, or an unborn branch
on_default() {
  local cur d; cur="$(current_branch)"
  [ -n "$cur" ] || return 0
  has_head || return 0
  [ "$cur" = "main" ] || [ "$cur" = "master" ] && return 0
  d="$(default_branch)"
  [ -n "$d" ] && [ "$cur" = "$d" ]
}

push_remote() {
  local rs n
  rs="$(git remote 2>/dev/null)"
  if printf '%s\n' "$rs" | grep -qx origin; then printf 'origin'; return; fi
  n="$(printf '%s' "$rs" | grep -c . || true)"
  [ "$n" -eq 1 ] && printf '%s' "$rs"
}

# Non-interactive network env: no credential prompts, SSH fails instead of asking.
net_env() {
  export GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never
  if [ -z "${GIT_SSH_COMMAND:-}" ] && [ -z "$(git config --get core.sshCommand 2>/dev/null)" ]; then
    export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=15"
  fi
}

# ssh_target <url> — what `ssh -T` should be pointed at for an SSH remote URL
ssh_target() {
  local h
  case "$1" in
    ssh://*) h="${1#ssh://}"; h="${h%%/*}"
             case "$h" in *:*) printf -- '-p %s %s' "${h##*:}" "${h%:*}" ;; *) printf '%s' "$h" ;; esac ;;
    *)       printf '%s' "${1%%:*}" ;;
  esac
}

# with_timeout <secs> <out-file> <cmd…> — run with stdin from /dev/null and output to a file;
# after <secs>, kill it and everything it started. Returns the command's code, 124 on timeout.
# The command runs in its own process group (set -m), so the kill reaches every descendant —
# git push → git-remote-https → a credential helper or askpass prompt — not just its children.
# The watcher polls once a second and exits with the command, so nothing outlives the call.
with_timeout() {
  local secs="$1" out="$2" pid w rc flag; shift 2
  flag="$(mktemp)"; rm -f "$flag"
  set -m
  "$@" </dev/null >"$out" 2>&1 &
  pid=$!
  set +m
  ( i=0
    while [ "$i" -lt "$secs" ]; do sleep 1; kill -0 "$pid" 2>/dev/null || exit 0; i=$((i + 1)); done
    : > "$flag"; kill -TERM -- "-$pid" 2>/dev/null
    sleep 2; kill -KILL -- "-$pid" 2>/dev/null ) >/dev/null 2>&1 &
  w=$!
  wait "$pid" 2>/dev/null; rc=$?
  wait "$w" 2>/dev/null
  # Timed out only if the watcher fired AND the command died of a signal: one that finished
  # on its own just as the deadline passed keeps its own exit code.
  if [ -e "$flag" ]; then rm -f "$flag"; [ "$rc" -gt 128 ] && return 124; fi
  return "$rc"
}

dirty_lines() {
  local rel; rel="$(run_rel)"
  if [ -n "$rel" ]; then git status --porcelain -- ':/' ":(exclude,top)$rel" 2>/dev/null
  else git status --porcelain 2>/dev/null; fi
}

# ------------------------------------------------------------------------------------------
case "$cmd" in
preflight)
  [ "$#" -eq 0 ] || usage
  if ! in_git; then echo "git: not a repository — relay will not commit"; exit 0; fi
  rc=0
  dirty="$(dirty_lines)"
  if [ -n "$dirty" ]; then
    n="$(printf '%s\n' "$dirty" | grep -c .)"
    echo "git: ❌ working tree has $n uncommitted change(s) — commit or stash them (\`! git stash -u\`), then re-check:"
    printf '%s\n' "$dirty" | head -10 | sed 's/^/   /'
    [ "$n" -gt 10 ] && echo "   … and $((n - 10)) more"
    rc=1
  else
    echo "git: working tree clean"
  fi
  cur="$(current_branch)"
  if on_default || [ "$cur" = "$run_branch" ]; then
    remote="$(push_remote)"
    if push_off; then
      echo "git: on ${cur:-detached HEAD} → run branch $run_branch, one commit per phase; push is off, so it stays local"
    elif [ -n "$remote" ]; then
      echo "git: on ${cur:-detached HEAD} → run branch $run_branch, one commit per phase, pushed to $remote after the audit"
      net_env
      out="$(mktemp)"
      with_timeout 20 "$out" git ls-remote --exit-code -q "$remote" HEAD; lr=$?
      if [ "$lr" -ne 0 ] && [ "$lr" -ne 2 ]; then
        url="$(git remote get-url "$remote" 2>/dev/null || true)"
        case "$url" in
          https://github.com/*) hint="run: ! gh auth login" ;;
          git@*|ssh://*)        hint="check your SSH key: ! ssh -T $(ssh_target "$url")" ;;
          *)                    hint="check access with: ! git ls-remote $remote" ;;
        esac
        [ "$lr" -eq 124 ] && why="timed out" || why="$(grep -v '^[[:space:]]*$' "$out" | tail -1 | sed -E 's/^(fatal|error): //' | cut -c1-160)"
        echo "git: ⚠ cannot reach $remote (${why:-exit $lr}) — the run will still finish; the push is reported for you to do by hand. $hint"
      fi
      rm -f "$out"
    else
      echo "git: on ${cur:-detached HEAD} → run branch $run_branch, one commit per phase; no remote, so it stays local"
    fi
  else
    echo "git: on $cur → one commit per phase lands on $cur; relay will not push it"
  fi
  if [ "$(git config --bool --get commit.gpgsign 2>/dev/null)" = "true" ]; then
    echo "git: ⚠ commit.gpgsign is on — a passphrase or touch prompt would stall each phase's commit while you are away"
  fi
  exit "$rc"
  ;;

branch)
  [ "$#" -eq 0 ] || usage
  if ! in_git; then echo "no-git"; exit 0; fi
  if [ -n "$(dirty_lines)" ]; then
    echo "relay-git.sh: working tree is not clean — re-run Stage 6.5's check" >&2; exit 1
  fi
  cur="$(current_branch)"
  if [ "$cur" != "$run_branch" ]; then
    if ! on_default; then echo "$cur (yours — relay commits, never pushes)"; exit 0; fi
    if git show-ref --verify -q "refs/heads/$run_branch"; then
      echo "relay-git.sh: $run_branch already exists but is not checked out — switch to it (\`! git switch $run_branch\`) or delete it, then re-run" >&2; exit 1
    fi
    err="$(git switch -q -c "$run_branch" 2>&1)" \
      || { echo "relay-git.sh: could not create $run_branch: $err" >&2; exit 1; }
  fi
  # A repository with no commits has no baseline to compare the run against: give it an empty
  # first commit on the run branch (hooks and signing apply, as for every relay commit).
  if ! has_head; then
    msg="$(mktemp)"; printf 'relay: start %s\n\nRelay-Run: %s\n' "$runid" "$runid" > "$msg"
    err="$(git commit -q --allow-empty -F "$msg" 2>&1 </dev/null)"; rc=$?; rm -f "$msg"
    [ "$rc" -eq 0 ] || { echo "relay-git.sh: could not make the first commit on $run_branch: $err" >&2; exit 1; }
  fi
  echo "$run_branch (created by relay)"
  ;;

commit)
  phase=""; round=""; kind="phase"
  case "${1:-}" in
    --audit-fix)    [ "$#" -eq 2 ] && [[ "$2" =~ ^[0-9]+$ ]] || usage; round="$2"; kind="audit-fix" ;;
    --cleanup)      [ "$#" -eq 1 ] || usage; kind="cleanup" ;;
    --security-fix) [ "$#" -eq 1 ] || usage; kind="security-fix" ;;
    *)
      [ "$#" -ge 1 ] && [[ "$1" =~ ^[0-9]+$ ]] || usage; phase="$1"
      if [ "$#" -eq 2 ] && [ "$2" = "--fix" ]; then kind="fix"
      elif [ "$#" -eq 2 ] && [ "$2" = "--review-fix" ]; then kind="review-fix"
      elif [ "$#" -ne 1 ]; then usage; fi ;;
  esac
  if ! in_git; then echo "commit: skipped (not a git repository)"; exit 0; fi

  # The run's commits belong on the branch STATE.md records. A resumed run can find HEAD
  # elsewhere (the owner checked out main to look into a handoff): committing there would put
  # relay's work on a branch nobody asked for and leave the pushed run branch without it.
  want="$(state_field Branch)"; want="${want%% *}"
  case "$want" in ""|"—"|"-"|no-git|"{{BRANCH}}") want="" ;; esac
  cur="$(current_branch)"
  if [ -n "$want" ] && [ "$cur" != "$want" ]; then
    echo "commit: refused — HEAD is on ${cur:-a detached HEAD}, but this run commits to $want (STATE.md **Branch:**); nothing was committed. Do not switch branch yourself: the owner runs \`git switch $want\`."
    exit 4
  fi

  if [ -n "$phase" ]; then
    name="$(awk -v p="$phase" -F'|' '$2 ~ ("^ *" p " *$") { gsub(/^ +| +$/, "", $3); print $3; exit }' "$runroot/STATE.md" 2>/dev/null)"
    if [ -z "$name" ] || [[ "$name" == *"{{"* ]]; then
      name="$(grep -m1 -E '^[[:space:]]*Phase:[[:space:]]*[0-9]+' "$runroot/phases/phase-$phase.md" 2>/dev/null \
        | sed -E 's/^[[:space:]]*Phase:[[:space:]]*[0-9]+([[:space:]]+of[[:space:]]+[0-9]+)?[[:space:]]*[—-]+[[:space:]]*//; s/[[:space:]]+$//')"
    fi
    subject="relay: phase $phase — ${name:-phase $phase}"
    trailer="Relay-Phase: $phase"
    [ "$kind" = "fix" ] && subject="$subject (fix)"
    # A review fix is its own trailer, so a review's diff range (Relay-Phase: N) never includes it.
    [ "$kind" = "review-fix" ] && { subject="$subject (review fix)"; trailer="Relay-Review-Fix: $phase"; }
  else
    case "$kind" in
      cleanup)      subject="relay: cleanup";         trailer="Relay-Cleanup: 1" ;;
      security-fix) subject="relay: security fix";    trailer="Relay-Security-Fix: 1" ;;
      *)            subject="relay: audit fix $round"; trailer="Relay-Audit-Fix: $round" ;;
    esac
  fi

  unstage() { if has_head; then git reset -q 2>/dev/null; else git read-tree --empty 2>/dev/null; fi; }

  # The run root is normally invisible here (claim-run.sh's info/exclude entry). Naming it in an
  # exclude pathspec makes `git add` fail on an ignored path, so put its index entries back to
  # HEAD afterwards instead: never committed, and a tracked run root is not deleted either.
  err="$(git add -A -- ':/' 2>&1)" \
    || { echo "commit: failed — git add could not stage the changes: $err"; exit 1; }
  rel="$(run_rel)"
  if [ -n "$rel" ]; then
    if has_head; then git reset -q -- ":(top)$rel" >/dev/null 2>&1
    else git rm -r -q --cached --ignore-unmatch -- ":(top)$rel" >/dev/null 2>&1; fi
  fi

  # secret_or_generated — the staged paths on stdin that are secrets or generated files
  secret_or_generated() { awk '
    { p = "/" $0; n = split($0, parts, "/"); base = parts[n] }
    base ~ /^\.env(\..*)?$/ && base !~ /^\.env\.(example|sample|template|dist)$/ { print; next }
    base == ".envrc" || base ~ /^id_(rsa|dsa|ecdsa|ed25519)$/ || base ~ /\.(pem|key|p12|pfx)$/ { print; next }
    p ~ /\/(node_modules|\.venv|venv|__pycache__|\.pytest_cache|\.next)\// { print; next }
    base == ".DS_Store" || base ~ /\.pyc$/ { print }'; }

  # Newly added secrets / generated files: refuse, restore the index, leave the files alone.
  bad="$(git diff --cached --name-only --no-renames --diff-filter=A 2>/dev/null | secret_or_generated)"
  if [ -n "$bad" ]; then
    unstage
    n="$(printf '%s\n' "$bad" | grep -c .)"
    echo "commit: refused — $n secret or generated file(s) would be committed:"
    printf '%s\n' "$bad" | head -10 | sed 's/^/   /'
    [ "$n" -gt 10 ] && echo "   … and $((n - 10)) more"
    echo "   Add them to .gitignore (or delete them if they should not exist), then run this again."
    exit 3
  fi

  if git diff --cached --quiet 2>/dev/null && has_head; then
    body="$(git log -1 --format=%B HEAD 2>/dev/null)"
    if printf '%s\n' "$body" | grep -qxF "Relay-Run: $runid" && printf '%s\n' "$body" | grep -qxF "$trailer"; then
      echo "commit: $(git rev-parse --short HEAD) (already committed) $(git log -1 --format=%s HEAD)"
    else
      echo "commit: none — no changes since the last commit"
    fi
    exit 0
  fi
  if ! has_head && [ -z "$(git diff --cached --name-only 2>/dev/null)" ]; then
    echo "commit: none — no changes to commit"; exit 0
  fi

  # Already tracked, so the owner chose to keep it in git: warn, don't refuse — but its new
  # contents are in this commit, and a relay branch with push on is pushed after the audit.
  while IFS= read -r f; do
    [ -n "$f" ] && echo "commit: ⚠ $f is tracked and looks like a secret or generated file — this commit includes its changes"
  done < <(git diff --cached --name-only --no-renames --diff-filter=M 2>/dev/null | secret_or_generated)

  top="$(git rev-parse --show-toplevel)"
  while IFS= read -r f; do
    [ -f "$top/$f" ] || continue
    sz="$(wc -c < "$top/$f" | tr -d ' ')"
    [ "$sz" -gt 10485760 ] && echo "commit: ⚠ large file $f ($((sz / 1048576)) MB)"
  done < <(git diff --cached --name-only --no-renames --diff-filter=AM 2>/dev/null)

  # Bounded: a signing passphrase / touch prompt or a hook waiting for input would otherwise
  # stall the window with nobody there to answer. Generous, so a slow pre-commit suite fits.
  msg="$(mktemp)"; out="$(mktemp)"
  printf '%s\n\nRelay-Run: %s\n%s\n' "$subject" "$runid" "$trailer" > "$msg"
  secs="${RELAY_COMMIT_TIMEOUT:-300}"
  with_timeout "$secs" "$out" git commit -q -F "$msg"; rc=$?
  if [ "$rc" -eq 0 ]; then
    rm -f "$msg" "$out"
    echo "commit: $(git rev-parse --short HEAD) $subject"
    exit 0
  fi
  if [ "$rc" -eq 124 ]; then
    echo "commit: failed — git commit did not finish in $secs s (a signing prompt, or a hook waiting for input?) and was stopped; nothing was committed:"
    lock="$(git rev-parse --git-path index.lock 2>/dev/null)"
    [ -n "$lock" ] && [ -e "$lock" ] && echo "   git left $lock behind — the next git write fails until it is removed"
  else
    echo "commit: failed — git commit exited $rc (a hook or commit signing refused it); nothing was committed:"
  fi
  tail -20 "$out" | sed 's/^/   /'
  rm -f "$msg" "$out"
  exit 1
  ;;

push)
  [ "$#" -eq 0 ] || usage
  if ! in_git; then echo "push: skipped — not a git repository"; exit 0; fi
  field="$(state_field Branch)"
  if [ -z "$field" ]; then echo "push: skipped — STATE.md has no Branch field"; exit 0; fi
  br="${field%% *}"
  case "$field" in
    *"(created by relay"*) ;;
    no-git) echo "push: skipped — not a git repository"; exit 0 ;;
    *) echo "push: skipped — $br is your branch; relay does not push it"; exit 0 ;;
  esac
  remote="$(push_remote)"
  if [ -z "$remote" ]; then
    if [ -z "$(git remote 2>/dev/null)" ]; then
      echo "push: skipped — no git remote, so $br stays local; after adding one, run: git push -u <remote> $br"
    else
      echo "push: skipped — several remotes and none is origin; run: git push -u <remote> $br"
    fi
    exit 0
  fi
  retry="run: git push -u $remote $br"
  if push_off; then echo "push: skipped — push is off for this run; $retry"; exit 0; fi
  if ! git show-ref --verify -q "refs/heads/$br"; then
    echo "push: failed — branch $br does not exist locally"; exit 0
  fi
  count=""
  base="$(state_field 'Baseline ref')"
  if [ -n "$base" ] && git rev-parse --verify -q "$base^{commit}" >/dev/null 2>&1; then
    count="$(git rev-list --count "$base..$br" 2>/dev/null || true)"
  fi
  net_env
  out="$(mktemp)"
  with_timeout "${RELAY_PUSH_TIMEOUT:-120}" "$out" git push -u "$remote" "$br"; rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "push: $br → $remote${count:+ ($count commits)}"
  elif [ "$rc" -eq 124 ]; then
    echo "push: failed — timed out after ${RELAY_PUSH_TIMEOUT:-120} s; $retry"
  else
    why="$(grep -E '(error|fatal|rejected|denied|Permission)' "$out" | tail -1 | sed -E 's/^[[:space:]]*(fatal|error): //; s/^[[:space:]]+//' | cut -c1-160)"
    echo "push: failed — ${why:-git push exited $rc}; $retry"
  fi
  rm -f "$out"
  exit 0
  ;;

*) usage ;;
esac
