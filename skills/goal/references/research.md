# Research (Stage 2.6) — reference

Relay researches once, at plan time: after the spec is agreed, before the design brief and
before any phase is cut. `SKILL.md` Stage 2.6 has the steps; this file has the reasoning, what
makes a good question, and the researcher contract.

## Why here, and why not per phase

Research used to be a Stage 3 bullet — "optional, use if available". The first Tunez plan shows
what that does: `tools.md` recorded WebSearch as available, then `THINKING.md` planned the stack
"from training knowledge" and did no research on pitch detection (the riskiest part of the app)
or on iOS Safari's audio rules. An optional instruction that produces no artifact gets skipped.
So research is now a stage that produces files a script checks.

- **After the spec** — the spec is what scopes research: its risks and open edges are the
  questions. Research before the interview would be unscoped.
- **Before the design brief** — some findings are design constraints (iOS will not start audio
  without a tap; a permission-denied state needs a screen). They belong in the brief, not in a
  discovery at build time.
- **Before decomposition** — research can change which phases exist and in what order.
- **Never per phase** (GSD's researcher placement). GSD plans each phase just in time, so its
  research feeds that phase's plan. Relay plans every phase up front and executes each cold: a
  finding at execution time would contradict an approved plan with nobody to arbitrate, cost a
  context window per phase, and repeat itself (phases 3, 7 and 11 each researching the same
  platform quirks).

## What makes a good question

A question is specific enough when its answer changes a **named decision**.

| Weak | Strong |
|---|---|
| Best practices for pitch detection | Which pitch detector (McLeod/MPM, YIN, other) is most accurate on sung vocals with vibrato, in real time in an AudioWorklet? → decides phase 2's algorithm and window size |
| How does iOS audio work? | What must happen before Safari on iOS will start microphone capture, and what breaks it mid-session (lock, call, backgrounding)? → decides the live screen's start and resume states |
| Is there test data? | Is there a licensed sung-vocal dataset with per-frame f0 labels we can fetch in CI? → decides whether S1's real-voice half is testable |

Sources of questions: the spec's risks and unresolved edges; libraries and APIs the plan leans
on (current version, breaking changes, licence); niche-domain algorithms; platform quirks;
standards and regulations. **1–6 questions.** Zero is a legal answer — a change inside a stack
the repo already uses often needs none — but it is written down with a reason and shown to the
user, who can overrule it.

The user approves the questions before anything is dispatched: they know which unknowns
actually worry them, and a question they add is usually the most valuable one.

## Tools

Stage 0 records `RESEARCH_TOOLS`. Without WebSearch, Stage 1 offers to stop so the user can
install it (and Context7) before planning starts; if they continue, every finding is marked
`unverified (training knowledge)` and lands in the Stage 6 key assumptions. The point is that
nothing learned from memory is ever presented as checked.

## The researcher contract

One `general-purpose` subagent per question, dispatched in parallel from a brief expanded from
`templates/RESEARCH-BRIEF.md`. It answers one question with a budget of about 12 tool calls,
prefers primary sources, notes the version or date a finding applies to, keeps its own window
small (specific WebFetch prompts), and writes `research/<slug>.md`:

`## Question` · `## Answer` (2–4 sentences) · `## Findings` (each bullet with a source URL or
`unverified (training knowledge)`) · `## Implications for this plan` · `## Confidence`
(high/medium/low) · `Contradicts: <S<k>… | none>`.

Before it returns, it runs `check-research.sh <run-root> --only <slug>` on its own file and fixes
every ❌ (fix 24). In the Tunez test plan, 5 of 6 researchers failed the planner's check the
first time on marker format alone: `— same source (…)`, and notes written inside
`unverified (training knowledge; …)`. The second is now accepted; "same source" still fails,
with a message saying to repeat the URL. Checking in the researcher's own window costs the
planner nothing, where the old way cost a SendMessage round trip per researcher.

It returns one line — `RESEARCH_DONE <slug> — <confidence> — <answer>` — never the file's
contents. `check-research.sh` validates the set; `--digest` prints only the answers,
implications and contradictions, so the planner's window never holds the findings.

## Contradictions

A researcher flags any finding that means a criterion or constraint cannot be met as written.
Each goes to the user — change the spec, or keep it and carry the risk as an assumption. The
question says whether the change **clarifies how a criterion is measured** (the target stands)
or **lowers or drops a target**, and how confident the finding is (fix 29). Keeping the spec is
a real choice: a finding can be unverified, the user can know something the researcher didn't
(their own recordings could cover a range no public dataset does), or "hard" can be a risk
worth taking.
Research never rewrites the spec on its own: the spec is what the user agreed, and the audit
grades against it.

## Known limits

- A planner session that ends mid-research is not resumable at that point (the run has no
  `STATE.md` yet); re-running starts the stage again. The answer files already written stay in
  `research/` for reference.
- The first real use of this stage is the Tunez re-plan. The researcher brief was dry-run once
  on the Tunez pitch-detection question (`DESIGN.md` decisions log, 2026-09-22): 16 tool calls, 8 sources, a real
  contradiction found (S3's 80 ms is not fully verifiable on iOS — the browser cannot measure
  microphone input latency). It also produced the `derived:` finding class and the 120-word
  Answer advisory.
