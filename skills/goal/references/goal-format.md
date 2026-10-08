# `/goal` format reference

## What `/goal` actually is

`/goal <end-state condition>` is a built-in Claude Code slash command. It is **not** a task description. It is a **measurable end-state condition** that a fast evaluator checks against the transcript after each agent turn. The agent keeps working — running tools, editing files — until the condition holds, at which point control returns to the user.

Key implications:

1. **Condition is short.** A long task body in the `/goal` argument is the wrong shape. Long content belongs in files the agent reads from disk.
2. **The evaluator only sees the transcript.** Conditions must be phrased so the agent's own output can prove them ("X printed", "Y exit code surfaced", "Z file count reported"). The evaluator does not independently run tools or read files.
3. **Evaluator behaviour:** a small fast model (Haiku) checks the condition each turn; "no" → continue with the reason as guidance; "yes" → clear goal, return control.

## Relay's single-`/goal` shape

Relay uses **one** `/goal` per run, dispatched by the **user** at the end of Stage 7. Slash commands fire only from user input — the planner cannot fire `/goal` from its own message text. Stage 7's job is to write all phase specs to disk, then print a copy-paste-ready `/goal` block. The user pastes once; from there, the run is autonomous.

The condition is (`<run-root>` is this run's namespaced artifact dir, e.g. `.relay/add-dark-mode-Ab3Kx9`; the planner substitutes the concrete path before printing the block so the pasted line carries the real directory — never the placeholder):

```
Working from this directory (never cd elsewhere), execute all
phases of <run-root>/ROADMAP.md sequentially, following
<run-root>/PROTOCOL.md: for each phase, assemble its brief and dispatch
it to a subagent, then echo the subagent's marker blocks
(RELAY_PHASE_VERIFY then RELAY_PHASE_DONE) verbatim into this
transcript; follow PROTOCOL.md's failure-recovery protocol if any
criterion fails. Run the review, cleanup and security steps
PROTOCOL.md names whenever record-phase.sh routes to them, echoing
their blocks verbatim. After the last phase and its checks, run the
FINAL AUDIT in
<run-root>/PROTOCOL.md (re-verify against <run-root>/ROADMAP.md and
<run-root>/SPEC.md; re-run aggregated mandatory commands; spot-check
criteria; on gaps, write <run-root>/phases/audit-fix-<round>.md and
dispatch it to a fresh subagent). Only after AUDIT_COMPLETE, print
RELAY_RUN_COMPLETE.

Done when RELAY_RUN_COMPLETE appears in the transcript with
one RELAY_PHASE_DONE per phase, AUDIT_COMPLETE printed before
RELAY_RUN_COMPLETE, and no FAILURE_HANDOFF or AUDIT_HANDOFF
this run.
```

The opening clause keeps the orchestrator where the session started. It rides in the line itself because the orchestrator's first command runs before it reads `PROTOCOL.md` (which says the same): on three runs, that first command `cd`'d from the worktree into the main checkout — the folder a shared project memory named — and a subagent inherits the orchestrator's directory. `tools/check-run.py` fails a run whose orchestrator changes directory.

`SPEC.md` is named alongside `ROADMAP.md` because the audit checks the run against the agreed statement of intent, not only against the phase plan compiled from it. It is optional — runs planned before 0.9 have none, and the audit degrades to the roadmap alone.

The review, cleanup and security steps are named in the instruction, not in the end-state: `record-phase.sh` routes the run into each one, `tools/check-run.py` fails a run that skipped one, and none of them can hand off — so the `Done when` clause is the same whether a run has every check or none (`--lean`).

There is no per-phase `/goal` dispatch and no inter-session chain — once active, a single `/goal` session reads PROTOCOL.md and orchestrates: one subagent per phase, per fix, and per audit round, each briefed from disk; it completes only when the audit is clean.

## Required transcript blocks (Relay-specific)

The phase specs, briefs, and PROTOCOL.md require named blocks in the transcript — `RELAY_PHASE_START` / `RELAY_PHASE_VERIFY` / `MEMORY_SAVED` / `RELAY_PHASE_DONE` per phase, `FAILURE_PROBE` / `FAILURE_ESCALATE` / `FAILURE_HANDOFF` for recovery, `REVIEW_START` / `REVIEW_CLEAN` / `REVIEW_FINDINGS` / `REVIEW_FIX`, `CLEANUP_START` / `CLEANUP_DONE` and `SECURITY_START` / `SECURITY_CLEAN` / `SECURITY_FINDINGS` / `SECURITY_FIX` for the checks, `AUDIT_START` / `AUDIT_VERIFY` / `AUDIT_GAPS` / `AUDIT_COMPLETE` / `AUDIT_HANDOFF` for the final audit, and `RELAY_RUN_COMPLETE` once. They are what the human-readable evaluator (you, watching) AND the host evaluator both rely on.

**The exact formats live in `templates/MARKERS.md`**, which Stage 7 copies to `<run-root>/MARKERS.md` so the run can read them (`references/` is never copied into a run). Keep the formats there, in one place.

**Who prints them.** Each phase runs in its own subagent, whose own window the evaluator never sees. Dispatch is asynchronous: the subagent's final report reaches the orchestrator later as a hand-back message (`<agent-message …>`, lines indented by the harness), not as the orchestrator's own text. So each subagent's final report *is* its marker blocks, and the orchestrator echoes them verbatim — first, before recording anything — into its own message text. The end-state condition is written against those echoes. In the first end-to-end run the evaluator released even though one phase's echo was skipped (it evidently read the hand-back too), but that is not a guarantee to build on, and a skipped echo still hides the phase from the user and from any tool reading the transcript.

**Background work defers the evaluator.** While a subagent or a background shell task is running, the evaluator postpones its check and sends a "Goal check-in: background work still running" notice listing the tasks. A shell task orphaned by a finished subagent keeps that deferral in place indefinitely — `PROTOCOL.md` has the orchestrator stop orphans, and the brief has subagents leave none behind.

Evidence and command output do **not** go in these blocks. They are recorded on disk — per-phase proof in `<run-root>/phases/phase-N.evidence.md`, audit proof in `<run-root>/phases/audit-<round>.evidence.md`, and full command output in `<run-root>/logs/` via `run-logged.sh`. The evidence file format is defined in `templates/PHASE-BRIEF.md` §6.

## Anti-patterns

- **Don't stuff long task content into the `/goal` argument.** Use a short condition; put work in files.
- **Don't make conditions the evaluator can't verify from the transcript.** "Tests pass" is wrong (evaluator can't run tests); "`RELAY_PHASE_DONE` printed for all phases" is right.
- **Don't chain `/goal` commands across sessions.** One run = one `/goal`. The agent loops internally inside that session.
- **Don't put evidence in the transcript.** Be exhaustive in the evidence file (no size budget) and keep marker blocks compact. Run commands through `run-logged.sh` so their output never floods the context window.
