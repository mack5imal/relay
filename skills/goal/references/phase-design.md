# Phase Design — slicing work that auto-chains cleanly

The goal of phase decomposition: hand the executor a sequence of **independently verifiable** units of work that compose into the full task. Done well, each phase has a clear "this is finished" signal and the next phase can start without re-reading the user's intent.

## How many phases?

**Whatever the task actually needs.** Phase count is derived, not chosen. There is no fixed range and no upper cap. Use these as loose orientation, not rules:

- **2 phases** — small change with a meaningful Polish & Harden pass at the end (one screen + harden; one API route + harden). Below this, you don't need Relay — just do the work.
- **3–4 phases** — small features, single-surface changes (one screen, one API route, one migration with tests).
- **5–7 phases** — typical features (foundation + core + integration + states/edges + polish, with a fork or two).
- **8–12 phases** — large features, full-stack greenfield apps, complex refactors that need a safety-net + staged migration.
- **13+ phases** — major migrations, multi-system rewrites, brownfield untangles. Don't combine just to hit a target number; combining hides dependencies.

**Two tests for whether you have the right count:**

1. **Each phase is independently verifiable.** It builds, typechecks, lints, and tests on its own; you could ship it as a partial increment. If a phase only makes sense once the next one is also done, merge them.
2. **Each phase delivers one coherent thing.** If you can't write its name in five words without using "and", you're packing two phases into one — split.

If you find yourself counting phases and trying to stay in some range, you're optimizing the wrong thing. Derive the count from the work; let it be 4 if that's right, 14 if that's right.

## Phase shapes that work

### The standard 5-phase shape (feature work)

1. **Foundation** — types, schemas, migrations, scaffolding. Builds but doesn't ship behavior.
2. **Core mechanic** — the central thing the feature does, working for the golden path.
3. **Integration** — wire into existing surfaces (routes, navigation, auth checks, etc.).
4. **States & edges** — loading, empty, error, unauthorized, offline; edge inputs.
5. **Polish & Harden** — copy, a11y, perf, security review, regression sweep, final QA.

### Brownfield refactor shape

1. **Safety net** — add characterization tests if coverage is thin.
2. **Extract** — pull out the abstractions you want without changing behavior.
3. **Migrate** — move callers to the new shape, one cluster at a time.
4. **Delete** — remove the old code.
5. **Polish & Harden** — final sweep.

### UI redesign shape

1. **Tokens & primitives** — design tokens, base components.
2. **Layout** — page shells, navigation, responsive grid.
3. **Content surfaces** — the actual screens, in order of prominence.
4. **Interactions** — animations, micro-interactions, state transitions.
5. **Polish & Harden** — a11y, contrast, copy, dark mode, motion-reduced, edge widths.

With a design package from Stage 2.7 (`references/design-stage.md`), the same shape carries the
design-fidelity criteria: phase 1 builds every token in `design/HANDOFF.md §Design tokens` into
one theme file and the named components as primitives; each content phase puts a
`design: <screen-id>` comment in the one file that builds each of its screens and cites
`design/HANDOFF.md §<screen-id>` + `design/screens/<screen-id>.png` as exemplars; Polish &
Harden captures each approved screen to `$RELAY_DESIGN_CHECK_DIR/<screen-id>.png` (the phase sets
it to `<run-root>/design-check` — never write a `.relay/` path into product code), or records
`capture unavailable: <screen-id> — <reason>`, for the owner's side-by-side after the run. It
records the one command that takes them as `Capture command: <command>`; the audit re-runs it, so
the screenshots show the build after the review, tidy-up and security fixes.

The fidelity criteria's check, `<run-root>/check-design.sh design --verify <aspect>`, covers
every approved screen at once, so it cannot pass until the last screen exists: make it a
mandatory command of the last screen-building phase and of Polish & Harden, not of earlier
phases (the tokens aspect is the exception — it can gate the tokens phase itself).

## Acceptance criteria — the test of a good phase

Each phase's acceptance criteria should be:

- **Traceable** — every criterion serves a `SPEC.md` success criterion or the engineering gate (build/typecheck/lint/test). One that serves neither is scope the user never asked for, and Stage 6a's intent-coverage check flags it
- **Observable in the transcript** — "build succeeds" is good; "feels right" is not
- **Atomic** — one fact per criterion
- **Falsifiable** — you can say yes or no, not "kind of"
- **Tied to commands or evidence** — `npm test` output, a file existing, a screenshot diff

Bad: "User authentication works."
Good:
- `npm run build` succeeds with 0 errors
- `npm run typecheck` succeeds with 0 errors
- Tests in `tests/auth/*.test.ts` pass
- `/api/auth/signin` returns 200 for valid credentials and 401 for invalid
- `<SignInForm/>` renders without console errors
- Authenticated middleware rejects requests without a session cookie

## Git is relay's job, not the spec's

Relay commits each phase itself: the phase subagent runs `relay-git.sh commit` as the last step of a passing verify (`PHASE-BRIEF.md` §6), a fix window commits on its success, and an audit-fix window commits its round. Stage 7 puts the run on a `relay/<run-id>` branch when it started on the default branch, and, when `STATE.md` says `Push: on`, the orchestrator pushes that branch once after the audit — never the user's own branch, and a failed push is reported, never a blocker. Push is off by default; then the branch stays local and the run's last message gives the command. So a phase spec carries **no** commit, branch, or push bullets and no acceptance criterion about commits: a planner-written "commit as `Phase 2: …`" makes two commits per phase, and "do not commit" contradicts the brief. The one exception is a push the task is *about* (a deploy that works by `git push`), written only when `SPEC.md` asks for it.

## Cleanliness (grep-checked at VERIFY)

Every phase's VERIFY block reports three grep-based counts against the complete set of added/new lines since the baseline — `bash <run-root>/repo-state.sh added-lines <Baseline ref>` (includes uncommitted + untracked work, not just committed; see `repo-state-comparison.md`):

- **Debug prints added** — `console.log`/`console.error` for JS/TS, `print(`/`pprint(` for Python, `print(`/`dump(` for Swift, `fmt.Println`/`log.Println` for Go (adjust per stack).
- **Session TODO/FIXME added** — `\b(TODO|FIXME|XXX)\b` introduced in this run's diff (not pre-existing).
- **Dead imports added** — new `import` statements with no usage in the same file.

Any non-zero count is treated like a failed acceptance criterion (3-strike). If a phase legitimately needs to ship debug output (e.g., a phase building a debug overlay or a logging integration), declare it in the phase spec with:

```
Cleanliness override: debug prints allowed (this phase ships <component>)
```

The override is read by the executor at VERIFY time and counts are reported but not failed. Keep overrides narrow — they're a release valve, not a default.

## Mandatory commands

Every phase must include the engineering commands the agent has to run (each through `run-logged.sh`, which writes the full output to a log and prints only the exit code and a short tail):

```
- pnpm build
- pnpm typecheck
- pnpm lint
- pnpm test
```

Each must exit 0 (lint: or only pre-existing warnings; test: or pre-existing failures proven unrelated). Adjust per stack. For iOS: `xcodebuild`, `swiftlint`, `swift test`. For Python: `uv run pytest`, `ruff check`, `mypy`.

**A bullet is the command alone** (backticks optional) — pre-flight, the tidy-up and the security pass run each bullet as written, so a trailing description runs too (`` `npm run build` — summary; exit 0 `` ran as command substitution plus `; exit 0`, a false pass). `validate-phase.sh` rejects a bullet with text after the command. Name the **summary line** each command should yield ("Tests: 47 passed, 0 failed") under `## Evidence required` instead, so the evidence file can report it without anyone opening the full log.

Pre-flight (Stage 6.5) runs these before phase 1. A command whose prerequisites come from the build — no `package.json` yet, a script a later phase adds, a script file that does not exist yet, `check-design.sh --verify` — is listed as *not runnable yet* rather than failed, so a greenfield plan can still be green. Don't avoid listing a command for that reason.

## Evidence required

For each phase, list what the agent must record in `<run-root>/phases/phase-N.evidence.md` to prove completion. The evidence file has no size budget; the transcript only carries the compact `RELAY_PHASE_VERIFY` block (one `pass|fail` line per criterion), and the final audit re-checks the work against repo ground truth. Common evidence types:

- **Command results** — exit code, log path, and summary line for each mandatory command
- **File listings** — `ls -la` of the new files created, with sizes
- **Diff snippets** — key changes, not full diffs
- **Screenshots** — for UI phases, paths to screenshots saved during execution. The executor opens an image only when a criterion needs a visual judgment, so don't write criteria that require reading every screenshot; prefer snapshot tests or explicit visual checks on named surfaces.
- **API responses** — `curl -X POST ... | jq` outputs for new endpoints
- **STATE.md update** — the new content of the phase's row

## Map seeds

Each phase names 3–6 symbols in a `Map seeds:` line. At phase start the executor reads a map slice of them — declaring files, members, what they use, what uses them, with file:line — built from a tree-sitter code graph (graphify), so it can open the right files without grepping the tree. The slice has a token budget (default 5000), so seeds are a precision tool, not a coverage list.

Choose seeds that are:

- **Exact, existing names** — `Scheduler`, not `scheduler logic`. Seeds match by exact label (case-insensitively as a fallback); a miss prints `no match` with suggestions.
- **Central to the change** — the types the phase edits or calls into most. Three sharp seeds beat six broad ones.
- **There when the phase runs** — the graph is rebuilt at every dispatch, so a seed only has to exist by then: either it is in the plan-time graph (it exists today), or an **earlier** phase creates it and that phase's spec names it verbatim. In a greenfield build, phase 9 seeds the types phase 2 created. A type *this* phase creates doesn't exist yet at its own dispatch; seed its neighbors instead (the protocol it conforms to, the coordinator that will own it).
- **Unique after normalization** — graphify derives a node id by lowercasing the label and dropping non-alphanumerics, so two symbols in one file that differ only in case or leading underscores (`Options` and `_options()`, `Widget` and `_widget()`) collapse onto one node: the class survives, the function disappears, and the function's own calls show up as a self-loop on the class. Seeding a factory function like that returns `no match` with no suggestions. Seed the class instead, or a caller, and name the function in the spec text.

`Map seeds: none` is correct only for greenfield phase 1 (nothing exists yet and no earlier phase created anything) and for runs without graphify (no graph is ever built). Judging existence at plan time instead turned the map off for a whole 14-phase greenfield run.

Check every seed before you ship the specs: Stage 5 runs `check-seeds.sh`, which resolves each seed against the plan-time graph or an earlier phase's spec (whole word, case-sensitive, not counting that phase's own `Map seeds:` line). A miss is cheap to fix at plan time and invisible at run time — the executor just gets a thinner map.

## Phase sizing — one phase, one context window

Every phase executes cold in its own subagent window, from a brief. A phase that does not fit one window fails the whole premise, so size is a plan-time gate, not a runtime concern. The heuristic is **files touched** (new + modified), because reads and writes both scale with it:

- Estimate it per phase and write `Estimated files: <n>` in the spec header.
- **Over 12 → split.** Natural seams: a layer (types and schemas vs. behavior), a surface (one screen, then the next), a caller cluster in a migration (move one group, then the next), or setup vs. use (add the dependency and config, then build on it).
- **No clean seam → keep it and say why**: `Estimated files: 14 — <why it can't split>`. A split at a false seam costs more than a large phase — the tunez plan's phase 1 dropped its shared test setup to fit the old limit of 8, so every later test file imports its matchers by hand.
- The limit was 8 until the tunez test plan (fix 28). That number was set before any subagent window had been measured, and the measurements since show file count is a weak predictor (below). 12 is a working default; recalibrate from the full run's per-phase peak windows. `validate-phase.sh` warns above the threshold without a reason (`RELAY_PHASE_FILE_LIMIT` overrides it).

**Reads, not writes, set the window size.** `Estimated files:` counts what a phase writes, but a cold executor's window fills with what it reads. In the first end-to-end run (contextmeter, 7 phases) subagent windows peaked at 109k–256k tokens; phase 7 changed 2 files and still peaked at 256k, almost all of it whole-file reads of source, tests, fixture docs, and earlier evidence. So when you size a phase, also ask what it must *read*:

- **Narrow the reading path.** Map seeds and exemplars give the executor `file:line` entry points; the brief tells it to read by range. Name the specific functions or sections a phase needs rather than "read X".
- **Cite shared planning docs by section.** A definitions or contract doc the planner wrote is read by every phase — point each spec at `DEFINITIONS.md §2`, not the whole file, and put anything every phase needs verbatim into the spec. Never mark a whole doc "REQUIRED reading".
- **Keep large fixture docs and generated data off the path** unless the phase's criteria depend on them.
- **Split a phase that must understand many large existing files**, even if it writes few — the seams are the same as above (a layer, a surface, a caller cluster).

## Exemplars — conventions a cold executor cannot infer

The planner is the only thing that ever sees the codebase holistically; the subagent that executes a phase starts with no history. Bridge that with a `## Exemplars` section in every spec naming 2–3 **existing** files and what to copy from each:

```
## Exemplars

- Sources/App/UI/DesignSystem/Controls.swift — control pattern (state, modifiers, previews)
- Tests/AppTests/SchedulerInterruptionTests.swift — test shape: given/when/then, one behavior per test
```

Choose files that are current, idiomatic for this repo, and close to what the phase will write — the nearest neighbor, not the biggest file. Greenfield phase 1 may say `- none yet (first code in the repo)`; every later phase points at files earlier phases created. Exemplars are read first, before the map slice and before any edit.

## Phases that reach an account (deploy, hosting, registries)

A deploy phase acts on something outside the repo that other work shares, so it is written to be
exact:

- **Pin the target.** Name the team or scope and the project in the command itself —
  `vercel link --yes --project <name> --scope <team>`, then `vercel deploy --prod --scope <team>`.
  Never rely on the CLI's default scope; the tunez account's default team held five unrelated
  projects.
- **Say what must not change.** One criterion: no other project in that scope is created,
  linked or redeployed (e.g. `vercel project ls --scope <team>` lists the same projects plus
  `<name>`).
- **Sign-in is checked, not searched for.** The planner records the account from the tool's
  status command (`vercel whoami`) in `tools.md`, and Stage 6.5 re-runs it before dispatch.
  Neither the planner nor a phase reads the Keychain, `.env*` or token files. A secret the build
  needs is an environment variable the phase names and the user supplies (Stage 6 key
  assumptions).

## The checks around the build — `Review:`, tidy-up, security

Three checks run in their own subagents around the build. None of them can block or hand off a run; their job is code that is well-formed and maintainable, not just code that passes its own spec.

**`Review:` per phase.** `yes` by default: after the phase passes, a reviewer that did not write it reads the phase's diff for bugs, unsafe patterns and wrong abstractions that later phases would build on, and findings go to one fix window. Skip it only when there is nothing to review for correctness — `skip — docs only`, `skip — config and CI only`, `skip — copy changes`. The reason is mandatory (`validate-phase.sh` rejects a bare `skip`), and Stage 6a questions any skip on a phase that changes behaviour. Do not skip a review to save time on a phase that "looks simple": early design mistakes compound, because every later phase builds on them seeing only a map slice. The Polish & Harden phase is reviewed like any other.

**Tidy-up (`Cleanup:` in `STATE.md`).** `on` by default. It runs once after the last phase and before the audit, over only what the run touched, and fixes only what is local, behaviour-preserving and covered by existing checks. Everything else is deferred to `FINDINGS.md` with a reason. It exists because per-phase isolation characteristically produces cross-phase duplication — phase 7 re-inventing phase 2's helper — which no per-phase review can see.

**Security pass (`Security pass:` in `STATE.md`).** `yes` when the build touches any of: network or HTTP (servers, clients, webhooks), authentication or authorisation, user-supplied input, file paths, shell or process execution, secrets or credentials, deserialisation of untrusted data, or new dependencies. `skip — <reason>` otherwise (`skip — styling and copy only`). When in doubt, run it: it is one read-only window. It looks for gaps only visible across phases, such as a route a later phase added without the auth check the earlier routes have.

**Push (`Push:` in `STATE.md`).** `off — default` unless the user chose otherwise: `--push` / `--no-push` for this run, or `RELAY_PUSH=on|off` as their standing default (the flag wins). A push is the one outward-facing, hard-to-undo thing a run does — it can trigger CI, deploy previews and team notifications, and it publishes code nobody has reviewed — and it happens unattended, so it is opt-in. Off, `relay-git.sh push` prints the command for the user instead. It never applies to the user's own branch, which relay never pushes.

**`--lean`** turns all three off (`Review: skip — --lean`, `Cleanup: off — --lean`, `Security pass: skip — --lean`). The security assessment is still made, so Stage 6 can warn when a lean build touches a security surface.

## Dependencies

State them explicitly. Phase 4 depends on phases 1, 2 and 3 — not "the previous ones". This lets you reason about whether mid-chain interruption breaks the next phase.

Almost always linear (1 → 2 → 3 → 4 → 5). True parallel phases are rare in a single-session goal chain; if you find yourself wanting them, you probably want sub-tasks within a phase, not a parallel phase.

## The Polish & Harden phase — non-negotiable

Always the last phase. Its job: catch what the earlier phases missed because they were focused on shipping behavior. Required sub-passes:

1. **UX & copy** — every visible string reads well, no debug placeholders, no Lorem ipsum
2. **States** — empty, loading, error, unauthorized states verified for every new surface
3. **Edges** — empty inputs, very long inputs, special characters, slow networks (where applicable)
4. **Security** — input validation, auth checks, no secrets in client bundles, no obvious injection surfaces
5. **A11y** (UI) — keyboard navigation, focus states, screen reader labels, contrast
6. **Perf** — no obvious N+1 queries, no megabyte client bundles, no blocking renders
7. **Diff review** — final `git diff` reviewed for stray debug logs, commented-out code, TODOs from this session
8. **Regression sweep** — re-run the full test suite; manually exercise one or two adjacent features

This is where "every aspect is perfect" gets enforced. Without this phase, Relay is just a multi-step planner.
