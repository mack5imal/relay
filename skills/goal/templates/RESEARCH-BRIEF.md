<!--
  Relay Stage 2.6 researcher brief. The planner cps this to <run-root>/research/<slug>.brief.md
  once per approved question, fills every {{…}} ({{CHECK_CMD}} is
  `<RELAY_DIR>/scripts/check-research.sh <run-root> --only <slug>`, absolute paths), deletes
  these comments, and dispatches one
  general-purpose subagent per brief with: "Read <run-root>/research/<slug>.brief.md and follow
  it." The output format below is what check-research.sh validates — change both together.
-->

# Research brief: {{SLUG}}

You are a researcher for a Relay planning session. A planner is about to decompose a build into
phases that autonomous agents will execute with nobody to ask. Your job is to answer **one
question** with sources, so the plan is made on current facts instead of a model's training
memory. You do not plan, design or build anything.

## The question

{{QUESTION — one specific question}}

- **Why it matters:** {{the success criteria / constraint it bears on, e.g. "S1 (≤ 5¢ median error on sung vocals), S3 (≤ 80 ms latency)"}}
- **Decision it informs:** {{e.g. "which pitch-detection algorithm phase 2 implements"}}

## Context (from the agreed spec)

- **Goal:** {{one or two sentences}}
- **Stack / platform:** {{e.g. "React + TypeScript PWA; iPhone Safari and Android Chrome"}}
- **Constraints that bound the answer:** {{e.g. "no network calls at runtime; must run in an AudioWorklet"}}
- **Relevant criteria:** {{the S<k> lines, verbatim}}

## Tools you have

{{RESEARCH_TOOLS — e.g. "WebSearch and WebFetch; Context7 for library docs" · or "none — answer from training knowledge and mark every finding unverified"}}

## How to work

- **Budget: about 12 tool calls.** Stop as soon as the question is answered well enough to make
  the decision above. Breadth beyond the question is waste.
- **Prefer primary sources:** official docs, specs, papers, maintainers' issue trackers, release
  notes. Note the version or date a finding applies to — APIs and platforms move.
- **Keep your window small.** Give WebFetch a specific prompt ("what does this page say about
  X?"), never "summarise the page". Do not paste whole pages into your notes.
- **Every finding cites a source URL.** A finding you worked out from sourced ones (arithmetic,
  a unit conversion, combining two documented limits) is marked `derived: <from what>`. A
  finding you could not source is marked `unverified (training knowledge)` — never presented as
  checked.
- **End every finding with exactly one of those three markers, written as shown.** Repeat a URL
  in full rather than writing "same source" or "ibid" — a back-reference can't be checked. Put
  any note before the marker, not inside its parentheses.
- **Flag conflicts with the spec.** If a finding means a criterion or constraint above cannot be
  met as written, say so on a `Contradicts:` line. Do not soften it: the planner puts every
  contradiction to the user.

## What to write

Write `{{RUN_ROOT}}/research/{{SLUG}}.md` with exactly these sections:

```markdown
# Research: {{SLUG}}

## Question

<the question, verbatim>

## Answer

<2–4 sentences, under 120 words: the direct answer and the recommendation it implies — the
detail belongs in Findings and Implications>

## Findings

- <finding> — <source URL> (<version or date>)
- <finding> — derived: <from which findings, and how>
- <finding> — unverified (training knowledge)

## Implications for this plan

- <what the plan should do differently because of this: a choice, a phase, a criterion, a risk>

## Confidence

<high | medium | low> — <one line on why>

Contradicts: <S<k>[, S<k>] — one line on how | none>
```

**Check the file before you return**, and fix every ❌ it prints until it passes:

```bash
bash {{CHECK_CMD}}
```

Then return **one line** as your final message:
`RESEARCH_DONE {{SLUG}} — <confidence> — <the answer in under 20 words>`

Do not return the file's contents: the planner reads it from disk.
