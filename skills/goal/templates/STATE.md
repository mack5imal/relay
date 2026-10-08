# State: {{TASK_TITLE}}

**Status:** PLANNING → IN_PROGRESS → COMPLETE    <!-- AWAITING_DESIGN while Stage 2.7 waits for the design package; READY_TO_DISPATCH at Stage 7; BLOCKED after a handoff -->
**Current phase:** —
**Started:** {{DATE}}
**Last update:** {{DATE}}
**Run root:** {{RUN_ROOT}}    <!-- this run's namespaced artifact dir under .relay/ (e.g. .relay/add-dark-mode-Ab3Kx9); isolates concurrent runs in the same working tree -->
**Baseline ref:** {{BASELINE_SHA}}    <!-- HEAD sha captured at Stage 7 dispatch; the audit + cleanliness checks compare the COMPLETE working tree (committed + staged + unstaged + untracked) against it via repo-state.sh -->
**Branch:** {{BRANCH}}    <!-- set at Stage 7 by relay-git.sh branch: "relay/<run-id> (created by relay)", "<name> (yours — relay commits, never pushes)", or "no-git". Each phase, fix and audit fix is committed here; the phase row's Notes carry its sha -->
**Cleanup:** {{CLEANUP}}    <!-- "on" — the tidy-up pass runs after the last phase, before the audit; "off — <reason>" (e.g. "off — --lean"). Missing = off (runs planned before 0.10) -->
**Security pass:** {{SECURITY_PASS}}    <!-- "yes" — the security pass runs after the tidy-up, before the audit; "skip — <reason>" (e.g. "skip — --lean", "skip — docs only"). Missing = skip -->
**Push:** {{PUSH}}    <!-- "on" — relay pushes the run branch it created once after the audit; "off — <reason>" ("off — default", "off — --no-push", "off — RELAY_PUSH=off"): the branch stays local and RELAY_RUN_COMPLETE gives the command. Never the owner's branch. Missing = on (runs planned before 0.11) -->
**Memory dir:** {{MEM_DIR}}    <!-- absolute path detected at Stage 0 by memory-dir.sh (Claude Code keeps one memory dir per git repository, shared by its worktrees and subdirectories: ~/.claude/projects/<main checkout, non-alphanumerics → ->/memory; outside git, the working directory). Phase subagents write memory files here; the brief assembler reads carryover from it. May not exist yet — created on first write -->


## Phase progress

| # | Phase | Status | Started | Completed | Notes |
|---|-------|--------|---------|-----------|-------|
| 1 | {{P1_NAME}} | pending | — | — | — |
| 2 | {{P2_NAME}} | pending | — | — | — |
| ... | ... | pending | — | — | — |
| N | Polish & Harden | pending | — | — | — |

## Engineering check status

Updated by each phase as it runs. Cleared at the start of the next phase, so this always reflects the **most recent** engineering check.

- Build: —
- Typecheck: —
- Lint: —
- Tests: —

## Notable events

Append-only log of anything noteworthy that happened during execution (assumption corrected mid-run, retry, manual intervention, etc.). Each phase writes a line here.

- {{DATE}} — Plan locked, {{N}} phases.
- ...

## Failure log

If a phase hits FAILURE_PROBE, record it here:

- Phase {{N}} ({{NAME}}): {{WHAT_FAILED}} — {{WHAT_WAS_TRIED}} — {{NEXT_MOVE}}

## Carryover

Memory files written this run (the `MEMORY_SAVED: <name>` from each phase, one `- <name>` per line, appended by the orchestrator). `assemble-brief.sh` feeds these files into every later phase's brief so a cold subagent inherits what earlier phases learned.

- (none yet)
