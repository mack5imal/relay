# Relay transcript markers

The named blocks a Relay run prints into the transcript. A phase, fix, review, cleanup, security, or audit subagent writes its report to a `.report.md` file and returns the same text; the report reaches the orchestrator as a hand-back message (every line indented two spaces by the harness), and the orchestrator echoes the blocks, verbatim and unindented, into its own message text — that echo is what the `/goal` evaluator and the user reliably see. Evidence and command output never go in these blocks — they live in the run's evidence files and logs. No block claims anything about `STATE.md`: the orchestrator echoes first and records afterwards.

This file is copied to `<run-root>/MARKERS.md` at Stage 7. The brief assembler (`assemble-brief.sh`) inlines **Phase blocks** + **Failure blocks** into phase and fix briefs, **Review blocks** into review, review-fix, cleanup, security and security-fix briefs, and **Audit blocks** into audit briefs. Edit the source at `templates/MARKERS.md`; the four `## ` headings are what the assembler slices on.

## Phase blocks

Printed once per phase, in this order, by the phase subagent (or the fix subagent on a successful fix).

### `RELAY_PHASE_START` (once per phase, at execution start)

```
RELAY_PHASE_START
Phase: <N> of <total> — <name>
Task: <one-line from ROADMAP.md>
Type: <greenfield|brownfield|bugfix|refactor|ui>
Mandatory commands: <comma-separated list>
Acceptance criteria: <count>
Evidence required: <comma-separated types>
Depends on phases: <list, or "none">
Map seeds: <comma-separated exact symbol names, or "none">
Estimated files: <n>
Review: <yes | skip — reason>
```

### `RELAY_PHASE_VERIFY` (once per phase, before DONE)

```
RELAY_PHASE_VERIFY
Acceptance (evidence: <run-root>/phases/phase-<N>.evidence.md):
- C1 <short criterion>: <pass|fail>
- C2 <short criterion>: <pass|fail>
...
Engineering: build <pass|fail> · typecheck <pass|fail> · lint <pass|fail|pre-existing> · tests <pass|fail|N pre-existing>
Cleanliness: debug prints <count> · TODO/FIXME <count> · dead imports <count>
Files changed: <count>
```

One line per acceptance criterion (`C<k>` = the k-th bullet in the spec's Acceptance criteria), no inline evidence; everything else fits in three lines. Cleanliness counts come from grepping `repo-state.sh added-lines` vs `Baseline ref` (incl. uncommitted + untracked); a non-zero count fails unless the phase spec sets `Cleanliness override:`. Matched lines, the changed-files list, and notable diffs are in the evidence file.

### `MEMORY_SAVED` (once per phase, between VERIFY and DONE)

```
MEMORY_SAVED: <memory-name>[, <memory-name>…]     (or "none — nothing non-obvious this phase")
```

### `RELAY_PHASE_DONE` (once per phase, final block of the phase)

```
RELAY_PHASE_DONE
Phase <N> complete.
Evidence: <run-root>/phases/phase-<N>.evidence.md
```

## Failure blocks

The 3-strike recovery protocol. `FAILURE_PROBE` and `FAILURE_ESCALATE` come from the phase subagent; `FAILURE_HANDOFF` comes from the fix subagent, or from the orchestrator when a dispatch returns no report twice.

### `FAILURE_PROBE` (first failure)

```
FAILURE_PROBE
Phase: <N> — <name>
Failed criterion: <text>
Tried: <what was attempted>
Hypothesis: <root cause guess>
Next: auto-retry with probe injected
```

### `FAILURE_ESCALATE` (second failure — fix spec)

```
FAILURE_ESCALATE
Phase: <N> — <name>
Failed criterion: <text>
Retry probe history:
  attempt 1: <summary>
  attempt 2: <summary>
Writing fix spec at <run-root>/phases/phase-<N>.fix.md
```

### `FAILURE_HANDOFF` (third failure — stop)

```
FAILURE_HANDOFF
Phase: <N> — <name>
Failed criterion: <text>
Three attempts tried:
  1. <summary>
  2. <summary>
  3. <fix spec summary>
Suggested next move: <one line>
Resume: run `bash <run-root>/resume-line.sh <run-root>` for a ready-to-paste /goal that restarts from this phase.
User intervention required.
```

## Review blocks

The checks around the build: a correctness review after a phase (when its spec says `Review: yes`), the tidy-up pass after the last phase, and the security pass before the audit. Each runs in its own subagent. **None of these steps ever hands off or blocks the run** — a finding that cannot be fixed is undone and written to `<run-root>/FINDINGS.md`, and the run carries on.

### `REVIEW_START` (review window, first block)

```
REVIEW_START
Phase: <N> — <name>
Diff: <first>^..<last>   (or: none — <why>)
Files: <count>
```

### `REVIEW_CLEAN` (review window — no findings)

```
REVIEW_CLEAN
Phase: <N>
Evidence: <run-root>/phases/phase-<N>.review.evidence.md
```

### `REVIEW_FINDINGS` (review window — something to fix)

```
REVIEW_FINDINGS
Phase: <N>
Findings: <n> to fix · <d> deferred
Writing fix spec at <run-root>/phases/phase-<N>.review-fix.md
```

`deferred` counts findings written to `FINDINGS.md` instead of the fix spec — only a genuine conflict with a spec criterion, never convenience.

### `REVIEW_FIX` (review-fix window — its only block)

```
REVIEW_FIX
Phase: <N>
Fixed: <a> of <b>
Unresolved:
- <file:line> <finding> — <why it could not be fixed>
<the line relay-git.sh commit printed, verbatim — it starts with "commit:">
```

Omit `Unresolved:` when every finding was fixed. An unresolved finding's changes were undone and it is in `FINDINGS.md`. One attempt, no retry, no handoff — the run moves on.

### `CLEANUP_START` (tidy-up window, first block)

```
CLEANUP_START
Footprint: <n> files
Commands: <comma-separated deduplicated set>
```

### `CLEANUP_DONE` (tidy-up window, last block)

```
CLEANUP_DONE
Result: <applied | nothing to change | restored — checks could not stay green>
Fixed: <n> · Deferred: <m> (<run-root>/FINDINGS.md)
Commands: <p>/<total> exit 0
<the line relay-git.sh commit printed, verbatim — it starts with "commit:"; "commit: none — <why>" when it did not run>
```

### `SECURITY_START` (security window, first block)

```
SECURITY_START
Footprint: <n> files
Surfaces: <comma-separated surfaces checked>
```

### `SECURITY_CLEAN` (security window — no findings)

```
SECURITY_CLEAN
Evidence: <run-root>/phases/security.evidence.md
```

### `SECURITY_FINDINGS` (security window — something to fix)

```
SECURITY_FINDINGS
Findings: <n> to fix · <d> deferred
Writing fix spec at <run-root>/phases/security-fix.md
```

### `SECURITY_FIX` (security-fix window — its only block)

```
SECURITY_FIX
Fixed: <a> of <b>
Unresolved:
- <file:line> <finding> — <why it could not be fixed>
<the line relay-git.sh commit printed, verbatim — it starts with "commit:">
```

Same rules as `REVIEW_FIX`.

### `FINDINGS.md` (on disk, not a transcript block)

Each review, tidy-up and security window appends its own section — `## Review — phase <N>`, `## Cleanup`, `## Security` — to `<run-root>/FINDINGS.md` (created by the first writer). One bullet per finding, never rewritten:

```
- [<correctness|security|cleanup>] <file:line> — <what> — <deferred|unresolved>: <reason> — next: <suggested move>
- [plan] <file:line> — <what the fix changed> — changed: plan said "<the line, quoted>" — next: keep it, or revert <commit or file>
```

The reason is mandatory. A `[plan]` bullet is a fix a check **kept** although it changed a line relay decided while planning (anything tagged `(planner)` — an out-of-scope or constraint bullet, or a value in a success criterion — or an assumption; `PHASE-BRIEF.md` §3b); a fix that would change the owner's call is deferred instead, with `contradicts the plan: "<line>"` as its reason. `record-phase.sh` adds a `## Skipped steps` bullet when a check's dispatch returns no report twice. `record-phase.sh --audit` counts the bullets for `RELAY_RUN_COMPLETE`. A run with no `FINDINGS.md` has none.

## Audit blocks

Printed by the audit subagent per round; `RELAY_RUN_COMPLETE` is printed by the orchestrator after `AUDIT_COMPLETE`.

### `AUDIT_START` (once per audit round, after the last phase)

```
AUDIT_START
Round: <1|2|3>
Phases to verify: <N>
Criteria to re-check: <count>
Spec criteria to re-check: <count, or "none — no SPEC.md this run">
Commands to re-run: <comma-separated, deduplicated set>
```

### `AUDIT_VERIFY` (once per audit round, after re-checks complete)

```
AUDIT_VERIFY
Evidence: <run-root>/phases/audit-<round>.evidence.md
Phases:
- Phase 1: <DONE ✓ | DONE missing | evidence missing> · criteria <p> pass / <f> fail / <t> trust-prior · deliverables <d>/<D> present
- Phase 2: ...
Commands: <n>/<total> exit 0
Spec: <m> met / <f> not met / <t> trust-prior · prohibitions <v> violated   (omit when no SPEC.md)
Failures:
- <cmd>: exit <code> — log: <run-root>/logs/audit-<round>/<slug>.log
- Phase <k> / C<j> "<criterion>": fail
- Phase <k> / deliverable "<bullet>": missing
- Spec S<k> "<label>": not met
- Uncommitted: <n> path(s) — <first few>
Summary: <pass count> pass, <fail count> fail, <trust count> trust-prior, <missing count> deliverable-gaps, <s> spec-gaps
```

Omit `Failures:` when there are none. Per-criterion evidence and every `repo-state.sh deliverable` result (complete-working-tree check vs `Baseline ref`) are in the audit evidence file — one line per phase keeps a long run's audit bounded.

### `AUDIT_GAPS` (only if gaps found this round)

```
AUDIT_GAPS
Round: <N>
Gaps:
- <gap 1>: <details>
- <gap 2>: <details>
Writing fix spec at <run-root>/phases/audit-fix-<N>.md for a fresh window.
```

### `AUDIT_COMPLETE` (zero gaps — emit before RELAY_RUN_COMPLETE)

```
AUDIT_COMPLETE
Rounds: <N>
Phases re-verified: <count>
Commands re-run clean: <count>
Acceptance criteria: <pass count> pass / <0> fail / <trust count> trust-prior
Deliverables: <present count> present / <0> missing
Spec criteria: <met count> met / <0> not met / <trust count> trust-prior   (omit when no SPEC.md)
Audit coverage: <re_verified> re-verified / <trust> trust-prior (<pct>% re-verified)
Design captures: <retaken — <n> screens | not retaken — <reason>; run: <command>>   (omit when there is no design-capture criterion)
```

### `AUDIT_HANDOFF` (3 audit rounds all failed — stop)

```
AUDIT_HANDOFF
Round: 3
Persistent gaps:
- <gap>
- ...
Three audit rounds attempted; fix specs at <run-root>/phases/audit-fix-{1,2,3}.md
Suggested next move: <one line>
Resume: run `bash <run-root>/resume-line.sh <run-root>` for a ready-to-paste /goal that restarts at the audit.
```

### `AUDIT_FIX` (once per audit-fix window — the only block an audit fix prints)

```
AUDIT_FIX
Round: <N>
Gaps addressed: <fixed> of <total>
Unresolved:
- <gap> — <why>
Evidence: <run-root>/phases/audit-<N>.evidence.md (## Fix)
```

Omit `Unresolved:` when every gap was fixed. The next audit round re-verifies; this block only tells the orchestrator (and the user) the fix window finished.

### `RELAY_RUN_COMPLETE` (once, after AUDIT_COMPLETE)

```
RELAY_RUN_COMPLETE
[⚠ Unresolved: <k> correctness/security finding(s) open, <s> check(s) skipped — see <run-root>/FINDINGS.md]   ← only when record-phase.sh printed it
[⚠ Plan changed: <p> check fix(es) went against the plan summary — see <run-root>/FINDINGS.md]   ← only when record-phase.sh printed it
[⚠ Audit coverage: <re_verified> re-verified, <trust_prior> trust-prior (<pct>% re-verified). Eyeball UI/UX before merging.]   ← only when record-phase.sh printed it
Audit coverage: <re_verified> re-verified, <trust_prior> trust-prior (<pct>% re-verified).   ← as record-phase.sh printed it
All <N> phases complete. Audit passed in <rounds> round(s).
<the one line `relay-git.sh push` printed, verbatim — it starts with "push:">
[Design captures: retaken at the end — compare <run-root>/design-check/<id>.png with design/screens/<id>.png]   ← only when record-phase.sh printed it (or its `⚠ Design captures: may be out of date — …` form)
[Findings: <d> cleanup deferred · <k> correctness/security open · <s> checks skipped[ · <p> plan changes] — <run-root>/FINDINGS.md]   ← only when record-phase.sh printed it
[Checks: skipped (--lean) — <phase reviews, tidy-up, security pass>]   ← only when record-phase.sh printed it
Summary: <5 lines max — what shipped, what changed, what to verify manually; when the push failed or was skipped with a command, that command is one of the manual steps>
```

The `⚠ Unresolved:`, `⚠ Plan changed:`, `Audit coverage:` (and its `⚠` banner), `Design captures:`, `Findings:` and `Checks:` lines are copied verbatim from what `record-phase.sh --audit` printed under its summary line — never recomputed. `<pct>` is the **re-verified** share, rounded down: a run that took nothing on trust reads 100%. The `Checks:` line is information, not a warning: the owner chose `--lean`.

The push line is `push: <branch> → <remote> (<n> commits)`, `push: skipped — <reason>` (`push: skipped — push is off for this run; run: <command>` when the run's `Push:` is off — the default), or `push: failed — <reason>; run: <command>`. A failed push never blocks completion: the run is complete, the owner pushes by hand.

Spec criteria count toward the same coverage fraction as phase criteria and deliverables: a run whose intent was stated in unverifiable terms should read as low coverage, not as a clean bill of health.

`record-phase.sh` prints the coverage banner **only** when trust-prior is more than 30% of total checks. Below 30%, only the plain `Audit coverage:` line appears — same honesty, no false alarm.
