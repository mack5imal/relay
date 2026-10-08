# Design stage (Stage 2.7) — reference

Relay does not generate designs. For UI work it compiles a design brief from the agreed
`SPEC.md`, puts it on the user's clipboard with an overview of the design session, stops, and
on the user's return commits and verifies the package, writes design-fidelity criteria into `SPEC.md`, and plans the UI phases against it.
`SKILL.md` Stage 2.7 has the steps; this file has the contract, the reasoning, and the edge
cases.

## Why a separate tool, and why stop

A design needs iteration with a human looking at pictures — the one thing an autonomous
overnight run cannot do. Claude Design is built for that loop, so the brief is written for it,
but nothing depends on it: any design tool or a human designer works, as long as the package
honours the contract below. Stopping costs the user one context switch; not stopping means the
run invents a look nobody approved and the audit has nothing visual to hold it to.

## How the design session runs (four gated stages)

The brief asks the design tool to stop at four gates. The user releases each in their own words
— the brief's quoted phrases are examples, not passwords — and the tool asks before advancing
when it cannot tell feedback from approval:

1. **Three takes on the anchor screen** — only that screen, three clearly different directions
   (colour scheme, type, design elements) → the user picks one.
2. **Refine** the chosen take until the look — palette, type scale, spacing, radii, component
   style — is settled; these become the tokens.
3. **Build out** every other screen and state in that direction, then stop for review.
4. **Review and revise** any screen; the package is produced only when the user says the
   screens are final.

Exact phrases were considered and dropped (owner): a phrase the user has to remember is friction
and will be forgotten; putting the burden on the tool to confirm when unsure keeps the gates
without it.

**Why:** the first version asked for the whole package in one pass. On tunez that took about 30
minutes, and a direction the owner disliked would have meant redrawing every screen. The owner's
own workflow — several takes on one screen, pick, iterate, then build out — is what the stages
encode; stage 4 exists because a built-out screen can still be wrong. The whole brief is pasted at
once so the takes are proposed knowing every screen they must carry.

**Delivery (fixes 31–32).** The brief runs to a few hundred lines, and selecting it out of a
terminal is unwieldy. The planner writes the paste to `<run-root>/DESIGN-BRIEF.paste.md` and puts
it on the clipboard with `pbcopy`. Claude Design runs in the browser and cannot open a local
path, so the clipboard is the handover, and the chat shows only an overview and the steps. The
overview says what each of the four stages will ask of the user before they start, so the stops
don't surprise them. Without `pbcopy` (Linux, a sandbox) the planner falls back to printing the
paste in a five-backtick fence.

**The anchor** is the product's canonical screen — its home, the one a returning user lands on.
Never onboarding, settings, an error or empty state, a sheet or a modal; if the app opens onto a
launcher that only routes to the main task, the task screen. Not the densest or most
state-heavy screen: a direction chosen on the most representative screen transfers; one chosen on
an outlier does not. For tunez: `live`.

## The contract (what comes back)

| Path | Required | Why |
|---|---|---|
| `design/HANDOFF.md` — `## Approved screens` table and one `### <id>` per screen under `## Screens` | **yes** | the text an executor can read cheaply and a script can parse |
| `design/screens/<id>.png` or `<id>--<state>.png`, at least one per approved id | **yes** | the visual reference; the post-run comparison is against these |
| `HANDOFF.md` `## Design tokens` table (`name \| value \| usage`) | recommended | yields the tokens criterion |
| `HANDOFF.md` `## Components` bullets | recommended | yields the components criterion |
| `HANDOFF.md` `## Copy` (per screen, exact strings in backticks, `{name}` for variables) | recommended | yields the copy criterion |
| `HANDOFF.md` `## Deviations from the brief` (`<brief said> → <design does> — <why>`, or `None`) | recommended | approved departures are confirmed together at reconciliation |
| `design/source/` | optional | working files for humans — **off every phase's reading path** |

The format follows the first real handoff (movez, Claude Design): its README carried
everything the build needed — ids, a token table, per-screen layout, states and copy, and which
options were approved — while its HTML canvas was 107 KB plus a 69 KB script, self-described as
"not production code". A cold executor that reads a mockup canvas spends its window on it and is
invited to port it; a structured markdown file and a PNG per screen cost a fraction and say what
to build. `check-design.sh` verifies the required pieces and warns on each missing recommended
one.

**`design/` must be committed before planning continues.** `repo-state.sh` counts every
untracked file as a change the run made and greps its added lines for debug output, so an
uncommitted export (HTML with a stray `console.log`) would fail cleanliness checks mid-run.
**The planner commits it (fix 30).** At Stage 2.7b it creates `design/`, and the user puts the
export's contents there (or the .zip itself). On **design ready**, `prepare-design.sh` unzips a
lone zip, lifts the export's wrapper folder, drops `.DS_Store`/`__MACOSX` and commits `design/`,
and only `design/`: anything else the user has staged stays staged. Relay never searches for the
export elsewhere, because `~/Downloads` can hold several and a sandboxed session may not reach it.
This is the one commit planning makes; it was the owner's by hand until the tunez test plan
showed it was pure friction. The same step also records the commit (`**Design:** design/HANDOFF.md @ <sha>` in `SPEC.md`), so the audit
checks against the exact package the plan was made from.

## Fidelity criteria (what the build is held to)

`check-design.sh design --criteria --start <next k> --run-root "$RELAY_ROOT" --theme <file>
[--allow <glob>]...` drafts them deterministically, with an `## Edge coverage` row for every edge
the probe raises on them. All structural — a pixel-diff gate would hand a run off at 2am over
antialiasing.

**One checker, run by everyone.** Criteria 1–4 each name `<run-root>/check-design.sh design
--verify <aspect> --except <run-root>/SPEC.md` (Stage 7 copies the script into the run), so the
phases and the audit run the same deterministic command instead of hundreds of agent greps —
the tunez package had 345 copy strings, 60 tokens and 29 components, and its planner invented a
fidelity script of its own. Source is every tracked and untracked file outside `design/` and
`.relay/`.

1. **Screens built** — each approved id is marked by a `design: <id>` comment in exactly one
   source file outside `design/`. One grep per id; exact whatever the language. Zero means the
   screen was never built; two means nobody can say which file is the screen.
2. **Components present** — each `## Components` name exists as an identifier outside `design/`.
3. **Tokens centralized** — every token is defined in the one theme file the tokens phase
   creates (names compared with `-`/`_` removed, case-insensitively), and no hex token value
   appears outside it or the `--allow` files. Every hex value in a value cell counts, so a
   themed `light #… · dark #…` token is checked on both sides, and a value only matches when no
   hex digit follows it (`#FFF` is not found inside `#FFFDF8`). Platform colour values that must be literal — a
   web manifest, `<meta name="theme-color">` — are **generated from the theme file** and listed
   with `--allow`; never hand-copied (tunez needed `#0D0F12` in both).
4. **Copy matches** — every `## Copy` string appears verbatim outside `design/`; `{name}`
   placeholders split it into fragments, each of which must appear. A one-word fragment must
   match as a whole word, so `Close` inside `onClose` does not count. That is still only a
   presence check, and the criterion says so: whether "Trends" renders where the design puts it
   is left to the post-run screen comparison (5). A stricter check, requiring each string as a
   quoted or `>…<`-delimited literal, was rejected (fix 22): a formatter that breaks JSX text
   across lines would fail a correct build, and a false failure hands off an overnight run.
5. **Screens captured for review (the human check)** — the polish phase writes
   `<run-root>/design-check/<id>.png` for each approved screen, **or** records
   `capture unavailable: <id> — <reason>` in its evidence file. Either passes. The comparison of
   capture against design is the owner's, **after** the run: it is listed under "Worth your eye"
   at Stage 6 and in the run's final "verify manually" list. **It never gates, pauses or hands
   off the run** — a run started at night must not be waiting on a human in the morning. A
   subagent that cannot take screenshots (headless macOS, no simulator) records the reason and
   moves on; the only way to fail this criterion is to do neither. The capture code reads its
   output directory from `RELAY_DESIGN_CHECK_DIR` (the phase sets it to
   `<run-root>/design-check`), and the criterion also checks that no `.relay/` path appears in
   the product's source — a run's directory must never be baked into the code it builds.

Criteria 2–4 are drafted only when their section is present. Review the drafts like any other
criterion — tighten a list, drop a component the spec already covers — then re-run
`validate-spec.sh`.

## Reconciliation (step e)

The design is drawn from the brief, not the spec, and a good designer makes decisions the spec
never considered — or contradicts it. On tunez the planner found four real conflicts only by
reading the whole handoff against the spec on its own initiative: tolerance changes retroactive
(spec) vs frozen per take (design); a trend rule by slope vs by halves; a per-degree trend the
design omitted; ≤ 80 ms latency vs a 10 Hz numeric readout. Planning against both would have
built one and failed the other at the audit.

So the comparison is a step, and it runs after the research contradictions are resolved (both
rewrite `SPEC.md`): every success criterion, constraint, prohibition and in-scope item
against the design's screens, states, behaviour and copy. Each conflict goes to the user —
**design wins** rewrites the spec; **spec wins** makes an exemption the build honours — and is
recorded in `SPEC.md`'s `## Design reconciliation`, ending `Reconciled: <n> conflicts`. The
design package itself is never edited: it is the committed record of what was approved.
Exempted items are named `screen: <id>`, `component: <Name>`, `token: <name>` or
`copy: <exact string>` so `--verify --except` skips them. `validate-spec.sh` requires the
`Reconciled:` line whenever a design package is recorded — zero conflicts is a result, not a
skipped step.

The brief's "The design must not" section (fix 14) is the cheap half of the same idea: tell the
designer the hard limits up front, so fewer conflicts reach reconciliation.

**Approved deviations (fix 25).** The owner often agrees to a better idea mid-session: the
gated tunez design moved to other fonts, a different trend rule, light and dark themes. The
tunez test plan then put all 12 conflicts to them one question at a time, re-asking choices they
had made in the design session. So the brief asks the designer to keep a list of every departure
the owner agreed to, and hand it back as `## Deviations from the brief`. Reconciliation still
compares everything. Conflicts the list names are confirmed in one question ("apply all — design
wins", or review each). Only unflagged drift is asked one by one, and a deviation that breaks a
prohibition is always asked on its own. A package without the list (an older package, another
tool) warns, and every conflict is asked individually, as before.

## How the plan uses the package

- **Phase order.** The first UI phase builds tokens and primitives from `HANDOFF.md §Design
  tokens` and creates the theme file criterion 3 names; content phases follow; the polish phase
  carries criterion 5 (the UI redesign shape in `phase-design.md`).
- **Markers.** Every phase that builds a screen says, in its Work, which file gets the
  `design: <id>` comment.
- **Exemplars.** A UI phase's `## Exemplars` cite the design by section and file —
  `design/HANDOFF.md §overlay`, `design/screens/overlay.png` — alongside code exemplars. Never
  `design/source/`, never the whole `HANDOFF.md` when one section will do.
- **Screenshots in a phase.** A subagent opens a screen's PNG only for the screen it is building.

## Edge cases

- **The user already has a design.** Stage 1's third option, or `design ready` with no brief
  printed: skip straight to verification. The contract is the same.
- **Brownfield with an existing design system.** The brief lists the tokens, components and
  fonts recon found and asks the designer to match them. The tokens criterion then names the
  existing theme file instead of a new one.
- **The export lands in the wrong shape.** A lone `.zip` in `design/` is unzipped; a single
  wrapper folder (`design/design_handoff_tunez/HANDOFF.md`) is lifted. Two zips, two folders, or
  a name that already exists stop `prepare-design.sh` with a ❌ that names them — nothing moves.
- **A partial package.** Missing PNGs or screen headings block (`check-design.sh` names each).
  Missing tokens/components/copy only warn — say so in the Stage 6 summary, since those checks
  will not run.
- **The user abandons the design.** `skip design` continues planning without it; record
  `**Design:** skipped` in `SPEC.md` so the audit and summary do not look for one.
- **Resuming in a new session.** Stage 2.7 parks the run with `Status: AWAITING_DESIGN` in an
  early `STATE.md`; Stage 0 sees it as active and resume detection jumps to verification.
- **A later design change.** A new commit to `design/` after planning is not picked up by a run
  in flight. Re-plan, or accept that the audit checks the recorded commit's package.
