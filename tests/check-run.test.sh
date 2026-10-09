#!/usr/bin/env bash
# check-run.test.sh — fixture tests for tools/check-run.py's git and check-order rules
#
# Proves the run checker enforces the git split: the orchestrator makes no git write at all
# (it only runs relay-git.sh push, after AUDIT_COMPLETE); a subagent commits only through
# relay-git.sh and never changes branch, but may stage / move / remove / restore files; read-only
# forms (stash list, branch --show-current, tag -l) are never flagged. And a completed run on a
# branch relay created must have run the push — nothing else enforces that step. And the 0.10
# checks: each check dispatch records in its own mode, a `Review: yes` phase is reviewed before
# the run moves on, findings are followed by their fix, and the tidy-up and security pass run
# (in that order) before the audit — with no rule at all for a legacy or all---lean run root.
#
# Repo-only (not shipped in the plugin payload). Needs python3.
#   bash tests/check-run.test.sh
# Exits 0 if every assertion passes, 1 otherwise.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CR="$REPO_ROOT/tools/check-run.py"
[ -f "$CR" ] || { echo "FATAL: missing $CR" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  \033[31m✗\033[0m %s\n      %s\n' "$1" "$2"; }
assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "expected [$2] got [$3]"; fi; }
assert_contains() { case "$3" in *"$2"*) ok "$1";; *) no "$1" "missing substring [$2] in [$3]";; esac; }
assert_missing()  { case "$3" in *"$2"*) no "$1" "unexpectedly contains [$2]";; *) ok "$1";; esac; }

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

# writes <role> <command> — what raw_git_writes reports, comma-joined ("" = allowed)
writes() {
  PYTHONDONTWRITEBYTECODE=1 python3 - "$CR" "$1" "$2" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("check_run", sys.argv[1])
m = importlib.util.module_from_spec(spec); sys.modules["check_run"] = m  # @dataclass looks it up
spec.loader.exec_module(m)
print(",".join(m.raw_git_writes(sys.argv[3], subagent=sys.argv[2] == "subagent")))
PY
}

# ---------------------------------------------------------------------------
echo "orchestrator: every git write is flagged"
for c in "git add -A" "git commit -m x" "git stash -u" "git reset" "git reset --hard HEAD" \
         "git checkout -b x" "git checkout main" "git switch main" "git branch relay/x" \
         "git restore a.txt" "git merge x" "git push origin x" "git tag v1" "git rm a" "git clean -fd"; do
  sub="$(printf '%s' "$c" | awk '{print $2}')"
  assert_eq "orchestrator: $c" "git $sub" "$(writes orchestrator "$c")"
done
assert_eq "after && in a compound command" "git add" "$(writes orchestrator 'cd x && git add -A')"
assert_eq "with -C and -c options" "git commit" "$(writes orchestrator 'git -c a=b -C repo commit -m x')"
assert_eq "two writes in one command" "git add,git commit" "$(writes orchestrator 'git add -A; git commit -m x')"

echo "read-only forms are never flagged"
for c in "git status --porcelain" "git diff --stat" "git log -1" "git show HEAD" "git stash list" \
         "git stash show -p" "git branch" "git branch --show-current" "git branch -a -v" \
         "git branch --list 'relay/*'" "git tag" "git tag -l 'v*'" "bash .relay/x/relay-git.sh commit .relay/x 1" \
         "grep -n 'git commit' notes.md"; do
  assert_eq "read-only: $c" "" "$(writes orchestrator "$c")"
done
assert_eq "git branch -D is a write" "git branch" "$(writes orchestrator 'git branch -D x')"

echo "subagent: commit / push / stash / reset / rebase / branch changes flagged"
for c in "git commit -m x" "git push" "git stash" "git reset HEAD~1" "git rebase main" "git switch -c y" \
         "git checkout -b y" "git branch y" "git merge y"; do
  sub="$(printf '%s' "$c" | awk '{print $2}')"
  assert_eq "subagent: $c" "git $sub" "$(writes subagent "$c")"
done
echo "subagent: file-level index work is allowed"
for c in "git add src/a.py" "git mv a.py b.py" "git rm --cached x" "git restore a.py" \
         "git checkout -- a.py" "git clean -n"; do
  assert_eq "subagent may: $c" "" "$(writes subagent "$c")"
done

# ---------------------------------------------------------------------------
echo "end state: a completed run on relay's branch must have pushed"
# run <name> <branch field> <push?> [<Push field>] — a minimal finished orchestrator transcript
# + run root; no 4th argument writes no **Push:** line (runs planned before 0.11)
run() {
  local d="$W/$1"; mkdir -p "$d/run"
  cat > "$d/run/STATE.md" <<EOF
**Status:** COMPLETE
**Branch:** $2${4:+
**Push:** $4}

| # | Phase | Status | Started | Completed | Notes |
|---|-------|--------|---------|-----------|-------|
EOF
  python3 - "$d/t.jsonl" "$3" <<'PY'
import json, os, sys
out, push = sys.argv[1], sys.argv[2] in ("yes", "cd")
def a(*items): return {"type": "assistant", "message": {"content": list(items)}}
recs = [{"type": "user", "message": {"content": "go"}},
        a({"type": "text", "text": "AUDIT_COMPLETE\nAudit coverage: 1 re-verified, 0 trust-prior (0%)."})]
if sys.argv[2] == "cd":  # the commit 14 runs' first command
    recs.insert(1, a({"type": "tool_use", "id": "t0", "name": "Bash",
                      "input": {"command": "cd /home/x/projects/main && pwd && git status --short"}}))
if push:
    recs.append(a({"type": "tool_use", "id": "t1", "name": "Bash",
                   "input": {"command": "bash run/relay-git.sh push run"}}))
for i, c in enumerate(filter(None, os.environ.get("EXTRA_CMDS", "").split("\n"))):
    recs.append(a({"type": "tool_use", "id": f"x{i}", "name": "Bash", "input": {"command": c}}))
line = os.environ.get("PUSHLINE", "Push: push: relay/x → origin (1 commits)")
recs.append(a({"type": "text", "text": "RELAY_RUN_COMPLETE\n" + line}))
with open(out, "w") as f:
    for r in recs: f.write(json.dumps(r) + "\n")
PY
  OUT="$(python3 "$CR" "$d/t.jsonl" "$d/run" 2>&1)"
}
run nopush "relay/x (created by relay)" no
assert_contains "no push on relay's branch → violation" "RELAY_RUN_COMPLETE without running relay-git.sh push" "$OUT"
assert_contains "… and the run FAILs" "Result: FAIL" "$OUT"
run pushed "relay/x (created by relay)" yes
assert_missing "push ran → no push violation" "without running relay-git.sh push" "$OUT"
assert_contains "… and the push is noted after the audit" "relay-git.sh push after AUDIT_COMPLETE" "$OUT"
run own "feature/z (yours — relay commits, never pushes)" no
assert_contains "owner's branch without the push step → warning only" "it would have skipped the owner's branch" "$OUT"
assert_missing "… not a violation" "✗ RELAY_RUN_COMPLETE without" "$OUT"
run nogit "no-git" no
assert_missing "no git → nothing to push" "relay-git.sh push" "$OUT"
run pushon "relay/x (created by relay)" no "on"
assert_contains "Push: on, no push step → violation" "✗ RELAY_RUN_COMPLETE without running relay-git.sh push" "$OUT"
run pushoff "relay/x (created by relay)" no "off — default"
assert_contains "Push: off, no push step → warning only" "push is off; its skipped line hands the owner the command" "$OUT"
assert_missing "… not a violation" "✗ RELAY_RUN_COMPLETE without" "$OUT"
run pushoffran "relay/x (created by relay)" yes "off — default"
assert_missing "Push: off, push step ran → nothing to flag" "without running relay-git.sh push" "$OUT"

echo "the push line: verbatim, no doubled label (old runs' 'Push: push:' still pass)"
run oldpushline "relay/x (created by relay)" yes
assert_missing "'Push: push: …' (pre-fix runs) → no warning" "RELAY_RUN_COMPLETE has no" "$OUT"
PUSHLINE='push: relay/x → origin (1 commits)' run barepushline "relay/x (created by relay)" yes
assert_missing "bare 'push: …' → no warning" "RELAY_RUN_COMPLETE has no" "$OUT"
PUSHLINE='All 1 phases complete.' run nopushline "relay/x (created by relay)" yes
assert_contains "no push line at all → warning" "RELAY_RUN_COMPLETE has no push line" "$OUT"

echo "STATE.md: read once at the start, then the Notable events section at completion"
EXTRA_CMDS=$'cat run/STATE.md\nawk \'/^## Notable events/{f=1; print; next} f && /^## /{exit} f\' run/STATE.md' run stateawk "no-git" no
assert_missing "the awk events read (current PROTOCOL.md) → no re-read warning" "reads STATE.md again" "$OUT"
EXTRA_CMDS=$'cat run/STATE.md\ngrep -A 40 \'^## Notable events\' run/STATE.md' run stategrep "no-git" no
assert_missing "the grep -A 40 events read (older runs) → no re-read warning" "reads STATE.md again" "$OUT"
EXTRA_CMDS=$'cat run/STATE.md\ncat run/STATE.md' run statetwice "no-git" no
assert_contains "a second whole read → warning" "reads STATE.md again" "$OUT"

echo "after an interruption: recover.sh first (run roots that carry it)"
# irun <name> <variant> [recover-in-root] — a transcript: dispatch phase 1, the session stops, a
# "continue" turn; variant: none (no recover), recover (recover then re-dispatch), echo (recover
# printed a finished report, echoed and recorded), echo-norecord, apierr (an API-error hand-back
# recorded with --interrupted)
irun() {
  local d="$W/$1"; mkdir -p "$d/run"
  printf '**Status:** IN_PROGRESS\n**Branch:** no-git\n' > "$d/run/STATE.md"
  [ "${3:-yes}" = "yes" ] && : > "$d/run/recover.sh"
  python3 - "$d/t.jsonl" "$2" <<'PY'
import json, sys
out, v = sys.argv[1], sys.argv[2]
def a(*items): return {"type": "assistant", "message": {"content": list(items)}}
def u(text): return {"type": "user", "message": {"content": text}}
def bash(i, c): return {"type": "tool_use", "id": i, "name": "Bash", "input": {"command": c}}
agent = {"type": "tool_use", "id": "d1", "name": "Agent", "input": {"description": "Relay phase 1",
         "prompt": "Read `run/phases/phase-1.brief.md` and follow it exactly. Open it with the Read tool."}}
recs = [u("go"), a(bash("b0", "bash run/assemble-brief.sh run 1")), a(agent),
        a({"type": "text", "text": "Phase 1 dispatched; waiting."})]
if v == "apierr":
    recs += [u('<agent-message from="x1">\n[Subagent hand-back]\n  API Error: usage limit reached\n</agent-message>'),
             a(bash("r1", 'bash run/record-phase.sh run 1 --interrupted "usage limit"'))]
elif v in ("notice-idle", "notice-act", "sendmsg"):
    notice = ('<task-notification>\n<task-id>x</task-id>\n<status>stopped</status>\n<summary>Background agent '
              '"Relay phase 1" didn\'t finish before the previous session ended</summary>\n</task-notification>')
    recs.append(u(notice))
    if v == "notice-act":
        recs.append(a(bash("b1", "bash run/assemble-brief.sh run 1")))
    elif v == "sendmsg":
        recs.append(a({"type": "tool_use", "id": "s1", "name": "SendMessage", "input": {"to": "x", "message": "continue"}}))
    else:
        recs += [u("continue"), a(bash("r0", "bash run/recover.sh run"))]
else:
    recs.append(u("continue"))
    if v == "none":
        recs.append(a(bash("b1", "bash run/assemble-brief.sh run 1")))
    elif v == "recover":
        recs += [a(bash("r0", "bash run/recover.sh run")), a(bash("b1", "bash run/assemble-brief.sh run 1")), a(dict(agent, id="d2"))]
    else:
        recs += [a(bash("r0", "bash run/recover.sh run")),
                 a({"type": "text", "text": "RELAY_PHASE_START\nRELAY_PHASE_VERIFY\nRELAY_PHASE_DONE\nPhase 1 complete."})]
        if v == "echo":
            recs.append(a(bash("r1", "bash run/record-phase.sh run 1")))
with open(out, "w") as f:
    for r in recs: f.write(json.dumps(r) + "\n")
PY
  OUT="$(python3 "$CR" "$d/t.jsonl" "$d/run" 2>&1)"
}
irun i-none none
assert_contains "a turn while waiting, without recover.sh → violation" "started while waiting on a hand-back, but recover.sh was not run first" "$OUT"
irun i-old none no
assert_missing "… not for a run root without recover.sh (pre-0.11)" "recover.sh was not run first" "$OUT"
irun i-rec recover
assert_missing "recover.sh first → no violation" "recover.sh was not run first" "$OUT"
assert_contains "… and noted" "recover.sh run after an interruption" "$OUT"
irun i-echo echo
assert_missing "a recovered report echoed and recorded → no violation" "never recorded" "$OUT"
irun i-norec echo-norecord
assert_contains "a recovered report echoed but not recorded → violation" "echoed a recovered report but never recorded it" "$OUT"
irun i-api apierr
assert_missing "an API-error hand-back recorded with --interrupted is handled" "not recorded with record-phase.sh --no-report" "$OUT"
irun i-nidle notice-idle
assert_missing "the 'didn't finish' notice with no action, then recover.sh → no violation" "recover.sh was not run first" "$OUT"
irun i-nact notice-act
assert_contains "acting on the 'didn't finish' notice without recover.sh → violation" "recover.sh was not run first" "$OUT"
irun i-send sendmsg
assert_contains "reviving the stopped agent with SendMessage → violation" "never revive a stopped Relay agent" "$OUT"

echo "the orchestrator never changes directory"
run pushed "relay/x (created by relay)" yes
assert_missing "no cd → no directory violation" "changes directory" "$OUT"
run cdrun "relay/x (created by relay)" cd
assert_contains "a cd into another checkout → violation" "orchestrator changes directory" "$OUT"
assert_contains "… and the run FAILs" "Result: FAIL" "$OUT"
# dirs <command> — what changes_directory reports, comma-joined ("" = none)
dirs() {
  PYTHONDONTWRITEBYTECODE=1 python3 - "$CR" "$1" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("check_run", sys.argv[1])
m = importlib.util.module_from_spec(spec); sys.modules["check_run"] = m
spec.loader.exec_module(m)
print(",".join(m.changes_directory(sys.argv[2])))
PY
}
assert_eq "cd at the start" "cd /x" "$(dirs 'cd /x && ls')"
assert_eq "cd after &&" "cd run" "$(dirs 'pwd && cd run')"
assert_eq "cd in a subshell" "cd run" "$(dirs '(cd run; ls)')"
assert_eq "pushd" "pushd /x" "$(dirs 'pushd /x')"
assert_eq "bare cd" "cd" "$(dirs 'cd')"
for c in "echo abcd" "git -C /x status" "grep -n cd PROTOCOL.md" "ls cdrom" "bash run/relay-git.sh push run"; do
  assert_eq "not a directory change: $c" "" "$(dirs "$c")"
done

# ---------------------------------------------------------------------------
# py <snippet> — run a snippet with check_run imported as m (args after the snippet in sys.argv)
py() {
  local code="$1"; shift
  PYTHONDONTWRITEBYTECODE=1 python3 - "$CR" "$@" <<PY
import importlib.util, sys, json
from pathlib import Path
spec = importlib.util.spec_from_file_location("check_run", sys.argv[1])
m = importlib.util.module_from_spec(spec); sys.modules["check_run"] = m
spec.loader.exec_module(m)
$code
PY
}
# mode <description> <record-phase.sh argument tail> — does the record call match the dispatch?
mode() { py 'import re; p = m.record_mode_for(sys.argv[2]); print("match" if p and re.search(p, sys.argv[3]) else "no")' "$1" "$2"; }

echo "record_mode_for: the 0.10 check dispatches"
assert_eq "phase 2 review ↔ 2 --review" "match" "$(mode "Relay phase 2 review" " 2 --review")"
assert_eq "phase 2 review ≠ 2 --review-fix" "no" "$(mode "Relay phase 2 review" " 2 --review-fix")"
assert_eq "phase 2 review fix ↔ 2 --review-fix" "match" "$(mode "Relay phase 2 review fix" " 2 --review-fix")"
assert_eq "phase 2 ≠ 2 --review" "no" "$(mode "Relay phase 2" " 2 --review")"
assert_eq "phase 2 still ↔ 2" "match" "$(mode "Relay phase 2" " 2")"
assert_eq "cleanup ↔ --cleanup" "match" "$(mode "Relay cleanup" " --cleanup")"
assert_eq "security pass ↔ --security" "match" "$(mode "Relay security pass" " --security")"
assert_eq "security pass ≠ --security-fix" "no" "$(mode "Relay security pass" " --security-fix")"
assert_eq "security fix ↔ --security-fix" "match" "$(mode "Relay security fix" " --security-fix")"
assert_eq "the new markers are recognised" "REVIEW_FINDINGS,CLEANUP_DONE,SECURITY_FIX" \
  "$(py 'print(",".join(m.markers("REVIEW_FINDINGS\nx\nCLEANUP_DONE\nSECURITY_FIX\nREVIEW_FINDINGSX")))')"

echo "check_steps: the checks run, in order, before the audit"
# steps <run-name> <cleanup|-> <security|-> <review per phase, comma list: yes|skip|-> <timeline>
# timeline: ;-separated "d:<description>" (dispatch) or "e:<MARKER>" (echo)
steps() {
  local d="$W/steps-$1" i=1 r
  mkdir -p "$d/phases"
  { echo "**Status:** IN_PROGRESS"
    [ "$2" = "-" ] || echo "**Cleanup:** $2    <!-- c -->"
    [ "$3" = "-" ] || echo "**Security pass:** $3"; } > "$d/STATE.md"
  local IFS=','
  for r in $4; do
    printf 'RELAY_PHASE_START\nPhase: %s of 9 — p\n' "$i" > "$d/phases/phase-$i.md"
    [ "$r" = "-" ] || printf 'Review: %s\n' "$r" >> "$d/phases/phase-$i.md"
    i=$((i + 1))
  done
  unset IFS
  py '
ev = []
for part in sys.argv[3].split(";"):
    k, v = part.split(":", 1)
    ev.append(("dispatch", v) if k == "d" else ("echo", [v]))
print(" | ".join(m.check_steps(ev, Path(sys.argv[2]))) or "ok")' "$d" "$5"
}
FULL="d:Relay phase 1;d:Relay phase 1 review;e:REVIEW_FINDINGS;d:Relay phase 1 review fix;d:Relay phase 2;d:Relay cleanup;d:Relay security pass;e:SECURITY_CLEAN;d:Relay audit round 1"
assert_eq "a complete checked run passes" "ok" "$(steps full on yes yes,skip "$FULL")"
assert_contains "a skipped review is a violation" "phase 1 says Review: yes, but 'Relay phase 2' was dispatched before its review" \
  "$(steps norev on yes yes,skip "d:Relay phase 1;d:Relay phase 2;d:Relay cleanup;d:Relay security pass;d:Relay audit round 1")"
assert_contains "findings without their fix" "REVIEW_FINDINGS was echoed, but the next dispatch was 'Relay phase 2'" \
  "$(steps nofix - - yes,skip "d:Relay phase 1;d:Relay phase 1 review;e:REVIEW_FINDINGS;d:Relay phase 2;d:Relay audit round 1")"
assert_contains "security findings without their fix" "SECURITY_FINDINGS was echoed, but the next dispatch was 'Relay audit round 1'" \
  "$(steps nosecfix - yes skip "d:Relay phase 1;d:Relay security pass;e:SECURITY_FINDINGS;d:Relay audit round 1")"
assert_contains "a skipped tidy-up is a violation" "Cleanup: on, but no tidy-up was dispatched" \
  "$(steps noclean on skip skip "d:Relay phase 1;d:Relay audit round 1")"
assert_contains "a skipped security pass is a violation" "Security pass: yes, but no security pass was dispatched" \
  "$(steps nosec "off — x" yes skip "d:Relay phase 1;d:Relay audit round 1")"
assert_contains "the wrong order is a violation" "after the security pass" \
  "$(steps order on yes skip "d:Relay phase 1;d:Relay security pass;d:Relay cleanup;d:Relay audit round 1")"
assert_eq "a re-dispatched review still counts" "ok" \
  "$(steps redis - - yes "d:Relay phase 1;d:Relay phase 1 review;d:Relay phase 1 review;e:REVIEW_CLEAN;d:Relay audit round 1")"
assert_eq "a fix window's phase is reviewed after the fix" "ok" \
  "$(steps viafix - - yes "d:Relay phase 1;d:Relay phase 1 fix;d:Relay phase 1 review;e:REVIEW_CLEAN;d:Relay audit round 1")"
assert_eq "a run blocked mid-phase owes no review" "ok" "$(steps blocked on yes yes "d:Relay phase 1")"
assert_eq "an all---lean run root dispatches no checks and passes" "ok" \
  "$(steps lean "off — --lean" "skip — --lean" "skip — --lean,skip — --lean" "d:Relay phase 1;d:Relay phase 2;d:Relay audit round 1")"
assert_eq "a legacy run root (no fields, no Review: lines) has no rule" "ok" \
  "$(steps legacy - - -,- "d:Relay phase 1;d:Relay phase 2;d:Relay audit round 1")"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] && echo "All fixture scenarios passed." && exit 0
exit 1
