# AGENTS.md

Authoritative project doc. Any agent opening this repo should be able to read this file alone and understand the project, where to make changes, and what conventions to follow. For the architecture and the decisions behind it, read `DESIGN.md`.

## What this repo is

**Relay** is a Claude Code plugin that turns a vague build request into a deeply-planned, autonomously-executed `/goal` run with built-in retry, fix-spec recovery, per-phase memory writeback, and a final audit pass that re-validates the work against the original plan.

- Slash command: `/relay:goal <task>` (plugin `relay`, skill `goal`)
- Central mechanism: produces one ready-to-paste `/goal` command. The user pastes it once; the rest is autonomous.
- Works on: Claude Code only, installed as a plugin (marketplace or `claude --plugin-dir`). No Codex support; no standalone skill install.
- Fork of [Supergoal](https://github.com/robzilla1738/supergoal) v0.7.0 (Robert Courson, MIT). The fork's goal is per-phase context isolation — see `DESIGN.md`.
- Public install: see `README.md`.

## Repo layout

```
relay/
├── .claude-plugin/
│   ├── marketplace.json        Catalog Claude Code reads when added as a marketplace
│   └── plugin.json             Plugin manifest (name, version, description, skills path)
├── .github/workflows/ci.yml    CI on every push: plugin validation, template checks, tests/run-all.sh on Linux (bash 5) and macOS (bash 3.2), and the leak check.
├── .gitattributes              LF for every text file (CRLF breaks shebangs and the parsed templates/fixtures); PNG/ZIP binary.
├── .gitignore                  Editor/OS junk + .relay/ artifact dirs
├── AGENTS.md                   This file. Authoritative project doc.
├── CLAUDE.md                   Claude Code-specific working rules. Points at this file.
├── DESIGN.md                   Architecture brief and decisions log.
├── CHANGELOG.md                Per-version release notes. Keep-a-Changelog format, SemVer. Pre-fork entries are upstream history.
├── LICENSE                     MIT.
├── README.md                   Public-facing: what it is, install, use, Mermaid flow charts.
├── skills/goal/
│   ├── SKILL.md                The skill itself (planner stages). ~1,100 lines; the `/goal`-session loop lives only in templates/PROTOCOL.md.
│   ├── references/             Progressive-disclosure docs the agent reads when needed.
│   │   ├── planning-depth.md          What makes a plan deep enough to hand off.
│   │   ├── phase-design.md            How to slice phases (adaptive count, no cap).
│   │   ├── research.md                Stage 2.6: plan-time research — why once and here, good questions, researcher contract.
│   │   ├── design-stage.md            Stage 2.7: design package contract, fidelity criteria, edge cases.
│   │   ├── goal-format.md             /goal mechanics; who prints the transcript blocks (formats: templates/MARKERS.md).
│   │   └── repo-state-comparison.md   The one comparison strategy (complete working tree vs baseline).
│   ├── scripts/                Bash scripts the planner/executor run during stages.
│   │   ├── detect-env.sh       Greenfield env recon.
│   │   ├── detect-stack.sh     Brownfield stack/framework detection.
│   │   ├── summarize-repo.sh   Compressed repo map.
│   │   ├── claim-run.sh        Atomically claims a unique per-run dir under .relay/ (concurrent-run isolation). Tested by tests/claim-run.test.sh.
│   │   ├── active-runs.sh      Stage 0: lists runs in this tree that are not COMPLETE (a script so zsh's no-match glob error can't break it). Tested by tests/active-runs.test.sh.
│   │   ├── stale-memories.sh   Stage 0: lists memories pointing at a deleted .relay/ run. Tested by tests/stale-memories.test.sh.
│   │   ├── memory-dir.sh       Stage 0: the repository's memory dir (shared by its worktrees and subdirectories), with fallbacks. Tested by tests/memory-dir.test.sh.
│   │   ├── edge-probe.py       Raises only the edge categories that apply to each SPEC.md success criterion's shape (closed 8-item taxonomy). Tested by tests/edge-probe.test.sh.
│   │   ├── validate-spec.sh    SPEC.md content gate: measurable criteria, Acceptance lines, no reasonless dismissals. Tested by tests/validate-spec.test.sh.
│   │   ├── resume-line.sh      Prints the /goal that resumes a blocked run from the phases that remain. Copied into the run dir at Stage 7. Tested by tests/resume-line.test.sh.
│   │   ├── preflight.sh        Stage 6.5 in one call: runs the mandatory commands, checks the tree, logs to STATE.md, prints PREFLIGHT_GREEN / _RED (planner-only). Tested by tests/preflight.test.sh.
│   │   ├── relay-git.sh        Every git write a run makes: preflight (dirty tree blocks), branch (relay/<run-id> from the default branch), commit (per phase / fix / audit fix, trailer-tagged), push (once after the audit, relay-created branches with Push: on only — off by default, prints the command; always exits 0). Copied into the run dir at Stage 7. Tested by tests/relay-git.test.sh.
│   │   ├── recover.sh          After an interruption: settles the dispatch that was in flight (dead → re-dispatch, live → wait, finished → record). Copied into the run dir. Tested by tests/recover.test.sh.
│   │   ├── repo-state.sh       Complete working-tree-vs-baseline comparison (audit + cleanliness). Copied into the run's .relay/<run-id>/ dir at Stage 7.
│   │   ├── run-logged.sh       Runs a command with full output to a log; prints only exit code + short tail. Copied into the run dir at Stage 7. Tested by tests/run-logged.test.sh.
│   │   ├── build-graph.sh      Builds/refreshes the run's graphify code graph at <run-root>/graph/ (optional; always exits 0). Tested by tests/build-graph.test.sh.
│   │   ├── map-slice.sh        Launcher: picks uv/python3, falls back to file-name matches. Tested by tests/map-slice.test.sh.
│   │   ├── map-slice.py        Token-budgeted map slice of named symbols from graph.json (stdlib Python).
│   │   ├── check-seeds.sh      Checks each phase's Map seeds will exist when the phase runs (planner-only). Tested by tests/check-seeds.test.sh.
│   │   ├── check-research.sh   Validates Stage 2.6 research answers; --digest prints what the planner reads; --only <slug> is the researcher's self-check (planner-only). Tested by tests/check-research.test.sh.
│   │   ├── prepare-design.sh   Stage 2.7d: unzips/lifts the export the user put in design/ and commits design/ only (planner-only). Tested by tests/prepare-design.test.sh.
│   │   ├── check-design.sh     Verifies the committed design/ package; --criteria drafts fidelity criteria + edge rows; --verify checks the build (copied to the run root at Stage 7). Tested by tests/check-design.test.sh.
│   │   ├── assemble-brief.sh   Expands PHASE-BRIEF.md into a subagent's brief (spec + carryover + map slice + state + formats). Copied into the run dir at Stage 7. Tested by tests/assemble-brief.test.sh.
│   │   ├── record-phase.sh     Validates a subagent's report file and applies every STATE.md change for its outcome; logs no-report dispatches. Copied into the run dir at Stage 7. Tested by tests/record-phase.test.sh.
│   │   └── validate-phase.sh   Sanity-checks a phase spec has required markers; warns on sizing / exemplar gaps.
│   └── templates/              Files the planner copies into a run's `.relay/<run-id>/` dir.
│       ├── SPEC.md             The run's agreed statement of intent (Stage 2.5); the audit re-verifies against it. Optional in every reader.
│       ├── RESEARCH-BRIEF.md   Stage 2.6 researcher brief: one question, spec context, source rules, answer format.
│       ├── DESIGN-BRIEF.md     Stage 2.7 brief for Claude Design or any design tool (delivered by clipboard); ends in the package contract.
│       ├── ROADMAP.md          Phase plan with dependencies.
│       ├── STATE.md            Live progress file.
│       ├── phase-goal.txt      Phase spec skeleton (work, criteria, evidence, commands).
│       ├── PROTOCOL.md         The orchestrator's manual: async dispatch loop, report validation, echo first, record via record-phase.sh, goal check-ins, audit dispatch.
│       ├── PHASE-BRIEF.md      The subagent contract, mode-fenced (phase / fix / audit / audit-fix): how to work (context hygiene, evidence format), failure protocol, report contract.
│       └── MARKERS.md          Exact format of every transcript block, grouped Phase / Failure / Audit. Copied to <run-root>/MARKERS.md at Stage 7.
├── tools/                      Repo-only tools.
│   ├── check-run.py            Checks a finished run's transcripts against the orchestrator protocol.
│   ├── run-report.py           One digest of a finished run: where it struggled, what the audit could not check, protocol verdict.
│   └── leak-check.sh           Fails on a private path, id or address in a tracked file or a commit after the fork point. Run by CI.
└── tests/                      Repo-only (not shipped in the plugin payload).
    ├── run-all.sh              Runs every suite; fails any whose pass count differs from CLAUDE.md's pre-ship block (catches skipped zsh/uv checks). What CI runs.
    ├── claim-run.test.sh       Fixture tests for claim-run.sh (incl. the concurrent-claim race).
    ├── memory-dir.test.sh      Fixture tests for memory-dir.sh (main checkout, subdirectory, linked worktree, outside git, fallbacks, zsh).
    ├── validate-phase.test.sh  Fixture tests for validate-phase.sh (structure, mandatory-command and criterion-count content checks, template still passes).
    ├── validate-spec.test.sh   Fixture tests for validate-spec.sh (measurable predicates, Acceptance lines, reasonless dismissals, advisory tier).
    ├── edge-probe.test.sh      Fixture tests for edge-probe.py (shape classification, the relevance filter, closed taxonomy, warnings). Needs python3.
    ├── resume-line.test.sh     Fixture tests for resume-line.sh (remaining-phase scoping, audit-only variant, read-only, COMPLETE refusal, uncommitted-work and wrong-branch warnings).
    ├── relay-git.test.sh       Fixture tests for relay-git.sh over throwaway repos with local bare remotes (dirty-tree rules, branch choice, trailers, refusals, hook failure, wrong-branch refusal, every push failure incl. a hang and a hanging helper's child).
    ├── check-run.test.sh       Fixture tests for tools/check-run.py's git rules (writes by role, read-only forms, the post-audit push). Needs python3.
    ├── preflight.test.sh       Fixture tests for preflight.sh (union + dedup, red tail and login hint, dirty tree, --bypass, STATE.md event, zsh).
    ├── recover.test.sh         Fixture tests for recover.sh + the in-flight file (live/dead/unknown process, finished report, commit-then-kill, every mode, zsh).
    ├── repo-state.test.sh      Fixture tests for repo-state.sh over throwaway git repos.
    ├── run-logged.test.sh      Fixture tests for run-logged.sh (tail length, exit codes, 5000-line output).
    ├── map-slice.test.sh       Fixture tests for map-slice.py + launcher (projection, shed-order sweep, fallbacks).
    ├── build-graph.test.sh     Fixture tests for build-graph.sh against a stub graphify.
    ├── assemble-brief.test.sh  Fixture tests for assemble-brief.sh (every mode, placeholders, fences, carryover, slice).
    ├── record-phase.test.sh    Fixture tests for record-phase.sh (every outcome, idempotence, no-report, real reports from end-to-end and failure-path runs).
    ├── leak-check.test.sh      Fixture tests for tools/leak-check.sh (each private shape, placeholder addresses, commit emails after the base).
    ├── fixtures/map-graph.json Small graph in graphify 0.9.61's schema.
    └── fixtures/record-phase/  Real subagent reports from end-to-end runs on contextmeter and its deliberately broken failure-path runs.
```

## What ships vs what doesn't

- **Ships to consumers** (via marketplace install or a `--plugin-dir` clone): everything under `skills/goal/` — including `scripts/repo-state.sh`, `scripts/run-logged.sh`, and `scripts/claim-run.sh` (the per-run namespace claimer) — the `/goal` session needs `PROTOCOL.md`, `PHASE-BRIEF.md`, `MARKERS.md`, `assemble-brief.sh`, `record-phase.sh`, `repo-state.sh`, `relay-git.sh`, `run-logged.sh`, `build-graph.sh`, `map-slice.sh`, and `map-slice.py`, all copied into the run's `.relay/<run-id>/` dir at Stage 7. graphify itself is an optional user install, never shipped. The plugin manifest at `.claude-plugin/plugin.json` declares `skills: "./skills/"`.
- **Repo-only** (not part of the plugin payload): `README.md`, `CHANGELOG.md`, `LICENSE`, `AGENTS.md`, `CLAUDE.md`, `DESIGN.md`, `.gitignore`, `.gitattributes`, `.github/`, `tests/`, `tools/`. Docs / hygiene / fixtures.
- **Marketplace entry** at `.claude-plugin/marketplace.json` is read by Claude Code when a user runs `/plugin marketplace add ...` against this repo. Points at the plugin at `./`.

## How the skill works (one paragraph)

When invoked, the skill runs Stages 0–6.5 (preload memory, detect tools, restate and classify, recon, **the Stage 2.5 specification interview — five mandatory rounds scored against four ambiguity dimensions, plus edge and prohibition probes, producing `SPEC.md`**, deep think, decompose into N phases, write per-phase specs to the run's namespaced `.relay/<run-id>/` dir, **self-critique + plan review with revision menu**, **pre-flight smoke check against the deduplicated mandatory commands**). At Stage 7 it captures `Baseline ref:` and `Memory dir:` into `STATE.md`, copies the orchestrator manual, brief template, marker formats, and helper scripts into the run dir, and prints a ready-to-paste `/goal` command. The user pastes it. The `/goal` session is an **orchestrator**: per phase it runs `assemble-brief.sh` (spec + executor contract + carryover memory + precomputed map slice + state excerpt + block formats → `phases/phase-N.brief.md`), dispatches a `general-purpose` subagent to execute the brief in its own context window (asynchronously — the report arrives later as a hand-back message), **echoes the subagent's marker blocks verbatim** into the transcript first, then records the report with `record-phase.sh`. Inside the subagent: open the exemplars and map slice → do the work, reading by range and running commands through `run-logged.sh`, recording proof in `phases/phase-N.evidence.md` → compact RELAY_PHASE_VERIFY including cleanliness counts → memory writeback → write the report to `phases/phase-N.report.md` and return the same marker blocks. Failures are hybrid 3-strike: auto-retry inside the phase window, then a fix spec executed by a fresh subagent, then `FAILURE_HANDOFF`. **Checks (0.10):** `record-phase.sh` routes a phase marked `Review: yes` to a read-only correctness review in its own subagent (findings → one review-fix window), and after the last phase to a tidy-up pass (`Cleanup: on`) and a security pass (`Security pass: yes`); none of them can block the run — what cannot be fixed goes to `FINDINGS.md`. `--lean` turns all three off. After the last phase and its checks, the **final audit** — one subagent per round — re-reads the original `ROADMAP.md`, re-runs the deduplicated mandatory commands, spot-checks every acceptance criterion, **diff-checks every declared deliverable against `Baseline ref`**, **re-verifies every `SPEC.md` success criterion and prohibition**, and writes `audit-fix-<round>.md` for any gaps, executed by a fresh subagent (up to 3 audit rounds). Only after `AUDIT_COMPLETE` does the orchestrator print `RELAY_RUN_COMPLETE` — with an audit-coverage line that warns when more than 30% of checks were `trust-prior-verify`.

## Making changes

### Editing the skill content

Edit `skills/goal/SKILL.md` or the files under `references/`, `scripts/`, `templates/`. The user-visible behavior is driven by what's in `SKILL.md` plus what the planner reads from `references/` and writes from `templates/`.

After editing:

1. **Validate** — `claude plugin validate .claude-plugin/plugin.json`, `claude plugin validate .claude-plugin/marketplace.json`, and `claude plugin validate skills`.
2. **Validate the templates and run the suites** — `bash skills/goal/scripts/validate-phase.sh skills/goal/templates/phase-goal.txt`, `bash skills/goal/scripts/validate-spec.sh skills/goal/templates/SPEC.md`, then `bash tests/run-all.sh` (every suite, each checked against its expected count in `CLAUDE.md`'s pre-ship block — update the count when you add tests) and `bash tools/leak-check.sh`.
3. **Bump the version** in `.claude-plugin/plugin.json` (patch for backwards-compatible fixes, minor for new features, major for breaking changes). The marketplace cache only refreshes when this field changes.
4. **Add a CHANGELOG entry** at the top of `CHANGELOG.md`, Keep-a-Changelog format.
5. **Commit, push, tag** with the new version: `git tag -a vX.Y.Z -m "..."`, `git push origin vX.Y.Z`.
6. **Update this file's "Working state" heading** to the new version.

### Editing READMEs / docs only

No version bump needed. Just commit + push. Docs don't affect what install consumers get.

### Conventions

- **Names**: plugin `relay` (command namespace), skill `goal` (directory + frontmatter `name:`), invocation `/relay:goal`, artifact dir `.relay/`, env vars `RELAY_DIR` / `RELAY_BASE` / `RELAY_ROOT` (+ `RELAY_PUSH`, the user's push default), transcript markers `RELAY_*`. The plugin and skill names differ on purpose — a skill named `goal` is only safe inside the plugin namespace. Pre-fork CHANGELOG entries keep the `supergoal` names.
- **Versioning**: SemVer, continuing upstream's line (first relay release is 0.8.0). Plugin manifest `version` field is the source of truth. README and CHANGELOG must match.
- **CHANGELOG**: every version gets an entry. Mention what changed, what's new, what's removed. Migration steps if breaking.
- **Co-Authored-By trailers**: commits made by Claude carry a `Co-Authored-By` trailer. Upstream (pre-fork) history is never rewritten.
- **Remotes**: `origin` is `github.com/mack5imal/relay`; `upstream` is Supergoal, fetch-only (push URL `DISABLED`).
- **No `.DS_Store`**: gitignored. If one slips in, remove it.

## Install flows

### For a new user

```text
/plugin marketplace add https://github.com/mack5imal/relay.git
/plugin install relay@relay
/reload-plugins
```

The `owner/repo` shorthand (`/plugin marketplace add mack5imal/relay`) also works, but only if the user has GitHub SSH keys configured — the CLI defaults to SSH cloning for that shorthand.

### For local development on this repo

Source of truth is your clone of the repo. Load it directly — no commit, push, or version bump needed:

```bash
claude --plugin-dir <path-to-your-relay-clone>
# edit files, then /reload-plugins in that session
```

Run test tasks from a scratch project — `/relay:goal` creates `.relay/` in the working directory. To test the marketplace path after pushing a version bump:

```bash
claude plugin marketplace update relay
claude plugin update relay@relay
# Then /reload-plugins in a Claude Code session
```

## Transcript markers (load-bearing)

### Inside the `/goal` session

Named blocks that must appear in the `/goal` session's transcript. The host's `/goal` evaluator + the user both read them. **Subagents print them as their report; the orchestrator echoes each report verbatim into its own message text, before recording anything** — a subagent's report arrives as an asynchronous hand-back message, not as the orchestrator's own text, and the end-state condition is written against the echoes.

- `RELAY_PHASE_START` — once per phase, at the start. Metadata only.
- `RELAY_PHASE_VERIFY` — once per phase, before DONE. **Compact (0.8):** one pass/fail line per criterion, with the evidence in `<run-root>/phases/phase-N.evidence.md`; engineering checks; **v0.6: `Cleanliness:` section** with grep counts vs `Baseline ref` (debug prints, session TODO/FIXME, dead imports). **v0.6.1: those counts run against the complete working tree via `bash <run-root>/repo-state.sh added-lines <Baseline ref>`, so uncommitted + untracked work is included — not just commits.** Non-zero cleanliness counts trigger 3-strike unless the phase spec declares `Cleanliness override:`.
- `MEMORY_SAVED` — once per phase, between VERIFY and DONE. `<name>` (comma-separated if several) or `none`.
- `RELAY_PHASE_DONE` — once per phase, final block. Names the phase's evidence file. **No block claims anything about `STATE.md`**: the orchestrator echoes first and records after.
- `FAILURE_PROBE` / `FAILURE_ESCALATE` / `FAILURE_HANDOFF` — 3-strike phase-criterion recovery. **0.8: hybrid** — probe + retry inside the phase subagent; `FAILURE_ESCALATE` returns with a fix spec for a fresh subagent; `FAILURE_HANDOFF` comes from the fix subagent (or the orchestrator after two no-report dispatches).
- `REVIEW_START` / `REVIEW_CLEAN` / `REVIEW_FINDINGS` / `REVIEW_FIX`, `CLEANUP_START` / `CLEANUP_DONE`, `SECURITY_START` / `SECURITY_CLEAN` / `SECURITY_FINDINGS` / `SECURITY_FIX` — **0.10:** the checks around the build (`## Review blocks` in `MARKERS.md`). None of them ever hands off.
- `AUDIT_FIX` — **0.8:** the one block an audit-fix subagent reports (gaps addressed / unresolved); the next audit round decides.
- `AUDIT_START` / `AUDIT_VERIFY` (**0.8: compact — one line per phase with criteria and deliverable counts plus one line per failure; full results in `<run-root>/phases/audit-<round>.evidence.md`. v0.6: deliverables checked vs `Baseline ref`; v0.6.1: that check compares the complete working tree via `bash <run-root>/repo-state.sh deliverable`, not a `..HEAD` commit range, and detects untracked deliverables**) / `AUDIT_GAPS` / `AUDIT_COMPLETE` (**v0.6: includes `Audit coverage:` line**) / `AUDIT_HANDOFF` — final audit pass.
- `RELAY_RUN_COMPLETE` — only after `AUDIT_COMPLETE`. Run is done. **v0.6: prepends a `⚠ Audit coverage: …` warning banner when trust-prior is > 30% of total checks.**

The `/goal` end-state requires `RELAY_RUN_COMPLETE` preceded by `AUDIT_COMPLETE` and one `RELAY_PHASE_DONE` per phase, with no `FAILURE_HANDOFF` or `AUDIT_HANDOFF`.

(Version tags like "v0.6" / "v0.6.1" above refer to upstream Supergoal releases where the feature landed.)

### Inside the planner session (v0.6)

Before the user pastes `/goal`, the planner emits two additional named blocks the user sees in Stage 6/6.5:

- `Self-critique:` — printed inside the Stage 6 plan-review summary (Stage 6a). 1–3 findings (falsifiability of criteria, phase atomicity, weakest dependency) or `clean`. Falsifiability issues are rewritten in place in the phase specs before the summary prints — so the user sees the post-critique version.
- `PREFLIGHT_GREEN` / `PREFLIGHT_RED` — Stage 6.5 output after running the deduplicated mandatory commands once. `PREFLIGHT_RED` re-enters Stage 6 with a "Skip pre-flight, dispatch anyway" option for cases where the broken baseline is exactly what phase 1 will fix.

These are not part of the `/goal` end-state — the `/goal` session hasn't started yet at this point — but they're load-bearing for plan quality.

### Other v0.6 state

- **`Baseline ref:`** in `<run-root>/STATE.md` is captured at Stage 7 dispatch from `git rev-parse --verify -q HEAD 2>/dev/null || echo "no-git"` (a repository with no commits gets an empty first commit from `relay-git.sh branch` first, so it has one). The audit's deliverable check and the cleanliness greps both compare the **complete working tree** (committed + staged + unstaged + deleted + untracked) against it via `scripts/repo-state.sh` — **not** a `<Baseline ref>..HEAD` commit range, which would miss every uncommitted change. The single documented strategy lives in `references/repo-state-comparison.md`.

- **`Memory dir:`** in `<run-root>/STATE.md` is the absolute memory directory detected at Stage 0 (Claude Code keeps one per git repository, shared by its worktrees: `~/.claude/projects/<main checkout, non-alphanumerics → ->/memory`; `scripts/memory-dir.sh` derives it). Memory writeback goes there; `## Carryover` in the same file lists the memory files written this run.

Full format spec: `skills/goal/templates/MARKERS.md` (copied into every run root); `/goal` mechanics: `skills/goal/references/goal-format.md`.

## Gotchas

- **Slash commands fire only from user input.** Agent text containing `/goal "..."` is *not* parsed as a command. Stage 7 is a one-paste handoff — the planner prints the line, the user pastes it. Never frame this as "automatic dispatch."
- **Plugin cache only refreshes on version-field change.** If you push a code change without bumping `plugin.json` version, `claude plugin update` reports "already at latest" and the cache stays stale. Always bump on shipped changes.
- **Skill assets are located via `${CLAUDE_SKILL_DIR}`.** Claude Code substitutes it with the skill's directory when loading `SKILL.md`. Never hard-code install paths — upstream's hard-coded `~/.claude/skills/…` list never matched a marketplace install and silently fell back to `.`.
- **Command output enters the context window as the command runs.** Printing less afterward saves nothing — run mandatory commands through `run-logged.sh` so the output goes to a log. Per-phase proof belongs in `<run-root>/phases/phase-N.evidence.md`, not in transcript blocks.
- **Run artifacts are hidden via `$GIT_DIR/info/exclude`.** `claim-run.sh` adds the run base (e.g. `/.relay/`) there when it claims a run. Without it, every untracked file under `.relay/` — specs, evidence files, logs, graphs — reaches `repo-state.sh`'s cleanliness greps and graphify's scan. Don't remove it.
- **Never run bare `graphify update` in a user's project.** graphify writes `graphify-out/` into the project by default (a directory teams commit). Always go through `build-graph.sh`, which sets `GRAPHIFY_OUT=<run-root>/graph` and passes `--no-cluster` (the only LLM step) and `--force` (so deleted code leaves the graph).
- **`.gitignore` extension filter**: the file has no extension, so `find -name "*.md"` etc. skip it. When doing mass renames, include the gitignore separately.
- **Memory writeback is per-phase, optional**. The agent emits `MEMORY_SAVED: <name>` or `MEMORY_SAVED: none`. Future runs preload these for the user — load-bearing for the "starts smarter" pitch.
- **One run = one namespace; one working tree ≠ safe for two executions.** Run namespacing (`.relay/<run-id>/` via `claim-run.sh`) isolates *planning* artifacts so concurrent `/relay:goal` planning can't clobber. It does **not** make two `/goal` *executions* in the same working tree safe — they still edit the same source files. For real parallelism, each task needs its own `git worktree`. Don't "fix" the coexistence warning by implying parallel execution in one tree is safe.
- **Mermaid renders natively in GitHub README** but not always in every external markdown viewer. Stick to standard Mermaid syntax (flowchart TD / LR, subgraphs, classDef styling).

## Working state (as of v0.11.0 — 2026-10-07)

Pre-1.0. Versions 0.8.0–0.11.0 were private pre-releases, summarised in `CHANGELOG.md`; 1.0.0 is the
first public release. Everything in the layout above is built and covered by the fixture suites,
which `tests/run-all.sh` runs on macOS (bash 3.2) and Linux (bash 5) on every push.

## Open work

- **Measuring a run:** `python3 tools/run-report.py <run-root> [transcript]` is the one-stop digest
  (where the run struggled, what the audit could not check, the protocol verdict);
  `python3 tools/check-run.py <transcript> <run-root>` checks protocol conformance alone
  (echo-first, recording mode, forbidden reads, `STATE.md` ownership, check-ins, per-subagent read
  hygiene).
- **Inherited upstream backlog** (from Supergoal's v0.6 brainstorm; re-evaluate against the
  orchestrator design before acting): plan-fitness checkpoint for runs ≥8 phases,
  `PHASE_SPEC_READ` calibration block, skill-binding written into phase specs. *Scope-driven
  Polish & Harden menu* is partly served by Stage 2.5's acceptance round; *resume-from-`BLOCKED`*
  is partly served by `resume-line.sh` (the full state machine is still unbuilt, deliberately — it
  would mean touching the end-state contract). Plus the deferred removal candidates (`Type:` tag,
  `MEMORY_SAVED: none` lines, `STATE.md` engineering-check duplication, possibly collapsing 3-tier
  failure recovery to 2-tier).
- Observe how often Stage 6a self-critique produces findings vs. "clean" on real plans — if it's
  nearly always "clean", drop it per the honesty test in SKILL.md. Its intent-coverage question
  (does every spec criterion map to a phase?) is the one most likely to produce real findings.
- **Watch the interview's cost/benefit on real runs.** The honesty test: on a *well-described*
  task, does Stage 2.5 surface at least one boundary or edge the prompt did not state? If it never
  does, the rounds are theater and the round list needs rework — not a shorter interview.

## Related

- Repo: https://github.com/mack5imal/relay
- Upstream: https://github.com/robzilla1738/supergoal (fork point v0.7.0, `ec2f6eb`)
- License: MIT
- Authors: Robert Courson (Supergoal), Kyle Mack (relay)
