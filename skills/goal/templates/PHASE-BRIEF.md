# Relay brief — {{MODE}}: {{TITLE}}

You are one worker in a Relay run. This brief is your complete manual — `assemble-brief.sh` built it for you, and everything you need is either in it or in a file it names. Read it once, top to bottom, with the Read tool, before touching anything.

| | |
|---|---|
| Run root | `{{RUN_ROOT}}` — the run's artifacts. The project's source is the working directory. |
| Mode | `{{MODE}}` |
<!-- mode: phase fix review review-fix -->
| Phase | {{PHASE_N}} of {{TOTAL}} — {{TITLE}} |
<!-- /mode -->
<!-- mode: audit audit-fix -->
| Audit round | {{ROUND}} of at most 3 |
<!-- /mode -->
| Baseline ref | `{{BASELINE}}` — the working tree is compared against this, not against HEAD |
| Memory dir | `{{MEM_DIR}}` |
| Evidence file | `{{EVIDENCE_PATH}}` |

## 1. Who you are

- You run in a **fresh context window**. The orchestrator (the `/goal` session) dispatched you and is waiting for your report. It cannot see your window; you cannot see the transcript. This brief is the whole handoff.
- **You cannot ask the user anything.** Nobody is watching this window. If the spec leaves a decision open, take the conservative reading, record the assumption in the evidence file, and continue. If you are truly blocked, follow §7 — the orchestrator escalates to the user.
- **A permission denial is an answer.** If a command is denied (for example the auto-mode classifier's `[PII Data Handling]` on real user data), do not retry variants of it. Record the denial as an assumption in the evidence file and proceed on the documented shapes the spec gives you.
- **Never edit `{{RUN_ROOT}}/STATE.md`.** The orchestrator owns it. You write the evidence file, logs under `{{RUN_ROOT}}/logs/`, memory files, and — only where this brief says so — a fix spec or `{{RUN_ROOT}}/FINDINGS.md`.
- **Never print `RELAY_RUN_COMPLETE`.** Never start work that belongs to another phase or to the final audit.
- **Git: `relay-git.sh commit` is the only way your work is committed** (§6 says when). Never run `git commit`, `git push`, `git stash`, `git reset`, `git rebase`, or `git switch` yourself, and never change branch — the run's branch and its history are the orchestrator's record. Read-only git (`status`, `diff`, `log`, `show`) is fine.
- Do not read `{{RUN_ROOT}}/PROTOCOL.md`; that is the orchestrator's manual. This brief is yours.
- **Your window is sized by what you read, not what you write.** In the first end-to-end run, windows peaked at 109k–256k tokens — one phase that changed 2 files peaked at 256k — almost all of it whole-file reads. Follow the context-hygiene rules in §6 from your first command.
- **Leave no background work running.** A background task still running when you report delays the whole run's completion check.

## 2. Your spec

<!-- mode: phase -->
The full work spec for this phase, verbatim from `{{SPEC_PATH}}`. `## Exemplars` names existing files whose patterns you must match — open them before you write anything.

{{SPEC}}
<!-- /mode -->
<!-- mode: fix -->
This is a **fix attempt**. A previous subagent tried this phase twice — one attempt plus one auto-retry — and both failed. It wrote the focused fix spec below. Do exactly what the fix spec says: no scope creep, no unrelated files. The success gate is the **original phase's full acceptance criteria** (reproduced after the fix spec): every criterion must pass, not only the ones that failed. Read the failed attempts in the evidence file first — the `### Failure probe` subsections say what was tried and why it failed.

{{SPEC}}
<!-- /mode -->
<!-- mode: audit -->
This is **audit round {{ROUND}}**. Per-phase VERIFY blocks are self-reports; you re-validate the whole run against the **original** `{{RUN_ROOT}}/ROADMAP.md` using repository ground truth. One round, these steps:

1. Open your report with `AUDIT_START` (round, total phases, criteria count, spec criteria count from §3b, deduplicated mandatory commands to re-run).
2. Read `{{RUN_ROOT}}/ROADMAP.md` and pull every phase's acceptance criteria fresh from the original plan.
3. **Phase completeness:** for each phase 1..{{TOTAL}}, (a) its row in `{{RUN_ROOT}}/STATE.md` is `completed` with an evidence path in its Notes cell, and (b) `{{RUN_ROOT}}/phases/phase-<k>.evidence.md` exists and its last attempt (or fix attempt) records a `Result:` for every acceptance criterion. Either missing = an `AUDIT_GAP`.
4. **Re-run aggregated mandatory commands** once each — the deduplicated union of every phase's mandatory commands — via `bash {{RUN_ROOT}}/run-logged.sh {{RUN_ROOT}}/logs/audit-{{ROUND}}/<cmd-slug>.log '<command>'`. Non-zero exit = an `AUDIT_GAP`.
5. **Spot-check verifiable acceptance criteria** across all phases: "File X exists" / "Function Y exported" / "Config key Z set" / "No `console.log` in app code" → re-check via `ls` / `grep` / `cat`. "Screenshot showed X" / "Manual smoke test passed" / non-deterministic checks → mark `trust-prior-verify`, don't re-run.
5b. **Deliverable check:** for each phase block in `ROADMAP.md`, parse the `**Deliverables:**` bullets. For every bullet naming a file path or glob, run `bash {{RUN_ROOT}}/repo-state.sh deliverable {{BASELINE}} "<path>"`. It compares the complete working tree (committed + staged + unstaged + deleted) against the baseline and detects untracked new files, printing `present — <evidence>` (exit 0) or `missing` (exit 1); an invalid baseline degrades to a filesystem existence check. `missing` → `AUDIT_GAP: phase <N> deliverable "<bullet>" not present in working tree or diff`.
5c. **Spec check (skip only when §3b says there is no `SPEC.md`):** for each success criterion `S<k>` in §3b, re-verify it against repository ground truth using the same split as step 5 — settle it with `ls` / `grep` / `cat` / a command where you can, and mark it `trust-prior-verify` only when it genuinely needs a human eye. Its `Acceptance:` line tells you what check to run. A failing criterion is `AUDIT_GAP: spec criterion <k> "<label>" not met — <what you found>`. Then check the `Prohibitions (must-NOT)` list the same way; a violated prohibition is `AUDIT_GAP: prohibition "<text>" violated — <evidence>`. A spec criterion that no phase appears to have addressed at all is still a gap — report it rather than assuming it was out of scope.
5d. **Everything is committed** (skip when this is not a git repository): `git status --porcelain`. Each phase commits its work, so anything listed is work no commit holds — the run's push would leave it behind. Non-empty = `AUDIT_GAP: uncommitted changes after the last phase — <n> path(s): <first few>`; the fix spec says to commit what belongs to the run and to `.gitignore` or delete what does not (generated files, stray output).
5e. **Findings report** (skip when `{{RUN_ROOT}}/FINDINGS.md` does not exist): it lists what the review, tidy-up and security steps deferred or could not fix, and any check that was skipped. It is **input, not a gap** — do not report its entries as `AUDIT_GAP`s; they are the owner's decisions, and `RELAY_RUN_COMPLETE` points at the file. A deferred entry that makes a criterion or command fail is still that criterion's or command's gap.
6. Write the round's full results to `{{EVIDENCE_PATH}}`: every command's exit code and log path, every criterion's `pass | fail | trust-prior-verify` with evidence, every deliverable's `repo-state.sh` output, and every spec criterion's result. Then add the compact `AUDIT_VERIFY` to your report.
7. **Gaps found, round {{ROUND}} < 3:** add `AUDIT_GAPS` to your report and write `{{RUN_ROOT}}/phases/audit-fix-{{ROUND}}.md` — a focused fix spec listing only the failing commands, criteria, and deliverables, forbidding scope creep, with the affected phases' original criteria as the success gate. **Stop there.** Do not execute the fix; the orchestrator dispatches it to a fresh window and then runs round {{ROUND}}+1.
   **Gaps found, round 3:** add `AUDIT_HANDOFF` instead (full gap history, suggested next move). The orchestrator marks the run `BLOCKED`.
8. **Zero gaps:** compute audit coverage — `re_verified / (re_verified + trust_prior)` as a percentage, where `re_verified` = criteria that passed in step 5, plus deliverables present in step 5b, plus spec criteria settled in step 5c, and `trust_prior` = every criterion marked `trust-prior-verify` in step 5 **or** step 5c — and add `AUDIT_COMPLETE` (rounds, phases re-verified, commands re-run clean, criteria pass / trust-prior counts, spec criteria met, coverage % — the re-verified share, written `(<pct>% re-verified)`). The orchestrator prints `RELAY_RUN_COMPLETE`; you do not.
<!-- /mode -->
<!-- mode: review -->
This is the **correctness review of phase {{PHASE_N}}**. The phase passed its own checks in another window; you are the second pair of eyes that did not write it. Its spec is below: it is what the code had to do, and its acceptance criteria are the gate any fix must keep green.

**What to look for** — only in what phase {{PHASE_N}} changed (`{{DIFF_RANGE}}`):

- **Bugs:** wrong logic, off-by-one, unhandled errors or empty / missing values, a code path the criteria never exercised, races, leaked resources.
- **Unsafe patterns:** unchecked input reaching a query, a shell, a file path or HTML; secrets in code; errors swallowed silently.
- **Wrong abstractions later phases would build on:** a helper that duplicates one that already exists, an interface that leaks its internals, state kept in the wrong layer.

**Not your job:** style, naming, formatting, anything a linter already checks, refactors, and code outside the diff. **Never edit project code** — you read and report; a separate window makes the fixes.

1. Open your report with `REVIEW_START`.
2. List the changed files — `bash {{RUN_ROOT}}/run-logged.sh {{LOG_DIR}}/review-stat.log 'git diff --stat {{DIFF_RANGE}}'` — then review **one file at a time**: `bash {{RUN_ROOT}}/run-logged.sh {{LOG_DIR}}/review-<file-slug>.log 'git diff {{DIFF_RANGE}} -- <file>'`, read that log by range, and open the surrounding code with `grep -n` or Read `offset`/`limit` where the diff alone does not settle it. If the range above says `none — …`, review the files `{{RUN_ROOT}}/phases/phase-{{PHASE_N}}.evidence.md` lists under `### Files changed` instead, and record the missing diff as a limit in the evidence file.
3. **Keep only what you can show.** Confirm each suspected defect — read the caller, trace the input, or run a quick command through `run-logged.sh` — and drop anything you cannot substantiate. A finding names `file:line`, what goes wrong, and when.
4. Write `{{EVIDENCE_PATH}}` (format in §6).
5. **No findings:** `REVIEW_CLEAN`. **Findings:** write `{{RUN_ROOT}}/phases/phase-{{PHASE_N}}.review-fix.md` — one numbered item per finding (`file:line`, the defect, the fix expected), a line forbidding changes outside those items, and phase {{PHASE_N}}'s acceptance criteria and mandatory commands as the gate that must still pass — then `REVIEW_FINDINGS`.
6. **Defer a finding only when fixing it would break a phase criterion or go against the owner's call in the plan (§3b)** — a genuine conflict, never convenience or effort. Leave it out of the fix spec and append it to `{{RUN_ROOT}}/FINDINGS.md` (§6) as `deferred`, with the conflict as the reason (`contradicts the plan: "<the line>"` for a plan line); the owner decides. A fix that changes **relay's call** stays in the fix spec, with a `Changes the plan: "<the line>" (relay's call)` line on its item (§3b).

{{SPEC}}
<!-- /mode -->
<!-- mode: review-fix security-fix -->
This is a **fix window for the findings below**. Fix each numbered item in the fix spec, once — no retry loop, no scope creep, no file the spec does not name. The gate must still pass after your changes.

For each finding, in order:

1. Make the fix.
2. Re-run the gate's commands through `run-logged.sh`, plus whatever check proves the finding is fixed.
3. **Green** → keep it. **Red, and you cannot get it green in this window** → undo that finding's changes (`git restore -- <file>` for a file only this finding touched; otherwise reverse your edit by hand), confirm the gate is green again, and record the finding as unresolved: under `Unresolved:` in your block, and appended to `{{RUN_ROOT}}/FINDINGS.md` (§6) as `unresolved` with why.

An item with a `Changes the plan: "<line>"` line goes against something relay decided while planning. Keeping it is allowed — the fix spec chose it — but the owner must hear about it: when you keep it, append a `[plan]` bullet to `{{RUN_ROOT}}/FINDINGS.md` (§6) quoting that line. When you undo it, record it as unresolved like any other; the plan then stands as written.

Then commit what you kept (§6). An unresolved finding never blocks the run: the run moves on, and `RELAY_RUN_COMPLETE` points the owner at `FINDINGS.md`.

{{SPEC}}
<!-- /mode -->
<!-- mode: security-fix -->

The gate — every phase's mandatory commands, deduplicated:

{{COMMANDS}}
<!-- /mode -->
<!-- mode: cleanup -->
This is the **tidy-up pass**. Every phase is built and committed. Before the audit re-verifies the run, you make the code this run added consistent and lean — **without changing what it does**.

**Scope: only what this run touched** — its changes against `{{BASELINE}}` (`bash {{RUN_ROOT}}/repo-state.sh changed-files {{BASELINE}}`) plus code those changes directly call or are called by. Nothing else, however tempting.

**What to look for** — the defects per-phase windows characteristically produce, because each saw earlier phases only through a map slice:

- a helper, type or constant a later phase re-invented when an earlier phase already wrote it;
- the same job done two ways (error handling, config access, two names for one concept);
- dead code the run added: unused functions, exports, branches, parameters, files;
- a layer that adds nothing (a wrapper that only forwards).

**Fix now only if all five hold** — otherwise defer:

1. it is inside the run's footprint;
2. it changes no public interface, no user-visible behaviour or copy, and nothing a spec criterion names;
3. existing tests or acceptance checks cover it, so the audit can prove behaviour was preserved;
4. it is local — dedupe, delete, collapse, make consistent — not a redesign;
5. it does not go against the owner's call in the plan (§3b). Going against **relay's** call is allowed: make it, and append a `[plan]` bullet to `FINDINGS.md` (§6) quoting the line.

A deferred finding goes to `{{RUN_ROOT}}/FINDINGS.md` (§6) as `[cleanup] … — deferred: <which rule it fails> — next: <suggested move>`. The reason is mandatory.

1. Open your report with `CLEANUP_START`.
2. Run `git status --porcelain` and write down anything already uncommitted: it is not yours, and you never touch or restore it.
3. List the footprint and work **one file at a time**: `bash {{RUN_ROOT}}/run-logged.sh {{LOG_DIR}}/diff-<file-slug>.log 'git diff {{BASELINE}} -- <file>'`, then read the log by range. Never print the whole footprint's diff at once — it is the likeliest thing in the run to fill a window.
4. Apply the fixes that pass all four rules. Then run **every** command below through `run-logged.sh`, and the cleanliness greps (§6).
5. **All green** → commit (§6) and report `CLEANUP_DONE` with `Result: applied` (or `nothing to change`). **Something red you cannot get green** → restore **only the files you changed**, one by one (`git restore -- <file>`; never a whole-tree restore), confirm the commands are green again, defer every finding with the reason `checks could not stay green: <command>`, and report `Result: restored — checks could not stay green`. A tidy-up never blocks the run and never hands off.

The gate — every phase's mandatory commands, deduplicated:

{{COMMANDS}}
<!-- /mode -->
<!-- mode: security -->
This is the **security pass**: one read-only review of everything this run changed, before the audit. Each phase was built in its own window and reviewed alone. You look for what only shows across phases — an input validated in one route and not the next, an auth check a later phase bypassed, a secret one phase logs.

**Scope:** the run's footprint — `bash {{RUN_ROOT}}/repo-state.sh changed-files {{BASELINE}}` — and the code it directly calls. **Never edit project code**; a separate window makes the fixes.

**Checklist** — check every item that applies to this build and record `n/a — <why>` for the rest:

- input handling and injection (SQL / NoSQL queries, shell commands, templates, regexes);
- authentication and authorisation on every new route, action and API, including ones a later phase added;
- secrets: none in code, logs, error messages, client bundles or committed config;
- file paths: user input never selects a path outside the intended directory;
- shell and process execution with user-controlled arguments;
- deserialisation of untrusted data;
- SSRF, XSS and CSRF where the build has web surfaces;
- new dependencies: pinned, from the expected registry, no unexpected install scripts.

1. Open your report with `SECURITY_START` (the surfaces you will check).
2. Work one file at a time, as in §6 — never the whole footprint's diff at once.
3. **Keep only what you can show:** the input, the path it takes, and what it reaches. Drop what you cannot substantiate.
4. Write `{{EVIDENCE_PATH}}` (format in §6).
5. **No findings:** `SECURITY_CLEAN`. **Findings:** write `{{RUN_ROOT}}/phases/security-fix.md` — one numbered item per finding (`file:line`, the flaw, the fix expected), a line forbidding changes outside them, and the commands below as the gate — then `SECURITY_FINDINGS`. Defer a finding to `FINDINGS.md` only when fixing it would break a spec criterion or go against the owner's call in the plan (§3b), with that conflict as the reason (`contradicts the plan: "<the line>"`). A fix that changes **relay's call** stays in the fix spec, with a `Changes the plan: "<the line>" (relay's call)` line on its item — a real flaw is fixed, and the owner is told.

You may run these to confirm a finding; you change nothing:

{{COMMANDS}}
<!-- /mode -->
<!-- mode: audit-fix -->
This is the **fix for audit round {{ROUND}}**. The audit found the gaps listed in the fix spec below. Do exactly what it says — only the failing commands, criteria, and deliverables; no scope creep, no unrelated files. There is no retry loop in this window: do the work once, carefully. The next audit round re-verifies everything, so record honestly what you fixed and what you could not.

{{SPEC}}
<!-- /mode -->

## 3. Carryover from earlier in this run

Memory files earlier phases wrote (distilled invariants, traps hit, confirmed preferences) plus the memories the planner applied. Read them — they are what you cannot recover from the code.

{{CARRYOVER}}

<!-- mode: audit -->
## 3b. The run specification

`SPEC.md`'s success criteria and prohibitions — the agreed statement of intent this run was
planned from. `ROADMAP.md` is what the planner *compiled* from this; checking only the roadmap
means a run can pass every phase it wrote for itself while still not being what was asked for.
Step 5c re-verifies these directly. Do not invent, reinterpret, or soften them, and do not
treat a phase's acceptance criteria as a substitute — they are the compilation, not the source.

{{SPEC_CRITERIA}}
<!-- /mode -->
<!-- mode: review cleanup security -->
## 3b. The plan this run was approved with

`SPEC.md`'s success criteria, prohibitions, scope, constraints and assumptions — what the owner approved before the build. Anything a criterion names is off-limits to a tidy-up (rule 2), and it is exactly what a fix must not break. Check every fix against the rest **before** it goes into a fix spec (in the tidy-up, before you make it): a fix goes against the plan when it does something the plan rules out, or changes something the plan settles — a behaviour, a default, a limit.

Who decided the line decides what happens:

- **Relay's call** — an `Out of scope` bullet ending `(planner)`, and every `Assumptions` bullet. Nobody asked the owner; relay chose while planning. A fix may change it: make the fix, and flag it as a `[plan]` bullet in `FINDINGS.md` so the run's last message says so.
- **The owner's call** — everything else: success criteria, prohibitions, in scope, constraints, and `Out of scope` bullets without `(planner)`. A fix never overrides it: defer the finding with the reason `contradicts the plan: "<the line>"`, and the owner decides.

{{SPEC_PLAN}}
<!-- /mode -->

## 4. Code map

<!-- mode: phase fix review review-fix -->
A precomputed slice of the code graph for this spec's `Map seeds:` — each seed's declaring files, members, what it uses, and what uses it, with `file:line`. Open the files it points at instead of grepping the whole tree. It is already built; do not rebuild it and do not copy it into the evidence file. A seed shown as `no match` just means the planner's name was off — see its `suggestions:`.

{{MAP_SLICE}}
<!-- /mode -->
<!-- mode: audit audit-fix -->
(No code map for audits — you work from `ROADMAP.md`, the evidence files, and the commands.)
<!-- /mode -->
<!-- mode: cleanup security security-fix -->
(No code map — start from the run's footprint, `bash {{RUN_ROOT}}/repo-state.sh changed-files {{BASELINE}}`, and open files by range.)
<!-- /mode -->

## 5. Run state

Excerpt of `{{RUN_ROOT}}/STATE.md` at dispatch time — the latest engineering check results and any failure-log entries relevant to you.

{{STATE_EXCERPT}}

**If the excerpt has a `### Left by an earlier window` section**, an earlier dispatch of this same window was cut short — the session stopped, or the window returned nothing usable — and what it listed is most likely that window's work. Keep and review it; do not start over blind:

- **Uncommitted changes:** check each against your spec. Keep what fits, fix or redo what does not, and finish the job from there. Say in the evidence file what you kept and what you redid.
- **A commit already carrying this window's trailer:** that work passed its checks and was committed before the stop. Verify it against your spec instead of rebuilding it; if everything passes, `relay-git.sh commit` prints "already committed" or commits only what you added — then report as usual.
- **A listed file you cannot account for** — nothing in your spec or the earlier window's evidence explains it — may be the owner's. Leave it untouched and name it in the evidence file; never delete it.

<!-- mode: phase fix -->
## 6. How to work

**Evidence lives on disk; the transcript gets compact markers.** Be exhaustive in the evidence file — there is no size budget there. Your report (§8) carries only the marker blocks.

**Context hygiene.** Everything a tool returns stays in your window until you finish:

- **Read this brief once.** Do not re-open it; `grep` it for a section if you need to check one.
- **Never `cat` a whole source, test, fixture, or doc file.** Use the Read tool with `offset`/`limit`, or `grep -n` for the symbol and then read that range. Start from the code map's `file:line` pointers (§4). Read a whole file only when you are about to rewrite most of it.
- **Planner docs and earlier evidence files:** read only the sections your spec cites — `grep -n '^#'` the file for headings, then read that range. Earlier phases' evidence files: `grep`/`tail` only.
- **Design package (`design/`):** read `HANDOFF.md` by section — the `### <id>` block for the screen you are building, plus `## Design tokens` / `## Components` / `## Copy` when your spec cites them. Open a screen's PNG only while building that screen. Never read `design/source/`: it is the designer's working files, large, and not something to port.
- **Never read `tool-results/` or `tasks/*.output` files.** They hold output too large to show you, and reading them puts that output back in your window. Re-run the command through `run-logged.sh` and `grep` its log instead.
- **Write files with the Write tool, not Bash heredocs, and keep each Bash call to one short step.** A long chained command can hit the 120 s tool timeout and be moved to the background.
- **If a Bash result says the command "was moved to the background",** wait for its completion notification before you report. If it is stuck or no longer needed, stop it with `TaskStop`. Background work still running when you report delays the run's `/goal` completion check.

**Commands.** Run every mandatory command — and any other command whose output is more than a few lines (builds, tests, linters, scripts) — through the logging helper. `ls`, `git status`, and `grep -n` / `sed -n` range reads can run directly:

```bash
bash {{RUN_ROOT}}/run-logged.sh {{RUN_ROOT}}/logs/phase-{{PHASE_N}}/a<attempt>-<cmd-slug>.log '<command>'
```

It writes the full stdout+stderr to the log and prints only the exit code, the log path, and a short tail (3 lines on success, 20 on failure). `<cmd-slug>` is the command lowercased with non-alphanumerics collapsed to `-` (e.g. `pnpm-test`); `<attempt>` starts at 1 and increments on each retry, so failed attempts keep their logs. Open a log beyond its tail only to diagnose a failure.

**Screenshots.** Record their paths in the evidence file (`ls -la` proves they exist). Open an image only when a criterion needs a visual judgment that code, logs, or snapshot-test results cannot answer. Never open an image just to confirm it exists. For a design capture (`design-check/<id>.png`), if this environment cannot take a screenshot of the screen, write `capture unavailable: <id> — <reason>` in the evidence file instead: that passes the criterion. Never mark it `fail` for want of tooling — the comparison with the design is the owner's, after the run.

**Evidence file format** (`{{EVIDENCE_PATH}}`; create it on your first attempt, append on later ones, never rewrite earlier attempts):

```
# Phase <N> evidence — <name>

## Attempt <K> (<ISO timestamp>)

### Mandatory commands
- `<command>` — exit <code> — log: logs/phase-<N>/a<K>-<slug>.log — <summary line, e.g. "Tests: 47 passed, 0 failed">

### Acceptance criteria
#### C1 <criterion text>
Result: pass|fail
Evidence: <command excerpts, file listings, diff snippets, API responses, screenshot paths>

#### C2 <criterion text>
...

### Cleanliness
- debug prints added: <count> — <matched lines, if any>
- session TODO/FIXME added: <count> — <matched lines, if any>
- dead imports added: <count> — <matched lines, if any>

### Files changed
<output of repo-state.sh changed-files>

### Notable diffs
- <file>: <one-line summary>

### Commit
<the line relay-git.sh commit printed>
```

`C<k>` is the k-th bullet under the spec's **Acceptance criteria** section. A retry appends `## Attempt <K+1>`; a fix attempt appends `## Fix attempt (<ISO timestamp>)` with the same subsections; a failure probe appends a `### Failure probe` subsection to the attempt that failed.

**Do the work**, writing the `## Attempt <K>` block as you go. Then **verify**:

1. Run the **cleanliness checks** — `bash {{RUN_ROOT}}/repo-state.sh added-lines {{BASELINE}}` gives the complete set of added/new lines since baseline, **including uncommitted and untracked work**. Grep it for stack-specific debug patterns (`console.log`/`console.error` for JS/TS; `print(`/`pprint(` for Python; `print(`/`dump(` for Swift; `fmt.Println`/`log.Println` for Go), for `TODO`/`FIXME`/`XXX` added this run, and for new imports with no use in the same file. List files changed via `bash {{RUN_ROOT}}/repo-state.sh changed-files {{BASELINE}}`. Record counts, matched lines, the changed-files list, and notable diffs in the evidence file. Any non-zero cleanliness count is treated as a failed criterion (§7) unless the spec declares a `Cleanliness override:` line.
2. Mark every criterion `pass` or `fail` in the evidence file, with its evidence.
3. If everything passes: **commit** — the phase's commit is the verified boundary, so it comes only after every criterion, command and cleanliness count is clean:
   ```bash
   bash {{RUN_ROOT}}/relay-git.sh commit {{RUN_ROOT}} {{PHASE_N}}          # a phase window
   bash {{RUN_ROOT}}/relay-git.sh commit {{RUN_ROOT}} {{PHASE_N}} --fix    # a fix window
   ```
   It stages everything (the run root excluded), commits with the run's trailers, and prints one line — record it under `### Commit`. Exit 0 covers "committed", "already committed" (a re-dispatch of work already committed), "none — no changes" and "skipped (not a git repository)". **Exit 3** means it refused to commit a secret or generated file: add those paths to `.gitignore` (or delete them if they should not exist) and run it again. **Exit 1** means a git hook or commit signing refused the commit, or the commit was stopped after `RELAY_COMMIT_TIMEOUT` (default 300 s — a signing prompt or a hook waiting for input), and nothing was committed: its output says why — fix what the hook reports and run it again; a timeout will not go away on a re-run. **Exit 4** means HEAD is not on the run's branch (the owner switched branch before resuming): do not switch it yourself — that is the owner's fix, and the line names the command. If you cannot get it to exit 0, that is a failure under §7 like any other; put the line in your failure block so the owner sees it.
4. **Memory writeback** (below), then the report (§8).

**Memory writeback.** Ask: did this phase surface anything a future Relay run on a similar task would benefit from knowing? Worth saving: a library API quirk not in the docs; a user preference confirmed by the spec; a project-level fact ("auth lives in `lib/auth/`, not `app/api/auth/`"); a failure pattern plus its fix. Never save secrets, transient task details, or ephemeral state — the bar is "useful to a future run"; when in doubt, skip. If saving: write `{{MEM_DIR}}/<name>.md` (`mkdir -p` the directory if it does not exist yet) with the standard frontmatter —

```
---
name: <short-kebab-case-slug>
description: <one line; used to decide relevance during recall>
metadata:
  type: feedback | project | reference | user
---
<the fact, then **Why:** and **How to apply:** lines>
```

— add a one-line `- [<name>](<name>.md) — <hook>` pointer to `{{MEM_DIR}}/MEMORY.md` (create it if absent), and report `MEMORY_SAVED: <name>` — comma-separated names if you wrote more than one, no other text on the line. Otherwise report `MEMORY_SAVED: none`. **If this is the last phase ({{PHASE_N}} of {{TOTAL}}), always** write a `project_<slug>.md` memory pointing at the new/changed project (repository name, stack, status, ROADMAP path relative to the repository) so future runs start from the latest state. **Name no absolute checkout path** (no folder path under your home directory): every checkout and worktree of the repository shares this memory, and a session that reads a folder path here tends to move into it (on three runs in a worktree, the orchestrator `cd`'d into the main checkout a project memory named); add `relay_run: {{RUN_ROOT}}` under its `metadata:`, so a later planner can tell when the run it points at is gone. General lessons (the other memories) carry no run tag — they stay true after the run's directory is deleted.

## 7. Failure protocol in this window

A failure is any acceptance criterion marked `fail`, any mandatory command with a non-zero exit, a non-zero cleanliness count without an override, or a `relay-git.sh commit` you cannot get to exit 0.

<!-- /mode -->
<!-- mode: phase -->
- **First failure.** Add a `FAILURE_PROBE` block to your report (phase, failed criterion, what was tried, root-cause hypothesis) and append the same as a `### Failure probe` subsection of the failed attempt in the evidence file. Then **retry once** as attempt K+1 — a new `## Attempt` block, new `a<K+1>-…` logs — treating the probe as "the previous attempt failed because …". Do not skip the retry and do not do a third attempt.
- **Second failure (the retry also failed).** Add a `FAILURE_ESCALATE` block (both attempts summarized). Write `{{RUN_ROOT}}/phases/phase-{{PHASE_N}}.fix.md`: a focused fix spec that targets only the failing criteria, forbids scope creep ("do not touch unrelated files"), and ends with this phase's full acceptance criteria as the success gate. Then **stop and report** — do not attempt the fix yourself. The orchestrator dispatches it to a fresh window.
- Never print `FAILURE_HANDOFF` from a phase window.
<!-- /mode -->
<!-- mode: fix -->
- Record your work as a `## Fix attempt (<ISO timestamp>)` block in the evidence file, with the same subsections as an attempt.
- **Fix succeeds** (every original criterion passes, commands exit 0, cleanliness clean): commit (§6 step 3, with `--fix`), memory writeback, then report `RELAY_PHASE_VERIFY`, `MEMORY_SAVED`, `RELAY_PHASE_DONE` exactly as a phase would.
- **Fix fails:** report `FAILURE_HANDOFF` (failing criterion, the three attempts — two from the phase window, one yours — and a suggested next move). One attempt only; there is no retry in a fix window. The orchestrator marks the run `BLOCKED` and hands off to the user.
<!-- /mode -->
<!-- mode: audit -->
## 6. How to work

Every command you re-run goes through `run-logged.sh` (step 4 above) so its output lands in `{{RUN_ROOT}}/logs/audit-{{ROUND}}/`. Open a log beyond its tail only to diagnose a failure. Do not modify the project — an audit changes nothing; the fix window does.

**Context hygiene.** Your window is sized by what you read. Read this brief once. For spot-checks, `grep` evidence files for `Result:` lines and headings instead of opening them whole; check source with `grep -n` or the Read tool with `offset`/`limit`, never a whole-file `cat`; read specs and `ROADMAP.md` by section. Never read `tool-results/` or `tasks/*.output` files — re-run through `run-logged.sh` and `grep` the log. Write the evidence file with the Write tool. If a Bash command is "moved to the background", wait for it or `TaskStop` it before you report. Screenshots referenced by evidence files are `trust-prior-verify` unless a criterion can be settled from code, logs, or snapshot tests.

## 7. Failure protocol

Not applicable — an audit reports gaps, it does not retry. Round 1 or 2 with gaps → `AUDIT_GAPS` + fix spec; round 3 with gaps → `AUDIT_HANDOFF`.
<!-- /mode -->
<!-- mode: audit-fix -->
## 6. How to work

Run every mandatory command you need through `bash {{RUN_ROOT}}/run-logged.sh {{RUN_ROOT}}/logs/audit-{{ROUND}}/fix-<cmd-slug>.log '<command>'`. Context hygiene: read this brief once; read files by range (`grep -n`, Read with `offset`/`limit`), never a whole-file `cat`; never read `tool-results/` or `tasks/*.output`; write files with the Write tool; wait for or `TaskStop` any command "moved to the background" before you report. Record everything you did under a `## Fix` heading in `{{EVIDENCE_PATH}}`: per gap, what changed, the command results, and the criterion's new `Result:`. Cleanliness rules from the phases still apply — run `bash {{RUN_ROOT}}/repo-state.sh added-lines {{BASELINE}}` and grep it for debug prints, TODO/FIXME, and dead imports before you finish. Then commit what you changed — `bash {{RUN_ROOT}}/relay-git.sh commit {{RUN_ROOT}} --audit-fix {{ROUND}}` — and record its line under `## Fix` (exit 3: `.gitignore` or delete the listed files and re-run; exit 1: fix what the hook reports and re-run — a timeout will not clear on a re-run; exit 4: HEAD is off the run's branch, never switch it yourself; anything you cannot resolve goes under `Unresolved:` with the line).

## 7. Failure protocol

None in this window — do the work once. Whatever remains unfixed goes in the `AUDIT_FIX` block's `Gaps addressed:` line; the next audit round decides.
<!-- /mode -->
<!-- mode: review review-fix cleanup security security-fix -->
## 6. How to work

**Context hygiene.** Everything a tool returns stays in your window until you finish. Read this brief once. **Never `cat` a whole file or print a whole diff:** run a diff through `run-logged.sh` into a log and read the log by range; open source with `grep -n` or the Read tool with `offset`/`limit`. Never read `tool-results/` or `tasks/*.output` files. Write files with the Write tool. If a Bash command is "moved to the background", wait for it or `TaskStop` it before you report.

**Commands** go through the logging helper, which prints only the exit code, the log path and a short tail:

```bash
bash {{RUN_ROOT}}/run-logged.sh {{LOG_DIR}}/{{MODE}}-<cmd-slug>.log '<command>'
```

**Evidence file** (`{{EVIDENCE_PATH}}`; create it or append to it — never rewrite what is there):

```
## <Review | Review fix | Cleanup | Security | Security fix> (<ISO timestamp>)

### Scope
<diff range or footprint; the files you reviewed, one per line>

### Findings
#### F1 <file:line> — <one line>
Evidence: <what shows it — the input, the path, the command output>
Outcome: <to fix | fixed | deferred: <reason> | unresolved: <why>>

### Commands
- `<command>` — exit <code> — log: <path>

### Commit
<the line relay-git.sh commit printed, or "none — read-only window">
```

**Findings report** — `{{RUN_ROOT}}/FINDINGS.md`, shared by every check window in this run. If it does not exist, create it with a `# Findings` heading. Append your own section — `## Review — phase <N>`, `## Cleanup` or `## Security` — with one bullet per deferred or unresolved finding:

```
- [<correctness|security|cleanup>] <file:line> — <what> — <deferred|unresolved>: <reason> — next: <suggested move>
- [plan] <file:line> — <what the fix changed> — changed: plan said "<the line, quoted>" — next: keep it, or revert <the fix's commit or file>
```

The reason is mandatory. A fixed finding does not go here — it is in the evidence file and the commit — **except** a fix that changed relay's call in the plan (§3b): that one gets a `[plan]` bullet, written by the window that kept the fix (the fix window, or the tidy-up). A fix window appends under its check's heading (`## Review — phase <N>` or `## Security`).

<!-- /mode -->
<!-- mode: review security -->
**You change nothing.** No edits to project code, no commits, no `git restore`. The only files you write are the evidence file, `FINDINGS.md`, the fix spec and your report.

<!-- /mode -->
<!-- mode: review-fix cleanup security-fix -->
**Cleanliness, then commit.** Run `bash {{RUN_ROOT}}/repo-state.sh added-lines {{BASELINE}}` and grep it for debug prints, `TODO`/`FIXME`, and dead imports, as the phases do — your changes must add none. Then commit what you kept:

```bash
bash {{RUN_ROOT}}/relay-git.sh commit {{RUN_ROOT}} {{PHASE_N}} --review-fix   # a review fix
bash {{RUN_ROOT}}/relay-git.sh commit {{RUN_ROOT}} --cleanup                  # the tidy-up
bash {{RUN_ROOT}}/relay-git.sh commit {{RUN_ROOT}} --security-fix             # a security fix
```

Record the line it prints in the evidence file and on your block's `Commit:` line. Exit 0 covers committed, already committed and none. **Exit 3** (a secret or generated file) → add it to `.gitignore` or delete it, and run again. **Exit 1** (a hook or signing refused it, or it timed out) → fix what the hook reports and run again; if you cannot, undo your changes as for a red gate and record why. **Exit 4** (HEAD is off the run's branch) → never switch it yourself; record the line. None of these hands off.

<!-- /mode -->
<!-- mode: review review-fix cleanup security security-fix -->
## 7. Failure protocol

None — these steps never hand off and never block the run. A finding you cannot fix is undone and written to `FINDINGS.md`; a check that cannot run says so in the evidence file and in its block. Never print `FAILURE_PROBE`, `FAILURE_ESCALATE` or `FAILURE_HANDOFF`, and never `MEMORY_SAVED`.
<!-- /mode -->

## 8. Your report — the last thing you do

**Your final message must contain only the marker blocks below, in order, and nothing else** — no preamble, no summary, no closing remarks. The orchestrator echoes your message verbatim into the parent transcript, where the `/goal` evaluator reads it; anything that is not a marker block is noise there, and a missing block means the run cannot advance.

**First write the report to `{{REPORT_PATH}}`** with the Write tool — exactly the blocks your final message will contain. The orchestrator records the run's state from that file, so the file and your final message must be identical. Then send the final message.

<!-- mode: phase -->
Report contents, in order:

1. `RELAY_PHASE_START` — metadata copied from the spec header.
2. `FAILURE_PROBE` — only if the first attempt failed.
3. Then **one** of:
   - `RELAY_PHASE_VERIFY` + `MEMORY_SAVED` + `RELAY_PHASE_DONE` (success — on the first attempt or the retry), or
   - `FAILURE_ESCALATE` (both attempts failed; fix spec written).
<!-- /mode -->
<!-- mode: fix -->
Report contents, **one** of:

- `RELAY_PHASE_VERIFY` + `MEMORY_SAVED` + `RELAY_PHASE_DONE` (fix succeeded — do not repeat `RELAY_PHASE_START`), or
- `FAILURE_HANDOFF` (fix failed).
<!-- /mode -->
<!-- mode: audit -->
Report contents, in order: `AUDIT_START`, `AUDIT_VERIFY`, then **one** of `AUDIT_COMPLETE`, `AUDIT_GAPS`, or `AUDIT_HANDOFF`.
<!-- /mode -->
<!-- mode: audit-fix -->
Report contents: exactly one `AUDIT_FIX` block.
<!-- /mode -->
<!-- mode: review -->
Report contents, in order: `REVIEW_START`, then **one** of `REVIEW_CLEAN` or `REVIEW_FINDINGS`.
<!-- /mode -->
<!-- mode: review-fix -->
Report contents: exactly one `REVIEW_FIX` block.
<!-- /mode -->
<!-- mode: cleanup -->
Report contents, in order: `CLEANUP_START`, `CLEANUP_DONE`.
<!-- /mode -->
<!-- mode: security -->
Report contents, in order: `SECURITY_START`, then **one** of `SECURITY_CLEAN` or `SECURITY_FINDINGS`.
<!-- /mode -->
<!-- mode: security-fix -->
Report contents: exactly one `SECURITY_FIX` block.
<!-- /mode -->

Block formats (`<run-root>` is `{{RUN_ROOT}}`):

{{MARKERS}}
