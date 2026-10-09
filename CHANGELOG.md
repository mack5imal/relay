# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased] (relay)

### Added

- **Relay offers to set up git.** In a folder that isn't a repository, the first planning
  question offers to create one and save the files already there as the starting point.
  Secrets and generated folders are left out and added to `.gitignore`. Without git, relay
  used to run on silently with no commits and weaker checks.
- **Relay offers a remote when push is on and there is none** — a private GitHub repo through
  `gh` (never public), an existing one, adding it yourself, or push off. With several remotes
  and none named `origin`, you pick one (`Push: on — to <remote>`). Connecting a remote never
  pushes; pre-flight warns when push is on and no remote has been added yet. Before, this was
  only found at the end of an unattended run.

### Fixed

- **The planner asks before changing what you settled.** After the interview, a change to
  anything you answered, a constraint, a prohibition or an outward-facing target (where and as
  whom something deploys, a remote, anything pushed) is a question — "you said X; I found Y; I
  propose Z" — never an assumption or a quiet spec edit, and the plan summary lists every such
  change. On the tunez run the planner moved the deploy from the personal scope chosen in the
  interview to a team scope with five live projects, loosened a licence constraint, and pushed
  the owner's `main` when asked for a repo.
- **Every question is in plain language.** Each question leads with what you will see, get or
  risk under each answer, then a recommendation; method names and statistics terms come after,
  if at all. "Edges" are explained wherever they appear ("unusual situations around each goal
  that the final check only tests if they're written down") and named as situations. Several
  tunez questions needed a lookup to answer.
- **Subagent briefs no longer grow with every memory the run saves.** Each window used to get
  every memory in full. On the tunez run that was 30 memories (51 KB), so phase briefs grew
  from 28 KB to 85 KB, check briefs reached about 100 KB, and from phase 13 on the first Read
  of every brief came back cut short. Now a phase gets the memories of the phases it depends on
  in full (up to 12 KB, nearest first), and every other memory as a one-line index it can open.
  Review, tidy-up, security and audit windows get the index only. Rebuilt from tunez's own
  memories, phase 19's brief is 50 KB instead of 83 KB and the audit's 45 KB instead of 92 KB.
  `STATE.md`'s carryover lines now record the phase that wrote each memory, and every brief
  states its length so a Read that stops early is resumed.
- Pre-flight is no longer red on every new project. A command whose prerequisites only the
  build creates — no `package.json` yet or no such script in it, no `Cargo.toml` / `go.mod` /
  `Makefile`, a script file that doesn't exist yet, `check-design.sh --verify` — is listed as
  *not runnable yet* with the phase that first uses it, instead of failing. The list is fixed in
  the script, so a broken baseline is still red. On the tunez run, 13 of 16 commands were red
  before phase 1 and "skip pre-flight" became part of the plan.
- A `## Mandatory commands` bullet with a description after the command no longer runs the
  description. `` `npm run build` — summary; exit 0 `` ran as command substitution plus
  `; exit 0`, a false pass. Pre-flight and the tidy-up / security gate now take only the
  command, and `validate-phase.sh` rejects such a bullet (the summary line belongs under
  `## Evidence required`). A phase command that is also an account check runs once.

- `check-design.sh` no longer reports an existing screen heading as missing. With a large
  `## Screens` section, `grep -q` stopped reading at its first match, the section writer died of
  SIGPIPE, and `pipefail` turned the found heading into "no '### <id>' heading" — at random,
  including inside `--verify`, which the design-fidelity criteria run. Found by the tunez run.

## [0.11.0] — 2026-10-07 (relay)

**What relay adds over Supergoal 0.7.0.** Versions 0.8.0–0.11.0 were private pre-releases; this
entry summarises them. Detailed per-version notes start with 1.0.0.

### Execution: one subagent per phase

- **The `/goal` session is an orchestrator.** Every phase, fix and audit round runs in its own
  `general-purpose` subagent with a fresh context window, so a large build no longer exhausts one
  window. `templates/PROTOCOL.md` is the orchestrator's manual; `templates/PHASE-BRIEF.md` is the
  subagent's contract, mode-fenced by role.
- **Self-contained briefs.** `scripts/assemble-brief.sh` builds each window's brief from the phase
  spec, the spec's success criteria, carryover memory from earlier phases, a precomputed code map
  slice, the run state and the exact marker formats (`templates/MARKERS.md`).
- **Echo first, then record.** Subagents report asynchronously; the orchestrator echoes each
  report's marker blocks verbatim into the transcript (the `/goal` evaluator reads only that),
  then `scripts/record-phase.sh` validates the report and applies every `STATE.md` change.
- **Hybrid 3-strike recovery.** Retry inside the phase's window, then a fix spec run by a fresh
  subagent, then a handoff. `scripts/resume-line.sh` prints the `/goal` that resumes a blocked run.
- **Evidence on disk, compact markers in the transcript.** Proof goes to
  `phases/phase-N.evidence.md`; commands run through `scripts/run-logged.sh` so their output goes
  to a log, not into a context window.
- **Code maps.** With graphify installed, each phase gets a token-budgeted map of the symbols it
  touches (`scripts/build-graph.sh`, `scripts/map-slice.py`); without it, file-name matches.
- **Recovery from an unplanned stop.** `scripts/recover.sh` settles the dispatch that was in
  flight after a crash or restart; interruptions (API errors, usage limits) are never counted as
  failures.

### Planning: an agreed specification

- **Stage 2.5 — the specification interview**, run after recon: five mandatory rounds, then more
  until an ambiguity score clears its gate, plus an edge-case probe (`scripts/edge-probe.py`) and a
  prohibition pass. It writes `SPEC.md`, gated by `scripts/validate-spec.sh`. `--quick` narrows it
  but never skips agreeing on acceptance.
- **The final audit verifies the spec**, not only the plan compiled from it, and reports an honest
  audit-coverage line.
- **Stage 2.6 — plan-time research.** 1–6 specific questions you approve, one researcher subagent
  each, sourced answers validated by `scripts/check-research.sh`.
- **Stage 2.7 — an optional design stage.** A brief for Claude Design or any design tool, then
  `scripts/check-design.sh` verifies the returned package and drafts fidelity criteria.
- **Phase sizing, exemplars and map seeds** in every phase spec; Stage 6 shows the phase-level
  rubric (`scripts/build-rubric.sh`) and the scope the planner decided without asking.
- **Stage 6.5 pre-flight** in one call (`scripts/preflight.sh`), which also refuses a dirty tree.

### Checks around the build

- **Per-phase correctness review, an end-of-run tidy-up and a security pass**, each in its own
  subagent. None can stop the run: what cannot be fixed goes to `FINDINGS.md`. A check may change
  a call relay made in the plan (flagged `⚠ Plan changed:`), never one you made. `--lean` turns
  all three off.

### Git

- **Every passing phase commits** through `scripts/relay-git.sh` (trailer-tagged, refusing secrets
  and generated files); a run that starts on the default branch moves to `relay/<run-id>`.
- **Pushing is opt-in** (`--push` or `RELAY_PUSH=on`): once, after the audit, only a branch relay
  created, never forced. A failed push never stops a run.

### Changed

- **Renamed to relay.** Plugin `relay`, skill `goal`, invoked as `/relay:goal` (was `/supergoal`);
  artifacts under `.relay/<run-id>/`, env vars `RELAY_*`, markers `RELAY_*`.
- **Skill assets are located via `${CLAUDE_SKILL_DIR}`**, so marketplace installs find them; the
  memory directory is the one Claude Code keeps per git repository (`scripts/memory-dir.sh`).

### Removed

- **Codex support** (relay depends on Claude Code subagents) and the **standalone skill install**
  (a standalone `goal` skill would collide with the built-in `/goal`).

### Tooling

- Fixture tests for every script (`tests/`, run by `tests/run-all.sh`), CI on macOS (bash 3.2) and
  Linux (bash 5), and repo-only run tools: `tools/check-run.py` (protocol conformance of a finished
  run) and `tools/run-report.py`.

## Fork point

**relay** forked from **Supergoal v0.7.0** at commit `ec2f6eb`
(upstream [`robzilla1738/supergoal`](https://github.com/robzilla1738/supergoal), by Robert
Courson, MIT). relay continues upstream's version line from 0.8.0.

Every entry below this line is upstream Supergoal release history. It is intentionally left
unrenamed — "Supergoal", `/supergoal`, `.supergoal/`, and `SUPERGOAL_*` there describe
Courson's releases as they shipped.

## [0.7.0] — 2026-06-06

Concurrent-run isolation. Two `/supergoal` runs started in the same working tree both defaulted to a single flat `.supergoal/` directory and overwrote each other's `STATE.md` / `ROADMAP.md` / `phases/` / `applied-memories.md` — a real, observed data-loss bug. Every run now claims its **own** namespaced subdirectory under `.supergoal/`, so the planning artifacts of two runs can never collide.

### Fixed

- **Concurrent runs no longer clobber each other's artifacts.** The root cause was a check-then-write race: each run independently decided `.supergoal/` was its workspace and wrote the same paths. Runs now claim a unique per-run directory via `mktemp -d` (atomic create-or-fail), so two simultaneous starts always land on distinct dirs — even when their task slugs are identical.

### Added

- **`scripts/repo-state.sh`'s sibling, `scripts/claim-run.sh`** — atomically claims `.supergoal/<slug>-XXXXXX` for a run and prints the path. Honours `$SUPERGOAL_BASE`; degrades to a safe `run-` slug for empty/garbage task strings; creates the base dir on demand. This is the load-bearing primitive of the fix.
- **`tests/claim-run.test.sh`** — fixture tests for the claim primitive. The headline assertion is the **race test**: 24 simultaneous claims of an identical slug must yield 24 distinct directories. Also covers slug derivation, sequential uniqueness, empty/garbage fallback, on-demand base creation, and `$SUPERGOAL_BASE` override. Repo-only (not shipped). 23 assertions, all green.
- **Coexistence notice (Stage 0).** When a fresh run detects another active run in the same working tree, it prints a prominent warning: planning artifacts are isolated, **but two `/goal` executions in the same tree still edit the same source files and clobber each other's code** — for true parallel execution, use a separate `git worktree` per task (or resume the existing run).
- **`Run root:` field in `STATE.md`** — records the run's namespaced dir for resume detection and the audit.

### Changed

- **All run artifacts live under a per-run namespace.** `SKILL.md` introduces `$SUPERGOAL_BASE` (the `.supergoal/` parent) and sets `$SUPERGOAL_ROOT` to the claimed per-run subdir in Stage 0. `PROTOCOL.md` and `phase-goal.txt` use a `{{RUN_ROOT}}` placeholder; Stage 7 `sed`-substitutes the concrete path into the copied `PROTOCOL.md`, and the planner fills it into each phase spec. The dispatched `/goal` line and the reference docs (`goal-format.md`, `repo-state-comparison.md`, `phase-design.md`) now reference `<run-root>/…` instead of a hardcoded `.supergoal/…`.
- **Stage 0 resume detection is namespace-aware** — it scans `.supergoal/*/STATE.md` (plus the legacy flat `.supergoal/STATE.md`) for active runs and either resumes the matching one or coexists with it.
- **Removed a vestigial `mkdir -p "$SUPERGOAL_ROOT/goals"`** from the locate block (the `goals/` subdir was created but never used anywhere).

### Migration

The on-disk layout moved from flat `.supergoal/` to `.supergoal/<run-id>/`. No action needed for Claude Code (the skill manages its own dirs; pre-0.7 in-progress runs are still detected via the legacy flat-layout scan). Codex users must re-sync (`rm -rf ~/.codex/skills/supergoal && cp -R skills/supergoal ~/.codex/skills/supergoal`) to pick up `claim-run.sh` and the namespacing logic. Any tooling that assumed a flat `.supergoal/ROADMAP.md` path should read the run dir from `.supergoal/<run-id>/`.

## [0.6.1] — 2026-06-05

Correctness + cross-platform fix for the audit/cleanliness comparison. An autonomous `/goal` run often leaves work uncommitted; the prior `git diff <Baseline ref>..HEAD` comparison compared two **commits**, so it saw none of it. The final deliverable audit and per-phase cleanliness checks now evaluate the **complete working tree** against the captured baseline. Additive and backward-compatible — every transcript marker, STATE.md field, and protocol step is preserved.

### Fixed

- **Audit + cleanliness no longer miss uncommitted work.** Replaced the commit-range `git diff <Baseline ref>..HEAD` in the deliverable check and the cleanliness greps with a complete-working-tree comparison: tracked changes via the single-revision `git diff <Baseline ref>` (committed + staged + unstaged + deleted) unioned with untracked-file detection. Previously a run that never committed showed an empty diff — deliverables read as "missing" and cleanliness reported 0 debug prints / TODOs / dead imports no matter what was written.
- **Deleted-file deliverables.** A "remove X" deliverable left uncommitted is now correctly reported `present` (the deletion shows in the working-tree diff) instead of a false `AUDIT_GAP`.
- **Shell scripts forced to LF.** `.gitattributes` (`*.sh text eol=lf`) verified correct — it overrides `core.autocrlf=true`, which on a fresh Windows checkout would otherwise produce a CRLF shebang that fails to execute. Renormalized the existing scripts that had been checked out CRLF locally.

### Added

- **`scripts/repo-state.sh`** — single source of truth for the comparison. Subcommands: `deliverable <baseline> <path>` (`present`/`missing` + evidence, exit 0/1), `changed-files <baseline>`, and `added-lines <baseline>` (tracked-diff additions + untracked file bodies, for the cleanliness greps). Never mutates the repo or index; degrades to a filesystem existence check when the baseline is invalid/unavailable (`no-git`, bogus sha, non-repo). Copied into `.supergoal/` at Stage 7 alongside `PROTOCOL.md`.
- **`references/repo-state-comparison.md`** — the one documented comparison strategy. PROTOCOL.md, SKILL.md, goal-format.md, and phase-design.md defer to it.
- **`tests/repo-state.test.sh`** — fixture tests over throwaway git repositories covering clean, modified-uncommitted, staged, untracked, deleted, committed-after-baseline, paths-with-spaces, invalid-baseline, LF-shell-script, `.gitignore`'d-file, and renamed-file scenarios. Repo-only (not part of the shipped plugin payload). 47 assertions, all green.

### Changed

- **`SUPERGOAL_PHASE_VERIFY` cleanliness** and **`AUDIT_VERIFY` Deliverables** now source from `repo-state.sh`. The transcript markers, block shapes, and 3-strike semantics are unchanged — only the comparison's source of truth moved from a commit range to the complete working tree, plus untracked detection.

### Migration

None for Claude Code (additive). Codex users must re-sync (`rm -rf ~/.codex/skills/supergoal && cp -R skills/supergoal ~/.codex/skills/supergoal`) to pick up the new `repo-state.sh` helper and reference doc.

## [0.6.0] — 2026-05-14

Five additive refinements to the validation/audit loops. Every addition closes a specific real failure mode; nothing is added that could become "AI-fills-in-blanks" boilerplate. No removals — every existing transcript marker, STATE.md field, and protocol step stays put.

### Added

- **Diff-based audit step.** During the final audit, the agent now reads each phase's `**Deliverables:**` bullets from `ROADMAP.md` and runs `git diff --stat <Baseline ref>..HEAD -- <path>` (with `ls`/`git ls-files` fallback) per deliverable. Missing files / empty diffs → `AUDIT_GAP`. This catches the case where a phase's commands all pass and VERIFY says ✓ but the deliverable was never actually shipped. Filesystem ground truth, not transcript self-report.
- **`Baseline ref:` field in `STATE.md`.** Captured at Stage 7 dispatch from `git rev-parse HEAD`. The audit reads it to diff deliverables against the working tree.
- **Stage 6a self-critique pass.** Before printing the plan-review summary, the planner runs **one** turn answering three questions: (1) is each acceptance criterion falsifiable? (2) is any phase packing two coherent units? (3) where would a partial failure cascade worst? Findings appear in the Stage 6 summary as a `Self-critique:` block; falsifiability issues are rewritten in place before the user sees the summary. Cheapest moment to catch the most expensive bugs.
- **Stage 6.5 pre-flight smoke check.** Between Stage 6 confirmation and Stage 7 dispatch, the planner runs the deduplicated mandatory commands once. `PREFLIGHT_GREEN` → proceed. `PREFLIGHT_RED` → re-show Stage 6 with a new revision option, **"Skip pre-flight and dispatch anyway"**, for cases where a broken baseline is the point (phase 1 fixes it). Prevents 3-strike thrash against a baseline that was never the agent's fault.
- **Cleanliness pass in `SUPERGOAL_PHASE_VERIFY`.** Three grep-based counts against `git diff <Baseline ref>..HEAD`: debug prints added (`console.log` / `print(` / etc., stack-aware), session TODO/FIXME added, dead imports added. Non-zero counts trigger 3-strike like any failed criterion, unless the phase spec declares `Cleanliness override: ...` (narrow release valve for legitimate debug-shipping phases).
- **Honest audit coverage in `AUDIT_COMPLETE` and `SUPERGOAL_RUN_COMPLETE`.** Audit completion now reports a coverage ratio — what fraction of the criteria/deliverable checks were re-verified vs. `trust-prior-verify`. When trust-prior is >30% of total checks, `SUPERGOAL_RUN_COMPLETE` prepends a one-line honesty banner: `⚠ Audit coverage: X re-verified, Y trust-prior (Z%). Eyeball UI/UX before merging.` Below 30%, only the plain coverage line appears.

### Changed

- **Stage 6 revision menu** "Start now" label now reflects that pre-flight kicks in next ("run pre-flight smoke check (Stage 6.5), then print the ready-to-paste `/goal` line").
- **`AUDIT_VERIFY` block** extended with a `Deliverables:` summary block from the new step 5b.
- **`SUPERGOAL_PHASE_VERIFY` block** extended with a `Cleanliness:` section.
- **`AUDIT_COMPLETE` block** extended with `Deliverables:` and `Audit coverage:` lines.

### Why

Today's loops are honest about per-phase work but have three quiet gaps: (a) a phase can VERIFY-pass without actually shipping its deliverable; (b) the planner can approve a plan with vague criteria the audit can't fix later; (c) a phase can ship debug logs, dead imports, or session TODOs alongside passing tests. v0.6 closes each with a filesystem read, a one-turn plan-time critique, and a grep — none of which add new transcript ceremony or run repeatedly enough to bloat token cost. The audit-coverage banner is the system's most honest output: it admits what the audit verified vs. didn't, rather than implying machine-verification of everything.

## [0.5.2] — 2026-05-14

Final audit stage. The run no longer completes on per-phase self-reports alone — it re-validates against the original plan and self-heals any gaps before declaring done.

### Added

- **Final audit (Stage 10 of the execution loop).** After the last phase and before `SUPERGOAL_RUN_COMPLETE`, the agent now:
  1. Re-reads `ROADMAP.md` and pulls every phase's acceptance criteria fresh from the original plan (not from this run's self-reports).
  2. Verifies one `SUPERGOAL_PHASE_DONE` per phase in the transcript.
  3. Re-runs the deduplicated set of mandatory commands (build / typecheck / lint / full test suite) once at the end to catch cross-phase regressions a per-phase VERIFY can miss.
  4. Spot-checks verifiable acceptance criteria (file exists, symbol exported, config key set, etc.); marks non-deterministic checks as `trust-prior-verify`.
  5. On any gap → writes `.supergoal/phases/audit-fix-<round>.md`, executes inline using the same 3-strike per-criterion protocol, then re-runs the audit. Up to 3 audit rounds; on the 3rd round's failure, `AUDIT_HANDOFF` (stops without `SUPERGOAL_RUN_COMPLETE`).
  6. On zero gaps → prints `AUDIT_COMPLETE`, then `SUPERGOAL_RUN_COMPLETE`.
- **New transcript markers:** `AUDIT_START`, `AUDIT_VERIFY`, `AUDIT_GAPS`, `AUDIT_COMPLETE`, `AUDIT_HANDOFF`. Documented in `references/goal-format.md`.

### Changed

- **`/goal` end-state condition** now requires `AUDIT_COMPLETE` before `SUPERGOAL_RUN_COMPLETE` and forbids `AUDIT_HANDOFF` in addition to `FAILURE_HANDOFF`. Updated the ready-to-paste `/goal` text in SKILL.md Stage 7 and `references/goal-format.md`.
- **PROTOCOL.md template** extended with the full audit protocol.
- **README Mermaid diagram** now includes the audit + audit-fix loop with its own blue color class.

### Why

Per-phase VERIFY is a self-report. A phase can pass its own check while a later phase silently breaks it (a type added in phase 2 violated in phase 5; tests that passed mid-run break after refactor; a config key set in phase 1 overwritten in phase 4). The audit catches that by re-running aggregated build/typecheck/lint/tests once at the end and verifying every criterion against the original plan — not against the agent's own optimistic mid-run reports.

## [0.5.1] — 2026-05-14

Stage 1 now gathers the full picture in greenfield runs.

### Changed

- **Stage 1 greenfield no longer caps at 4 questions total.** The planner walks an explicit category checklist — platform, stack, **design direction**, integrations, scope, audience, performance, data model — eliminates anything memory or prompt already covers, and asks about every remaining gap in batches of up to 4 (the `AskUserQuestion` tool ceiling). Two batches is normal for a real greenfield task; three is rare but allowed.
- Anti-patterns are now explicit in SKILL.md: don't proceed with silent assumptions about stack or design direction; don't pad questions when memory/prompt covers them; don't ask micro-details that belong in the Stage 6 revision menu.
- Brownfield unchanged (0–2 questions; recon answers most structural questions).

### Fixed

- `.gitignore` was still referencing `.superplan/` (missed by the v0.5.0 mass-rename since the find filter didn't include extensionless files).

## [0.5.0] — 2026-05-14

Renamed `superplan` → `supergoal` end-to-end. The skill produces a `/goal`, so the name now points at the central primitive. Breaking change for anyone who had v0.4.x installed: uninstall the old marketplace + plugin, then re-add at the new name.

### Changed

- **Repo:** `github.com/robzilla1738/superplan` → `github.com/robzilla1738/supergoal` (GitHub auto-redirects old URLs).
- **Plugin name:** `superplan` → `supergoal`. Install command is now `/plugin install supergoal@supergoal`.
- **Marketplace name:** `superplan` → `supergoal`. Re-add with `/plugin marketplace add https://github.com/robzilla1738/supergoal.git`.
- **Slash command:** `/superplan` → `/supergoal`.
- **Skill dir:** `skills/superplan/` → `skills/supergoal/`.
- **Artifact dir in user projects:** `.superplan/` → `.supergoal/`.
- **Transcript markers:** `SUPERPLAN_PHASE_START` / `_VERIFY` / `_DONE` / `_RUN_COMPLETE` → `SUPERGOAL_*`.
- **Env vars in scripts:** `$SUPERPLAN_DIR` / `$SUPERPLAN_ROOT` → `$SUPERGOAL_*`.
- **All copy and Mermaid diagrams** in README updated to the new name.

### Migration

```text
/plugin uninstall superplan@superplan
/plugin marketplace remove superplan
/plugin marketplace add https://github.com/robzilla1738/supergoal.git
/plugin install supergoal@supergoal
/reload-plugins
```

For Codex: `rm -rf ~/.codex/skills/superplan` and re-clone per the new README.

## [0.4.1] — 2026-05-14

Public-release readiness pass. Honest install + honest dispatch.

### Fixed

- **Stage 7 dispatch is now correct.** Previously SKILL.md instructed the planning agent to print `/goal "..."` as its final text output, expecting the host to auto-fire it. Slash commands fire only from user input on both Claude Code and Codex, so the autonomous-execution claim was structurally broken. Stage 7 now prints a clearly fenced, ready-to-paste `/goal` block with a one-line instruction telling the user to paste it. One paste between Stage 6 confirmation and full autonomous execution.
- **Plugin install now actually works** (end-to-end verified against the live GitHub repo with `claude plugin install supergoal@supergoal` returning `Successfully installed plugin: supergoal@supergoal (scope: user)`). Added `.claude-plugin/marketplace.json` so the plugin can be installed via the Claude Code marketplace command sequence: `/plugin marketplace add https://github.com/robzilla1738/supergoal.git` → `/plugin install supergoal@supergoal` → `/reload-plugins`. The README's `owner/repo` shorthand is documented with a note that it requires GitHub SSH keys, falling back to the HTTPS URL otherwise.
- **Codex install path is now explicit.** Removed the dead `.codex-plugin/` directory (Codex CLI has no plugin system; the file was silently ignored). README's Codex section now contains the actual clone-and-copy commands to `~/.codex/skills/supergoal/`.

### Changed

- `SKILL.md` description, one-shot summary, Stage 6 confirmation copy, and revision-menu option labels all updated to reflect the user-paste dispatch model.
- `references/goal-format.md`: "Supergoal's single-`/goal` shape" section clarified to state that dispatch is user-initiated by paste, not agent-initiated.
- `README.md`: rewritten install sections for both Claude Code (marketplace flow + manual fallback) and Codex (manual clone-and-copy). Use walkthrough's Stage 7 description aligned with the new dispatch mechanic.
- `.claude-plugin/plugin.json`: description aligned with new dispatch language, version bumped 0.4.0 → 0.4.1.

### Removed

- `.codex-plugin/plugin.json` and the surrounding `.codex-plugin/` directory (Codex has no plugin manifest convention).
- Stray `.DS_Store` files from `skills/supergoal/`.

## [0.4.0] — 2026-05-14

Initial single-`/goal` redesign. Adaptive phase count, memory preload + writeback, tool discovery, 3-strike self-healing recovery. Internal release; see v0.4.1 for the first public-ready cut.
