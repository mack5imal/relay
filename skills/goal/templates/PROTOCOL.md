# Relay execution protocol

This file is read by the **orchestrator** — the agent in the single `/goal` session — at the start of the run and followed throughout. It is the operating manual for the autonomous run.

All paths below are rooted at this run's artifact directory (`{{RUN_ROOT}}`) — the concrete namespaced path is baked in when this file is copied at Stage 7, so two runs in the same working tree read and write entirely separate artifacts.

## You are the orchestrator, not the builder

Every phase, every fix, every check (a phase's review, the tidy-up, the security pass) and every audit round runs in its **own subagent with a fresh context window**. Your job is to brief, dispatch, echo, and record — not to read source, run builds, or write code. That is what keeps a run of any size from exhausting this window: you pay roughly one compact report per phase, not the whole build.

The one thing that cannot be delegated: **echo every marker block a subagent returns, verbatim, in your own message text.** A subagent's report reaches you as a hand-back message, not as your own text; the echo is what the user sees, what tools reading this transcript count, and what the `/goal` evaluator's end-state condition is written against. If you summarize, paraphrase, reorder, or skip one, the run's record is wrong and the end-state may never hold.

Run every command from the directory the session started in — the paths above are relative to it. Never `cd` elsewhere; a subagent inherits your working directory, and a run that drifts into the wrong checkout writes its work there. The Bash tool may run zsh: never echo a bare `====` or `----` as a separator (zsh runs it as a command, and the rest of that call is lost — on one run, its `STATE.md` read), and quote any glob you pass as an argument.

Helpers in `{{RUN_ROOT}}/`: `assemble-brief.sh` and `PHASE-BRIEF.md` (yours — they build each subagent's manual), `record-phase.sh` (yours — it validates a report file and applies every `STATE.md` change), `recover.sh` (yours — after an interruption; see that section), `resume-line.sh` (yours — read-only; only after a handoff; it also warns when the tree holds uncommitted work or HEAD is off the run's branch — pass its output on as it is), `relay-git.sh` (the subagents commit their work with it; you only run its `push`, once, after the audit — whatever `Push:` says; it decides), `MARKERS.md` (the exact block formats), and `run-logged.sh` / `repo-state.sh` / `build-graph.sh` / `map-slice.sh` / `map-slice.py` (the subagents' tools; you never call them). Do not read a brief or a report file — they are written for the subagent and the script, and reading them here spends the context the design is saving.

## The loop

Repeat until `RELAY_RUN_COMPLETE` is printed:

1. Read `{{RUN_ROOT}}/STATE.md` once at the start of the run. Find `Current phase: N` and the total phase count. A resumed run can start elsewhere: `review N`, `cleanup` or `security` → start at that step in "Checks" below; `audit` → the Final audit. After that, `record-phase.sh`'s summary line tells you what is next — do not re-read `STATE.md` each phase. **If `{{RUN_ROOT}}/phases/in-flight` exists when you start** (a run resumed from a resume line, after a stop), run `bash {{RUN_ROOT}}/recover.sh {{RUN_ROOT}}` first and follow it, as in "After an interruption" — it settles the window that was cut short.
2. **Assemble the brief** — one line of output, nothing to read:
   ```bash
   bash {{RUN_ROOT}}/assemble-brief.sh {{RUN_ROOT}} N
   ```
   It writes `{{RUN_ROOT}}/phases/phase-N.brief.md`: the spec, the executor contract, carryover memory (in full from the phases this one depends on, the rest as a one-line index), a precomputed code-map slice, the run-state excerpt, and the block formats. If it exits non-zero, its message names the missing file — fix that (usually a spec the planner did not write) and re-run; do not hand-write a brief.
3. **Dispatch.** Call the `Agent` tool with `subagent_type: general-purpose`, `description: "Relay phase N"`, and this prompt, with the real path substituted:

   > Read `{{RUN_ROOT}}/phases/phase-N.brief.md` and follow it exactly. Open it with the Read tool, not `cat` — it is longer than a Bash result can show. It is your complete manual for this window. Your final message must contain only the marker blocks it specifies, in order, and nothing else.

   **Dispatch is asynchronous.** The tool result only confirms the subagent launched — it is not the report. End your turn with one line (`Phase N dispatched; waiting.`). Do not do the phase's work yourself, do not start the next phase, and see "While a subagent runs" for what arrives in the meantime.
4. **The report arrives** later as a message wrapped in `<agent-message from="…">` with a `[Subagent hand-back]` preamble; the harness indents every line of the report by two spaces. **Validate it**: it must contain `RELAY_PHASE_START` and exactly one of `RELAY_PHASE_DONE` or `FAILURE_ESCALATE` (a `FAILURE_PROBE` in between is normal — it means the retry ran). Anything else — empty, an error, prose without blocks — is a **no-report** (see below), with one exception: a hand-back that is an **API error, a usage limit or a rate limit** (the window was cut short from outside, not by its own work) is an interruption. Record it with `bash {{RUN_ROOT}}/record-phase.sh {{RUN_ROOT}} N --interrupted "<the error, one line>"` (or the dispatch's own mode) — never a strike — and re-dispatch once the session can run again, exactly as "After an interruption" below says for a re-dispatch.
5. **Echo first — before any tool call, in your reply to the hand-back.** Your reply's text is the report verbatim: everything from the first marker line to the end of the last block, with the harness's two-space indent removed. Add nothing after the last block; drop any prose outside the blocks; do not reformat or wrap in a code fence. If you want a status line, it goes in a later turn — never between or after the blocks.
6. **Record** — in the same reply, after the echo:
   ```bash
   bash {{RUN_ROOT}}/record-phase.sh {{RUN_ROOT}} N
   ```
   It reads `{{RUN_ROOT}}/phases/phase-N.report.md` (the subagent writes it before handing back), validates it, and updates `STATE.md` — phase row (with the commit sha it finds in git), `Status`, `Current phase`, engineering lines, a `Notable events` line, the `## Failure log` line on escalation, and each `MEMORY_SAVED` name under `## Carryover` (how later briefs inherit what this phase learned). Pass `--note "<short text>"` to add context to the event line. It prints one summary line ending `→ next: …`, `→ blocked`, or `→ complete — next: relay-git.sh push, then RELAY_RUN_COMPLETE`. Exit codes:
   - `0` — recorded; follow the summary.
   - `1` with `report not found` — the subagent handed back a valid report but did not write the file. Write the hand-back text you just echoed to the path it names with the Write tool, then run the command again.
   - `3` — the report file is invalid: treat the dispatch as a **no-report**.
7. **Branch:**
   - `RELAY_PHASE_DONE` → step 8.
   - `FAILURE_ESCALATE` → the phase subagent wrote `{{RUN_ROOT}}/phases/phase-N.fix.md`. Assemble and dispatch the fix in a **fresh** window:
     ```bash
     bash {{RUN_ROOT}}/assemble-brief.sh {{RUN_ROOT}} N --fix
     ```
     Dispatch as in step 3 with `description: "Relay phase N fix"` and the path `{{RUN_ROOT}}/phases/phase-N.fix.brief.md`. The fix report must contain exactly one of `RELAY_PHASE_DONE` (with `RELAY_PHASE_VERIFY` and `MEMORY_SAVED` before it) or `FAILURE_HANDOFF`. Echo it, then record with `bash {{RUN_ROOT}}/record-phase.sh {{RUN_ROOT}} N --fix`. `RELAY_PHASE_DONE` → step 8. `FAILURE_HANDOFF` → the script sets `Status: BLOCKED`; **stop**. The `/goal` condition will not be satisfied; the user takes the wheel.
8. **User-interrupt check.** If a user message has arrived since the last turn, pause here — see "Mid-run interruption".
9. **Follow the summary's `next:`** — it is the only routing you need:
   - `next: phase K` → back to step 2 for phase K.
   - `next: review N`, `next: cleanup` or `next: security` → run that step as in **Checks** below.
   - `next: audit` → do **not** print `RELAY_RUN_COMPLETE` yet. Run the **Final audit** below.

   Never run a check the summary did not name, and never skip one it did: whether a phase is reviewed, and whether the tidy-up and security pass run, was decided at planning time (the spec's `Review:` line, `STATE.md`'s `Cleanup:` and `Security pass:`), and `record-phase.sh` reads those for you.

### Checks — a phase's review, the tidy-up, the security pass

Each is one subagent, dispatched exactly like a phase (steps 2–6: assemble, dispatch, end your turn, echo the hand-back first, then record). Use the row for the summary's `next:`:

| `next:` | Assemble | `description` | Brief | Record |
|---|---|---|---|---|
| `review N` | `assemble-brief.sh {{RUN_ROOT}} N --review` | `Relay phase N review` | `phases/phase-N.review.brief.md` | `record-phase.sh {{RUN_ROOT}} N --review` |
| `review fix N` | `assemble-brief.sh {{RUN_ROOT}} N --review-fix` | `Relay phase N review fix` | `phases/phase-N.review-fix.brief.md` | `record-phase.sh {{RUN_ROOT}} N --review-fix` |
| `cleanup` | `assemble-brief.sh {{RUN_ROOT}} --cleanup` | `Relay cleanup` | `phases/cleanup.brief.md` | `record-phase.sh {{RUN_ROOT}} --cleanup` |
| `security` | `assemble-brief.sh {{RUN_ROOT}} --security` | `Relay security pass` | `phases/security.brief.md` | `record-phase.sh {{RUN_ROOT}} --security` |
| `security fix` | `assemble-brief.sh {{RUN_ROOT}} --security-fix` | `Relay security fix` | `phases/security-fix.brief.md` | `record-phase.sh {{RUN_ROOT}} --security-fix` |

(Every script lives in `{{RUN_ROOT}}/`; prefix each with `bash {{RUN_ROOT}}/`, and the brief path with `{{RUN_ROOT}}/`.) **Validate** the hand-back: a review has `REVIEW_START` and exactly one of `REVIEW_CLEAN` / `REVIEW_FINDINGS`; a review fix one `REVIEW_FIX`; a tidy-up `CLEANUP_START` and one `CLEANUP_DONE`; a security pass `SECURITY_START` and exactly one of `SECURITY_CLEAN` / `SECURITY_FINDINGS`; a security fix one `SECURITY_FIX`. Anything else is a no-report. Then echo, record, and follow the new summary's `next:` — `REVIEW_FINDINGS` routes to `review fix N`, `SECURITY_FINDINGS` to `security fix`, everything else to the next phase or step.

**These steps never hand off and never block the run.** A finding the fix window could not fix was undone and written to `{{RUN_ROOT}}/FINDINGS.md`; a check whose dispatch returns no report twice is skipped (`record-phase.sh` says `→ skipped — next: …`). Either way, follow the summary and carry on. Never print `FAILURE_HANDOFF` for a check, and never re-dispatch one the summary has moved past.

### While a subagent runs

Between dispatch and hand-back, three kinds of message can arrive. None of them is the report, and none needs more than one line from you:

- **`<task-notification>` … `Agent "Relay …" finished`** — the harness noting a subagent stopped. Its report comes (or came) as the hand-back; this notice may arrive late or more than once. Reply in one line (`Phase N already recorded.` or `Waiting on the phase N hand-back.`) with no tool calls.
- **Goal check-in — "background work still running"**, listing tasks as `<id> · subagent · …` or `<id> · shell · …`:
  - If it lists a **subagent**, reply in one line (`Phase N subagent still running; waiting.`) with **no tool calls** — even if shell tasks are listed too. A shell task may be the running subagent's own long test run.
  - If it lists **only shell tasks**, no subagent is running, so they are orphans a finished subagent left behind — and while they are listed, the `/goal` evaluator defers its check. Stop each with `TaskStop <id>`, then continue the loop. `TaskStop` echoes the whole original command back into your window; that is the accepted cost of an orphan. Never `TaskStop` a subagent.
- The check-in suggests reading the tasks' output. **Do not.** A subagent's `tasks/<id>.output` file is its entire transcript, and files under `tool-results/` are output too large to show — reading either pulls a whole window's worth of tokens into yours.

**Check-ins can stop.** After a stretch with nothing new, Claude Code may say idle check-ins are paused until the next message. From then on only a hand-back (or a `finished` notification) wakes you — so a subagent that hangs without finishing leaves the run silent, and nothing on your side notices. That is expected, not something to work around: the owner's next message wakes the run, and a turn that starts while you are waiting on a hand-back goes through `recover.sh` first ("After an interruption"), which says whether the window is still running.

### No-report dispatches

A dispatch that returns without the required blocks — the subagent ran out of context, hit a tool error, or ended with prose — is not a phase failure; it is a dispatch failure, and the 3-strike protocol does not apply. Record it:

```bash
bash {{RUN_ROOT}}/record-phase.sh {{RUN_ROOT}} N --no-report "<one-line reason>"
```

(`N --fix`, `--audit R`, `--audit-fix R`, or a check's mode from the table above, for the other dispatch kinds.) The first time for a dispatch target, the summary says `→ next: re-dispatch`: **re-dispatch once** with a freshly assembled brief (its run-state excerpt now carries the failure-log line, so the new window knows). The second time for a **check**, the summary says `→ skipped — next: …`: the step is skipped and noted in `FINDINGS.md`; follow the `next:`. The second time for anything else, the script sets `Status: BLOCKED` and says `→ blocked`: print `FAILURE_HANDOFF` yourself (format in `MARKERS.md`; the three attempts become "dispatch 1: no report", "dispatch 2: no report", and a suggested next move) and stop. An audit or audit-fix dispatch that is blocked this way ends in `AUDIT_HANDOFF` instead.

### After a handoff, the goal condition stays unmet

`FAILURE_HANDOFF` and `AUDIT_HANDOFF` make the `/goal` end-state unsatisfiable for this run: the condition forbids them, and a printed block cannot be retracted. So the evaluator will keep re-prompting you after you stop. Answer each re-prompt in one line — the run is blocked, `STATE.md` says so, the user has the wheel — and stop again. **Never print `RELAY_PHASE_DONE`, `AUDIT_COMPLETE`, or `RELAY_RUN_COMPLETE` to satisfy the evaluator**, and never re-dispatch work you have already handed off. The user clears the goal.

**Print the resume line once, in the same turn as the handoff block**, so the work already done is not lost:

```bash
bash {{RUN_ROOT}}/resume-line.sh {{RUN_ROOT}}
```

It reads `STATE.md` and prints a ready-to-paste `/goal` scoped to the phases that remain — the completed ones stay recorded and are not re-run. It changes nothing on disk. Print its output after the handoff block and then stop; do not paste or act on the line yourself, and do not re-run it on each evaluator re-prompt.

### If the `Agent` tool is unavailable

If the tool is missing from your tool list or the call is denied, assemble the brief anyway, then read it and execute it yourself in this window under the same contract — including writing the report file and printing the same marker blocks, in the same order, as your report. Continue the loop (record, branch) as if the report had been handed back by a subagent. This costs the context isolation, not the correctness; it is a degraded mode, not the design.

## Final audit (runs after the last phase, before completion)

Per-phase VERIFY blocks are self-reports. The audit closes that loophole by re-validating against the **original** `ROADMAP.md` — and, when the run has one, against `SPEC.md`'s success criteria, so a run is checked against what was asked for and not only against the plan compiled from it — using repository ground truth. Each round runs in its own window; the audit procedure itself is in the audit brief (built from `PHASE-BRIEF.md`), not here.

For round R = 1, 2, 3:

1. **Assemble and dispatch the audit round.**
   ```bash
   bash {{RUN_ROOT}}/assemble-brief.sh {{RUN_ROOT}} --audit R
   ```
   Dispatch as in loop step 3 with `description: "Relay audit round R"` and the path `{{RUN_ROOT}}/phases/audit-R.brief.md`. End your turn; the report arrives as a hand-back.
2. **Validate.** The report must contain `AUDIT_START`, `AUDIT_VERIFY`, and exactly one of `AUDIT_COMPLETE`, `AUDIT_GAPS`, or `AUDIT_HANDOFF`. Otherwise: no-report handling.
3. **Echo the report verbatim**, first, exactly as in loop step 5.
4. **Record**: `bash {{RUN_ROOT}}/record-phase.sh {{RUN_ROOT}} --audit R` (exit codes as in loop step 6). It writes the round's event line and sets `Status: COMPLETE` on `AUDIT_COMPLETE` or `Status: BLOCKED` on `AUDIT_HANDOFF`.
5. **Branch:**
   - `AUDIT_COMPLETE` → **push** the run branch once:
     ```bash
     bash {{RUN_ROOT}}/relay-git.sh push {{RUN_ROOT}}
     ```
     It pushes only a branch Relay created, and only when `STATE.md` says `Push: on` (never yours, never with force), and prints one line — `push: …`, `push: skipped — …` (with `Push:` off: `push: skipped — push is off for this run; run: <command>`), or `push: failed — …; run: <command>`. Run it either way: with push off its line is how the owner gets the command. It always exits 0. **A failed push never stops the run:** do not retry it, diagnose it, or push another way — the line goes into `RELAY_RUN_COMPLETE` and the owner pushes by hand. Then get the summary material with `awk '/^## Notable events/{f=1; print; next} f && /^## /{exit} f' {{RUN_ROOT}}/STATE.md` — the whole events section and nothing after it (not a full read; a fixed line count cut a 19-phase run's events off at phase 12), then print `RELAY_RUN_COMPLETE` (format in `MARKERS.md`): the `Audit coverage:` line `record-phase.sh --audit` printed — with the `⚠ Audit coverage:` banner above it when it printed one; never compute either yourself — then `All <N> phases complete. Audit passed in <R> round(s).`, the push line (the push output verbatim — it starts with `push:`; add no `Push:` label), and a summary of at most 5 lines drawn from those events (what shipped, what changed, what to verify manually). **Copy the lines `record-phase.sh --audit` printed under its summary line**, verbatim: a `⚠ Unresolved: …` line and then a `⚠ Plan changed: …` line go first in the block (before the coverage lines); a `Design captures: …` line (or `⚠ Design captures: …`), `Findings: …` and `Checks: skipped (--lean) — …` go after the push line, in that order. When the design captures line is there, the summary's "what to verify manually" points at it instead of naming the screenshots itself. When it printed none of them, there are none. The `/goal` condition is satisfied at that point. **Stop.** If a goal check-in then lists only shell tasks, stop them as in "While a subagent runs" — they would otherwise hold the evaluator's check.
   - `AUDIT_GAPS` → the audit subagent wrote `{{RUN_ROOT}}/phases/audit-fix-R.md`. Dispatch the fix in a fresh window:
     ```bash
     bash {{RUN_ROOT}}/assemble-brief.sh {{RUN_ROOT}} --audit-fix R
     ```
     `description: "Relay audit fix R"`, path `{{RUN_ROOT}}/phases/audit-fix-R.brief.md`. Its report is exactly one `AUDIT_FIX` block; echo it, record with `bash {{RUN_ROOT}}/record-phase.sh {{RUN_ROOT}} --audit-fix R`, and start round R+1. Whether the fix worked is the next round's job, not yours.
   - `AUDIT_HANDOFF` → **stop**. Do **not** print `RELAY_RUN_COMPLETE`.

The audit subagent decides between `AUDIT_GAPS` and `AUDIT_HANDOFF` from its round number (round 3 with gaps → handoff), so you never dispatch a fourth round.

## After an interruption

The session can stop under you — a crash, a closed terminal, a restart — and be reopened with `claude --resume`. The goal comes back; the subagent you were waiting on does not: it died with the old process, and its hand-back will never arrive.

**Whenever a turn starts while you are waiting on a hand-back, and its message is not that hand-back, a `finished` `<task-notification>` or a goal check-in** — the user typed `continue` after reopening, Claude Code's notice that a `Relay …` agent "didn't finish before the previous session ended" (`<status>stopped</status>`), or anything else — run this first, before any other tool call:

```bash
bash {{RUN_ROOT}}/recover.sh {{RUN_ROOT}}
```

It compares the Claude process that dispatched the window with the one running now, settles the dispatch, and prints what to do:

- **Exit 4 — still in flight:** the subagent is working, or its hand-back is on its way. Do not re-dispatch — a second window would edit the same files. Carry on as in "Mid-run interruption" below.
- **Exit 5 — it cannot tell:** ask the user whether the session was restarted since the dispatch, and do as the output says.
- **Exit 0, a report printed:** the window finished before the stop but was never recorded. Echo its blocks verbatim — unless your last message before the stop already shows them — then run the `record-phase.sh` command it names and follow its `next:`.
- **Exit 0, "cut short":** it has already recorded the dispatch as interrupted. Re-dispatch with the `assemble-brief.sh` command and the description it names, as in loop step 3 (or the step for that dispatch kind); the new brief lists what the earlier window left.
- **Exit 0, "nothing was in flight":** continue from the last `next:` `record-phase.sh` printed.

Never re-dispatch a window on your own judgement that it "must have died" — only on `recover.sh`'s word. **Never revive a stopped Relay agent with `SendMessage`**, even though Claude Code's notice suggests it: `recover.sh` has already recorded it and the re-dispatch replaces it, so a revived old window would build the same phase alongside the new one. If `recover.sh` is missing (a run planned before 0.11), ask the user whether the session was restarted, and re-dispatch only if they say so.

## Mid-run interruption

If the user sends any message during the run (after "After an interruption" above has said the dispatch is still in flight, when you were waiting on one):
- Pause at the next phase boundary — after you have echoed and recorded the current report, before assembling the next brief. Never interrupt a dispatched subagent.
- Address the message.
- Ask whether to resume, revise the next phase spec, or stop.

## What the subagents own

You never write these (except a report file in the `report not found` fallback); you only read `record-phase.sh`'s summary line and the hand-backs:

- **Report files** — `{{RUN_ROOT}}/phases/phase-N.report.md`, `phase-N.fix.report.md`, `phase-N.review.report.md`, `phase-N.review-fix.report.md`, `cleanup.report.md`, `security.report.md`, `security-fix.report.md`, `audit-R.report.md`, `audit-fix-R.report.md`: the exact text of each hand-back, which `record-phase.sh` reads.
- **Evidence files** — `{{RUN_ROOT}}/phases/phase-N.evidence.md` per phase (attempts, fix attempts, per-criterion results, cleanliness matches, changed files) and `{{RUN_ROOT}}/phases/audit-R.evidence.md` per audit round. Format: `PHASE-BRIEF.md` §6.
- **Command logs** — `{{RUN_ROOT}}/logs/phase-N/` and `{{RUN_ROOT}}/logs/audit-R/`, written by `run-logged.sh`.
- **Memory files** — under the `Memory dir:` named in `STATE.md`, per the writeback rules in `PHASE-BRIEF.md` §6. `record-phase.sh` appends each `MEMORY_SAVED` name to `## Carryover` with the phase that wrote it (`- <name> (phase N)`).
- **Fix specs** — `phase-N.fix.md` (from a phase window on its second failure), `phase-N.review-fix.md` and `security-fix.md` (from a review or security window with findings), and `audit-fix-R.md` (from an audit window with gaps).
- **`FINDINGS.md`** — what the review, tidy-up and security windows deferred or could not fix (`record-phase.sh` adds a line for a skipped check). You never read it during the run; `RELAY_RUN_COMPLETE` points the owner at it.
- **Commits** — each phase, fix, review-fix, tidy-up, security-fix and audit-fix window commits its own work with `relay-git.sh commit` once it passes; `record-phase.sh` finds the sha in git and records it. **Never run `git commit`, `git add`, `git stash`, or a branch change yourself**, not even to tidy up after a subagent: uncommitted work at the end is the audit's gap to report and an audit-fix window's to commit. A handed-off run's partial work stays uncommitted for the user.

## Required transcript blocks

Formats: `{{RUN_ROOT}}/MARKERS.md`. Which you **author** yourself: `RELAY_RUN_COMPLETE`, and `FAILURE_HANDOFF` / `AUDIT_HANDOFF` only in the no-report case. Everything else — `RELAY_PHASE_START` / `RELAY_PHASE_VERIFY` / `MEMORY_SAVED` / `RELAY_PHASE_DONE`, `FAILURE_PROBE` / `FAILURE_ESCALATE` / `FAILURE_HANDOFF`, `REVIEW_START` / `REVIEW_CLEAN` / `REVIEW_FINDINGS` / `REVIEW_FIX`, `CLEANUP_START` / `CLEANUP_DONE`, `SECURITY_START` / `SECURITY_CLEAN` / `SECURITY_FINDINGS` / `SECURITY_FIX`, `AUDIT_START` / `AUDIT_VERIFY` / `AUDIT_GAPS` / `AUDIT_COMPLETE` / `AUDIT_HANDOFF`, `AUDIT_FIX` — you **echo** from subagent reports, verbatim.

The `/goal` end-state — `RELAY_RUN_COMPLETE` preceded by `AUDIT_COMPLETE` and one `RELAY_PHASE_DONE` per phase, with no `FAILURE_HANDOFF` or `AUDIT_HANDOFF` — is met by those echoes plus your final block.
