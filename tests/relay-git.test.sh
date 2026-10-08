#!/usr/bin/env bash
# relay-git.test.sh — fixture tests for scripts/relay-git.sh
#
# Proves the run's git writes stay inside their contract: pre-flight refuses any uncommitted
# change (tracked or untracked) but ignores the .relay/ run dir; the run branch is created only
# from the default branch / a detached HEAD / an unborn branch; each commit carries the subject
# and trailers record-phase.sh looks up, never includes the run root, refuses secrets and
# generated files without touching the working tree, and is idempotent on a re-dispatch; a hook
# failure commits nothing; the push goes only to a relay-created branch, never forces, and every
# failure — rejected, unreachable, hanging — still exits 0 with a command for the owner.
#
# Repo-only (not shipped in the plugin payload). Uses local bare repos as remotes (no network).
#   bash tests/relay-git.test.sh
# Exits 0 if every assertion passes, 1 otherwise.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RG="$REPO_ROOT/skills/goal/scripts/relay-git.sh"
[ -f "$RG" ] || { echo "FATAL: missing $RG" >&2; exit 1; }

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  \033[31m✗\033[0m %s\n      %s\n' "$1" "$2"; }

assert_rc()       { if [ "$2" = "$RC" ]; then ok "$1"; else no "$1" "expected exit $2 got $RC (out: $OUT)"; fi; }
assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "expected [$2] got [$3]"; fi; }
assert_contains() { case "$3" in *"$2"*) ok "$1";; *) no "$1" "missing substring [$2] in [$3]";; esac; }
assert_missing()  { case "$3" in *"$2"*) no "$1" "unexpectedly contains [$2]";; *) ok "$1";; esac; }

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
unset GIT_SSH_COMMAND

# rg <args…> — run relay-git.sh inside $R; sets OUT and RC
rg() { OUT="$(cd "$R" && bash "$RG" "$@" 2>&1)"; RC=$?; }
g() { git -C "$R" "$@"; }

RUN=".relay/add-thing-Ab3Kx9"
BR="relay/add-thing-Ab3Kx9"

# repo <name> [<branch>] — a repo with one commit on <branch> (default main), a claimed run
# root excluded the way claim-run.sh does it, and a STATE.md with one phase row; sets R
repo() {
  R="$W/$1"
  mkdir -p "$R/$RUN/phases"
  git -C "$R" init -q -b "${2:-main}"
  g config user.email t@example.com; g config user.name t; g config commit.gpgsign false
  g config core.hooksPath .git/no-hooks
  echo ".relay/" >> "$R/.git/info/exclude"
  printf 'x\n' > "$R/README.md"; g add README.md; g commit -qm init
  cat > "$R/$RUN/STATE.md" <<EOF
**Baseline ref:** $(g rev-parse HEAD)
**Branch:** —

| # | Phase | Status | Started | Completed | Notes |
|---|-------|--------|---------|-----------|-------|
| 1 | Reader core | pending | — | — | — |
| 2 | CLI flags | pending | — | — | — |
EOF
  printf 'RELAY_PHASE_START\nPhase: 3 of 3 — Polish pass\n' > "$R/$RUN/phases/phase-3.md"
}
set_branch_field() {
  awk -v v="$1" 'index($0, "**Branch:**") == 1 { print "**Branch:** " v; next } { print }' \
    "$R/$RUN/STATE.md" > "$R/$RUN/STATE.tmp" && mv "$R/$RUN/STATE.tmp" "$R/$RUN/STATE.md"
}
bare() { git init -q --bare "$W/$1.git"; g remote add "${2:-origin}" "$W/$1.git"; }
# set_push_field <value> — add or replace STATE.md's **Push:** line ("-" removes it)
set_push_field() {
  awk -v v="$1" 'index($0, "**Push:**") == 1 { next } { print } index($0, "**Branch:**") == 1 && v != "-" { print "**Push:** " v }' \
    "$R/$RUN/STATE.md" > "$R/$RUN/STATE.tmp" && mv "$R/$RUN/STATE.tmp" "$R/$RUN/STATE.md"
}

# ---------------------------------------------------------------------------
echo "preflight"
repo pf
rg preflight "$RUN"
assert_rc "clean tree passes (the .relay/ run dir is not dirt)" 0
assert_contains "says clean" "working tree clean" "$OUT"
assert_contains "plans the run branch from main" "run branch $BR" "$OUT"
assert_contains "no remote → stays local" "stays local" "$OUT"

printf 'y\n' >> "$R/README.md"
rg preflight "$RUN"
assert_rc "modified tracked file blocks" 1
assert_contains "names the file" "M README.md" "$OUT"
assert_contains "suggests stash" "git stash -u" "$OUT"
g checkout -q README.md

printf 'n\n' > "$R/notes.txt"
rg preflight "$RUN"
assert_rc "untracked file blocks" 1
assert_contains "names the untracked file" "?? notes.txt" "$OUT"
rm "$R/notes.txt"

for i in $(seq 1 13); do printf '%s\n' "$i" > "$R/f$i.txt"; done
rg preflight "$RUN"
assert_contains "long lists are cut at 10" "… and 3 more" "$OUT"
rm -f "$R"/f*.txt

g config commit.gpgsign true
rg preflight "$RUN"
assert_rc "signing is a warning, not a block" 0
assert_contains "warns about signing" "commit.gpgsign is on" "$OUT"
g config commit.gpgsign false

g switch -q -c feature/x
rg preflight "$RUN"
assert_contains "owner's branch: commits land there" "lands on feature/x; relay will not push" "$OUT"
g switch -q main

g remote add origin "$W/does-not-exist.git"
rg preflight "$RUN"
assert_rc "unreachable remote is a warning, not a block" 0
assert_contains "warns the remote is unreachable" "cannot reach origin" "$OUT"
assert_contains "promises the run still finishes" "the run will still finish" "$OUT"
g remote remove origin
bare pf
rg preflight "$RUN"
assert_contains "reachable remote → pushed after the audit" "pushed to origin after the audit" "$OUT"
assert_missing "no warning for a reachable (empty) remote" "cannot reach" "$OUT"
set_push_field "on"
rg preflight "$RUN"
assert_contains "Push: on → pushed after the audit" "pushed to origin after the audit" "$OUT"
set_push_field "off — default"
g remote set-url origin "$W/does-not-exist.git"
rg preflight "$RUN"
assert_rc "Push: off → still passes" 0
assert_contains "Push: off → the run branch stays local" "run branch $BR, one commit per phase; push is off, so it stays local" "$OUT"
assert_missing "Push: off → the remote is never contacted" "cannot reach" "$OUT"
set_push_field "-"

repo pf-noexcl
awk '!/relay/' "$R/.git/info/exclude" > "$R/x" && mv "$R/x" "$R/.git/info/exclude"
[ -n "$(g status --porcelain)" ] && ok "setup: the run root shows as untracked" || no "setup: run root untracked" "status empty"
rg preflight "$RUN"
assert_rc "run root with no exclude entry is not dirt (absolute RELAY_BASE)" 0
rg preflight "$(cd "$R" && pwd -P)/$RUN"
assert_rc "… also when the run root is passed as an absolute path" 0
printf 'n\n' > "$R/notes.txt"
rg preflight "$RUN"
assert_rc "… but the owner's files still block" 1
assert_missing "… and the run root is not listed" ".relay" "$OUT"
rm "$R/notes.txt"

repo pf-ssh
g remote add origin "ssh://git@gitlab.example.invalid:2222/team/x.git"
printf '#!/bin/sh\necho "Permission denied (publickey)." >&2\nexit 255\n' > "$W/ssh-deny"; chmod +x "$W/ssh-deny"
OUT="$(cd "$R" && GIT_SSH_COMMAND="$W/ssh-deny" bash "$RG" preflight "$RUN" 2>&1)"; RC=$?
assert_contains "ssh:// remote → ssh -T hint names host and port" "ssh -T -p 2222 git@gitlab.example.invalid" "$OUT"
g remote set-url origin "git@github.example.invalid:team/x.git"
OUT="$(cd "$R" && GIT_SSH_COMMAND="$W/ssh-deny" bash "$RG" preflight "$RUN" 2>&1)"; RC=$?
assert_contains "scp-style remote → ssh -T user@host" "ssh -T git@github.example.invalid" "$OUT"

mkdir -p "$W/nogit/$RUN"
OUT="$(cd "$W/nogit" && bash "$RG" preflight "$RUN" 2>&1)"; RC=$?
assert_rc "no git passes" 0
assert_contains "no git says relay will not commit" "not a repository" "$OUT"

# ---------------------------------------------------------------------------
echo "branch"
repo br
rg branch "$RUN"
assert_rc "creates the run branch from main" 0
assert_eq "value for STATE.md" "$BR (created by relay)" "$OUT"
assert_eq "HEAD is on the run branch" "$BR" "$(g branch --show-current)"
rg branch "$RUN"
assert_rc "re-running on the run branch is fine" 0
assert_contains "still reports it as relay's" "(created by relay" "$OUT"

repo br-feat feature/y
rg branch "$RUN"
assert_eq "owner's branch is left alone" "feature/y (yours — relay commits, never pushes)" "$OUT"
assert_eq "HEAD unchanged" "feature/y" "$(g branch --show-current)"

repo br-trunk trunk
g config init.defaultBranch trunk
rg branch "$RUN"
assert_contains "init.defaultBranch counts as default" "$BR (created by relay" "$OUT"

repo br-remote develop
bare br-remote
g push -q origin develop
g symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop
rg branch "$RUN"
assert_contains "the remote's HEAD branch counts as default" "$BR (created by relay" "$OUT"

repo br-det
g checkout -q --detach HEAD
rg branch "$RUN"
assert_contains "detached HEAD gets the run branch" "$BR (created by relay" "$OUT"
assert_eq "HEAD is now on it" "$BR" "$(g branch --show-current)"

# `git init` + `remote add` + `push -u` never records refs/remotes/origin/HEAD.
repo br-nohead develop
git init -q --bare -b develop "$W/br-nohead.git"; g remote add origin "$W/br-nohead.git"
g push -q -u origin develop 2>/dev/null
g config init.defaultBranch main
assert_eq "setup: no origin/HEAD recorded" "" "$(g symbolic-ref -q refs/remotes/origin/HEAD)"
rg branch "$RUN"
assert_contains "no origin/HEAD → the remote is asked; its HEAD branch counts as default" "$BR (created by relay" "$OUT"
repo br-nohead2 feature/q
git init -q --bare -b develop "$W/br-nohead2.git"; g remote add origin "$W/br-nohead2.git"
g push -q origin feature/q:develop 2>/dev/null
rg branch "$RUN"
assert_eq "… and any other branch is still the owner's" "feature/q (yours — relay commits, never pushes)" "$OUT"

repo br-exists
g branch "$BR"
rg branch "$RUN"
assert_rc "run branch existing but not checked out → exit 1" 1
assert_contains "… says so, not 'dirty'" "already exists but is not checked out" "$OUT"
assert_contains "… and how to recover" "git switch $BR" "$OUT"

R="$W/br-unborn"; mkdir -p "$R/$RUN"; git -C "$R" init -q -b main
g config user.email t@example.com; g config user.name t; g config commit.gpgsign false
g config core.hooksPath .git/no-hooks
echo ".relay/" >> "$R/.git/info/exclude"
rg branch "$RUN"
assert_contains "an unborn main gets the run branch" "$BR (created by relay" "$OUT"
assert_eq "unborn HEAD now names it" "$BR" "$(g symbolic-ref --short HEAD)"
assert_eq "… with an empty first commit, so the baseline is a real sha" "relay: start add-thing-Ab3Kx9" "$(g log -1 --format=%s 2>/dev/null)"
assert_contains "… carrying the run trailer" "Relay-Run: add-thing-Ab3Kx9" "$(g log -1 --format=%b 2>/dev/null)"
assert_eq "… and no files" "" "$(g ls-tree -r --name-only HEAD)"
assert_eq "Stage 7's baseline command gives one sha" "1" "$(cd "$R" && { git rev-parse --verify -q HEAD 2>/dev/null || echo no-git; } | grep -c .)"
rg branch "$RUN"
assert_eq "re-running makes no second start commit" "1" "$(g rev-list --count HEAD)"

repo br-dirty
printf 'z\n' > "$R/new.txt"
rg branch "$RUN"
assert_rc "dirty tree is refused" 1
assert_eq "HEAD unchanged on refusal" "main" "$(g branch --show-current)"

# ---------------------------------------------------------------------------
echo "commit"
repo cm
rg branch "$RUN"
printf 'code\n' > "$R/reader.py"; printf 'y\n' >> "$R/README.md"
rg commit "$RUN" 1
assert_rc "phase commit succeeds" 0
assert_contains "prints sha + subject" "relay: phase 1 — Reader core" "$OUT"
assert_eq "subject uses the STATE.md row name" "relay: phase 1 — Reader core" "$(g log -1 --format=%s)"
body="$(g log -1 --format=%b)"
assert_contains "Relay-Run trailer" "Relay-Run: add-thing-Ab3Kx9" "$body"
assert_contains "Relay-Phase trailer" "Relay-Phase: 1" "$body"
assert_eq "tree is clean after the commit" "" "$(g status --porcelain)"
assert_eq "run root never committed" "" "$(g ls-files .relay)"
assert_eq "new file committed" "reader.py" "$(g ls-files reader.py)"

sha1="$(g rev-parse --short HEAD)"
rg commit "$RUN" 1
assert_rc "re-running with nothing new is fine" 0
assert_contains "reports the existing commit" "$sha1 (already committed)" "$OUT"
assert_eq "no empty commit made" "$sha1" "$(g rev-parse --short HEAD)"

rg commit "$RUN" 2
assert_contains "nothing new for another phase → none" "commit: none" "$OUT"

printf 'fix\n' >> "$R/reader.py"
rg commit "$RUN" 1 --fix
assert_eq "fix subject" "relay: phase 1 — Reader core (fix)" "$(g log -1 --format=%s)"

printf 'p\n' > "$R/polish.txt"
rg commit "$RUN" 3
assert_eq "name falls back to the spec header" "relay: phase 3 — Polish pass" "$(g log -1 --format=%s)"

printf 'a\n' >> "$R/reader.py"
rg commit "$RUN" --audit-fix 2
assert_eq "audit-fix subject" "relay: audit fix 2" "$(g log -1 --format=%s)"
assert_contains "audit-fix trailer" "Relay-Audit-Fix: 2" "$(g log -1 --format=%b)"

# The 0.10 checks: review fix, tidy-up, security fix — each its own subject and trailer.
printf 'rf\n' >> "$R/reader.py"
rg commit "$RUN" 1 --review-fix
assert_rc "review-fix commit succeeds" 0
assert_eq "review-fix subject" "relay: phase 1 — Reader core (review fix)" "$(g log -1 --format=%s)"
body="$(g log -1 --format=%b)"
assert_contains "review-fix trailer" "Relay-Review-Fix: 1" "$body"
assert_missing "… not a Relay-Phase trailer (the review's diff range must not include it)" "Relay-Phase:" "$body"
shr="$(g rev-parse --short HEAD)"
rg commit "$RUN" 1 --review-fix
assert_contains "review fix re-run → already committed" "$shr (already committed)" "$OUT"
rg commit "$RUN" 1
assert_contains "… but it is not phase 1's commit" "commit: none" "$OUT"

printf 'tidy\n' >> "$R/reader.py"
rg commit "$RUN" --cleanup
assert_rc "cleanup commit succeeds" 0
assert_eq "cleanup subject" "relay: cleanup" "$(g log -1 --format=%s)"
assert_contains "cleanup trailer" "Relay-Cleanup: 1" "$(g log -1 --format=%b)"
shc="$(g rev-parse --short HEAD)"
rg commit "$RUN" --cleanup
assert_contains "cleanup re-run → already committed" "$shc (already committed)" "$OUT"

printf 'sec\n' >> "$R/reader.py"
rg commit "$RUN" --security-fix
assert_rc "security-fix commit succeeds" 0
assert_eq "security-fix subject" "relay: security fix" "$(g log -1 --format=%s)"
assert_contains "security-fix trailer" "Relay-Security-Fix: 1" "$(g log -1 --format=%b)"

mkdir -p "$R/cfg"; printf 's\n' > "$R/cfg/.env"
head_before="$(g rev-parse HEAD)"
rg commit "$RUN" --cleanup
assert_rc "the secret refusal applies to a cleanup commit too" 3
assert_eq "… and nothing is committed" "$head_before" "$(g rev-parse HEAD)"
rm -rf "$R/cfg"

rg commit "$RUN" --cleanup extra
assert_rc "--cleanup takes no argument" 2
rg commit "$RUN" --review-fix
assert_rc "--review-fix needs a phase number" 2
rg commit "$RUN" 1 --review-fix extra
assert_rc "… and nothing after it" 2

for bad in ".env" "config/.env.local" "node_modules/pkg/i.js" ".venv/bin/python" "src/__pycache__/m.cpython-312.pyc" ".DS_Store" ".next/cache/x" ".pytest_cache/v/x"; do
  mkdir -p "$R/$(dirname "$bad")"; printf 's\n' > "$R/$bad"; printf 'ok\n' >> "$R/reader.py"
  head_before="$(g rev-parse HEAD)"
  rg commit "$RUN" 2
  assert_rc "refuses $bad" 3
  assert_contains "names $bad" "$bad" "$OUT"
  assert_eq "no commit made ($bad)" "$head_before" "$(g rev-parse HEAD)"
  assert_eq "index restored ($bad)" "" "$(g diff --cached --name-only)"
  [ -f "$R/$bad" ] && ok "working tree untouched ($bad)" || no "working tree untouched ($bad)" "file gone"
  rm -rf "$R/${bad%%/*}"
done
g checkout -q reader.py

printf 'EXAMPLE=1\n' > "$R/.env.example"
rg commit "$RUN" 2
assert_rc ".env.example is allowed" 0

mkdir -p "$R/.git/hooks-fail"; printf '#!/bin/sh\necho "lint: 2 problems" >&2\nexit 1\n' > "$R/.git/hooks-fail/pre-commit"
chmod +x "$R/.git/hooks-fail/pre-commit"; g config core.hooksPath .git/hooks-fail
printf 'h\n' > "$R/hooked.txt"; head_before="$(g rev-parse HEAD)"
rg commit "$RUN" 2
assert_rc "failing hook → exit 1" 1
assert_contains "shows the hook's output" "lint: 2 problems" "$OUT"
assert_eq "nothing committed on hook failure" "$head_before" "$(g rev-parse HEAD)"
[ -f "$R/hooked.txt" ] && ok "work kept on hook failure" || no "work kept on hook failure" "file gone"
g config core.hooksPath .git/no-hooks
rg commit "$RUN" 2
assert_rc "re-run after the hook is fixed commits" 0

OUT="$(cd "$W/nogit" && bash "$RG" commit "$RUN" 1 2>&1)"; RC=$?
assert_rc "no git → exit 0" 0
assert_contains "no git → skipped" "skipped" "$OUT"

for bad in ".envrc" "keys/id_ed25519" "certs/server.pem" "certs/tls.key" "certs/client.p12"; do
  repo cm-key
  mkdir -p "$R/$(dirname "$bad")"; printf 's\n' > "$R/$bad"
  rg commit "$RUN" 1
  assert_rc "refuses $bad" 3
done
repo cm-pub; mkdir -p "$R/keys"; printf 'ssh-ed25519 AAAA\n' > "$R/keys/id_ed25519.pub"
rg commit "$RUN" 1
assert_rc "a public key is allowed" 0

repo cm-envm
printf 'A=1\n' > "$R/.env"; g add -f .env; g commit -qm "owner tracks .env"
printf 'KEY=sk-live\n' >> "$R/.env"
rg commit "$RUN" 1
assert_rc "a tracked .env that changed still commits" 0
assert_contains "… with a warning naming it" "⚠ .env is tracked and looks like a secret" "$OUT"
assert_eq "… and the change is in the commit" ".env" "$(g show --name-only --format= HEAD)"

repo cm-branch
rg branch "$RUN"; set_branch_field "$OUT"
printf 'a\n' > "$R/a.txt"; rg commit "$RUN" 1
g switch -q main
printf 'b\n' > "$R/b.txt"; head_before="$(g rev-parse main)"
rg commit "$RUN" 2
assert_rc "HEAD off the run's branch (resumed after the owner switched) → exit 4" 4
assert_contains "… names both branches" "HEAD is on main, but this run commits to $BR" "$OUT"
assert_contains "… and the owner's command" "git switch $BR" "$OUT"
assert_eq "… nothing committed on main" "$head_before" "$(g rev-parse main)"
assert_eq "… index untouched" "" "$(g diff --cached --name-only)"
g switch -q "$BR"; rg commit "$RUN" 2
assert_rc "back on the run branch → commits" 0
g checkout -q --detach HEAD; printf 'c\n' > "$R/c.txt"
rg commit "$RUN" 3
assert_rc "detached HEAD → exit 4" 4
assert_contains "… says detached" "a detached HEAD" "$OUT"
repo cm-own feature/o
set_branch_field "feature/o (yours — relay commits, never pushes)"
g switch -q -c other; printf 'o\n' > "$R/o.txt"
rg commit "$RUN" 1
assert_rc "owner's branch recorded, HEAD elsewhere → exit 4" 4

repo cm-noexcl
awk '!/relay/' "$R/.git/info/exclude" > "$R/x" && mv "$R/x" "$R/.git/info/exclude"
printf 'n\n' > "$R/n.txt"
rg commit "$RUN" 1
assert_rc "run root with no exclude entry: commit succeeds" 0
assert_eq "… and the run root is not committed" "" "$(g ls-files .relay)"
repo cm-tracked
g add -f "$RUN/STATE.md"; g commit -qm "run root tracked by mistake"
printf 'q\n' > "$R/q.txt"; printf 'edit\n' >> "$R/$RUN/STATE.md"
rg commit "$RUN" 1
assert_rc "tracked run root: commit succeeds" 0
assert_eq "… the commit holds only the phase's work" "q.txt" "$(g show --name-only --format= HEAD)"
assert_eq "… the run root is not deleted from git" "$RUN/STATE.md" "$(g ls-files .relay)"

repo cm-sub
mkdir -p "$R/pkg"; printf 's\n' > "$R/pkg/s.txt"
OUT="$(cd "$R/pkg" && bash "$RG" commit "$(cd "$R" && pwd -P)/$RUN" 1 2>&1)"; RC=$?
assert_rc "from a subdirectory with an absolute run root" 0
assert_eq "… commits the whole tree's changes" "pkg/s.txt" "$(g show --name-only --format= HEAD)"
assert_eq "… and not the run root" "" "$(g ls-files .relay)"

repo cm-hang
mkdir -p "$R/.git/hooks-hang"; printf '#!/bin/sh\nsleep 30\n' > "$R/.git/hooks-hang/pre-commit"
chmod +x "$R/.git/hooks-hang/pre-commit"; g config core.hooksPath .git/hooks-hang
printf 'h\n' > "$R/h.txt"; head_before="$(g rev-parse HEAD)"
start=$(date +%s)
OUT="$(cd "$R" && RELAY_COMMIT_TIMEOUT=2 bash "$RG" commit "$RUN" 1 2>&1)"; RC=$?
took=$(( $(date +%s) - start ))
assert_rc "a hook that never returns → exit 1" 1
assert_contains "… says it was stopped" "did not finish in 2 s" "$OUT"
assert_eq "… nothing committed" "$head_before" "$(g rev-parse HEAD)"
if [ "$took" -lt 15 ]; then ok "… cut off at the timeout (${took}s)"; else no "… cut off at the timeout" "took ${took}s"; fi
g config core.hooksPath .git/no-hooks
rg commit "$RUN" 1
assert_rc "… and a re-run once the hook is fixed commits" 0

# ---------------------------------------------------------------------------
echo "push"
repo ps
rg branch "$RUN"; set_branch_field "$OUT"
printf 'c\n' > "$R/c.txt"; rg commit "$RUN" 1
rg push "$RUN"
assert_contains "no remote → skipped, stays local" "no git remote" "$OUT"
bare ps
rg push "$RUN"
assert_rc "push exits 0" 0
assert_eq "pushed line with the commit count" "push: $BR → origin (1 commits)" "$OUT"
assert_eq "remote has the branch" "$(g rev-parse HEAD)" "$(git --git-dir="$W/ps.git" rev-parse "$BR")"
assert_eq "upstream set" "origin/$BR" "$(g rev-parse --abbrev-ref '@{upstream}')"
assert_eq "main never pushed" "" "$(git --git-dir="$W/ps.git" branch --list main)"

# Diverge the remote: another clone pushes to the run branch.
git clone -q "$W/ps.git" "$W/ps-other" 2>/dev/null && git -C "$W/ps-other" checkout -q "$BR"
printf 'o\n' > "$W/ps-other/o.txt"
git -C "$W/ps-other" -c user.email=o@e -c user.name=o add o.txt
git -C "$W/ps-other" -c user.email=o@e -c user.name=o commit -qm other
git -C "$W/ps-other" push -q origin "$BR"
printf 'd\n' > "$R/d.txt"; rg commit "$RUN" 2
rg push "$RUN"
assert_rc "rejected push still exits 0" 0
assert_contains "rejected → failed line" "push: failed" "$OUT"
assert_contains "gives the owner the command" "run: git push -u origin $BR" "$OUT"
assert_missing "never forces" "force" "$OUT"
assert_eq "remote keeps the other clone's commit" "other" "$(git --git-dir="$W/ps.git" log -1 --format=%s "$BR")"

g remote set-url origin "$W/gone.git"
rg push "$RUN"
assert_rc "unreachable remote exits 0" 0
assert_contains "unreachable → failed line with the command" "run: git push -u origin $BR" "$OUT"

mkdir -p "$W/fakessh"; printf '#!/bin/sh\nsleep 30\n' > "$W/fakessh/ssh"; chmod +x "$W/fakessh/ssh"
g remote set-url origin "ssh://example.invalid/x.git"
start=$(date +%s)
OUT="$(cd "$R" && GIT_SSH_COMMAND="$W/fakessh/ssh" RELAY_PUSH_TIMEOUT=2 bash "$RG" push "$RUN" 2>&1)"; RC=$?
took=$(( $(date +%s) - start ))
assert_rc "hanging push exits 0" 0
assert_contains "hang → timed out" "timed out after 2 s" "$OUT"
assert_contains "hang → gives the command" "run: git push -u origin $BR" "$OUT"
if [ "$took" -lt 15 ]; then ok "hang is cut off at the timeout (${took}s)"; else no "hang is cut off at the timeout" "took ${took}s"; fi

# A helper git push starts (git-remote-https → credential helper / askpass prompt) is a
# grandchild: the timeout must stop it too, not leave it running after relay gives up.
mkdir -p "$W/fakehelper"
printf '#!/bin/sh\nsh -c '"'"'echo $$ > "$HELPER_PID"; exec sleep 60'"'"' &\nwait\n' > "$W/fakehelper/git-remote-hang"
chmod +x "$W/fakehelper/git-remote-hang"
g remote set-url origin "hang::x"
OUT="$(cd "$R" && PATH="$W/fakehelper:$PATH" HELPER_PID="$W/helper.pid" RELAY_PUSH_TIMEOUT=2 bash "$RG" push "$RUN" 2>&1)"; RC=$?
assert_rc "hanging remote helper → exit 0" 0
assert_contains "… timed out" "timed out after 2 s" "$OUT"
assert_missing "… no job-control noise" "Terminated" "$OUT"
sleep 1
if [ -s "$W/helper.pid" ] && ! kill -0 "$(cat "$W/helper.pid")" 2>/dev/null; then ok "… the helper's own child is stopped too"
else no "… the helper's own child is stopped too" "pid $(cat "$W/helper.pid" 2>/dev/null) still running"; kill "$(cat "$W/helper.pid")" 2>/dev/null; fi

# Push: off (the default since 0.11) — never pushed, the owner gets the command.
repo ps-off
rg branch "$RUN"; set_branch_field "$OUT"; set_push_field "off — default"
printf 'c\n' > "$R/c.txt"; rg commit "$RUN" 1
bare ps-off
rg push "$RUN"
assert_rc "Push: off → exit 0" 0
assert_eq "Push: off → skipped line with the command" "push: skipped — push is off for this run; run: git push -u origin $BR" "$OUT"
assert_eq "Push: off → the remote never gets the branch" "" "$(git --git-dir="$W/ps-off.git" branch --list)"
set_push_field "OFF — --no-push"
rg push "$RUN"
assert_contains "Push: off is read case-insensitively" "push is off for this run" "$OUT"
set_push_field "on"
rg push "$RUN"
assert_eq "Push: on → pushed" "push: $BR → origin (1 commits)" "$OUT"
assert_eq "Push: on → the remote has the branch" "$(g rev-parse HEAD)" "$(git --git-dir="$W/ps-off.git" rev-parse "$BR")"

repo ps-own feature/z
bare ps-own
set_branch_field "feature/z (yours — relay commits, never pushes)"
printf 'c\n' > "$R/c.txt"; rg commit "$RUN" 1
rg push "$RUN"
assert_contains "owner's branch is not pushed" "feature/z is your branch" "$OUT"
assert_eq "remote untouched" "" "$(git --git-dir="$W/ps-own.git" branch --list)"

set_branch_field "—"
awk 'index($0, "**Branch:**") != 1' "$R/$RUN/STATE.md" > "$R/x" && mv "$R/x" "$R/$RUN/STATE.md"
rg push "$RUN"
assert_contains "no Branch field → skipped (hand-authored run roots)" "no Branch field" "$OUT"

# ---------------------------------------------------------------------------
echo "usage + shells"
R="$W/cm"
rg bogus "$RUN"; assert_rc "unknown subcommand → 2" 2
rg commit "$RUN"; assert_rc "commit without a phase → 2" 2
rg commit "$RUN" x; assert_rc "non-numeric phase → 2" 2
rg preflight "$W/missing-run"; assert_rc "missing run root → 2" 2
if command -v zsh >/dev/null 2>&1; then
  OUT="$(cd "$R" && zsh -c "bash '$RG' preflight '$RUN'" 2>&1)"; RC=$?
  assert_rc "runs from zsh (the Bash tool's shell)" 0
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] && echo "All fixture scenarios passed." && exit 0
exit 1
