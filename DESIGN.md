# relay — design brief

*A fork of Supergoal with per-phase context isolation: an orchestrator plus one subagent per phase.*

**Status:** built through 0.11.0 (private pre-releases); 1.0.0 is the first public release. Every
execution path — phases, fix dispatch, audit-fix dispatch, no-report re-dispatch, both handoffs,
the review / tidy-up / security checks, and recovery from an unplanned stop — has run end to end
against real projects.
**Name:** `relay` (plugin) / `goal` (skill) — invoked as `/relay:goal`.

This file holds the architecture and the decisions behind it. `AGENTS.md` describes the repository
as it is; `CLAUDE.md` holds the working rules.

### Decisions log

| Date | Decision |
|---|---|
| 2026-09-12 | **Claude Code only — no Codex support.** Codex has no subagent equivalent, and per-phase subagents are the whole architecture. No host-capability branch. |
| 2026-09-12 | **Plugin install only — no standalone skill install.** The skill locates its assets via `${CLAUDE_SKILL_DIR}`, not a hardcoded path list. |
| 2026-09-12 | **GSD retrieval code: reimplement + credit, never copy.** Source pinned to `gsd-build/get-shit-done` tag `v1.42.3` (MIT, Copyright (c) 2025 Lex Christopherson). Credit line in the `map-slice.py` header and README. |
| 2026-09-12 | **Map-slice runtime: stdlib-only Python, run via `uv run --no-project`, falling back to `python3`, then to the plain file tree.** Map slices exist only for users who installed graphify, whose recommended install already provides `uv` — so zero extra installs. Chosen over `jq` (free only on macOS 15+; extra install on older macOS / Linux / Windows Git Bash; BFS + tiered budget-shedding is unmaintainable in jq). |
| 2026-09-12 | **Evidence goes to files.** (1) `RELAY_PHASE_VERIFY` lists one `pass\|fail` line per criterion plus 3 summary lines — Stage 4 mandates 5–10 criteria, so a hard ≤15-line digest was infeasible. (2) Commands run through a tested helper, `scripts/run-logged.sh`, not a prose shell pattern — command output enters context as it runs, so redirection is where the savings are. (3) `SKILL.md`'s duplicated loop is replaced by a pointer. (4) Screenshots: record paths, open only for visual judgment. Audit completeness reads evidence files and `STATE.md` rows, never the transcript. |
| 2026-09-12 | **Code map slices.** (1) Graph written to `<run-root>/graph/` via `GRAPHIFY_OUT` — graphify's default `graphify-out/` is meant to be committed, so never touch it. (2) The run dir is hidden with `$GIT_DIR/info/exclude` at claim time — on movez, graphify had scanned the run files, and untracked run artifacts were also inflating `repo-state.sh` cleanliness counts. (3) Graph built at **Stage 2** and refreshed at each phase start (`--force`, ~3 s on movez), not only at Stage 7, so the warm planner can write and check `Map seeds:` per phase. (4) Build via `build-graph.sh` + a log file, not a subagent — `run-logged.sh`-style redirection already contains the noise. (5) A bash launcher (`map-slice.sh`) owns runner choice and a file-name fallback. (6) Output grouped by file: Scheduler 824 tokens vs §6's 1,457 flat projection. Real schema (graphify 0.9.61): 12 relation types, only EXTRACTED/INFERRED observed, external types have an empty `source_file`, type declarations get an incoming `contains` from each declaring file. |
| 2026-09-12 | **Memory dir, marker formats, audit inputs.** (1) Stage 0 detects the memory directory (now `scripts/memory-dir.sh`: the one Claude Code keeps per git repository, shared by its worktrees), falls back to the other candidates, and records it in `STATE.md` as `Memory dir:`; `STATE.md` also gains a `## Carryover` list of memory files written this run. (2) Marker formats live in `templates/MARKERS.md` (grouped Phase / Failure / Review / Audit so the brief assembler can slice it), copied to `<run-root>/MARKERS.md` at Stage 7; `goal-format.md` keeps the `/goal` mechanics and links there. (3) Audit step 3 reads `STATE.md` rows + evidence files — an audit subagent cannot see the parent transcript. |
| 2026-09-12 | **The orchestrator.** (1) **Dispatch:** built-in `Agent` tool, `general-purpose`, prompt = "read `phases/phase-N.brief.md` and follow it" — no plugin-shipped agent definition (one less surface to verify under marketplace installs). (2) **Brief assembly by script**, `assemble-brief.sh` + fixture suite: the orchestrator pays one summary line per phase and never holds the brief in context; the template `PHASE-BRIEF.md` is mode-fenced (`<!-- mode: … -->`) so the executor contract has one copy. (3) **3-strike is hybrid:** attempt + auto-retry inside the phase window (it has the failing context); the second failure writes the fix spec and returns `FAILURE_ESCALATE`; the orchestrator dispatches the fix to a fresh window, which returns `RELAY_PHASE_DONE` or `FAILURE_HANDOFF`. A dispatch that returns no blocks at all is a dispatch failure, retried once, then the orchestrator itself prints the handoff. (4) **Audit rounds run in subagents** too, with fixes in fresh windows and an `AUDIT_FIX` block for the fix report; the orchestrator authors only `RELAY_RUN_COMPLETE`. (5) **Fallback** is one paragraph: no `Agent` tool → execute the brief inline under the same contract. (6) **Phase sizing:** `Estimated files:` (new + modified) in the spec header, split above 12 or state why (8 at first — raised once windows were measured, below), advisory warning in `validate-phase.sh` (`RELAY_PHASE_FILE_LIMIT`); Stage 6a checks it. (7) **Exemplars:** a `## Exemplars` section in the spec body, advisory warning when missing. (8) The `/goal` condition's end-state clause is unchanged; its instruction clause says "assemble its brief and dispatch it to a subagent, then echo the marker blocks verbatim". (9) `PROTOCOL.md` is the orchestrator's manual; the executor rules (evidence format, cleanliness, memory writeback) live only in `PHASE-BRIEF.md`. |
| 2026-09-16 | **Fixes from the first end-to-end run.** (1) **Async dispatch is documented, not fought:** the `Agent` result is a launch notice; the report arrives as an `<agent-message>` hand-back; "agent finished" notices and goal check-ins are answered in one line with no tool calls. (2) **Echo first, then record:** the reply to a hand-back opens with the verbatim echo, then runs `record-phase.sh`. Every `STATE.md` claim is dropped from subagent blocks. (3) **`record-phase.sh` + fixture suite:** subagents write their report to `phases/*.report.md` and return the same text; the script validates it and applies every `STATE.md` change idempotently, including no-report logging (second one → `BLOCKED`). Replaces ~700 output tokens of inline bookkeeping per phase. (4) **Orphaned shell tasks: prevent + guarded stop, not a `TaskStop` ban.** The run's stale task came from a subagent Bash call auto-backgrounded at the 120 s timeout, and it deferred the `/goal` evaluator. The brief forbids long chained commands and requires waiting for / stopping backgrounded ones; the orchestrator stops shell tasks only when a check-in lists no subagent, and never reads `tasks/*.output` (a whole subagent transcript). (5) **Read hygiene in two places:** brief §6 context-hygiene rules (range reads, no whole-file `cat`, never `tool-results/`, Write tool for files) and Stage 5 / `phase-design.md` (cite shared planning docs by section; reads, not writes, set window size). No `Estimated reads:` header field — an estimate enforces nothing. (6) **Carryover: no cap yet;** `assemble-brief.sh` reports brief and carryover KB so growth is measurable. |
| 2026-09-17 | **Failure-path runs.** Three deliberately broken runs on a small real project exercised every recovery path: one recovered everything (fix succeeds, one no-report, audit gap), one failed its fix (`FAILURE_HANDOFF`), one returned no report twice (orchestrator-authored `FAILURE_HANDOFF`). `tools/check-run.py` checks the protocol rules no fixture can — echo-first and verbatim, recording mode, forbidden reads, `STATE.md` ownership, check-in handling, per-subagent read hygiene. Fixes the runs justified: `PROTOCOL.md` gains "never `cd`" and an after-a-handoff rule (the evaluator keeps re-prompting a blocked run; never fake completion markers); `record-phase.sh --no-report` marks the phase row `in_progress`. Their real reports are `record-phase` fixtures, so every recovery outcome is pinned. |
| 2026-09-19 | **The specification stage.** (1) **The audit had no independent statement of intent**: it re-verified against `ROADMAP.md`, which the planner compiled from the request, so a misread request produced a clean `AUDIT_COMPLETE` over the wrong software. `SPEC.md` (Stage 2.5) is that statement, and audit step 5c re-verifies it; spec criteria count toward `Audit coverage:`. Optional in every reader — pre-0.9 runs and hand-authored test run roots have none. (2) **The interview is thorough by default**, reversing the inherited "frictionless / zero questions is a win" stance. That value came from upstream, where a human executed the plan step by step and corrected as they went; relay's executors run cold and cannot ask, and the trade is minutes against hours and tens of millions of tokens. `--quick` is the opt-in exception and never skips the acceptance round. (3) **The ambiguity score is a completeness meter, not a skip gate** — it says when the interview is finished, never whether it happens, because the opening score is derived from the same prompt it is judging. Thresholds are tightened over GSD's (≤ 0.15; acceptance minimum 0.85) since relay's spec governs a whole run rather than one phase. (4) **Ordering:** questioning runs after recon; Stage 1 is restate-and-classify. (5) **Completeness probes** (`edge-probe.py` + a prohibition pass) because the gate only measures whether *stated* requirements are clear — omission is the failure mode a verifier cannot catch, by construction. Output is a floor to union with; dismissal needs a reason. Reimplemented + credited per the GSD rule. (6) **Two execution-path bugs**, both found by reading rather than by a run: the 3-round audit cap lived only in prose to a subagent (`record-phase.sh` would ask for round 4), and phase validation never required `RELAY_PHASE_VERIFY`, so a report claiming DONE with no verify recorded `0/0 criteria pass`. Both now enforced in the script. (7) **`resume-line.sh` instead of a resume state machine:** a printed handoff makes the end-state permanently unsatisfiable, but the primitives for continuing in a *fresh* session already existed (idempotent recording, `Current phase`); only a remaining-phases condition was missing. The full pathway would mean touching the end-state contract, so it stays unbuilt. (8) **`run-report.py` leads with development signal** (retries, probe hypotheses, trust-prior criteria), not token accounting. |
| 2026-09-22 | **Map seeds exist when the phase runs.** (1) **Existence is judged at dispatch, not plan time:** `assemble-brief.sh` rebuilds the graph before every phase, so a seed resolves if it is in the plan-time graph *or* an earlier phase's spec names it verbatim (whole word, case-sensitive). One rule for greenfield and brownfield; `Map seeds: none` is right only for greenfield phase 1 and runs without graphify. (2) **An earlier phase's own `Map seeds:` line does not count** — seeding a symbol is not a promise to create it. (3) **The plan-time check is `check-seeds.sh`**, run once over all specs (Stage 5, after Stage 6 tweaks, and in Stage 7's pre-dispatch block); its ❌ blocks dispatch but cannot deadlock, since dropping a seed always clears it. It degrades to warnings when the graph cannot be queried (no Python) or graphify is absent. Planner-only. |
| 2026-09-22 | **Design stage shape (Stage 2.7).** (1) **Relay briefs, never designs:** a brief compiled from `SPEC.md` (screens with stable ids, states from `## Edge coverage`, fixed copy, constraints, the brownfield design system), then a stop — the Stage 7 channel. Written for Claude Design, but **tool-agnostic**: any tool or designer works if it returns the contract. (2) **Contract:** `design/HANDOFF.md` (`## Approved screens` table + `### <id>` per screen) and one PNG per approved screen are required; tokens/components/copy sections recommended (each yields a criterion, each missing one warns); `design/source/` optional and off every reading path. Chosen from a real Claude Design handoff: its README carried everything the build needed, its 176 KB HTML canvas was self-described mockup code a cold executor would waste a window on or port. (3) **`design/` lives in the repo, committed** — `repo-state.sh` counts untracked files as run changes; relay makes that commit itself (`prepare-design.sh`, below). (4) **Screens proven by a `design: <id>` comment** in exactly one file — one grep, language-agnostic, deterministic; over a planner-written screen→file map (paths guessed before code exists) or audit judgment (non-deterministic). (5) **Fidelity criteria stay structural** — screens marked, components present, tokens in one theme file, copy verbatim — drafted by `check-design.sh --criteria` together with dispositions for the edges the probe raises on them (any pair without a canned reason stays `unresolved`, so the probe remains the floor). (6) **The human check never gates** (an overnight run must not wait on a person): the polish phase captures each screen or records `capture unavailable: <id> — <reason>`; either passes; the comparison is listed for after the run. (7) **Opt-in:** `--design`, or one `AskUserQuestion` at Stage 1 for `ui` tasks — the single exception to "ask no questions at Stage 1", since recon cannot answer it. (8) **Resume:** Stage 2.7 writes `STATE.md` early with `Status: AWAITING_DESIGN`, so Stage 0's active-run scan sees the parked run. |
| 2026-09-22 | **Design brief: four gated stages.** The first real run (tunez) returned a correct package, but Claude Design drew all 8 screens and their states in one ~30-minute pass, with no point at which the owner could reject the look short of redrawing everything. The brief now asks for (1) exactly three takes on one anchor screen, (2) refinement until the look is settled, (3) build-out of every screen, (4) review and revision; only then the package. **Stages advance on intent, not exact phrases** (a remembered phrase is friction and gets forgotten) — the brief's phrases are examples, and the tool must ask before advancing when it cannot tell feedback from approval. **Anchor = the canonical screen**: the product's home, the one a returning user lands on — not the densest or most state-heavy; never onboarding, settings, error/empty states, sheets or modals; a launcher gives way to the task screen. The planner names it with a reason; the user can override in the tool. |
| 2026-09-22 | **Design reconciliation and fidelity.** (1) **Reconciliation is step 2.7e**, not planner initiative: every criterion/constraint/prohibition/in-scope item against the design; each conflict to the user via `AskUserQuestion` (design wins → spec rewritten; spec wins → an exemption); recorded in `SPEC.md` `## Design reconciliation` ending `Reconciled: <n> conflicts`, which `validate-spec.sh` requires whenever `**Design:**` carries a sha. The design package is never edited — it is the committed record of what was approved. (2) The brief gains "The design must not", filled from prohibitions/constraints. (3) `--criteria --theme/--allow`: the theme file is named by the script, and generated files that must carry a token value literally are allowed — generated, never hand-copied. (4) Captures go to `$RELAY_DESIGN_CHECK_DIR`; the criterion also fails on any `.relay/` path in product source. (5) **Only the last phase's project memory carries `relay_run:`** — general lessons stay true after a run's directory is deleted, so tagging every memory would lose knowledge; Stage 0 lists memories naming a missing `.relay/<id>` as `Stale (run gone)` and does not apply them; the planner never writes memories about its own plan. (6) The intake block opens the Stage 1 design question's text. (7) **`check-design.sh --verify <aspect>` is the fidelity check** the criteria name, copied into the run root at Stage 7 — one deterministic command for phases and audit instead of hundreds of agent greps; `--except SPEC.md` honours spec-wins rows; copy fragments checked in one `grep -F -f` pass with a per-fragment fallback for fragments hidden inside longer ones. The full verify can only pass once the last screen exists, so it gates the last screen phase and Polish & Harden. |
| 2026-09-22 | **Plan-time research (Stage 2.6).** (1) **Research runs once, at plan time** — after `SPEC.md`, before the design brief and decomposition — never per phase (GSD's placement fits its just-in-time planning, not relay's plan-everything-then-execute-cold model); design is Stage 2.7 so stages read in the order they run. (2) **The user approves the questions** in one `AskUserQuestion` — go / edit or add / no research — including a zero-questions "none needed, because…", so the user can overrule it. (3) **Tools checked up front:** Stage 0 records `RESEARCH_TOOLS`; without WebSearch, Stage 1 offers **stop so I can install** (removes the just-claimed run dir, prints how) or continue with every finding flagged `unverified (training knowledge)`. (4) **`--quick` changes nothing** — the question count is risk-driven. (5) **Artifacts, not prose:** one `general-purpose` researcher per question from `templates/RESEARCH-BRIEF.md`, dispatched in parallel, each writing `research/<slug>.md`; `check-research.sh` validates (sources, `Contradicts:` line) and `--digest` is all the planner reads. (6) Contradictions go to the user — research never rewrites the spec; unverified findings and unanswered questions become Stage 6 key assumptions. (7) A dry run with one real researcher produced a strong answer and a genuine contradiction nobody had raised (a latency target that cannot be fully verified in a mobile browser), and showed two validator gaps: findings that are arithmetic on sourced facts (hence the `derived: <from what>` class) and long answers (hence a 120-word advisory, since the digest carries it). |
| 2026-09-22 | **Git facilities.** (1) **The subagent commits**, through `scripts/relay-git.sh commit`, as the last step of a passing verify — not the orchestrator after `record-phase.sh`: a failing pre-commit hook or signing error is then an ordinary in-window failure the builder can fix (it escalates like a failed criterion), where an orchestrator could only hand off or bypass hooks. `record-phase.sh` finds the sha in git by trailer (`Relay-Run:` + `Relay-Phase:` / `Relay-Audit-Fix:`), not from the report; a missing commit is a warning, never an invalid report. Idempotent: a re-dispatch after a no-report finds `already committed`. (2) **Failure:** nothing commits on `FAILURE_ESCALATE` (only a passing verify commits); the fix window commits on success (`… (fix)`); a handoff leaves partial work uncommitted for the owner, and `resume-line.sh` warns with a count because the resumed phase commits whatever is in the tree. (3) **One commit per audit-fix round**, not re-verified until the next round; audit step 5d makes uncommitted work at the end a gap. Message: `relay: phase N — <name>` + trailers, no Co-Authored-By (the owner's identity authors it). (4) **Dirty tree = anything `git status --porcelain` shows**, tracked or untracked (it honours `.gitignore` and the `.relay/` exclude); no bypass, never auto-stash; checked after the pre-flight commands so their artifacts count. (5) **`repo-state.sh` is commit-invariant** — proven, not assumed (`repo-state.test.sh` scenario 12, two commits); per-phase diffs are `git diff <prev sha>..<sha>`. (6) **Branch:** a run that starts on the default branch (remote HEAD / `init.defaultBranch` / main / master; also detached or unborn) moves to `relay/<run-id>` at Stage 7; on any other branch it commits in place. (7) **Push:** common practice is to push feature branches, never the default branch, never force; agents push only branches they own and humans merge. Reasons for restraint in relay: a push is outward-facing and irreversible (a leaked secret stays leaked), triggers CI/deploys, and can fail unattended. So relay pushes **only a branch it created, once, after `AUDIT_COMPLETE`**, `git push -u`, never `--force`; the owner's own branch is never pushed. **A failed push never stops a run**: every failure, a hang included (`RELAY_PUSH_TIMEOUT`, default 120 s), exits 0 and `RELAY_RUN_COMPLETE`'s `Push:` line hands the owner the command. Pre-flight warns about an unreachable remote and commit signing, never blocks. (Pushing became opt-in on 2026-10-07, below.) Also: phase specs carry no git bullets; `relay-git.sh commit` refuses newly added secrets / generated files (`.env`, `node_modules/`, `.venv/`, …) and restores the index; `check-run.py` flags raw git writes and a push before the audit. |
| 2026-09-22 | **Git facilities review fixes.** A review against the row above; fixes kept inside its decisions. (1) **The run's commits stay on its recorded branch:** `commit` refuses (exit 4) when HEAD is off `**Branch:**`; the subagent never switches (the owner does, from `resume-line.sh`'s warning). (2) **An unborn repository gets an empty `relay: start` commit** on the run branch at Stage 7, so the baseline is a sha. (3) **Default-branch detection asks the remote** (`ls-remote --symref`, bounded) when no `refs/remotes/*/HEAD` exists. (4) **The run root is never dirt:** excluded by path in `relay-git.sh`, and `claim-run.sh` excludes an absolute in-repo base. (5) **Timeouts kill the process group**; `git commit` gets one (`RELAY_COMMIT_TIMEOUT`, 300 s — generous for pre-commit suites). Refuse key material (`.envrc`, private SSH keys, `*.pem`/`*.key`/`*.p12`/`*.pfx`) but not `dist/`/`build/`/`.npmrc`, which repos often commit on purpose; warn, not refuse, on a changed tracked `.env`; do **not** strip `GIT_ASKPASS` (token-supplying helpers rely on it — the group kill cleans up instead); do **not** add the push to the `/goal` condition — the push stays enforced by `record-phase.sh`'s completion line naming it and `check-run.py` failing a relay-branch run that skipped it. |
| 2026-09-22 | **Design and research fixes from a real planning session.** (1) **Relay commits `design/`, and only `design/`** (running git to hand back a design is friction). The planner creates `design/` at 2.7b and the owner puts the export there; relay never hunts for it (a downloads folder can hold several, and a sandbox may not reach it). `prepare-design.sh` unzips a lone zip or lifts one wrapper folder, refuses anything ambiguous, and commits with `git commit -- design` so the owner's other staged work is untouched. (2) **The brief goes by clipboard** (`pbcopy` of `<run-root>/DESIGN-BRIEF.paste.md`). Claude Design runs in the browser and cannot open a local path. The five-backtick paste stays as the fallback. An overview of the four design stages comes first. (3) **Approved deviations:** the designer keeps a `## Deviations from the brief` list, and reconciliation still compares everything but confirms listed deviations in one question. A deviation that breaks a prohibition is always asked alone. (4) **Accounts: status command only.** Inside relay, a tool's status command is the only sign-in check — never a credential-store query — and deploys pin scope and project. (5) **Stage order:** read-only design work may overlap the researchers, but 2.7e waits for 2.6f, since both rewrite `SPEC.md`. (6) **Phase cap 12, over with a reason.** 8 was set before any window was measured, and it forced a worse phase-1 design. Interim: recalibrate from measured per-phase peaks. (7) **Contradictions are still asked.** The spec is the audit's contract, findings can be unverified, and the owner can know better. Each question says whether it clarifies a measurement or lowers a target. (8) **Glob loops stay out of `SKILL.md` bash blocks** (zsh errors on an unmatched glob). (9) Researchers self-check with `check-research.sh --only`. |
| 2026-09-22 | **`check-design.sh` parsing.** (1) **A table's header is the first row of each table**, not of the section: the count restarts at any non-table line, in the one shared `table_rows` helper every table parser uses. (2) **Every hex value in a token value cell is checked**, so themed `light … · dark …` cells are no longer silently skipped; a value matches only where no hex digit follows it (a `#FFF` token must not match `#FFFDF8`). (3) **A one-word copy fragment must match as a whole word** (`grep -w`), so `onClose` no longer satisfies `Close`; one-word strings are only presence-checked, and rendering is the post-run comparison's job. Delimited literals were rejected: a formatter that splits JSX text would fail a correct build, and a false failure hands off an overnight run. |
| 2026-09-23 | **Review, tidy-up and security checks.** Goal: generated code must be well-formed and maintainable, not only pass the spec. **Why two passes:** per-phase-only misses the defect context isolation characteristically produces (phase N re-inventing phase M's helper, seen only through a map slice); end-only lets early design mistakes compound. The tidy-up runs **before the audit**, so the audit re-verifies `SPEC.md` and the mandatory commands against the code as it ships, and it touches **only what the run touched** (the run's changes vs `Baseline ref`). (1) **Scope:** per-phase correctness review and end-of-run tidy-up. (2) **Instructions are relay's own** — five brief modes in `PHASE-BRIEF.md` (`review`, `review-fix`, `cleanup`, `security`, `security-fix`), never an installed skill such as `/simplify`. (3) **One subagent per check, dispatched by the orchestrator**: no nested fan-out under `/goal`. (4) **A third check, the security pass**, after the tidy-up and before the audit; the planner decides per run from the surfaces the build touches (network, auth, user input, file paths, shell, secrets, deserialisation, dependencies) — skip needs a reason, Stage 6 shows it, the owner can overrule. (5) **Enforcement without touching the end-state:** the `Done when` text is byte-identical; `record-phase.sh` routes `N → review N → N+1 … → cleanup → security → audit` from the spec's `Review:` line and `STATE.md`'s `Cleanup:` / `Security pass:` (missing = skip, so pre-0.10 runs route as before); `check-run.py`'s `check_steps` fails a run that skipped or reordered one. (6) **The checks never block** (an unattended run must finish): an unfixable finding is undone and written to `FINDINGS.md`; a check's second no-report skips it; `RELAY_RUN_COMPLETE` opens with a ⚠ line pointing at the file. Review and security windows are read-only; findings go to one fix window each (`phase-N.review-fix.md` / `security-fix.md`), which is never itself reviewed. Review fixes carry their own trailer (`Relay-Review-Fix: N`) so a review's diff range — the phase's `Relay-Phase: N` commits — never includes one. (7) **`--lean`:** one flag turns all three checks off, independent of `--quick`; it is only a planner decision, written as `Review: skip — --lean` / `Cleanup: off — --lean` / `Security pass: skip — --lean`, so no script reads the flag. The security assessment still runs and Stage 6 warns when a lean build touches a surface. The run ends with a plain `Checks: skipped (--lean) — …` line, not a ⚠. |
| 2026-09-23 | **Never `cd`; coverage; pre-flight script.** (1) **The stray `cd` is fixed at both ends:** the `/goal` line opens "Working from this directory (never cd elsewhere)", and the last phase's `project_<slug>.md` memory names no absolute checkout path — the memory dir is shared by every worktree, and three of four run sessions `cd`'d into exactly the path it named. (2) **`check-run.py` fails an orchestrator `cd`** (was a warning). (3) **The coverage percentage is `record-phase.sh`'s**, computed from the two counts and rounded down, labelled "re-verified"; the audit's own `(<pct>%)` is ignored. (4) **Pre-flight is `preflight.sh`**, which prints the block itself (a planner instruction lands when it writes an artifact or rides a rendered channel, not when it says "print this"); a re-check after a dirty tree re-runs the whole pre-flight, so a stale command result can never print `PREFLIGHT_GREEN`. |
| 2026-10-07 | **1.0 scope.** (1) **No cost or token estimate.** Three measured runs on one small codebase give 3.4M–7.2M tokens per phase, retries and codebase size can't be known at plan time, and subscription limits aren't published as token counts. A wrong estimate is worse than none, and dollar cost isn't wanted at all (pricing changes too often). The README gives measured runs as examples instead. (2) **Platforms:** macOS, Linux and WSL. Native Windows is untested and deferred (risks: CRLF checkouts, `memory-dir.sh`'s path keying, `python3` naming, process-group timeouts in `relay-git.sh`); `.gitattributes` pins LF. (3) **Unplanned-stop recovery, scaled down.** Claude Code already covers the common pauses (it waits out a usage limit when the session stays open and the reset is within a day, and retries transient API errors before pausing; a paused goal stays set). A crash or closed terminal costs at most the phase in flight, and reopening the conversation (`claude --resume`) restores the goal. Built: handoff wording, an "after an interruption" `PROTOCOL.md` step (`recover.sh` settles the in-flight dispatch; leftovers are kept and reviewed) and a fixture test for a kill between commit and recording. Not built: Stage 0 interrupted-run detection and a machine-wide live-process check. |
| 2026-10-07 | **Pushing becomes opt-in — reverses the 2026-09-22 push-by-default.** A push is the one outward-facing, hard-to-undo thing a run does (CI, deploy previews, team notifications, publishing unreviewed code), and it happens unattended. **Default off.** Selected per run at planning: a `**Push:** on` / `off — <reason>` field in `STATE.md` (like `Cleanup:` / `Security pass:`), shown on the plan summary at "Start chain?" and changeable there; set by a `--push` / `--no-push` invocation flag, with `RELAY_PUSH=on\|off` as a standing per-user default. `relay-git.sh push` honours it; off prints `push: skipped — push is off for this run; run: <the git push command>`. A missing field (runs planned before this) keeps the old behaviour. Unchanged: only a relay-created branch, never the owner's, never `--force`, a failed push never stops a run. |
| 2026-10-07 | **CI shape.** GitHub Actions on every push to any branch plus a manual trigger (no pull-request trigger: work merges locally, so it would only double-run). Matrix `ubuntu-latest` + `macos-latest`, `fail-fast: false`. **macOS runs the suites under the system bash 3.2 on purpose** (a PATH shim to `/bin/bash`): most Mac users have it, and Linux covers bash 5, so the pair spans both. `zsh` and `uv` are installed, and **pass counts are enforced**: `tests/run-all.sh` fails a suite whose count differs from `CLAUDE.md`'s `# expects:` line, because a missing `zsh`/`uv` skips checks by lowering the count rather than failing. `claude plugin validate` runs unpinned and without `--strict` (its only warning is `CLAUDE.md` at the plugin root, expected here). `.gitattributes` widened to `* text=auto eol=lf`. |
| 2026-10-07 | **A check that contradicts the plan: who decided decides.** A test run's security fix changed a `(planner)` out-of-scope line ("a `--force` replacement gets the umask mode") and nothing flagged it — no check window was ever shown `SPEC.md`'s scope, constraints or assumptions. Now **a fix that changes relay's own call** — a `(planner)`-tagged out-of-scope item or an `## Assumptions` item ("decisions taken without confirmation") — **is made and flagged**; **a fix that goes against the owner's call** — everything else in `SPEC.md` — **is deferred** to `FINDINGS.md` (`contradicts the plan: "<line>"`). Either way `RELAY_RUN_COMPLETE` carries a ⚠ line. Why the split: the planner's guesses were only "not corrected" at approval (weak consent), and a real flaw should not ship to protect a guess; the owner's explicit answers are never overridden by an unattended agent. The audit is unchanged. |
| 2026-10-08 | **Pre-flight on a new project: "not runnable yet" is the script's call, never the planner's.** On a greenfield or design-stage run most mandatory commands cannot run before phase 1 (no `package.json`, a script a later phase adds, `check-design.sh --verify` on screens not yet built), so pre-flight was always red and "skip pre-flight" became a planned step — the check meant nothing. `preflight.sh` now lists such a command as *not runnable yet* (with the phase that first uses it) instead of running it, from a fixed list: a package manager with no `package.json` or without the named script, a build tool with no manifest, a script path that does not exist, `check-design.sh --verify`. Rejected: letting the planner mark commands "later" — that is the same rubber stamp as the routine skip. A command whose prerequisites exist still runs, and a failure is still red. |
| 2026-10-08 | **The public repository.** relay's private development (0.8.0–0.11.0) stays private: the public repository is Supergoal's history up to the fork commit, then relay, keeping the original authors' commits intact. `tools/leak-check.sh`, run by CI on every push, keeps private paths, ids and addresses out of tracked files and commit metadata. |

---

## 1. Fork point and provenance

| | |
|---|---|
| Upstream | `https://github.com/robzilla1738/supergoal.git` |
| Fork commit | `ec2f6eb8eb3304a4ed32f1f18948a6c6198fcd67` (`v0.7.0-1-gec2f6eb` — the v0.7.0 tag plus one README-only commit) |
| Version | v0.7.0 (released 2026-06-06) |
| License | MIT, Copyright (c) 2026 Robert Courson |

**License obligation:** keep `LICENSE` with Courson's copyright line intact, with relay's line
beneath for its modifications. MIT permits modify / rename / redistribute / sell without further
restriction. The repository keeps Supergoal's commit history up to the fork commit; `upstream` is a
fetch-only remote for cherry-picks.

---
## 2. The problem

A single `/goal` session executes every phase inline, so context grows monotonically across
the whole run. The movez build (14 phases, ~139 Swift files, ~700 KB) exhausted its window
and required a manual `/clear` at a phase boundary, watched for by hand.

### Measured breakdown (movez, real run)

| Source | Volume | Est. tokens |
|---|---|---|
| Swift source written | ~700 KB / 139 files | **~175k** |
| Tool's own artifacts | ROADMAP 40 KB + specs 117 KB + PROTOCOL 12 KB | **~42k** |
| Snapshot images | 21 PNGs; specs mandate "the executor Reads each" | **~30k+** |
| Test output | 104 filtered lines x ~14 runs | **~20k** |
| Build output | `xcodebuild -quiet` | ~0 |

**Floor for a zero-rework run: ~270–300k tokens.** 175k of that is irreducible — you cannot
write a 139-file app without the source passing through a window. Real runs have rework.

### Consequence

Token-hygiene fixes (evidence-to-disk, snapshot diffing, slimmer audit input) are worth
60–80k. Against a 1M window that is a constant factor, not a fix. **Only splitting work
across multiple context windows makes consumption independent of build size.**

---

## 3. Architecture

Main `/goal` session becomes an **orchestrator**. Each phase executes in a **subagent with its
own context window**.

```
orchestrator (parent, under /goal)
  |- read STATE.md once -> current phase N
  |- assemble-brief.sh N            (one summary line; never reads the brief)
  |- dispatch subagent  ---->  [fresh window: reads brief, does the work, 3-strike retry inline,
  |   (async: end turn)           writes evidence + phases/phase-N.report.md, hands back]
  |- hand-back arrives  <----
  |- echo report blocks verbatim into parent transcript   (first, before any tool call)
  |- record-phase.sh N  -> STATE.md row/status/events/carryover, prints "-> next: ..."
  '- next phase
```

### The load-bearing constraint

`references/goal-format.md` is explicit: the `/goal` evaluator checks the condition **against
the parent transcript** and "does not independently run tools or read files." The end-state
condition requires one `RELAY_PHASE_DONE` per phase *in the transcript*.

A subagent's own window is invisible to the evaluator. **Fix:** the subagent's final report *is*
the marker blocks, and the orchestrator echoes them verbatim. The first end-to-end run showed
the evaluator also reads hand-back messages (it released despite one skipped echo), but the
echo stays mandatory — it is what the user and transcript tools see, and the hand-back reading
is not a documented guarantee.

### Measured (contextmeter build, 2026-09-16 — 7 phases, 1 audit round)

The original projection was ~2.5k orchestrator tokens per phase (~35k for 14 phases, ~150k for
60). Measured with contextmeter on its own build:

| Metric | Measured |
|---|---|
| Orchestrator setup (system prompt + tools + skill listing, `/goal` prompt, PROTOCOL/ROADMAP/STATE reads) | ~70k |
| Orchestrator growth per phase, steady state | 4.2k–4.7k |
| Orchestrator peak | 118.6k over 34 requests (one 20.8k outlier phase: a `TaskStop` echoing a 30k-char command) |
| Subagent peak windows | 109k (phase 1) → 256k (phase 7); audit 174k |
| Total processed | 23.9M tokens (2.95M orchestrator, 21M subagents) |

Where the ~4.5k per phase goes: the report arrives twice (hand-back ~1k tokens, echo ~0.7k),
inline `STATE.md` bookkeeping (~0.7k output, now one `record-phase.sh` call), brief assembly and
dispatch (~0.5k), and notification/hook attachments. Projection at the measured rate: ~135k for
14 phases, ~340k for 60 — still far inside a 1M window, so the orchestrator is not the binding
constraint.

The binding constraint is that a **single phase must fit one window**, and the measured peaks
show it is set by what the subagent *reads*, not what it writes (phase 7 changed 2 files and
peaked at 256k). That makes context management a phase-sizing and read-hygiene problem at plan
time (Stage 4 sizing, Stage 5 section-level citations) and at run time (brief §6 context hygiene).

### Around the phases

`record-phase.sh` is also the router. After a phase whose spec says `Review: yes`, the next
dispatch is a read-only correctness review of that phase's commits (findings → one review-fix
window). After the last phase come the tidy-up (`Cleanup: on`) and the security pass
(`Security pass: yes`), then the audit rounds (gaps → an audit-fix window, up to 3 rounds), then
the push (only when `Push: on`), then `RELAY_RUN_COMPLETE`. Every window that changes code commits
through `relay-git.sh` after a passing verify; the orchestrator never commits. Every dispatch
writes `phases/in-flight`, so after a crash or restart `recover.sh` can tell a live window (wait),
a dead one (re-dispatch), and a finished but unrecorded one (echo and record).

---

## 4. Carryover — already solved, do not reinvent

The obvious objection to cold-start subagents: phase 12 has not lived through phases 1–11.

**Every phase window writes a memory file at its boundary** (`PHASE-BRIEF.md` §6). Upstream's
movez run, which wrote them the same way, produced 17 files, 26 KB total (~6.5k tokens) — not narrative summaries, but distilled
portable invariants. Example (`movez-defer-never-reset-invariant.md`):

> "Exactly four things move `boutStartedAt`... Two traps this run hit: **Double credit** —
> sleeping twenty minutes *during* a break made `applyGap` credit the absence as a break
> **and** resolve the interrupted break... **A short lock must be a true no-op** — store the
> absolute due time at the moment of going away."

That is precisely what a cold executor needs and cannot recover from reading code. The entire
institutional knowledge of a 14-phase, 700 KB build in 6.5k tokens, generated automatically.

**relay re-points this output into each brief**, not a new memory system: `record-phase.sh` lists
each memory a window writes under `STATE.md`'s `## Carryover`, and `assemble-brief.sh` inlines them
into every later brief (how much to inline is §9 item 7).

### Second mechanism: planner-authored exemplars

Stage 5 (writing phase specs) runs with **full recon context** — the only moment anything sees
the codebase holistically. Have it bake per-phase exemplar pointers into each spec:

> "Follow the control pattern in `Sources/movez/UI/DesignSystem/Controls.swift`; match the
> test shape in `Tests/movezTests/SchedulerInterruptionTests.swift`."

Subagent reads two named files, inherits conventions. ~5k tokens, targets the drift risk
directly, and requires the warm planner to do nothing it is not already positioned to do.

---

## 5. Briefing bundle

| Component | Source | Size |
|---|---|---|
| Phase spec | `phases/phase-N.md` (exists) | ~9 KB |
| Subagent contract | `PHASE-BRIEF.md`, the dispatch's mode only | ~3 KB |
| Success criteria + prohibitions | `SPEC.md` | ~1–2 KB |
| Block formats | the mode's sections of `MARKERS.md` | ~1 KB |
| Carryover | accreted memory-writeback entries | ~4 KB at phase 14 |
| Repo map slice | graphify query (see §6) | ~4–5 KB |
| Failure log, baseline, commands | `STATE.md` excerpt | ~1 KB |

**~25 KB / ~7k tokens** to cold-start any phase.

**Measured (contextmeter, 7 phases):** 24 KB (phase 1) → 38 KB (phase 7), growing with carryover
(7 memories by phase 7); the audit brief was 24 KB. Each subagent `Read`s its brief whole, so the
brief is the single largest read in most windows. `assemble-brief.sh`'s summary line reports
brief and carryover KB; a 19-phase run showed the growth (§9 item 7).

Non-obvious upside: a warm context at phase 12 carries phase 3's abandoned approaches,
superseded file versions and dead ends. A distilled briefing carries none. Cold-start with
good carryover is plausibly *higher signal*, not merely cheaper.

---

## 6. Repo map: use graphify, do not write extractors

| | |
|---|---|
| Repo | `https://github.com/Graphify-Labs/graphify` |
| License | Dual Apache-2.0 / MIT — forkable |
| PyPI | `graphifyy` (double-y); CLI command is `graphify` |
| Version benchmarked | 0.9.61, with `tree-sitter-swift` 0.7.3 |
| Install | `brew install uv && uv tool install graphifyy` |

### Benchmark run 2026-09-12 against a copy of movez `Sources/` + `Tests/`

```
graphify update . --no-cluster
  -> 139 Swift files, 10 workers
  -> 2,445 nodes, 6,566 edges
  -> 1.5 seconds
```

**Per-phase graph rebuilds are effectively free.**

### Swift extension resolution: PASSES

This was the decisive risk. movez splits one type across seven files
(`Scheduler.swift`, `Scheduler+Actions.swift`, `+Sleep`, `+Idle`, `+Hours`, `+Pause`,
`+Suppression`). Graphify resolves all of them to the declaring type:

```
node: Scheduler  (Sources/movez/Scheduler/Scheduler.swift:L8, _callable_class: true)
  87 outgoing edges = 82 'method' + 5 'references'
  methods by defining file:
    22 Scheduler.swift      9 Scheduler+Idle.swift
    19 Scheduler+Actions    7 Scheduler+Hours.swift
    13 Scheduler+Sleep      7 Scheduler+Pause.swift
                            5 Scheduler+Suppression.swift
```

For contrast, a hand-written regex extractor on that same directory returned **377 lines
against a true count near 83**. Tree-sitter parses the grammar; regex never will.

### Schema

- Node: `id`, `label`, `file_type`, `source_file`, `source_location` (`L8`), `_callable`,
  `_callable_class`, `_origin`
- Edge: `source`, `target`, `relation` (`imports` / `contains` / `method` / `references`),
  `context`, `confidence` (`EXTRACTED` / `INFERRED` / `AMBIGUOUS`), `source_file`,
  `source_location`, `weight`
- Top-level: `nodes`, `links`, `directed`, `extracted_sources`, `failed_sources`

Every fact carries a file:line citation. The `confidence` field is real — it is what makes
tiered budget-shedding (§7) possible.

### No LLM, no network

`update --no-cluster` is pure local AST extraction. The **clustering / report /
community-naming** path is the only part that wants an API key (it prints a
`set GEMINI_API_KEY` tip). Skip it. Three reasons this matters:

- **Privacy** — source never leaves the machine
- **Cost** — rebuilding every phase would otherwise be a recurring API bill
- **Determinism** — same code always yields the same graph, so phase 12 sees the world the
  way phase 11 did. An LLM naming step could silently drift between phases.

Cost of skipping: `GRAPH_REPORT.md` and human-friendly cluster names. Not needed for
briefings.

### Retrieval tuning is where the care goes

`graph.json` is **3.2 MB** (~800k tokens) plus a 4.1 MB AST cache. It cannot be injected.
And naive retrieval is worse than useless:

| Approach | Result |
|---|---|
| 2-hop, substring seed on "Scheduler" | 1,403 nodes / 3,365 edges — **~284k tokens** |
| 1-hop, **exact-label** seed, projected to `label + file:line` | 88 nodes — **~1,457 tokens** |

Tuned slices, same method:

```
Scheduler         88 nodes  ~1,457 tokens
OverlayViewModel  42 nodes  ~  561 tokens
HistoryStore      19 nodes  ~  279 tokens
RoutineBuilder    18 nodes  ~  277 tokens
```

A briefing seeded on 5–6 types from the phase spec lands at **~4–5k tokens**.

**Measured with relay's `map-slice.py`** (2026-09-12, graphify 0.9.61, movez including tests,
2,829 nodes / 7,104 edges): Scheduler **824** tokens (grouped by file; all seven
`Scheduler+*.swift` files present), OverlayViewModel 527, HistoryStore 513 (its used-by list
includes test call sites), RoutineBuilder 206. Six seeds: **3,692 tokens** under the 5,000
default. ~60 ms per query; graph build ~3 s.

**Design consequence:** graphify is a *build-time* dependency only. Query time is a
stdlib-only Python script reading a JSON file — no graphify binary, no third-party packages.
It runs via `uv run --no-project` (present wherever graphify was installed the recommended
way), else `python3`, else degrades to file-name matches. Do not make dispatch depend on the
graphify binary.

---

## 7. What to port from GSD (template, not dependency)

`get-shit-done/bin/lib/graphify.cjs` at `gsd-build/get-shit-done` tag **`v1.42.3`** (577 lines)
already solves the retrieval layer. Line numbers below refer to that version.

Read it; port the approach; keep the fork standalone. Do **not** take a runtime dependency on
GSD — the 1.x line is archived.

| Function | Line | Why it matters |
|---|---|---|
| `seedAndExpand` | 218 | Seed on term, expand N hops. Default `maxHops = 2` — **too loose**, see §6 |
| `applyBudget` | 267 | Caps result at a token budget, estimating `JSON.stringify(x).length / 4`. Sheds edges **by confidence tier** — `AMBIGUOUS` first, then `INFERRED`, keeping `EXTRACTED` longest. Prunes unreachable nodes but always keeps seeds. Reports `[N edges omitted, M nodes unreachable]` |
| `graphifyBuild` | 494 | Returns `action: 'spawn_agent'` — delegates the noisy build to a subagent. Same pattern we want |
| `graphifyDiff` / `writeSnapshot` | 435 / 530 | Snapshots the graph per build so structural change between phases is diffable. Candidate carryover input |
| `graphifyQuery` | 314 | Never calls the CLI — reads `graph.json` with `fs`. Confirms the build/query split |

Also worth copying: the `COMMIT_HASH_RE` fence (hostile `graph.json` values cannot smuggle
`--upload-pack=` into a `git` argv), and typed failure reason codes over stderr-grepping.

### GSD licensing — resolved 2026-09-12

- Installed copies carry no license file (stripped install artifacts), so provenance was traced
  upstream instead.
- **v1.42.3 came from `gsd-build/get-shit-done`** (archived; tag `v1.42.3` →
  `7dfeb7ad`). Its `LICENSE` is **MIT, Copyright (c) 2025 Lex Christopherson**. (GitHub's
  license metadata reports "none", but the file is plain MIT.)
- The successor `open-gsd/gsd-core` is also MIT, Copyright (c) 2026 Open GSD. Not our source.
- **Decision: reimplement, do not copy.** `map-slice.py` is written fresh from the approach.
  MIT does not strictly require attribution for that, but credit anyway — a header comment in
  `map-slice.py` and a README credits line naming `gsd-build/get-shit-done` v1.42.3 and Lex
  Christopherson. If any code is ever lifted verbatim, ship the full MIT notice with it.

---

## 8. Naming

| Slot | Value |
|---|---|
| Plugin name (command namespace) | `relay` |
| Skill name (directory + frontmatter) | `goal` |
| Invocation | `/relay:goal` |
| Artifact base dir | `.relay/` |
| Env vars | `$RELAY_DIR` / `$RELAY_BASE` / `$RELAY_ROOT`; `$RELAY_PUSH` (the user's push default) |
| Transcript markers | `RELAY_PHASE_START` / `_VERIFY` / `_DONE`, `RELAY_RUN_COMPLETE` |
| Install | Plugin marketplace only (or `claude --plugin-dir <clone>`). No standalone skill, no Codex |

The plugin and the skill deliberately differ. `supergoal:supergoal` stutters because they share a
name; `relay` + `goal` keeps the goal lineage in the invocation and leaves room for a second skill
later.

**Why plugin-only:** (a) a standalone copy of `skills/goal/` would register as bare `/goal` and
collide with the built-in `/goal` that Stage 7 hands off to — the plugin namespace is what makes
`goal` a safe skill name; (b) marketplace installs get versioned updates, manual copies never do;
(c) with Codex dropped, the manual-copy path has no remaining purpose. Upstream's locate block
probed only standalone-install paths, so under a marketplace install `dirname ""` returned `.` and
`$SUPERGOAL_DIR/scripts/...` silently resolved against the user's project; relay uses
`${CLAUDE_SKILL_DIR}`, which Claude Code substitutes with the skill's directory, plus an existence
guard.

**Markers are renamed only with one global replace.** `validate-phase.sh` anchors on
`RELAY_PHASE_START`, and the literal `/goal` end-state condition appears in both
`references/goal-format.md` and `SKILL.md` Stage 7. A partial rename breaks a run silently.

**The CHANGELOG is not renamed below the fork point.** Rewriting "Supergoal 0.7.0 fixed
concurrent-run isolation" into relay's name would misattribute Courson's work; his entries stay
intact under a fork-point header, and relay's versioning continues above it.

**Why `relay`:** the architecture *is* a relay — sequential legs, each run by a fresh runner, with
a baton (the carryover) passed at each exchange. The name describes the mechanism rather than
decorating it, and it is five characters to type. Rejected: anything with `ultra` (collides
conceptually with existing Claude Code commands) and `goalpost` ("moving the goalposts" means scope
creep — precisely what the phase protocol forbids).

---

## 9. Open questions and risks

1. **Convention drift** is mitigated, not eliminated. Exemplars + the final audit (which
   re-verifies against the original ROADMAP and `SPEC.md` using repo ground truth) are the
   backstop, with the per-phase review and the tidy-up in between.
2. **Phase sizing is load-bearing.** A phase too large for one window fails the whole premise.
   Stage 4 estimates files touched per phase (`Estimated files:`) and splits above 12 or states
   why; `validate-phase.sh` warns (`RELAY_PHASE_FILE_LIMIT`). The cap is interim — recalibrate
   from measured per-phase peaks.
3. **`map-slice.py` language coverage.** Graphify handles 37+ languages, but the *projection*
   logic may need per-language tuning. It uses the graphify schema as-is, which is
   language-neutral.
4. **Total token cost rises even as per-window cost falls** — N cold recons instead of one warm
   context. **Measured:** 23.9M processed for 7 phases + 1 audit round (21M in subagents, 1.6M–3.7M
   each). Acceptable trade; read hygiene (item 6) is the main lever.
5. **Subagents cannot ask the user questions.** Failures escalate to the orchestrator, which
   pauses at the boundary.
6. **Reads dominate subagent windows.** The first run peaked at 109k–256k, with only 2–16 of 18–46
   Bash calls per subagent going through `run-logged.sh`; whole-file `cat`s of source, tests and
   evidence files made up the rest. Brief §6's context-hygiene rules and Stage 5's section-level
   citations help but are not followed reliably (a 19-phase run still peaked at 276–330k in its
   heaviest windows). The next lever is structural, not more prose.
7. **Carryover grows the brief linearly.** Every window gets every memory written so far: on a
   19-phase run, 30 memories (52 KB) grew phase briefs from 28 KB to 85 KB, and check windows got
   them too. Options: choose carryover by the phase's dependencies and map seeds, give check
   windows names and descriptions only, warn over a size.
8. **Orchestrator bookkeeping drift.** The first run skipped one echo while hand-editing
   `STATE.md`. Mitigated by echo-first ordering and `record-phase.sh`; `tools/check-run.py` is the
   regression check on a real run.

---

## 10. Development loop

```bash
claude --plugin-dir <path-to-your-relay-clone>
```

A `--plugin-dir` plugin takes precedence over an installed plugin of the same name, so you can
iterate on relay while the marketplace version stays installed. The repo root is already the
plugin root (`.claude-plugin/plugin.json`, `"skills": "./skills/"`), so it loads as-is.
`/reload-plugins` picks up edits without restarting. Run test tasks from a scratch project —
`/relay:goal` creates `.relay/` in the working directory.

### Platform notes

- **Claude Code (2.1.273 and later) runs `Agent` subagents in the background.** The tool result
  is a launch notice; the final report arrives as a user-role message `<agent-message
  from="<id>">` with a `[Subagent hand-back]` preamble and every report line indented two spaces;
  a `<task-notification>` "Agent … finished" follows (possibly more than once). While background
  work runs, `/goal` defers evaluation and injects "Goal check-in: background work still running"
  notices listing each task as `subagent` or `shell`. `tasks/<id>.output` for a subagent is a
  symlink to its transcript.
- **A Bash call that exceeds 120 s is moved to the background**, not killed. One long command
  (an evidence heredoc plus a memory write) stayed "running" for 70 minutes until the
  orchestrator stopped it. Keep Bash calls short and write files with the Write tool.
- **The auto-mode classifier denies reads of real transcripts** (`head`, `grep`, value dumps of
  `~/.claude/projects/**/*.jsonl`) as "[PII Data Handling]". Any run whose work touches user data
  will hit this; the brief tells subagents to record the denial as an assumption and proceed on
  documented shapes.
- **graphify 0.9.61 collapses symbols whose labels normalize to the same node id.** The id is the
  lowercased label with non-alphanumerics stripped, so `Options` (class) and `_options()`
  (function) in one file both map to `pkg_<mod>_options`: only the class keeps a node, the
  function's edges become a self-loop on the class, and the function's docstring survives as an
  orphaned `rationale_for` node pointing at the class. Python factory functions hit this
  constantly; any language graphify extracts by AST can. Seeds therefore need a plan-time check
  (`check-seeds.sh`, `references/phase-design.md`), and `map-slice.py` names the surviving symbol
  to seed instead.
- **Build a scratch graph without touching a repository** via
  `GRAPHIFY_OUT=<scratch>/graph graphify update . --no-cluster`.
