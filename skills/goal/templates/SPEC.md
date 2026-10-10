# Spec: {{TASK_TITLE}}

**Task:** {{ONE_LINE_TASK}}
**Type:** {{TAGS}}
**Created:** {{DATE}}
**Interview:** {{ROUNDS}} round(s){{QUICK_NOTE}}
**Research:** {{research/README.md — <n> questions, <u> unverified | none — <reason>}}   <!-- Stage 2.6 -->
**Design:** {{none | skipped | <design dir>/HANDOFF.md @ <sha> — design/, or design/<feature>/ beside an existing design; Stage 2.7, optional}}

<!--
  Written by Stage 2.5, after recon, before decomposition. This is the agreed statement of
  intent for the whole run — the source the audit checks against, so that a clean
  AUDIT_COMPLETE means "we built what was asked for" and not merely "we did what the roadmap
  said". ROADMAP.md compiles this into phases; this file is what the compilation is judged by.

  Every `## Success criteria` entry is re-verified by the final audit. Write them so a fresh
  agent with repo access can settle each one yes/no without asking anyone.
-->

## Goal

{{GOAL_PARAGRAPH — what this run delivers and why, in the user's terms. Two or three sentences.}}

## In scope

- {{IN_SCOPE_1}}
- {{IN_SCOPE_2}}

## Out of scope

Stated explicitly so the executor does not drift into it. "Not mentioned" is not the same as
"excluded" — anything the interview ruled out belongs here. An exclusion the user chose stays as
written; one the planner decided because nobody asked ends in `(planner)` — it is an assumption,
and Stage 6 lists it for the user to correct.

- {{OUT_OF_SCOPE_THE_USER_CHOSE}}
- {{OUT_OF_SCOPE_NOBODY_ASKED_ABOUT}} (planner)

## Constraints

Performance, compatibility, platform, data, dependency, and stylistic requirements the build must
respect.

- {{CONSTRAINT_1}}
- {{CONSTRAINT_2}}

## Success criteria

The run-level rubric. The final audit re-verifies every entry against repository ground truth and
reports `pass` / `fail` / `trust-prior-verify` per entry, so each needs a check a verifier can
actually run. `S<k>` is the stable id the audit cites. A value the planner chose because nobody
gave one (a limit or count, typically while settling an edge case) is followed by `(planner)` —
"within 150 ms (planner)" — so the plan review lists it and the checks after the build treat it
as Relay's call, not the owner's.

- **S1 — {{SHORT_LABEL}}**: {{SPECIFIC_TESTABLE_STATEMENT}}
  - Current: {{WHAT_EXISTS_OR_DOES_NOT_TODAY}}
  - Target: {{WHAT_IT_SHOULD_BECOME}}
  - Acceptance: {{CONCRETE_PASS_FAIL_CHECK}}
- **S2 — {{SHORT_LABEL}}**: {{SPECIFIC_TESTABLE_STATEMENT}}
  - Current: {{...}}
  - Target: {{...}}
  - Acceptance: {{...}}

<!--
  ✗ "The system should be fast"           ✗ "Improve the user experience"
  ✓ "GET /api/report responds in < 200ms at p95 over 100 concurrent requests"
  ✓ "`relay --json` exits 1 and prints a JSON error object on an unreadable input file"
-->

## Edge coverage

From the edge probe (`scripts/edge-probe.py`), which names the edge categories that genuinely
apply to each success criterion's shape. Every raised edge must be `resolved` (the spec now
covers it), `dismissed` **with a reason**, or `unresolved` (carried into the plan as a known gap).
A silent dismissal is a validation error — the reason string is the audit trail.

| Criterion | Edge | Status | Reason / where covered |
|---|---|---|---|
| {{S1}} | {{boundary}} | {{resolved\|dismissed\|unresolved}} | {{REASON_OR_CRITERION_REF}} |

## Design reconciliation

<!--
  Stage 2.7e, only when a design package is recorded above (`**Design:** … @ <sha>`); delete the
  section otherwise. Compare the design (screens, states, behaviour, copy) against every success
  criterion, constraint, prohibition and in-scope item. Each conflict was put to the user; the
  answer rewrote this spec (design wins) or made an exemption the fidelity criteria honour
  (spec wins). Name an exempted item in Area as `screen: <id>`, `component: <Name>`,
  `token: <name>` or `copy: <exact string>` — `check-design.sh --verify --except` reads those.
  validate-spec.sh requires the `Reconciled:` line whenever a design is recorded.
-->

| # | Area | Spec said | Design shows | Resolution |
|---|---|---|---|---|
| {{1}} | {{`copy: <string>` or a behaviour}} | {{…}} | {{…}} | {{design wins — spec updated \| spec wins — <what the build does>}} |

Reconciled: {{N}} conflicts   <!-- or: Reconciled: 0 conflicts — <what was compared> -->

## Prohibitions (must-NOT)

What this build must not silently become. Values, safety, and scope-integrity items only —
routine engineering hygiene belongs in the phase specs, and security canon (OWASP/GDPR-shaped)
is the Polish & Harden phase's job, not this list's. The `Probe:` line is the audit trail of the
two-pass prohibition probe — what was recalled, what survived, and why the rest went.

Probe: {{N}} recalled → {{K}} kept · dropped {{N}} hygiene, {{N}} restating out-of-scope, {{N}} security canon (Polish & Harden)

- {{PROHIBITION_1}}
- {{PROHIBITION_2}}

## Assumptions

Decisions taken without confirmation, plus any ambiguity dimension still below its minimum. These
are copied into `ROADMAP.md`'s `## Assumptions` so the plan review surfaces them.

- {{ASSUMPTION_1}}

## Ambiguity report

Scored after the final interview round. Ambiguity = 1.0 − (0.35×goal + 0.25×boundary +
0.20×constraint + 0.20×acceptance); the gate is ambiguity ≤ 0.15 with every dimension at or above
its minimum.

| Dimension | Weight | Minimum | Score | |
|---|---|---|---|---|
| Goal clarity | 35% | 0.85 | {{G}} | {{✓ or ⚠ Below minimum — treated as assumption}} |
| Boundary clarity | 25% | 0.80 | {{B}} | {{...}} |
| Constraint clarity | 20% | 0.75 | {{C}} | {{...}} |
| Acceptance criteria | 20% | 0.85 | {{A}} | {{...}} |

**Ambiguity: {{SCORE}}** (gate: ≤ 0.15) — {{PASSED or "written with N dimension(s) below minimum"}}

## Interview log

Evidence that the requirements came from discovery rather than assumption. One row per round,
plus round 0 for the opening score, with the scores printed after that round (G/B/C/A → ambiguity).

| Round | Focus | Asked about | Decision locked | Scores (G/B/C/A → amb) |
|---|---|---|---|---|
| 0 | Opening | — (scored from the prompt and recon) | — | {{0.90/0.80/0.85/0.60 → 0.21}} |
| 1 | Researcher | {{...}} | {{...}} | {{...}} |

<!-- After the interview, a change to anything settled above, a constraint, a prohibition or an
outward-facing target is made only after asking the owner. Record each one here, one line each:
- Changed after the interview: <item> — <was> → <now> (asked at <stage>) -->
