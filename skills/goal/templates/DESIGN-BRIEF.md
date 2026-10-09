<!--
  Relay Stage 2.7 design brief. The planner cps this to <run-root>/DESIGN-BRIEF.md, fills every
  {{…}} from SPEC.md and recon, and writes everything below the first `---` — the paste — to
  <run-root>/DESIGN-BRIEF.paste.md, which it puts on the clipboard (pbcopy). Only when that
  fails does it print the paste, fenced with five backticks (the brief holds 3- and 4-backtick
  fences), as the last message of its turn.

  Written for Claude Design (recommended), but it must read correctly to any design tool or a
  human designer: no relay jargon, no S<k> ids, no run paths. The "What to hand back" section is
  fixed text — check-design.sh verifies exactly that contract when the user returns, so do not
  reword it. Required back: HANDOFF.md + one PNG per approved screen. Tokens, components and
  copy are asked for because each one becomes a build check; a package without them still
  passes, with warnings. "Deviations from the brief" lets Stage 2.7e confirm the departures the
  owner already approved in one question instead of one each (the tunez test plan reconciled 12,
  most of them choices made in the design session).

  The four stages exist so the owner settles the look on ONE screen before anything else is
  drawn — without them, a direction the owner rejects means redrawing every screen. Keep the
  gates. The quoted phrases are examples of intent, not passwords: the user says it any way
  they like, and the designer asks before advancing when it is unclear.

  The anchor is the product's canonical screen — its home: the screen a returning user lands on
  when they open it. Never onboarding, settings, an error or empty state, a sheet or a modal.
  If the app opens onto a menu or launcher that only routes to the main task, choose the screen
  where that task happens. Not the densest or most state-heavy screen — the most representative.

  ADDING TO AN APP THAT ALREADY HAS A DESIGN (design-dir.sh printed `existing:` lines, or the
  owner chose to match the app's current look at Stage 1 — a design kept elsewhere, the
  `Design reference:` paths, or a look only in the code, `theme`): keep
  `## How we'll work — adding to an existing app` and `## The existing design system`, and
  delete the plain `## How we'll work`; for a new app, delete those two instead. The paste has
  exactly one "How we'll work" section. The look is already settled, so there is no three-takes
  stage — one take of the anchor in the existing style, then build-out. The anchor is the new
  screen the user will see most (the feature's main screen). Tell the owner which existing files
  to attach in the design tool (the existing package's HANDOFF.md and the PNGs of the screens
  the new ones sit beside, or the reference folder's colour doc and pictures; with `theme`,
  screenshots they take of the running app) — the brief names them; it cannot attach them.

  {{SLUG}} is the feature name in kebab-case: the run's design folder name for an addition
  (design/<slug>/), otherwise the product name.
-->

---

# Design brief: {{PRODUCT_OR_FEATURE_NAME}}

I'm about to have this built by an autonomous coding agent that works from your handoff alone —
it cannot ask you anything. We'll design it together in stages, and I'll review at the end of
each one; the final package goes in the exact shape described at the end.

## How we'll work

Read the whole brief first — every screen and state below — so that the directions you propose
can carry the entire app, not just one screen. Then work in four stages. **At the end of each
stage, stop and wait for me. Don't start the next stage until I've told you to.** I won't use
exact words — anything that clearly means the same thing counts. If you can't tell whether I'm
finished with a stage or still giving feedback, ask me before moving on.

1. **Three directions, one screen.** Design only `{{ANCHOR_SCREEN_ID}}` — {{WHY: one line, e.g.
   "the screen the app opens to, where singing happens"}} — in **exactly three takes**, each
   clearly different in colour scheme, typography and design elements. No other screens yet,
   and no handoff package.
   → I'll tell you which take I prefer (e.g. "go with take 2"), or ask for new takes.
2. **Refine the direction.** Iterate on the chosen take with me until the look is settled:
   palette, type scale, spacing, radii, component style. These become the design tokens.
   → I'll tell you when the direction is settled.
3. **Build out.** Design every other screen, and every state listed below, in the settled
   direction. Then stop so I can review them all.
4. **Review, then package.** I may ask for changes to any screen; revise until I'm satisfied.
   Only when I tell you the screens are final, produce the package described in "What to hand
   back".

**Keep a list of every departure from this brief that I agree to** — a different rule, an
added or dropped section, a changed behaviour, other fonts, anything the brief below says
differently. Good ideas that change the brief are welcome; the list is how the builder learns
that I approved them. It goes in the package as "Deviations from the brief".

## How we'll work — adding to an existing app

This app already has a design (below, under "The existing design system"), and the new screens
must look as if they were always part of it. Read the whole brief first. Then work in three
stages. **At the end of each stage, stop and wait for me. Don't start the next stage until I've
told you to.** I won't use exact words — anything that clearly means the same thing counts. If
you can't tell whether I'm finished with a stage or still giving feedback, ask me before moving
on.

1. **Match what exists, one screen.** Design only `{{ANCHOR_SCREEN_ID}}` — {{WHY: one line, e.g.
   "the screen the new feature opens to"}} — in the existing style, from the existing tokens and
   components. One take, not three: the look is already settled. No other screens yet, and no
   handoff package.
   → I'll tell you when it fits, or what to change.
2. **Build out.** Design every other new screen, and every state listed below, the same way.
   Then stop so I can review them all.
3. **Review, then package.** I may ask for changes to any screen; revise until I'm satisfied.
   Only when I tell you the screens are final, produce the package described in "What to hand
   back".

**Reuse before you invent.** An existing token, component or pattern always wins. When the new
screens genuinely need something new — a colour, a component — name it and mark it new. If a new
screen changes an existing one (a new button, a new row), draw the changed screen too and keep its
existing id.

**Keep a list of every departure from this brief or from the existing design that I agree to** —
a changed rule, an added or dropped section, a different behaviour, a new colour where an
existing one would do. The list is how the builder learns that I approved them. It goes in the
package as "Deviations from the brief".

## What we're building

{{GOAL — two or three sentences from SPEC.md ## Goal, in the user's terms: who it is for, what
it lets them do.}}

## Platform and constraints

- Platform: {{e.g. macOS 14 menu-bar app, SwiftUI · responsive web app, React + Tailwind, 360–1440px}}
- {{CONSTRAINTS from SPEC.md that affect the design: accessibility level, dark mode, localization,
  minimum sizes, performance-visible limits}}

## The existing design system

Use what is here before inventing anything. I've attached {{the files the owner attaches — the
existing design's `HANDOFF.md` or colour list and the pictures of the screens named below, or
screenshots of those screens from the app}}.

- Tokens: {{names and values — from the existing package's ## Design tokens by section, the
  reference folder's colour or token list, or the theme file when there is neither}}
- Components: {{names, with one line each where it helps}}
- Fonts: {{families}}
- Screens the new ones sit beside: {{`<existing-id>` — <name> — why it matters (shares a layout,
  opens the new screen, holds the changed row…)}}

## The design must not

{{Limits from SPEC.md's Prohibitions and Constraints that a designer could break without knowing
— e.g. "load anything from another domain: fonts, icons and images must be bundled (no Google
Fonts, no icon CDNs)", "rely on hover", "use stock imagery we have no licence for", "need a
screen wider than 430 px". Delete this section if none apply.}}

## Screens to design

Use these ids exactly — the build refers to screens by id.

{{ONE BLOCK PER SCREEN, derived from SPEC.md ## In scope and the success criteria:

### `<screen-id>` — <Screen name>
- Purpose: <what the user does here, one line>
- Content: <the data and controls it shows>
- States: <every state it must be drawn in — take these from SPEC.md ## Edge coverage and the
  criteria: empty, loading, error, long content, first run, permission denied, …>
}}

## Copy that is already decided

{{Strings SPEC.md fixes verbatim (labels, messages, error text), per screen. Write "None — you
choose the wording" if SPEC.md fixes none.}}

## Out of scope

Do not design these — they are not part of this build:

{{SPEC.md ## Out of scope, one bullet each}}

## Fidelity

High fidelity: colours, type, spacing, radii and copy you choose are final and will be matched.
Anything you leave unspecified, the builder will decide.

## What to hand back

Stage 4 only — after I've told you the screens are final. Hand back a folder (a zip is fine) with this layout.
**The two required pieces are `HANDOFF.md` and one PNG per approved screen**; everything else
makes the build more faithful.

```
HANDOFF.md
screens/<screen-id>.png            one per approved screen (required)
screens/<screen-id>--<state>.png   one per extra state (recommended)
source/                            optional — your working files (HTML, Figma export, …)
```

`HANDOFF.md` uses these headings, in this order:

````markdown
# Handoff: <name>

<one paragraph: what this covers, and the scale of the screenshots if not 1:1>

## Approved screens

| id | name | files |
|---|---|---|
| `<screen-id>` | <Screen name> | `<screen-id>.png`, `<screen-id>--<state>.png` |

## Design tokens

| name | value | usage |
|---|---|---|
| `accent` | `#7fc8b7` | primary buttons, links |
| `paper` | light `#F4EFE4` · dark `#16140F` | app background |

## Components

- `ComponentName` — one line on what it is and where it appears

## Screens

### <screen-id> — <Screen name>

Layout, sizes, spacing, every state, and interactions/transitions.

## Deviations from the brief

- <what the brief said> → <what the design does instead> — <why; that I agreed>
   ← or "None"

## Copy

### <screen-id>
- `Exact string as shown`
- `Next break at {time}`   ← variable parts in {braces}
````

Rules for the package:

- Only **approved** designs go in `screens/` and `HANDOFF.md`. The two takes I didn't choose,
  and any other rejected explorations, stay out — or under `source/` only.
- Use the screen ids above verbatim — in the table, the `###` headings, and the PNG file names.
- Every piece of visible text goes in `## Copy`, exactly as it should appear. Sample values
  (a name, a number) go in `(e.g. …)` after the string they fill: `` `{key}` (e.g. `F major`) ``
  — examples are not checked as wording.
- Name every colour, size and radius you reuse as a token, and name every reusable component —
  the builder will define each one once, under your name. A colour that changes with the theme
  is one token whose value reads `light #… · dark #…`, not two tokens. Several tables under
  `## Design tokens` (colour, type, space…) are fine.
- `source/` is for humans; the builder will not read it. Anything it needs belongs in
  `HANDOFF.md` or a screenshot.
- **Adding to an existing app:** the package holds only the new screens and any existing screen
  you changed, under its existing id. In `## Design tokens` and `## Components`, list every
  existing one the new screens use, under its existing name and value, and mark each new one
  `(new)` in its usage or description.
- Export the package as `design_handoff_{{SLUG}}.zip`.
