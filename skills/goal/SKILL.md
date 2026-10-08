---
name: goal
description: Plan and autonomously build a software task end-to-end. Triggered by `/relay:goal`, "plan and ship X", "supercharged plan", "autonomous build", "plan it out and don't stop until it's done", "I don't want to babysit this", or any non-trivial feature/refactor/redesign the user wants driven to completion. Strongly prefer over a plain plan when the user signals "every aspect", "fully", "perfectly", "until done", or wants depth + autonomous follow-through. Recons the codebase, applies preloaded memory, researches best practices with whatever tools are available, decomposes into the right number of phases, gets one confirmation, then prepares a single ready-to-paste `/goal` command — one paste between you and done — that drives the entire chain to completion with built-in retry, fix-spec recovery, and per-phase memory writeback.
argument-hint: <describe what you want built, fixed, or shipped> [--quick] [--lean] [--push | --no-push]
---

# Relay

You are running the Relay workflow. The user's task is:

$ARGUMENTS

Your job: **plan deeply, then auto-execute under a single `/goal`** until the task is verifiably complete across every phase.

## What "every aspect is perfect" means here

The user's bar is high. Translate it into measurable criteria, not vibes:

- **Functional** — the feature works for the golden path and the obvious edge cases
- **Engineering** — build, typecheck, lint, tests all pass; no new warnings
- **Polish** — UX/copy, error states, empty states, loading states are handled
- **Hardening** — security review, input validation, no obvious regressions
- **Verification** — every phase records its proof in an evidence file and prints a compact VERIFY block the evaluator can see

If a phase can't be measured, it isn't a phase. Rewrite it until it can.

## How this skill works (one-shot summary)

0. **Available context** — preload memory; detect available tools (Context7, WebSearch, MCPs, skills); resume any in-progress Relay state
1. **Intake** — restate and classify. Questions only for what recon cannot answer — missing research tools (continue, or stop to install) and whether a `ui` task gets the design stage; everything else waits for recon, so the interview never asks what the repo can answer.
2. **Recon** — parallel codebase + environment scan
2.5. **Specification** — the interview. Five rounds minimum, scored against four ambiguity dimensions, then edge and prohibition probes; writes `SPEC.md`, the agreed statement of intent the final audit re-verifies against. `--quick` narrows it to what is genuinely unclear.
2.6. **Research** — the planner turns the spec's unknowns into 1–6 specific questions (or a reasoned "none"), you approve them, one researcher subagent per question answers with sources into `research/`, and any finding that contradicts the spec comes back to you
2.7. **Design (optional)** — for UI work: compile a design brief from `SPEC.md`, hand it to the user for Claude Design (or any design tool), stop; on return verify the package at `design/`, add design-fidelity criteria to `SPEC.md`
3. **Deep think** — consume the research digest; list top-3 risks + dependencies
4. **Decompose** — derive phase count from the task itself; no fixed cap
5. **Write phase specs** — one work-spec file per phase under `$RELAY_ROOT/phases/phase-N.md` (any length, no char budget)
6. **Plan review** — show summary + concrete revision menu; wait for explicit go/no-go
7. **Hand off one ready-to-paste `/goal`** with a short end-state condition; the user pastes once, and the agent inside that fresh `/goal` session becomes an **orchestrator**: each phase runs in its own subagent context window from a self-contained brief, with retry + fix-spec recovery + per-phase memory writeback; a separate subagent reviews each phase marked `Review: yes` for correctness, and after the last phase a tidy-up pass and (when the build has security surfaces) a security pass run — none of them ever blocks the run; then a **final audit** (also in subagents) re-verifies the work against the original ROADMAP and self-heals any gaps before completion holds. `--lean` turns the three checks off

Human gates: **the specification interview (Stage 2.5)**, **the research questions (Stage 2.6)** and **plan review (Stage 6)** — plus, for UI work that opts in, **the design round-trip (Stage 2.7)**. Everything else runs autonomously.

**Why the interview is thorough by default.** Once `/goal` is pasted, nobody can add information: phase subagents run cold and cannot ask, so anything you meant but did not write down is unrecoverable at execution time. The trade is minutes of interview against hours and tens of millions of tokens spent building the wrong thing. Spend the minutes. `--quick` exists for tasks the user already knows are small — it is never the default, and it never skips the acceptance round.

### Why one `/goal`, not a chain

`/goal` takes a **short end-state condition**, not a long task body. A fast evaluator checks the condition against the transcript after each turn and auto-continues until it holds. This design leverages it directly: one `/goal` covers the whole run; phase work lives in files the agent reads from disk; the condition is "all phases done, `RELAY_RUN_COMPLETE` printed." No char budget, no inter-session chain dispatch, no fragility.

## Locate the skill directory

```bash
# Claude Code substitutes ${CLAUDE_SKILL_DIR} with this skill's directory when it loads
# SKILL.md. Never hard-code install paths — plugin installs live in a versioned cache.
RELAY_DIR="${CLAUDE_SKILL_DIR}"
[ -f "$RELAY_DIR/scripts/claim-run.sh" ] || { echo "relay: cannot locate skill assets" >&2; exit 1; }
export RELAY_DIR
# $RELAY_BASE holds ALL runs. Each run gets its own namespaced subdir under it
# (claimed in Stage 0) so two runs in the same working tree never clobber each other.
# The per-run dir — $RELAY_ROOT — is set in Stage 0, not here.
export RELAY_BASE="${RELAY_BASE:-.relay}"
mkdir -p "$RELAY_BASE"
echo "RELAY_DIR=$RELAY_DIR"
echo "RELAY_BASE=$RELAY_BASE"
echo "RELAY_PUSH=${RELAY_PUSH:-unset}"   # the user's standing push default (Stage 1)
```

All artifacts for a run live under `$RELAY_ROOT` — a per-run subdir of `$RELAY_BASE`, claimed in Stage 0. Skill assets (scripts, references, templates) live under `$RELAY_DIR`.

---

## Stage 0 — Available context (memory + tools)

Before doing anything else, sense what's available this session. This is what makes the run frictionless — if memory already knows the user's preferences, don't ask; if a tool isn't available, don't try to call it.

### Claim the run namespace (resume or fresh)

**Do this first** — before memory preload, recon, or anything that writes a file. Every run gets its **own** subdirectory under `$RELAY_BASE`, so two runs started in the same working tree can never overwrite each other's STATE/ROADMAP/phases (the v0.7 fix for concurrent-run clobbering).

```bash
# Every run dir (and the pre-0.7 flat .relay/STATE.md) whose Status is not COMPLETE.
bash "$RELAY_DIR/scripts/active-runs.sh" "$RELAY_BASE"
```

Run the scan through the script, never as an inline loop: the Bash tool runs the user's shell,
and under zsh an unmatched `"$RELAY_BASE"/*/STATE.md` is an error — the first run in an empty
`.relay/` failed on it.

Then decide:

- **Fresh run (default for a new task)** — claim a unique namespace:
  ```bash
  RELAY_ROOT="$(bash "$RELAY_DIR/scripts/claim-run.sh" "$ARGUMENTS")"
  export RELAY_ROOT
  echo "RELAY_ROOT=$RELAY_ROOT"   # e.g. .relay/add-dark-mode-Ab3Kx9
  ```
  `claim-run.sh` uses `mktemp -d` to create-and-claim the dir atomically, so two simultaneous starts always get distinct dirs — the race that caused the overwrite is gone.

- **Resume** — if an active run clearly matches this task (its STATE.md title ≈ `$ARGUMENTS`, or the user said "resume"/"continue"), set `RELAY_ROOT` to that run dir and follow the resume path (don't re-plan). If several active runs exist and intent is ambiguous, ask with **one** `AskUserQuestion` which to resume — or to start fresh.

**Coexistence notice (load-bearing — print it).** If `ACTIVE_RUNS` is non-empty and you're starting a fresh run, surface this before continuing:

> ⚠ Another Relay run is active in this working tree (`<list>`). Your planning artifacts are isolated under `<RELAY_ROOT>`, so they won't collide — **but two `/goal` executions in the same working tree will still edit the same source files and clobber each other's code.** Namespacing protects the plan, not the build. For true parallel execution, run each task in its own `git worktree`; or resume the existing run instead of starting a second.

That boundary is the honest one: namespacing removes the artifact overwrite that happens during planning; it does not make two autonomous builds in one tree safe.

### Memory preload

```bash
# Detect the memory directory. Claude Code keeps one per git repository, shared by its
# worktrees and subdirectories: ~/.claude/projects/<main checkout, non-alphanumerics → ->/memory
# (e.g. -home-me-projects-app). The script falls back to $HOME/.claude/memory,
# $PWD/.claude/memory and $RELAY_ROOT/memory; if none exists it prints the derived path anyway —
# recorded in STATE.md as `Memory dir:` and created on first write.
MEM_DIR="$(bash "$RELAY_DIR/scripts/memory-dir.sh" "$RELAY_ROOT")"
echo "MEM_DIR=$MEM_DIR"

if [[ -n "$MEM_DIR" && -f "$MEM_DIR/MEMORY.md" ]]; then
  echo "--- MEMORY INDEX ---"
  cat "$MEM_DIR/MEMORY.md"
fi
```

Read the index. Then **selectively** read individual memory files that look relevant to the task (feedback memories about the stack/domain, user role memories, related project memories). Don't dump them all into context — pull what matters.

**Stale memories.** A memory that points at a relay run which no longer exists — a
`relay_run:` key, or any `.relay/<run-id>` path in its body — describes a plan or build whose
artifacts are gone. Find them before reading anything:

```bash
bash "$RELAY_DIR/scripts/stale-memories.sh" "$MEM_DIR"   # one "STALE <name> (run gone: <path>)" line each
```

Do **not** apply a `STALE` memory. List each one in the intake as `Stale (run gone): <name>` so
the user can delete it or say it still holds. (A fresh tunez run once started with a deleted
run's plan in context this way.)

Capture applicable memory hits in `$RELAY_ROOT/applied-memories.md` (one line per memory: name, why-applicable, what-it-changes). Surface them in Stage 1 as "Applied from memory: …" so the user can see what's being inherited and correct anything stale.

**The planner never writes memories about its own plan.** Plan state lives in `$RELAY_ROOT`,
which Stage 0 already scans; a memory saying "a plan exists" outlives the run it describes.
Memories are written by phases, after work is verified (`PHASE-BRIEF.md`, memory writeback).

### Tool discovery

Tools differ between sessions (different MCP server sets, skills, and permissions). Detect, don't assume:

- **Context7** — available if `mcp__claude_ai_Context7__resolve-library-id` or similar is in the tool list (it may be a deferred tool, loaded with `ToolSearch`).
- **WebSearch / WebFetch** — available if listed, deferred or not.
- **Research tools** — from the two above, record `RESEARCH_TOOLS: web+docs | web | docs | none` in `tools.md`. Stage 2.6's researchers get exactly these; Stage 1 asks about them when WebSearch is missing.
- **Project skills** — check the available-skills list for domain-relevant skills (e.g. `mobile-ios-design`, `clerk-auth`, `expo-dev-client`) and note them in `$RELAY_ROOT/applied-skills.md` to invoke from inside phase goals if relevant.
- **Prior Relay state** — handled above in "Claim the run namespace": active runs are detected per-namespace and either resumed (reuse their `$RELAY_ROOT`) or explicitly coexisted-with.

Write detected tools to `$RELAY_ROOT/tools.md`. Stage 2.6 and the phase goals reference this file when deciding what to invoke.

### Resume detection

If you resolved to resume a run in "Claim the run namespace", read its `$RELAY_ROOT/STATE.md`. If `Status` is `AWAITING_DESIGN`, the planner stopped at Stage 2.7 for a design: print "Resuming Relay at design verification (`$RELAY_ROOT`)" and go to Stage 2.7 step d. If `Status` is `IN_PROGRESS` / `READY_TO_DISPATCH` / `BLOCKED` with a phase pending, **do not re-plan**. Print a one-line "Resuming Relay from phase N (`$RELAY_ROOT`)" and jump straight to Stage 6 (plan review) with the existing artifacts, or directly to Stage 7 (dispatch) if the user confirms resume.

---

## Stage 1 — Intake & classification

Echo the task back in **one sentence**, classify it, and name the mode — then print the intake
block below. Classification tags (they can combine):

| Tag | Trigger |
|---|---|
| `greenfield` | Request implies a new project; cwd has no `.git/` or empty tree |
| `brownfield` | Change in an existing repo |
| `bugfix` | Mentions "bug", "broken", "fails", "regression" |
| `refactor` | Mentions "refactor", "clean up", "restructure" |
| `ui` | Mentions "design", "polish", "UI", "UX", "responsive", "redesign" |

Also note whether `$ARGUMENTS` carries the **`--quick`**, **`--design`**, **`--lean`**,
**`--push`** or **`--no-push`** flag (anywhere in the arguments), and strip them from the task
text before echoing. They are the only five flags Relay reads. `--design` opts into the design stage (Stage 2.7) whatever the tags say.
`--lean` turns off the three checks around the build — the per-phase correctness reviews, the
tidy-up pass and the security pass (Stage 4); the audit still runs. It is independent of
`--quick`: `--quick` shortens planning, `--lean` shortens the checks, and either works alone.
**Push** is off unless chosen: `--push` / `--no-push` decide it for this run; without either,
`RELAY_PUSH` (printed by the setup block — `on` or `off`, the user's standing default) does;
otherwise it is off. On, the orchestrator pushes the branch relay creates once after the audit;
off, the branch stays local and the run's last message gives the push command. A push is the
one outward-facing, hard-to-undo thing a run does, and it happens unattended — so it is never
on by default (owner, 2026-10-07).

Then print this block **as message text, before any recon tool call** — it leads with what you
already know, so the user can correct a stale inheritance or a missed flag before either shapes
anything:

```
Task: <the one-sentence echo>
Type: <tags>  ·  Mode: full interview   (or: --quick — only below-minimum dimensions, plus acceptance)
Design: on (--design)   (or: asking — tagged ui · or: off)
Checks: review, tidy-up and security as planned   (or: lean (--lean) — no review, tidy-up or security pass)
Push: off — the run branch stays local   (or: on (--push) · on (RELAY_PUSH=on) · off (--no-push))
Applied from memory: <the hits in $RELAY_ROOT/applied-memories.md, or "none">
From your prompt: <what the request itself already settles>
```

In the first four planning sessions this step ran in one: the others went straight from setup to
recon, and neither `--quick` run said it was one. The mode and the memory hits therefore repeat
on the first interview question (Stage 2.5), which cannot be skipped the same way — but print the
block here too, because this is the moment a stale memory or a missed flag is cheapest to fix.

**Ask no questions here — with the exceptions below** (design, research tools, git, the push remote). The interview is Stage 2.5, after recon. Asking
before the codebase has been scanned means asking things the repo could have answered — the
single most common way an interview wastes the user's patience and spends it on the wrong
questions.

The exception: when the task is tagged `ui` and `--design` is absent, ask one `AskUserQuestion`
right after the intake block — header "Design?", question "This is UI work. Design the screens
before planning the build?", options **Design stage (Recommended)** (Stage 2.7 puts a brief
on the clipboard for Claude Design or any design tool, then waits for the package) · **I already have a design in
`design/`** (skip the brief; Stage 2.7 goes straight to verification) · **No design stage**.
Recon cannot answer this one, and asking now tells the user early that the run will pause for a
design. Record the answer as the `Design:` value (`on`, `existing`, `off`).

**Missing research tools.** When `RESEARCH_TOOLS` has no `web` (WebSearch unavailable), ask —
in the same `AskUserQuestion` call as the design question when both apply — header "Research",
question "WebSearch isn't available in this session, so Stage 2.6 research would come from
training knowledge only. Continue, or stop and install first?", options **Stop so I can install
(Recommended)** · **Continue — flag research unverified**. On *stop*: print how to enable
WebSearch (allow the tool in `/permissions` or settings; it can be unavailable on some API
providers) and how to add Context7 (`claude mcp add` for the Context7 MCP server, then restart
the session), remove the run directory Stage 0 just claimed (`rm -rf "$RELAY_ROOT"` — it holds
only Stage 0 files), and stop; re-running `/relay:goal` starts clean. On *continue*, every
researcher marks its findings `unverified (training knowledge)`. When only Context7 is missing,
ask nothing: add `Context7: not installed — library docs researched via web search` to the
intake block.

**Git and the push remote.** Right after printing the intake block, run (one call, from the
project root):

```bash
bash "$RELAY_DIR/scripts/relay-git.sh" setup "$RELAY_ROOT"
```

It only reads: `git: repo|none`; without git, `files: N` and the folder's entries (secrets and
generated folders marked `(left out — …)`); `remote: <name>|none|choose: <a> <b>…`; and when
there is no usable push remote, `gh: <login>|signed-out|missing` and `suggest: <login>/<folder>`
(`(exists, private|public)` when that repo is already on GitHub).

- **`git: none`** — ask, in the same `AskUserQuestion` call as the design / research questions
  when they apply: header "Git", question "This folder isn't a git repository. Relay saves each
  phase as a commit, and its review, tidy-up and final audit compare against git — without it
  they fall back to weaker checks. Set up git here?" When `files:` is above 0, put the listed
  entries in the question text and say which are left out. Options: **Set up git here
  (Recommended)** — with files, label it "Set up git and save the N files here as the starting
  point", and say in the description that secrets and generated folders are left out and added
  to `.gitignore` · **Continue without git** (no commits, no run branch, no push, weaker checks).
  On *set up*: `bash "$RELAY_DIR/scripts/relay-git.sh" init "$RELAY_ROOT"`, adding `--save` when
  `files:` is above 0 (owner, 2026-10-08: one choice covers both, so pre-flight is not stopped by
  the files a moment later); show its lines. Exit 1 prints the reason and the fix (e.g. no git
  name/email) — show it, and re-run once the user has fixed it. On *continue*: Push is `off — no
  git repository`, whatever the flags said.
- **Push is on and there is no usable remote** (`remote: none` or `choose:`, with git, or just
  set up) — ask, as its own question after any `init`: header "Remote". With `remote: none`,
  the question is "Push is on, but this repository has no remote to push to. Connect one?", and
  the options are:
  - **Create a private GitHub repo `<suggest>` and connect it (Recommended)**. Offer it only
    when `gh:` is a login, and give the full name in the label. When `suggest:` says `exists`,
    the label is **Connect your existing repo `<suggest>`** instead, and the description gives
    its visibility.
  - **I'll add a remote myself**. Print `git remote add origin <url>` (pushing comes after the
    audit, so adding the remote mid-run still works).
  - **Turn push off for this run**, which sets `off — no remote`.

  Without `gh` (`missing` / `signed-out`), the first option is **Install / sign in to gh, then
  check again**. Its description is "`brew install gh` (or https://cli.github.com), then
  `! gh auth login`", and choosing it re-runs `setup` and asks again. On *create* / *connect*,
  run `bash "$RELAY_DIR/scripts/relay-git.sh" remote "$RELAY_ROOT" --create <suggest>` (or
  `--connect`) and show its line.

  With `choose: <a> <b>…`, the question is "Push is on, and this repository has several remotes,
  none called origin. Which one should the run branch go to?". The options are the remotes (at
  most three) plus **Turn push off for this run**, and the answer becomes `Push: on — to
  <remote>`.

  **Relay never creates a public repository and never pushes while planning.** `remote` only
  adds `origin`. The one push is the run branch, after the audit. On tunez, the planner made the
  repo itself and pushed the owner's `main`.

The same remote question runs when the user turns push on at Stage 6.

**Open the first question's text with the intake block** — `Task:`, `Type:` · `Mode:`, `Design:`,
`Checks:`, `Push:`, `Applied from memory:` (and any `Stale (run gone):` or `Context7:` lines) — then ask. Whichever
Stage 1 question comes first (research tools or design) is Stage 1's first rendered channel; a block printed on its own between tool calls was not shown in
the first design-stage run, and the question then referred to "the intake above".

---


## Stage 2 — Recon (parallel)

Run recon scripts in parallel. They populate context files under `$RELAY_ROOT/`.

### Brownfield path

```bash
bash "$RELAY_DIR/scripts/detect-stack.sh"   > "$RELAY_ROOT/context.md"
bash "$RELAY_DIR/scripts/summarize-repo.sh" > "$RELAY_ROOT/repo-map.md"
bash "$RELAY_DIR/scripts/build-graph.sh" "$RELAY_ROOT"   # one "graph: …" line; needs graphify (optional)
```

`build-graph.sh` builds a tree-sitter code graph at `$RELAY_ROOT/graph/graph.json` when graphify is installed (a few seconds, no LLM, no network) and prints a skip line otherwise. Stage 5 uses it to check each phase's `Map seeds:`.

### Greenfield path

```bash
bash "$RELAY_DIR/scripts/detect-env.sh" > "$RELAY_ROOT/context.md"
```

Read the outputs. Then print a **5-line summary** to the user: stack, package manager, build/test/lint commands, notable modules (if any), risky areas — and whether a code graph was built (the `graph:` line). This is what tells them you've actually understood their codebase before planning.

---

## Stage 2.5 — Specification (the interview)

Now that recon has answered everything the codebase can answer, establish what the user actually
wants — and write it down in a form the final audit can check. This stage produces
`$RELAY_ROOT/SPEC.md`.

**Why this is the deepest stage in the planner.** `ROADMAP.md` is a *compilation* of intent into
phases, and the audit has historically re-verified the compilation against itself. A misread
request therefore produces a clean `AUDIT_COMPLETE` over the wrong software. `SPEC.md` is the
source the compilation is judged against, so its quality bounds the correctness of the entire
run. It is also the last moment anyone can add information: after Stage 7 the user is out of the
loop and every executor runs cold.

### The ambiguity model

Score four dimensions from 0.0 (no idea) to 1.0 (unambiguous):

| Dimension | Weight | Minimum | What it measures |
|---|---|---|---|
| **Goal clarity** | 35% | 0.85 | Is the outcome specific and measurable? |
| **Boundary clarity** | 25% | 0.80 | What is in scope, and what is explicitly out? |
| **Constraint clarity** | 20% | 0.75 | Performance, compatibility, platform, data, dependency limits? |
| **Acceptance criteria** | 20% | 0.85 | How will we know it is done — in terms a verifier can settle? |

```
Ambiguity = 1.0 − (0.35×goal + 0.25×boundary + 0.20×constraint + 0.20×acceptance)
Gate: ambiguity ≤ 0.15 AND every dimension at or above its minimum
```

Both halves matter: the weighted score alone lets a crisp goal paper over a 0.40 boundary, which
is exactly how scope drift gets into an autonomous run.

**The score says when the interview is finished. It never decides whether it happens.** The
opening score is derived from the same prompt it is judging, so a high one means the request
*sounded* confident, not that it was understood. Never skip rounds because the opening score
looks good.

### The rounds

Ask **≤3 questions per round** with `AskUserQuestion` (4 options max, headers ≤12 characters),
building on the previous answers rather than front-loading a list. Score the prompt before round
1, then re-score after every round.

**The scoreboard rides on the round's first question.** Open that question's text with the
scores, then ask:

```
Scores (opening) — goal 0.85 (at minimum) · boundary 0.65 (below minimum) · constraint 0.85 (pass) · acceptance 0.60 (below minimum) → ambiguity 0.25 (gate ≤ 0.15)
Mode: --quick (only below-minimum dimensions, plus the acceptance round)
Memory: <the hits from applied-memories.md, or "none">

<the question>
```

Tag every dimension against **its own** minimum (goal 0.85, boundary 0.80, constraint 0.75,
acceptance 0.85): `below minimum` under it, `at minimum` exactly on it, `pass` above it. The tags
are what make the line readable at a glance — 0.85 is a pass for constraint and a knife-edge for
goal, and an at-minimum dimension is one `--quick` will not return to.

Round 1 carries `Scores (opening)` plus the `Mode:` and `Memory:` lines (and `Design: on` when
`--design` skipped the Stage 1 question, so the choice is still shown); every later round
carries `Scores (after round <n>)` alone. In full mode the second line reads
`Mode: full interview`. Record the same numbers in `SPEC.md`'s interview log (round 0 is the
opening score).

**Why the question and not a printed line:** a question is always rendered and always kept in the
transcript. In the first four planning sessions the scoreboard was only ever a thinking summary,
including the session run specifically to check that it printed — the scores were right and
recorded in the spec, but nobody saw them in time to act on them.

Run all five, in order, every time:

1. **Researcher** — the delta. What exists today versus the target state, grounded in the Stage 2
   recon output. Cite what you found: *"`lib/auth/` already has session handling — extend it, or
   replace it?"*
2. **Simplifier** — the irreducible core. *"If this had to ship at half the size, what stays?"*
   Surfaces the real priority, and often removes a phase.
3. **Boundary Keeper** — what will explicitly **not** be done. "Not mentioned" is not "excluded";
   an executor with spare capacity and a vague boundary will invent work.
4. **Failure Analyst** — *"what would make you reject this when it came back?"* The cheapest
   possible way to discover an unstated requirement.
5. **Acceptance** — what "done" and "every aspect is perfect" concretely mean here. **Mandatory
   in every mode, including `--quick`**: this round produces `## Success criteria`, and a run
   with no agreed criteria gives the audit nothing to check. Push every answer to something a
   verifier can settle — this is also where the scope of the final Polish & Harden phase is set.

Then **Seed Closer** rounds until the gate passes, each naming the lowest-scoring dimensions:
*"Boundary clarity is at 0.6 — what is the one thing you would be annoyed to find changed?"*

**Never force-stop.** From round 6 on, offer: **Write SPEC.md** / **Keep going** / **Write it and
flag the gaps**. If the user stops early, the below-minimum dimensions are recorded as assumptions,
not silently treated as answered.

### Question discipline

- **Don't checklist-walk.** These are perspectives, not a form. Follow the thread the user opens.
- **Don't ask what recon answered** — stack, package manager, conventions, what exists.
- **Don't ask what the user shouldn't have to decide** — implementation approach, architecture,
  file layout, library minor versions. Claude decides those; they belong in Stage 6's assumptions.
- **Don't ask what memory already settled.** Say "Applied from memory: …" and move on.
- **When the user wants to explain freely, stop using `AskUserQuestion`** and let them talk.
  *"Go ahead — what are you thinking?"* A forced multiple choice destroys the best answers.
- **Offer real options**, not a "you decide" escape hatch — they are here to decide. "Other" is
  always available for free text.

### `--quick`

Score first, then ask only about dimensions below their minimum — **except round 5, which always
runs**. For tasks the user already knows are small. Record `Interview: --quick` in `SPEC.md` so a
later reader knows the spec was narrowed deliberately.

**What `--quick` costs is scope, not precision.** Fewer questions means more boundary decisions
made by you rather than the user — in the first `--quick` session the planner put four features
into `## Out of scope` that the full-mode run had asked about, and the user had chosen to build
two of them. Every such decision is an assumption: tag it `(planner)` (see *Write `SPEC.md`*) so
Stage 6 shows it as one.

### The completeness probes (after the gate passes)

The gate measures whether what was stated is *clear*. These measure whether it is *complete* — the
omission failure mode, which is what silently wastes an autonomous run. A verifier only checks
assertions that exist, and an assertion only exists for a requirement someone wrote down, so an
omitted edge is invisible to every downstream check no matter how rigorous.

**Edge probe** — run it, then resolve what it raises:

```bash
python3 "$RELAY_DIR/scripts/edge-probe.py" --from-spec "$RELAY_ROOT/SPEC.md"
```

It classifies each success criterion by shape and emits only the edge categories that genuinely
apply to that shape, from a closed eight-item taxonomy (`boundary`, `adjacency`, `empty`,
`encoding`, `ordering`, `precision`, `idempotency`, `concurrency`). Its output is a **floor**:
union it with your own judgement, never narrow it. For each raised edge, either fold the answer
into a success criterion (`resolved`), dismiss it **with a reason** (`dismissed` — "N/A, the
input is a bounded enum"; silence is not a disposition), or record it `unresolved` so the plan
inherits it as a known gap. If it warns that nothing was probed, that is a parsing or authoring
problem — not a clean bill of health.

The floor is **enforced**: `validate-spec.sh` re-probes the spec's *current* criteria and fails on
any raised edge with no row, printing the row to paste. Rewording a criterion after probing can
raise new edges — that is what the re-probe catches. Every gap has an honest answer (`unresolved`
is always legal), so add the row; never narrow the probe's list to make the check pass.

**Prohibition probe** — two passes, no tooling, **recorded in `SPEC.md`**. First recall:
*"what could this silently become that the user would not want, but the spec does not forbid?"* —
over-produce, around ten candidates. Then precision: drop routine engineering hygiene ("must not
mutate its input"), drop anything that restates an `## Out of scope` item or a constraint (a
prohibition forbids what the spec does *not* already exclude), keep values, safety, and
scope-integrity items, and collapse to the two or three that would genuinely matter. Security
canon (OWASP/GDPR-shaped) belongs to the Polish & Harden phase, not this list — drop those with a
one-line breadcrumb.

Write the outcome of both passes into `SPEC.md`'s `## Prohibitions` section as its `Probe:` line
— how many candidates were recalled, how many kept, and what the dropped ones were dropped for:

```
Probe: 11 recalled → 3 kept · dropped 4 hygiene, 2 restating out-of-scope, 2 security canon (Polish & Harden)
```

Stage 6b then prints the kept prohibitions in the plan summary. The user needs to see what the
run is forbidden to do in any case, and a printed block between tool calls does not survive: in
the first four sessions neither pass was ever visible, and on a greenfield plan three of the four
prohibitions merely restated the out-of-scope list.

### Write `SPEC.md`

`cp` `$RELAY_DIR/templates/SPEC.md` to `$RELAY_ROOT/SPEC.md`, then edit the copy — read the
template once, through that copy. Fill every section: goal, in scope, out of scope, constraints,
the `S<k>` success criteria (each with `Current:` / `Target:` / `Acceptance:`), edge coverage,
prohibitions, assumptions, the ambiguity report, and the interview log (with each round's scores).

**Tag planner-decided scope.** An `## Out of scope` item the user chose in the interview stays as
written; one you decided because nobody asked gets a trailing `(planner)`. Those are assumptions
in disguise, and Stage 6 lists them for correction.

Then validate it:

```bash
bash "$RELAY_DIR/scripts/validate-spec.sh" "$RELAY_ROOT/SPEC.md"
```

Fix every ❌ before continuing — a criterion the gate rejects is one the audit could not have
re-verified either. Advisories are judgement calls; read them, act where they land. **Read the
validators' output, never their source:** `validate-spec.sh`, `validate-phase.sh`,
`edge-probe.py` and `build-rubric.sh` print what is wrong and how to fix it. Every planning
session so far `cat`-ed the validator's source anyway, spending context on nothing.

Finally, copy any below-minimum dimension, any `unresolved` edge and every `(planner)` scope item
into the assumptions that Stage 5 writes into `ROADMAP.md`, so Stage 6's review surfaces them for
one-click correction.

## Stage 2.6 — Research

Runs after `SPEC.md` passes `validate-spec.sh`, before the design brief and before any phase is
cut — research can change which phases exist, and some findings are design constraints. **Once,
here; never per phase:** relay plans every phase up front and executes cold, so a finding that
arrived during execution would contradict an approved plan with nobody to arbitrate.
`--quick` changes nothing here. Background, question examples and the failure it fixes:
`references/research.md`.

**a. Questions.** From the spec, write **1–6 specific questions** — each tied to what it bears
on and the decision it informs. Sources: the spec's risks and unresolved edges; libraries or
APIs the plan will lean on (current versions, breaking changes); niche-domain algorithms;
platform quirks; standards or regulations. Never "research best practices for X": a question
is specific enough when its answer changes a named decision. Zero questions is allowed — the
change stays inside a stack the repo already uses, say — but only with a written reason.
Write the index `$RELAY_ROOT/research/README.md`:

```markdown
# Research index

Tools: <RESEARCH_TOOLS>

| # | Slug | Question | Why it matters | Status |
|---|---|---|---|---|
| 1 | `pitch-detection` | <question> | S1, S3 — which detector phase 2 implements | pending |
```

(or a single `No research: <reason>` line).

**b. Gate.** One `AskUserQuestion`, header "Research", its text listing the numbered questions
with their one-line reasons (or the no-research reason): **Go (Recommended)** · **Edit or add a
question** (ask what, update the index, ask again) · **No research** (record `No research:
<the user's reason>`). The user knows which unknowns actually worry them; this is the moment to
say so.

**c. Dispatch.** For each question: `cp "$RELAY_DIR/templates/RESEARCH-BRIEF.md"
"$RELAY_ROOT/research/<slug>.brief.md"`, fill it (question, why, decision, a context excerpt from
the spec — goal, stack, bounding constraints, the relevant `S<k>` lines verbatim — the tools, and
`{{CHECK_CMD}}`: `"$RELAY_DIR/scripts/check-research.sh" "$RELAY_ROOT" --only <slug>` with both
paths absolute, so the researcher validates its own file before it returns), then dispatch one `general-purpose` subagent per brief **in one message, in parallel**,
each with: `Read <run-root>/research/<slug>.brief.md and follow it.` Dispatch is asynchronous:
each researcher reports later as a one-line `RESEARCH_DONE <slug> — …` hand-back. Wait for every
hand-back before step d; never read `tasks/*.output` (it is the researcher's whole transcript).
Set each answered row's Status to `answered`. A researcher that fails or returns no file is
re-dispatched once; after that its row reads `unanswered — <why>` — a known gap, carried into
the assumptions, not a blocker.

**While the researchers run** (`Design: existing`, or a design package already back), you may
do Stage 2.7d's **read-only** work — `check-design.sh`, drafting the fidelity criteria, reading
`HANDOFF.md`. Ask no Stage 2.7e question and edit no `SPEC.md` until step f is resolved, then
reconcile against the post-research spec: both steps rewrite `SPEC.md`, and a contradiction can
change a criterion reconciliation compares against — the tunez test run reconciled first and
could have had the user answer the same criterion twice.

**d. Validate.**

```bash
bash "$RELAY_DIR/scripts/check-research.sh" "$RELAY_ROOT"
```

Every ❌ names its fix (a missing section, a finding with no source, no `Contradicts:` line);
send the researcher its fix (or re-dispatch) and re-run until green.

**e. Read the digest, not the files.**

```bash
bash "$RELAY_DIR/scripts/check-research.sh" "$RELAY_ROOT" --digest
```

It prints each answer, its implications and its `Contradicts:` line — everything planning
needs. The findings and sources stay on disk for whoever wants to check them.

**f. Contradictions.** Every answer whose `Contradicts:` is not `none` goes to the user, up to
four per `AskUserQuestion`: **Change the spec** (edit the criterion or constraint, re-run
`validate-spec.sh`) · **Keep the spec** (the risk becomes a key assumption) · Other. Each
question says what kind of change it proposes — one that **clarifies how a criterion is
measured** (the target stands: "S1's reference pitch is the dataset's corrected f0") or one that
**lowers or drops a target** ("real-voice evidence stops at A♯4") — and the finding's confidence,
with "unverified" when the finding is training knowledge. Keeping the spec is a real option: a
finding can be weak, the user can know something the researcher didn't (their own recordings),
or "hard" may be a risk worth taking. Research
never rewrites the spec on its own. Record each resolution under `## Resolutions` in the index,
and add `**Research:** research/README.md — <n> questions, <u> unverified` under the `SPEC.md`
header (`**Research:** none — <reason>` when there was none).

**What the research feeds:** the design brief (Stage 2.7a — implications that constrain the
design go in "Platform and constraints" and "The design must not"), Stage 3 (the digest replaces
guessing), the phase specs (Stage 5 — cite `research/<slug>.md §Implications for this plan`,
copy any fact a phase depends on into its Notes), and the Stage 6 summary (a `Research:` line;
unverified findings and unanswered questions under Key assumptions).

---

## Stage 2.7 — Design (optional)

Runs when `Design:` is `on` or `existing` (Stage 1), after `SPEC.md` passes `validate-spec.sh`.
Relay does not generate designs: it writes a brief, the user takes it to **Claude Design**
(recommended — the brief is written for it) or any other design tool or designer, and comes back
with a package at `design/`. What the package must contain, why, and the edge cases:
`references/design-stage.md` (read it once, the first time this stage runs in a session).

With `Design: existing`, skip a–c and go straight to d. (If `design/` is absent, `mkdir -p
design`, tell the user its absolute path, and wait for **design ready**.)

**a. Brief.** `cp "$RELAY_DIR/templates/DESIGN-BRIEF.md"
"$RELAY_ROOT/DESIGN-BRIEF.md"` and fill the copy in place from `SPEC.md` and recon: the goal,
platform and constraints, the existing design system (brownfield), the **anchor screen** (below),
one block per screen with a stable kebab-case id, and **every state each screen must be drawn in — take them from
`## Edge coverage`** (empty, error, loading, long content…), the copy `SPEC.md` fixes, Out of
scope, and **"The design must not"** — every prohibition, constraint and Stage 2.6 research
implication a designer could break
without knowing: third-party origins (fonts, icons, images from another domain), platform limits
(no hover on touch, viewport widths), accessibility floors, asset licensing. The first real run's
design loaded Google Fonts against a same-origin-only privacy criterion; saying so in the brief
is cheaper than reconciling it afterwards. Leave "How we'll work" (its four stages) and "What to hand back" exactly as
written: the stages let the user settle the look on one screen before every screen is
drawn, and `check-design.sh` verifies the hand-back contract.

**The anchor screen** is where the design direction is set — three takes on it, then
refinement, before any other screen exists. Pick the product's **canonical** screen: its home,
the one a returning user lands on when they open it. Never onboarding, settings, an error or
empty state, a sheet or a modal; if the app opens onto a menu or launcher that only routes to the
main task, pick the screen where that task happens. Not the densest or most state-heavy screen —
the most representative one. Name it with a one-line reason; the user can change it in the
design tool.

**b. Park the run.** `cp "$RELAY_DIR/templates/STATE.md" "$RELAY_ROOT/STATE.md"`, fill the title,
`Run root:` and `Memory dir:`, and set `Status: AWAITING_DESIGN`. That makes the run visible to
Stage 0's active-run scan, so a new session can resume it. Stage 5 fills this file in rather than
re-copying it.

Then get the package's home and the paste ready:

```bash
mkdir -p design                       # the user puts the export here; relay never searches for it
awk 'f && (n || NF) {n=1; print} /^---$/ && !f {f=1}' "$RELAY_ROOT/DESIGN-BRIEF.md" > "$RELAY_ROOT/DESIGN-BRIEF.paste.md"
pbcopy < "$RELAY_ROOT/DESIGN-BRIEF.paste.md" && echo "brief: on the clipboard"
```

The paste file is everything below the brief's first `---` (the comment block above it is for
you). Relay never looks for the export in `~/Downloads` or anywhere else: several exports can
sit there, and a sandboxed session may not reach it — the user puts it in `design/`, which is
also why the folder exists before they leave.

**c. Stop.** End the turn with the overview, the steps and — only when `pbcopy` failed — the
brief, as your final message; nothing after it. The user reads what the design session will ask
of them **before** they start it, so no stage surprises them (anchor, three takes, a stop after
each stage):

```
Design brief ready — it's on your clipboard. (File: <abs path to run root>/DESIGN-BRIEF.paste.md)

What happens in Claude Design — four stages, each ending with a stop for you:
  1. Three takes on `<anchor>` (<one-line reason>) — you pick one, or ask for new takes.
  2. Refine that take until the look is settled — palette, type, spacing, components.
  3. Every other screen and state is drawn in that look.
  4. You review, ask for changes, and say they're final — then it exports the package.
  You move on in your own words ("go with take 2", "that's settled"); it asks if it can't tell.
  Tell it when you want something different from the brief — it keeps a list of those, and
  the plan adopts them in one confirmation instead of asking about each.

1. Open Claude Design (or any design tool or designer) and paste the brief as your first message.
2. Work through the four stages.
3. Export the package, and put its contents — `HANDOFF.md`, `screens/`, … — in
   `<abs path>/design/` (created for you; the .zip itself is fine too).
4. Come back and say **design ready** — or, in a new session, run `/relay:goal resume`.
   Relay checks the package and commits `design/` for you.

Say **skip design** to plan without one, or **copy the brief** to put it on the clipboard again.
```

When `pbcopy` is missing or fails (Linux, a sandbox), replace the first line with `Design brief
ready (<path>). Paste this into Claude Design — or any design tool or designer:` and print the
paste file's contents fenced with **five** backticks — the brief holds three- and four-backtick
fences of its own, and a shorter outer fence cuts the paste short. On **copy the brief** (also
after a resume), run the `pbcopy` line again.

**d. Verify on return.** Settle and commit the package, then check it:

```bash
bash "$RELAY_DIR/scripts/prepare-design.sh" design   # unzips a lone .zip, lifts a wrapper folder, commits design/ only
bash "$RELAY_DIR/scripts/check-design.sh" design
```

`prepare-design.sh` is the one commit relay makes while planning: `design/` must be committed
(untracked files would count as run changes, and `SPEC.md` records the package's sha), and the
user should not have to run git to hand back a design. The commit holds only `design/` —
anything else the user has staged stays staged. It touches nothing outside `design/`; when it
cannot tell what to do (two zips, a name clash) its ❌ says what it found, and you pass that to
the user and wait. Every `check-design.sh` ❌ names its fix (a missing screen PNG, a missing
`### <id>` heading); a content fix is the user's — they fix the package in `design/` and say
**design ready** again, and both commands re-run.
⚠ lines (no tokens, components or copy section) are not blockers — they mean that check will not
exist; carry them to the Stage 6 summary. No deviations list means step e asks every conflict
individually.

Then draft the fidelity criteria, numbered after the last `S<k>`. Decide the theme file the
tokens phase will create (e.g. `src/theme/tokens.ts`) and any files generated from it that must
carry a token value literally (e.g. `index.html` for `theme-color`, a web manifest) — generated,
never hand-copied:

```bash
bash "$RELAY_DIR/scripts/check-design.sh" design --criteria --start <k+1> --run-root "$RELAY_ROOT" \
  --theme <theme file> [--allow <generated file or glob>]...
```

Each drafted Acceptance line runs `<run-root>/check-design.sh design --verify <aspect>` — the
same deterministic check for the phases and the audit (Stage 7 copies the script into the run).

Read `SPEC.md` by section (`grep -n '^#'`, then the ranges you need) — never `cat` it whole;
the first resumed run overflowed its tool output doing that. `HANDOFF.md` is the exception, read
whole once for step e.

Add the printed criteria to `## Success criteria` and the printed rows to `## Edge coverage`,
and add `**Design:** design/HANDOFF.md @ <sha from the inventory line>` under the `SPEC.md`
header. `validate-spec.sh` will now fail until step e records the reconciliation. The last criterion —
screens captured for review — is the human check: it passes on a capture **or** a recorded
reason, so it can never stall the run; the side-by-side comparison is the user's, after the run.

**e. Reconcile the design against the spec.** Not before Stage 2.6f's contradictions are
resolved: both rewrite `SPEC.md`, so reconcile against the post-research spec. The design was
drawn from the brief, not the spec, and a designer makes real decisions — the owner often agrees
to better ideas mid-session. Read `HANDOFF.md`'s `## Deviations from the brief` first, then
compare the design — its screens, states, behaviour and copy — against **every** success
criterion, constraint, prohibition and in-scope item. Sort the conflicts:

- **Approved deviations** — conflicts the deviations list names. The owner already chose them,
  so confirm them together: one `AskUserQuestion` listing each (`<spec said> → <design does>`),
  options **Apply all — design wins (Recommended)** · **Review each** (ask them as below) · Other.
  A deviation that breaks a prohibition is never in this group — ask it on its own.
- **Unflagged drift** — every other conflict (all of them, when the package has no deviations
  list). Up to four per `AskUserQuestion`, as many calls as needed: **Design wins** (rewrite the
  spec to match) · **Spec wins** (the build deviates from the design here) · Other; recommend
  keeping the approved design unless it breaks a prohibition.

The tunez test plan put 12 conflicts to the owner one by one; most were choices they had already
made in the design session. Record every
conflict in `SPEC.md`'s `## Design reconciliation` — name an exempted item as `screen: <id>`,
`component: <Name>`, `token: <name>` or `copy: <exact string>` so `--verify --except` honours it
— (an approved deviation's Resolution reads `design wins — approved in the design session`)
and end with `Reconciled: <n> conflicts` (`Reconciled: 0 conflicts — <what was compared>` when
there are none; `validate-spec.sh` rejects a recorded design without it). Phases that build an
affected screen cite the row. The first real run found four conflicts this way — tolerance
history, a trend rule, a missing trend section, latency vs a throttled readout — on the planner's
own initiative; it is a step now so it does not depend on one.

Re-run `validate-spec.sh`, set `STATE.md` to `Status: PLANNING`, and continue to Stage 3.

On **skip design**: record `**Design:** skipped` in `SPEC.md`, set `Status: PLANNING`, continue.

---

## Stage 3 — Deep think

This is the difference between a generic plan and a Relay. Spend real cycles here — but use only what's available.

**Required:**
- Identify the **top 3 risks**: what's most likely to go wrong, what's hardest to undo, what's easy to miss until shipped.
- Identify **non-obvious dependencies**: things that have to happen in a specific order or block other work.
- Apply memory hits from `$RELAY_ROOT/applied-memories.md` — bake them into goals, constraints, or risk mitigations.

**Research is done** (Stage 2.6). Work from the digest (`check-research.sh --digest`), not
from memory: every choice the research informed cites its file in THINKING.md, and anything
still resting on training knowledge — an unverified finding, an unanswered question, a question
nobody asked — is written down as an assumption, not presented as fact.

**Project skills** — if relevant skills are listed in `$RELAY_ROOT/applied-skills.md` (e.g. `clerk-auth`, `mobile-ios-design`), note them in THINKING.md as "consult `<skill>` skill during phase N" so the executor invokes them at the right moment.

**Write `$RELAY_ROOT/THINKING.md`** with sections: Goals, Constraints, Risks, Dependencies, Open Questions (already-assumed), Memory hits applied, Tools/skills relied on, Best Practices Applied (each citing its `research/<slug>.md`, or marked as an assumption). Keep it tight — 1–2 pages. This is the substrate the roadmap derives from.

See `references/planning-depth.md` for the bar to clear here.

---

## Stage 4 — Decompose into phases

Break the work into **as many phases as the task actually needs** — no fixed count, no upper or lower cap. The right number falls out of the work itself: how many independently verifiable units exist between empty repo (or current state) and "done perfectly." A trivial change might need 2 phases; a typical feature 4–6; a full-stack greenfield app 8–12; a major migration 15+. Read `references/phase-design.md` for how to slice well — the short version:

- Each phase delivers something **verifiable on its own** (it builds, it passes its own tests, you could ship it as a partial increment)
- Phases have **explicit dependencies** (phase 3 depends on 1 and 2)
- The **last phase is always a "Polish & Harden" phase** covering edge cases, error states, security, accessibility, copy, perf — this is how "every aspect is perfect" gets enforced
- For UI work, include a dedicated **visual polish** phase with screenshot/visual evidence requirements. With a design package (Stage 2.7), the first UI phase builds the tokens and primitives from `design/HANDOFF.md §Design tokens` and creates the theme file the tokens criterion names, and the polish phase carries the screens-captured criterion (`references/design-stage.md`)
- For brownfield, include an early **safety net** phase if test coverage is thin (add characterization tests before changing behavior)
- **Each phase must fit one context window.** Every phase executes in its own subagent, cold, from a brief — so a phase too large for one window fails the whole run. Estimate the files each phase touches (new + modified). **Over 12, split it** at a seam: usually a layer (types vs. behavior), a surface (one screen vs. the next), or a caller cluster in a migration. A phase that is one coherent unit with no clean seam may stay over 12 — say why on the line: `Estimated files: 14 — <why it can't split>`; a split at no real seam makes the design worse. Record the estimate as `Estimated files: <n>` in the spec header; `validate-phase.sh` warns above the threshold without a reason (`RELAY_PHASE_FILE_LIMIT` overrides it). File count is only half of size: what a phase **reads** fills its window (see Stage 6a).

Every phase's acceptance criteria must trace back to a `SPEC.md` success criterion or to the
engineering gate (build/typecheck/lint/test). A criterion that serves neither is scope the user
never asked for; Stage 6a's intent-coverage check will flag it.

Each phase has:
- **Name** (5 words max, action-first: "Build auth foundation")
- **Why** (1 sentence)
- **Deliverables** (concrete files/features that will exist when done)
- **Acceptance criteria** (5–10 measurable items)
- **Mandatory commands** (build, typecheck, lint, test that must pass)
- **Evidence required** (what the agent must record in the phase's evidence file to prove completion)
- **Dependencies** (which prior phases must be done)
- **Estimated files** (new + modified; the sizing gate above)
- **Exemplars** (2–3 existing files whose patterns the phase must match — written in Stage 5)
- **Review** — `yes` (the default: after the phase passes, a separate subagent reviews its diff for bugs, unsafe patterns and wrong abstractions later phases would build on) or `skip — <reason>` for a phase with nothing to review for correctness (docs only, config only). The reason is mandatory; Stage 6 shows every skip

**The checks after the build (per run).** Decide two more things for the run as a whole, and write them into `STATE.md` at Stage 5:

- **Tidy-up pass** — `Cleanup: on` by default. After the last phase, one subagent removes the duplication, inconsistency and dead code that per-phase windows leave behind, behaviour-preserving only, before the audit re-verifies everything.
- **Security pass** — `Security pass: yes` when the build touches any security surface: network or HTTP, authentication or authorisation, user input, file paths, shell or process execution, secrets or credentials, deserialisation, or new dependencies. Otherwise `skip — <reason>` (e.g. `skip — docs and styling only`). Name the surfaces you found; Stage 6 shows them.

**Push** — `Push: on` or `off — <reason>`, from Stage 1: `off — default` when nothing chose it, `off — --no-push`, `off — RELAY_PUSH=off`, `off — no git repository`, `off — no remote`; `on` for `--push` or `RELAY_PUSH=on`, or `on — to <remote>` when Stage 1 picked one of several remotes. It only matters on a branch relay creates (Stage 7); on the user's own branch nothing is ever pushed, but write the field anyway.

**Under `--lean`**, write `Review: skip — --lean` on every phase, `Cleanup: off — --lean` and `Security pass: skip — --lean`. Still make the security assessment above: when it finds surfaces, Stage 6 warns that the pass is off, and the user can switch any check back on there (change that one field or line; the rest stay off). `references/phase-design.md` has the guidance on review skips and security surfaces.

---

## Stage 5 — Write the roadmap and phase specs

Three files, all under `$RELAY_ROOT/`:

1. **`ROADMAP.md`** — the plan (template at `$RELAY_DIR/templates/ROADMAP.md`).
2. **`STATE.md`** — live progress file the orchestrator records into after each report (via `record-phase.sh`) (template at `$RELAY_DIR/templates/STATE.md`; if Stage 2.7 already created it, fill that copy in). Fill `Memory dir:` with `$MEM_DIR` from Stage 0 — the `/goal` session has no other way to find where memory writeback goes. Fill `Cleanup:` (`on`, or `off — <reason>`) and `Security pass:` (`yes`, or `skip — <reason>`) from Stage 4 — `record-phase.sh` routes the run by them, and a missing field means the step never runs. Fill `Push:` (`on`, or `off — <reason>`) too — `relay-git.sh` reads it, and a missing field means the old push-after-the-audit behaviour, not off.
3. **`phases/phase-N.md`** — one work-spec file per phase (template at `$RELAY_DIR/templates/phase-goal.txt`, renamed conceptually to "phase spec"). **Any length** — these are read from disk by the executor, not passed to `/goal`, so no char budget.

Each phase spec must include these markers so the agent and evaluator both have stable anchors:

```
RELAY_PHASE_START
Phase: <N> of <total> — <name>
Task: <one-line>
Mandatory commands: <list>
Acceptance criteria: <count>
Evidence required: <list>
Depends on phases: <list or "none">
Map seeds: <3–6 exact existing symbol names, or "none">
Estimated files: <n new + modified>
Review: <yes | skip — reason>

[... full work description, exemplars, acceptance criteria, evidence requirements ...]

[Agent will print RELAY_PHASE_VERIFY and RELAY_PHASE_DONE here during execution]
```

Validate each spec with `bash $RELAY_DIR/scripts/validate-phase.sh "$RELAY_ROOT/phases/phase-N.md"` — it confirms the required markers exist and rejects a missing `Review:` line or a skip with no reason. No char budget.

**Map seeds.** Give every phase a `Map seeds:` line naming 3–6 types or symbols the phase will read or change (e.g. `Map seeds: Scheduler, HistoryStore, OverlayViewModel`). At phase start the executor refreshes the code graph and reads a compact map of those symbols — declaring files, members, what they use, what uses them, with file:line — before opening files. The graph is rebuilt at every dispatch, so a seed must exist **when its phase runs**, not when you write the plan: a symbol already in the code, or one an **earlier** phase creates and names in its spec. On a greenfield build, later phases seed the types earlier phases created — phase 9 seeds phase 2's model. A type the phase creates itself isn't there at its own dispatch; seed its neighbors instead. `Map seeds: none` is correct only for greenfield phase 1 and for runs without graphify. Once every spec is written, check all seeds at once:

```bash
bash "$RELAY_DIR/scripts/check-seeds.sh" "$RELAY_ROOT"
```

It resolves each seed against `$RELAY_ROOT/graph/graph.json` (when Stage 2 built one) or an earlier phase's spec, and prints a ❌ per seed that resolves to neither — a typo (its `suggestions:` line usually names the right label) or a symbol no earlier phase creates. Fix the name, seed a neighbor, or drop it. Guidance: `references/phase-design.md`.

**Exemplars.** Give every phase a `## Exemplars` section naming 2–3 **existing** files whose patterns the phase must match — "follow the control pattern in `Sources/App/UI/Controls.swift`; match the test shape in `Tests/SchedulerTests.swift`". Write them now, while recon context is warm: this is the only moment anything sees the codebase holistically, and the subagent that executes the phase starts cold and opens these files first. Greenfield phase 1 may say `- none yet (first code in the repo)`; every later phase names files earlier phases created. `validate-phase.sh` warns when the section is missing.

**Design package (Stage 2.7).** A phase that builds a screen names, in its Work, the file that gets the screen's `design: <id>` comment — the screens-built criterion counts exactly one per id. Its `## Exemplars` cite the design by section and file next to the code exemplars — `design/HANDOFF.md §overlay`, `design/screens/overlay.png` — never `design/source/` and never all of `HANDOFF.md` when one section will do.

**Research (Stage 2.6).** A phase whose work a research answer shapes cites it by section —
`research/pitch-detection.md §Implications for this plan` — and copies the specific fact it
depends on (a window size, an API call order, a version pin) into its `## Notes`. Never cite a
research file whole.

**Self-contained specs.** The executor is a fresh subagent that reads the spec inside its brief and cannot ask anyone anything. Anything you would have told an inline executor in passing — the assumption behind a criterion, which of two files is canonical, why a command is mandatory — goes in the spec's `## Notes`.

**A `## Mandatory commands` bullet is the command alone** (backticks optional) — pre-flight, the tidy-up and the security pass run each bullet as written. Put the summary line it should print under `## Evidence required`; `validate-phase.sh` rejects a bullet with a description after the command (a tunez bullet `` `npm run build` — summary; exit 0 `` ran as `; exit 0` and passed). List the gate even when its prerequisites come from the build (no `package.json` before phase 1) — pre-flight reports those as not runnable yet, not as failures.

**No git in phase specs.** Relay commits every phase itself (`relay-git.sh commit`, the last step of a passing verify; `PHASE-BRIEF.md` §6), on the branch Stage 7 sets up, and pushes only after the audit, and only with `Push: on`. So a spec carries no commit, branch, or push bullets and no criterion about commits — a planner-written "commit as …" would make two commits per phase, and a "do not commit" would contradict the brief. The one exception is a push the task itself is about (a deploy that works by `git push`), and only when `SPEC.md` asks for it.

**Shared planning docs are cited by section, never required whole.** If phases lean on a doc you wrote (definitions, formulas, an API contract), point each spec at the sections it needs — "`DEFINITIONS.md` §2 (tool accounting)" — and copy anything every phase needs verbatim into the spec itself. Never write "REQUIRED reading" for a whole doc, and keep large fixture READMEs off every phase's reading path. In the first end-to-end run every subagent `cat`-ed a 17.5k-character definitions file because each spec required it; a window's size is set by what it reads, not what it writes (`references/phase-design.md`).

---

## Stage 6 — Plan review & confirmation (hard gate)

Before any `/goal` is dispatched, show the user the full plan and **ask for explicit confirmation**. The chain runs unsupervised once it starts, so this is the last cheap moment to correct course. Skipping this step is a bug.

### Stage 6a — Self-critique pass (cheap, runs once)

Plan-time is the cheapest moment to catch the most expensive bugs (vague criteria, mis-sliced phases, weak dependencies). Before printing the summary, run **one** self-critique turn answering exactly four questions:

1. **Falsifiability:** Is every acceptance criterion across every phase a yes/no test, not a vibe? Flag any that say "works", "good", "ready", "correct" without a measurable predicate.
2. **Phase atomicity and size:** Is any phase secretly two coherent units packed into one (deliverables that don't share a verify gate, names containing "and", split-able dependency lines)? Does any phase's `Estimated files:` exceed 12 without a stated reason? And what must each phase **read** — its exemplars, seeds, cited docs and the files it modifies? A heavy reading path is the real size risk (a 2-file phase peaked at 256k); narrow it or split the phase. And the checks: is any `Review: skip` on a phase that changes behaviour (only docs- or config-only phases should skip), and does the security decision match what the build touches?
3. **Weakest dependency:** Where would a partial failure cascade worst? (e.g., phase 2 unblocks 3, 4, and 5 — if 2 ships shaky, three phases inherit the bug.)
4. **Intent coverage:** Does every `SPEC.md` success criterion map to at least one phase's acceptance criteria, and does every phase trace back to something the spec asked for? Name any criterion no phase delivers (a gap) and any phase serving nothing in the spec (scope creep). This is the only check that compares the plan against the *source* rather than against itself — the other three grade the compilation on its own terms.

**Output:**

- If clean: record `Self-critique: clean.` and proceed.
- If findings: list 1–4 specific findings (no padding). An unmapped spec criterion is a plan bug: add or widen a phase before printing the summary. For falsifiability issues, **rewrite the offending criteria in place** in the affected `phase-N.md` files and `ROADMAP.md` before printing the summary. Re-run `validate-phase.sh` on any touched spec. Surface the rewrites in the Stage 6 summary so the user sees the post-critique version, not the pre-critique one.

Honesty check: this pass must produce findings *or* a "clean" verdict per run. If it silently always says "clean" on real plans, it's theater and we remove it in the next release.

**Then compile the rubric** — every phase's acceptance criteria and mandatory commands, in one file:

```bash
bash "$RELAY_DIR/scripts/build-rubric.sh" "$RELAY_ROOT"
```

It prints one line (`rubric: <N> criteria across <M> phases, <K> flagged → <path>`) and writes
`$RELAY_ROOT/RUBRIC.md`. The flagged criteria are the handful worth a human look: *human eye*
(screenshots, visual or manual checks — the audit will likely mark these `trust-prior-verify`)
and *outside the repo* (deploys, network, accounts). Read the flagged lines from `RUBRIC.md` for
the summary; don't read the phase specs again. Re-run it after every Stage 6 revision.

### Stage 6b — Summary print

Print a scannable summary in this exact shape:

```
✓ Plan ready for review. <N> phases.

Applied from memory:
  - <memory hit 1>
  - <memory hit 2>
  (or: "none — clean run")

Spec (<run-root>/SPEC.md) — what the audit will grade against:
  S1. <success criterion, one line>
  S2. <success criterion, one line>
  ...
  Ambiguity: <score> (gate ≤ 0.15) · <N> round(s)<, dimensions below minimum: ...>
  Unresolved edges: <count, or "none">
  Research: <n> questions — <a> answered, <u> unverified finding(s), <c> contradiction(s) resolved
    (or: "none — <reason>")
  Design: design/HANDOFF.md @ <sha> — <S> screens · fidelity S<a>–S<b><, no tokens/components/copy check: …>
    (or: "skipped" · or omit the line when there was no design stage)

Phases:
  1. <name> — <one-line deliverable>
  2. <name> — <one-line deliverable>
  ...
  N. Polish & Harden — every aspect verified

Done when: every phase's acceptance criteria pass (<N> across <M> phases — <run-root>/RUBRIC.md)
  and the final audit re-verifies S1–S<n> and the mandatory commands. Nothing else ends the run.

Checks: review after phases <list> (skipped: <k> — <phase: reason, …>) · tidy-up on/off
  · security pass on (<surfaces>) / skipped — <reason>
  (or, under --lean: "Checks: off (--lean) — no review, tidy-up or security pass", plus, when
   the security assessment found surfaces:
   "⚠ This build touches <surfaces>; the security pass is off because of --lean — say
    \"security on\" to restore it.")

Push: off — <branch> stays local; say "push on" to push it after the audit
  (or: "Push: on — <branch> goes to <remote> after the audit", <remote> as `setup` reports it
   — never a placeholder; "Push: on — no remote yet; add one before the run ends" when the user
   chose to add it themselves; on the user's own branch:
   "Push: n/a — commits land on <branch>, which relay never pushes")

Worth your eye (<K> of <N> criteria):
  - Phase <n> (human eye): <criterion>
  - Phase <n> (outside the repo): <criterion>
  - Design (after the run): compare <run-root>/design-check/<id>.png with design/screens/<id>.png
  (or: "none — every criterion is checkable inside the repo")

Stack: <stack> · pkg: <pm> · build/test/lint: <commands>

Scope I decided (not asked — correct any):
  - <each `(planner)` item from SPEC.md's Out of scope>
  (or: "none — every exclusion was your call")
  (the checks after the build may change these and the key assumptions to fix a real flaw — the
   run's last message says so; what you chose, they never override)

Prohibited (the run must not do these):
  - <each kept prohibition from SPEC.md, one line>

Key assumptions (correct any that are wrong):
  - <assumption 1>   (unverified research findings and unanswered research questions go here)
  - <assumption 2>
  - <assumption 3>

Top risks & mitigations:
  1. <risk> → <mitigation>
  2. <risk> → <mitigation>
  3. <risk> → <mitigation>

Self-critique:
  - <finding 1, or "clean">
  - <finding 2 (optional)>
  - <finding 3 (optional)>
  (criteria rewrites applied in-place if any were flagged)

Artifacts:
  Spec: <run-root>/SPEC.md
  Rubric: <run-root>/RUBRIC.md (every phase's acceptance criteria and commands)
  Roadmap: <run-root>/ROADMAP.md
  Progress: <run-root>/STATE.md (auto-updates)
  Phase specs: <run-root>/phases/phase-1..N.md

Once you confirm, I'll print a ready-to-paste `/goal` line. Paste it
once and the chain runs through to completion, with auto-retry and
fix-spec recovery.
```

Print the success criteria in full, not a count. The user approved a phase list in earlier versions of this skill and never saw the rubric their run would be graded against — that is the gap this closes, so do not summarise it away. The phase-level criteria gate completion just as much, but there are too many to print (121 on a 14-phase plan), so the summary gives their count, the file, and — inline — only the flagged ones. The `/goal` line itself carries no criteria: it is the same procedural condition every run, and says nothing about what is being built.

Then call `AskUserQuestion` with one question, header "Start chain?", offering **concrete revision modes** (not a vague "revise plan"):

- **Start now** — run pre-flight smoke check (Stage 6.5), then print the ready-to-paste `/goal` line; I paste it and the chain runs unsupervised
- **Adjust an assumption** — pick one to change (will re-show plan)
- **Tweak a phase** — change criteria, scope, or commands for a specific phase (including its `Review:` line, the run's tidy-up and security checks, or push on/off — turning push on runs Stage 1's remote check and question first)
- **Restructure phases** — merge, split, add, or remove a phase

If the user's correction changes *what is being built* rather than how it is sliced, the spec is
wrong, not the plan: update `$RELAY_ROOT/SPEC.md`, re-run `validate-spec.sh`, and re-derive the
affected phases. Never let `ROADMAP.md` and `SPEC.md` disagree — the audit checks both.

Keep options at 4 max. If the user picks any revision option, follow up with a second `AskUserQuestion` to pin down exactly what (e.g., "Which assumption?" with the assumptions listed). For **Tweak a phase**, once the phase is chosen, **put that phase's criteria in the follow-up question's text** — read them from `RUBRIC.md`, number them, and list the mandatory commands under them, then ask what to change (`Criteria` / `Scope` / `Commands`). The user cannot correct a criterion they have not seen, and a question is the one place text is certain to be read: in session D the planner `awk`-ed the rubric section into collapsed tool output and then asked what to change, which showed the user nothing. Apply the change, update ROADMAP/THINKING/STATE and the affected phase specs, re-run `validate-phase.sh` on each touched spec, then `check-seeds.sh` and `build-rubric.sh` once, then re-show the Stage 6 summary and ask again. Loop until "Start now" or user aborts.

**Wait for the answer.** Do not dispatch `/goal` until the user picks "Start now". Never assume confirmation; never start the chain on silence.

---

## Stage 6.5 — Pre-flight smoke check

After Stage 6 returns "Start now" and **before** printing the `/goal` block, run a single pre-flight pass against the deduplicated mandatory commands. This catches the case where the baseline is already broken (e.g., `pnpm build` red before phase 1 ever ran) — without this, the 3-strike loop would thrash trying to "fix" phase 1 work that was never the cause.

**Procedure:**

1. List the sign-in status command of every account the plan reaches (Operating principles: `vercel whoami`, `gh auth status`) with its login command — a deploy phase that finds itself signed out at 3 a.m. hands off the run.
2. Run the pre-flight — one call, from the project root:
   ```bash
   bash "$RELAY_DIR/scripts/preflight.sh" "$RELAY_ROOT" --account 'gh auth status' 'gh auth login'
   ```
   (one `--account '<status>' '<login>'` pair per account from step 1; none when the plan reaches no account). It unions every phase spec's `Mandatory commands:` into a deduplicated set and runs each once (full output in `$RELAY_ROOT/logs/preflight/`) — except a command whose prerequisites only the build creates (no `package.json` yet or no such script in it, no `Cargo.toml` / `go.mod` / `Makefile` / …, a script file that does not exist yet, `check-design.sh --verify`), which it lists as `- later <command> — <why>; first used by phase N` without running. That list is fixed in the script; you cannot add to it, so a broken baseline still shows as `FAIL`. Then it checks the working tree with `relay-git.sh preflight` — after the commands, so anything they created is caught too — appends the outcome to `STATE.md`'s `Notable events`, and prints the `PREFLIGHT_GREEN` / `PREFLIGHT_RED` block: per-command `ok` / `FAIL` lines (a failure with its exit code, last 5 lines, and `run: ! <login>` for an account check), then the `git:` lines. **Its output is the block — show it to the user as printed** (all of it, `later` lines included — never a summary of it); never write your own loop (the inline zsh loop broke on two runs and never printed the block). Exit 0 = green (`later` lines allowed), 1 = a command failed, 3 = the working tree is dirty. **The pre-flight outcome is never a plan assumption**: don't write "pre-flight will be red — dispatch with skip" into Key assumptions (the tunez planner did, which made the skip routine) — a red result goes to the owner through step 5.

   Why the tree matters: relay commits each phase with `git add -A`, so any uncommitted change — modified tracked files **or** untracked files — would be swept into phase 1's commit (and `repo-state.sh` would count it as the run's work). The `git:` lines also carry the branch plan (on the default branch: a `relay/<run-id>` run branch, pushed after the audit with `Push: on` or kept local with it off; on any other branch: commits land there, never pushed) and warnings that never block — commit signing on, or a remote relay cannot reach (checked only with `Push: on`) (the run still finishes; a failed push is reported for the user to do by hand). Without git it says relay will not commit, and passes.
3. **Exit 3 — the tree is dirty** (whatever the commands did): ask with `AskUserQuestion`, putting the `git: ❌` line's path list in the question text: **"I've committed or stashed it — re-check"** / **"Stop here"**. Say how in the question: commit what they want to keep, or `! git stash -u` to set everything aside (`! git stash pop` after the run). **Never stash, commit, or discard the user's work yourself, and never offer to dispatch anyway** — phase 1's commit would take their work with it. "Re-check" runs step 2 again (the whole pre-flight — a command result from before the cleanup would be stale); "Stop here" ends the session; the plan stays in `$RELAY_ROOT`.
4. **Exit 0 — green:** proceed to Stage 7.
5. **Exit 1 — a command is red** (and the tree is clean): re-show the Stage 6 summary with the failures surfaced and a revised menu (still 4 options to stay under the `AskUserQuestion` ceiling): **"Skip pre-flight, dispatch anyway"** (replaces "Start now" — the user might know the baseline is intentionally broken, e.g., phase 1's whole job is to fix it) / **"Adjust an assumption"** / **"Tweak a phase"** / **"Restructure phases"**. If "Skip pre-flight, dispatch anyway" → `bash "$RELAY_DIR/scripts/preflight.sh" "$RELAY_ROOT" --bypass` (logs `Pre-flight bypassed by user.`) and proceed to Stage 7. Any other choice loops back through the normal Stage 6 revision flow; after the user finishes revising, Stage 6.5 re-runs.

**Honesty test:** real command run, real exit code. The "skip anyway" option keeps the user in control — no forced re-plan if the baseline being red is the point.

---

## Stage 7 — Hand off the `/goal` dispatch (one paste)

Slash commands fire **only from user input** — agent message text is never parsed as a command. So Stage 7 is not an automatic dispatch; it's an honest one-paste handoff. After explicit "Start now" in Stage 6:

1. **Set up the run branch** — before the baseline, so nothing moves after it is captured:
   ```bash
   bash "$RELAY_DIR/scripts/relay-git.sh" branch "$RELAY_ROOT"
   ```
   On the default branch (or a detached HEAD, or a repository with no commits yet) it creates and switches to `relay/<run-id>`; on any other branch it leaves HEAD where it is. A repository with no commits also gets an empty first commit (`relay: start <run-id>`) on the run branch, so the baseline below is a real commit. Write its one line of output to `STATE.md`'s `Branch:` field. Exit 1 prints the reason: `working tree is not clean` → the tree got dirty since Stage 6.5, go back to Stage 6.5 step 4; anything else (the run branch already exists but is not checked out, or git refused the switch or the first commit) → show the user the message, which says what to run, and re-run this step once they have. Then update `STATE.md`: `Status: READY_TO_DISPATCH`, `Current phase: 1`, and **capture the baseline ref** — set `Baseline ref:` to the output of `git rev-parse --verify -q HEAD 2>/dev/null || echo "no-git"`. The audit reads this to diff deliverables against the working tree. Confirm `Memory dir:` holds the absolute `$MEM_DIR` path (not a placeholder).
2. Copy the operating manual and the helper scripts into this run's namespace, baking the run root into the manual:
   ```bash
   sed "s#{{RUN_ROOT}}#$RELAY_ROOT#g" "$RELAY_DIR/templates/PROTOCOL.md" > "$RELAY_ROOT/PROTOCOL.md"
   cp "$RELAY_DIR/templates/MARKERS.md" "$RELAY_ROOT/MARKERS.md"
   cp "$RELAY_DIR/templates/PHASE-BRIEF.md" "$RELAY_ROOT/PHASE-BRIEF.md"
   cp "$RELAY_DIR/scripts/assemble-brief.sh" "$RELAY_ROOT/assemble-brief.sh"
   cp "$RELAY_DIR/scripts/record-phase.sh" "$RELAY_ROOT/record-phase.sh"
   cp "$RELAY_DIR/scripts/resume-line.sh" "$RELAY_ROOT/resume-line.sh"
   cp "$RELAY_DIR/scripts/recover.sh" "$RELAY_ROOT/recover.sh"
   cp "$RELAY_DIR/scripts/repo-state.sh" "$RELAY_ROOT/repo-state.sh"
   cp "$RELAY_DIR/scripts/relay-git.sh" "$RELAY_ROOT/relay-git.sh"
   cp "$RELAY_DIR/scripts/check-design.sh" "$RELAY_ROOT/check-design.sh"
   cp "$RELAY_DIR/scripts/run-logged.sh" "$RELAY_ROOT/run-logged.sh"
   cp "$RELAY_DIR/scripts/build-graph.sh" "$RELAY_DIR/scripts/map-slice.sh" "$RELAY_DIR/scripts/map-slice.py" "$RELAY_ROOT/"
   ```
   `PROTOCOL.md` is the manual the executing agent reads at the start of the `/goal` session; the `sed` substitutes the concrete run root for every `{{RUN_ROOT}}` placeholder, so the agent reads `$RELAY_ROOT/STATE.md` (etc.), never a placeholder. `MARKERS.md` carries the exact transcript block formats — `references/` is never copied into a run, so this is the only copy the `/goal` session can read. `PHASE-BRIEF.md` is the subagent contract; `assemble-brief.sh` expands it per phase (spec + carryover + map slice + state + formats) into `phases/phase-N.brief.md`, which the orchestrator dispatches without reading; `record-phase.sh` validates each subagent's report file and applies every `STATE.md` change for its outcome, so the orchestrator never hand-edits `STATE.md`. `resume-line.sh` prints the ready-to-paste `/goal` that restarts a blocked run from the phases that remain — `PROTOCOL.md` calls it after a handoff so a stopped run is not lost. `recover.sh` is what a reopened session runs after an interruption: it tells a window that died with the old process from one still running, and settles it (`PROTOCOL.md` "After an interruption"). `repo-state.sh` is the complete-working-tree comparison helper the cleanliness + deliverable checks invoke (strategy in `references/repo-state-comparison.md`); `run-logged.sh` runs each mandatory command with its full output written to `<run-root>/logs/`, printing only the exit code and a short tail. `relay-git.sh` is how each phase, fix, review-fix, tidy-up, security-fix and audit-fix subagent commits its work once it passes, and how the orchestrator pushes the run branch once after the audit (only a branch relay created, only with `Push: on`; off prints the command instead; a failed push is reported, never a blocker). `build-graph.sh`, `map-slice.sh`, and `map-slice.py` let the executor refresh the code graph and read each phase's map slice. `check-design.sh --verify` is the design-fidelity check the S-criteria from Stage 2.7 name (copied on every run; unused without a design package). The helpers take paths as arguments, so none needs substitution.
3. Verify each `$RELAY_ROOT/phases/phase-N.md` exists; run `bash $RELAY_DIR/scripts/validate-phase.sh "$RELAY_ROOT/phases/phase-<N>.md"` on each. Run `bash $RELAY_DIR/scripts/check-seeds.sh "$RELAY_ROOT"` once — a Stage 6 revision can renumber phases or rename a type a later phase seeds. Confirm `STATE.md` carries `Cleanup:` (`on` or `off — <reason>`), `Security pass:` (`yes` or `skip — <reason>`) and `Push:` (`on` or `off — <reason>`), with no placeholder: `grep -E '^\*\*(Cleanup|Security pass|Push):\*\* (on|off —|yes|skip —)' "$RELAY_ROOT/STATE.md"` must print three lines. Re-run `bash $RELAY_DIR/scripts/validate-spec.sh "$RELAY_ROOT/SPEC.md"` too — Stage 6 revisions can edit the spec, and this is the last point before it becomes the audit's rubric. A ❌ here blocks dispatch.
4. Print a fenced code block with the **ready-to-paste `/goal` command**. **Substitute the literal value of `$RELAY_ROOT` for every `<run-root>` below** (e.g. `.relay/add-dark-mode-Ab3Kx9`) — the pasted line must contain the real directory, not the variable or the `<run-root>` placeholder. The condition is short, instructional but measurable, and well under the 4000-char `/goal` argument limit:

````
```
/goal "Working from this directory (never cd elsewhere), execute all phases of <run-root>/ROADMAP.md sequentially, following <run-root>/PROTOCOL.md: for each phase, assemble its brief and dispatch it to a subagent, then echo the subagent's marker blocks (RELAY_PHASE_VERIFY then RELAY_PHASE_DONE) verbatim into this transcript; follow PROTOCOL.md's failure-recovery protocol if any criterion fails. Run the review, cleanup and security steps PROTOCOL.md names whenever record-phase.sh routes to them, echoing their blocks verbatim. After the last phase and its checks, run the FINAL AUDIT in <run-root>/PROTOCOL.md (re-verify against <run-root>/ROADMAP.md and <run-root>/SPEC.md; re-run aggregated mandatory commands; spot-check criteria; on gaps, write <run-root>/phases/audit-fix-<round>.md and dispatch it to a fresh subagent). Only after AUDIT_COMPLETE, print RELAY_RUN_COMPLETE. Done when RELAY_RUN_COMPLETE appears in the transcript with one RELAY_PHASE_DONE per phase, AUDIT_COMPLETE printed before RELAY_RUN_COMPLETE, and no FAILURE_HANDOFF or AUDIT_HANDOFF this run."
```
````

5. Follow the fenced block with **exactly this instruction** (substitute the working directory's absolute path for `<cwd>`):

> **Exit this session (`/exit`), start a new Claude Code session in `<cwd>`, and paste the `/goal` line above there.** The new session becomes the run's orchestrator: it starts with an empty context window, and its transcript holds only the run, which is what `check-run.py` reads. From there it runs autonomously — auto-retry, fix-spec recovery, per-phase memory writeback — until `RELAY_RUN_COMPLETE` appears.

   Then, still part of the same instruction, print this paragraph (same substitutions):

> **If the run stops.** Run it in auto mode and leave the session open: after a usage limit that resets within a day, Claude Code waits and continues on its own. After a weekly limit, a closed terminal, a crash or a restart, reopen the run's conversation — `cd <cwd> && claude --resume`, pick this run's session — and type `continue`: the goal comes back and relay picks up the interrupted phase, keeping its half-done work. If the goal does not come back, `bash <run-root>/resume-line.sh <run-root>` prints a fresh `/goal` line to paste instead.

   Why a new session (commit 14): pasting here would carry the whole planning context into the orchestrator's window, and the planner's own reads, writes and researcher dispatches would sit in the transcript the protocol checks run against. The `/goal` line's paths are relative, so the new session must start in the same directory.

6. **Stop.** Do not generate any further output. The Relay invocation ends here. The user's paste begins the autonomous run under a fresh `/goal` session, which reads `PROTOCOL.md` and `STATE.md` from disk and runs the orchestrator loop documented in the next section.

Once `/goal` is active (you'll see the `◎ /goal active` indicator), the per-turn evaluator keeps the agent working until the end-state condition holds. The agent inside the `/goal` session has zero special context from the Relay invocation; everything it needs is in the files on disk — by design.

---

## Phase execution loop (inside the single `/goal` session)

The `/goal` session has zero context from this planner session. It is an **orchestrator**: it follows `<run-root>/PROTOCOL.md` — the copy written at Stage 7 — and every phase, fix, and audit round runs in its own subagent context window from a brief built by `assemble-brief.sh` out of `PHASE-BRIEF.md`. In short:

- **Per phase:** the orchestrator runs `assemble-brief.sh` (spec + executor contract + carryover memory + precomputed map slice + state excerpt + block formats → `phases/phase-N.brief.md`) → dispatches a `general-purpose` subagent with "read the brief and follow it" (dispatch is asynchronous: the report arrives later as a hand-back message) → **echoes the subagent's marker blocks verbatim** into the transcript, first, before any tool call → records the report with `record-phase.sh`, which updates `STATE.md` and prints what is next.
- **Inside the subagent:** open the exemplars and the map slice → do the work, running mandatory commands through `run-logged.sh` → record everything in `<run-root>/phases/phase-N.evidence.md` → memory writeback → write the report to `phases/phase-N.report.md` and return the same text: only `RELAY_PHASE_START`, `RELAY_PHASE_VERIFY`, `MEMORY_SAVED`, `RELAY_PHASE_DONE`.
- **3-strike recovery, hybrid:** the phase subagent auto-retries once with a failure probe; on a second failure it writes a fix spec and returns `FAILURE_ESCALATE`; the orchestrator dispatches the fix to a **fresh** subagent, which returns `RELAY_PHASE_DONE` or `FAILURE_HANDOFF` (→ `BLOCKED`).
- **Checks, never blocking:** `record-phase.sh` routes a phase marked `Review: yes` to a review subagent (read-only; findings → one review-fix window), and after the last phase to the tidy-up (`Cleanup: on`) and then the security pass (`Security pass: yes`, findings → one security-fix window). A finding that cannot be fixed is undone and written to `FINDINGS.md`; `RELAY_RUN_COMPLETE` points at it.
- **Final audit** after the last phase, one subagent per round: re-verifies against the original `ROADMAP.md`, re-runs the deduplicated mandatory commands, checks every phase's evidence file and every declared deliverable against repo ground truth (`repo-state.sh`); gaps → an audit-fix subagent, up to 3 rounds; then the orchestrator prints `RELAY_RUN_COMPLETE`.
- **Memory writeback** at every phase boundary (`record-phase.sh` appends each `MEMORY_SAVED` name to `STATE.md`'s `## Carryover`, which feeds later briefs), plus a `project_<slug>.md` memory at the final phase.
- **Interruptions** pause at the next phase boundary. If the `Agent` tool is unavailable, the orchestrator executes the brief inline under the same contract.

To change the orchestrator, edit `templates/PROTOCOL.md`; to change what a subagent does, edit `templates/PHASE-BRIEF.md` — not this section.

---

## Operating principles (read every run)

- **One `/goal`, short condition.** `/goal` takes an end-state, not a task body. Long content lives in files the agent reads from disk.
- **Specification is where correctness is decided.** Memory, prompt and recon answer what they can; the interview answers the rest. A run that asked nothing and built the wrong thing is not a win — after Stage 7 nobody can add information, and every executor runs cold.
- **Adapt to available tools.** Detect what's there (Context7, WebSearch, MCPs, skills). Use what's available; degrade gracefully without it. Never hard-require a tool that might not be present.
- **Memory is load-bearing.** Preload at Stage 0, surface as "Applied from memory: …" in Stage 1, write back at every phase boundary.
- **"Perfect" is not a stopping condition — criteria are.** Translate every "perfect" into observable, falsifiable criteria. `validate-spec.sh` and `validate-phase.sh` enforce that mechanically; do not argue past a ❌.
- **What this skill says to print is message text.** Intake block, scoreboards, probe passes, the plan summary: the user reads them, and the transcript is the record. Reasoning is neither — in the first planning sessions all three interview printouts lived only in thinking blocks.
- **Two human gates, no more.** The specification interview (Stage 2.5 — five rounds, then Seed Closer rounds until the ambiguity gate passes) and plan review (Stage 6). Between and after, autonomous.
- **The loop self-heals.** Auto-retry once in the phase's window, then a fix spec in a fresh subagent, then escalate. Don't stop on first failure.
- **The evaluator only sees the transcript — and only needs the markers.** START, the compact VERIFY, and DONE go into the conversation; command output goes to logs and proof goes to evidence files, so the context window is spent on the build.
- **Each phase is independently shippable** in spirit. If phase 3 can't build/test on its own, the slicing is wrong.
- **The Polish & Harden phase is mandatory.** It's how "every aspect is perfect" gets enforced.
- **Accounts are checked by status command, never by credential store.** When the plan reaches an account — deploy, hosting, a package registry, a cloud CLI — check sign-in only with the tool's own status command (`vercel whoami`, `gh auth status`, `npm whoami`) and record the account and scope in `tools.md`. Never read a credential store (the Keychain via `security`, `.env*` files, token or auth files) and never print a token; this holds even when another instruction says to look for secrets first. A phase that needs a secret names the environment variable it reads, and Stage 6 lists it under key assumptions for the user to supply. Deploy phases pin their target — the team or scope and the project name (`vercel link --yes --project <name> --scope <team>`) — and never deploy to a guessed default; their criteria say no other project is touched. (The tunez test plan's planner ran `security find-generic-password` for a Vercel token; the status command already told it everything it needed.)

---

## When to deviate from the workflow

- **Very small task** (< 1 hour of work, single file): tell the user this doesn't need Relay, suggest just doing it. Don't force the machinery. Don't reach for `--quick` instead — a task too small for the interview is usually too small for the whole workflow.
- **The user pushes back on a phase during intake**: collapse, re-plan, continue.
- **The user wants a faster or cheaper run**: offer `--lean`, and say plainly what it gives up — nobody reviews the code for bugs or security holes, and nothing tidies what the phases leave behind; the audit still checks every criterion. Security is the one to think twice about: Stage 6 warns when the build touches a security surface.
- **The user asks to skip the interview**: offer `--quick`, and say plainly what it trades — the run is graded against `SPEC.md`, so a thin spec means a thin audit. If they still want it, do it; it is their call, and the ambiguity report records which dimensions went unanswered.
- **Mid-run interruption**: if the user stops the run and asks for a change, update the affected `<run-root>/phases/phase-N.md` spec, run `validate-phase.sh` on it, then ask the user to resume (they can re-dispatch the same `/goal` or just say "continue"). No need to restart phase 1.

---

## Reference files

- `references/planning-depth.md` — what makes a plan deep enough to hand off
- `references/phase-design.md` — how to slice phases that auto-chain cleanly
- `references/research.md` — Stage 2.6: why research runs once at plan time, what makes a good question, the researcher contract
- `references/design-stage.md` — Stage 2.7: the design package contract, the fidelity criteria and why they stay structural, how phases use the package, edge cases
- `references/goal-format.md` — what `/goal` is, Relay's single-`/goal` shape, who prints the transcript blocks (formats themselves: `templates/MARKERS.md`)

## Scripts

- `scripts/active-runs.sh` — lists this tree's runs whose `STATE.md` is not COMPLETE (Stage 0; planner-only)
- `scripts/stale-memories.sh` — lists project memories that point at a deleted `.relay/<run-id>` (Stage 0; planner-only)
- `scripts/detect-stack.sh` — identifies language, package manager, framework, build/test/lint commands (brownfield)
- `scripts/detect-env.sh` — greenfield environment recon
- `scripts/summarize-repo.sh` — compressed repo map (brownfield)
- `scripts/validate-phase.sh` — checks a phase spec has the required RELAY_PHASE_START marker, a non-empty acceptance criteria section, at least one mandatory command, and a header criterion count matching its bullets; warns on a missing `Map seeds:` / `Estimated files:` / `## Exemplars`, on unreplaced placeholders, and when `Estimated files:` exceeds the sizing threshold (12) without a stated reason
- `scripts/validate-spec.sh` — the Stage 2.5 content gate: required sections, an `Acceptance:` line and a measurable predicate on every success criterion, no edge dismissed without a reason, and every edge the probe raises given a row
- `scripts/edge-probe.py` — classifies each success criterion by shape and raises only the edge categories that apply to it (closed 8-item taxonomy); a floor to union with, never to narrow. `--check <SPEC.md>` enforces the floor (called by `validate-spec.sh`)
- `scripts/build-rubric.sh` — compiles every phase's acceptance criteria and mandatory commands into `<run-root>/RUBRIC.md` and flags the ones worth a human look (Stage 6; planner-only)
- `scripts/check-research.sh` — validates the Stage 2.6 research (index, one sourced answer per question, a `Contradicts:` line each); `--digest` prints only the answers, implications and contradictions; `--only <slug>` checks one answer — the researcher's own check before it returns (planner-only)
- `scripts/prepare-design.sh` — settles the export the user put in `design/` (unzips a lone zip, lifts a wrapper folder) and commits `design/` only (Stage 2.7d; planner-only)
- `scripts/check-design.sh` — verifies the design package at `design/` (HANDOFF.md + one PNG per approved screen required, committed); `--criteria` drafts the design-fidelity success criteria plus their edge rows (Stage 2.7); `--verify <aspect>` checks the built code against the package — the command those criteria name (copied to `<run-root>/` at dispatch)
- `scripts/check-seeds.sh` — checks every phase's `Map seeds:` resolves to a symbol in the plan-time graph or one an earlier phase's spec names, i.e. something that will exist when the phase runs (Stage 5; planner-only)
- `scripts/recover.sh` — after an interruption, settles the dispatch that was in flight (the window died with the old process → recorded as interrupted and re-dispatched; still running → keep waiting; finished but unrecorded → echo and record), from the `phases/in-flight` file `assemble-brief.sh` writes (copied to `<run-root>/recover.sh` at dispatch)
- `scripts/resume-line.sh` — prints the ready-to-paste `/goal` that restarts a blocked run from the phases that remain, and warns when uncommitted work would land in the resumed phase's commit (read-only; copied to `<run-root>/` at dispatch)
- `scripts/preflight.sh` — Stage 6.5 in one call: runs every phase's mandatory commands (plus account sign-in checks) once, checks the working tree via `relay-git.sh preflight`, logs the outcome to `STATE.md`, and prints the `PREFLIGHT_GREEN` / `PREFLIGHT_RED` block; `--bypass` logs the owner's skip (planner-only)
- `scripts/relay-git.sh` — every git write a run makes: `setup` / `init` / `remote` (Stage 1: report, `git init` [+ save the folder's files], connect a private GitHub repo — never pushes), `preflight` (Stage 6.5: a dirty tree blocks; branch plan; signing / remote warnings), `branch` (Stage 7: `relay/<run-id>` from the default branch), `commit` (each phase / fix / audit-fix subagent, with the run's trailers; refuses secrets and generated files), `push` (the orchestrator, once after the audit; relay-created branches with `Push: on` only — off prints the command; always exits 0) (copied to `<run-root>/` at dispatch)
- `scripts/assemble-brief.sh` — builds a subagent's brief (`phases/phase-N.brief.md`, or `.fix.brief.md` / `audit-R.brief.md` / `audit-fix-R.brief.md`) from `PHASE-BRIEF.md`: spec, carryover memory files, precomputed map slice, state excerpt, block formats; one summary line (copied to `<run-root>/assemble-brief.sh` at dispatch)
- `scripts/record-phase.sh` — validates a subagent's report file (`phases/phase-N.report.md`, or `.fix.report.md` / `audit-R.report.md` / `audit-fix-R.report.md`) and applies every `STATE.md` change for its outcome — phase row, status, current phase, engineering lines, events, failure log, carryover — idempotently; logs no-report dispatches; one summary line (copied to `<run-root>/record-phase.sh` at dispatch)
- `scripts/run-logged.sh` — runs a command with its full output written to a log file, printing only the exit code and a short tail (copied to `<run-root>/run-logged.sh` at dispatch)
- `scripts/build-graph.sh` — builds or refreshes the run's graphify code graph at `<run-root>/graph/` when graphify is installed; one summary line, always exits 0 (Stage 2, and each phase start)
- `scripts/map-slice.sh` — prints a token-budgeted map slice of named symbols (members, uses, used-by, file:line), falling back to file-name matches without a graph or Python; runs `scripts/map-slice.py`

## Templates

- `templates/SPEC.md` — the run's agreed statement of intent (Stage 2.5): success criteria, edge coverage, prohibitions, ambiguity report, interview log
- `templates/RESEARCH-BRIEF.md` — the Stage 2.6 researcher brief: one question, spec context, source rules, the answer-file format `check-research.sh` validates
- `templates/DESIGN-BRIEF.md` — the Stage 2.7 brief for Claude Design or any design tool, ending in the fixed package contract
- `templates/ROADMAP.md` — phase plan with dependencies
- `templates/STATE.md` — live progress file
- `templates/phase-goal.txt` — phase spec skeleton (work, criteria, evidence, mandatory commands)
- `templates/PROTOCOL.md` — the orchestrator's manual: async dispatch loop, report validation, echo-first rule, recording via `record-phase.sh`, goal check-ins and orphaned shell tasks, no-report handling, audit dispatch, mid-run interruption (copied to `<run-root>/PROTOCOL.md` at dispatch, with `{{RUN_ROOT}}` substituted for the run root)
- `templates/MARKERS.md` — exact formats of every transcript block (copied to `<run-root>/MARKERS.md` at dispatch)
- `templates/PHASE-BRIEF.md` — the subagent contract: who you are, spec, carryover, code map, run state, how to work (context hygiene, evidence file format, cleanliness, memory writeback), failure protocol, report contract (report file + final message); mode-fenced for phase / fix / audit / audit-fix (copied to `<run-root>/PHASE-BRIEF.md` at dispatch, expanded per phase by `assemble-brief.sh`)
