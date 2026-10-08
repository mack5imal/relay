RELAY_PHASE_START
Phase: 1 of 3 — Build the core
Task: Build the widget core.
Type: brownfield
Mandatory commands: npm test, npm run lint
Acceptance criteria: 3
Evidence required: command summaries
Depends on phases: none
Map seeds: none
Estimated files: 2

## Why

Delivers SPEC S2 and S1.

## Work

- do the phase work

## Acceptance criteria (all must pass — one pass|fail line each in VERIFY; evidence in the evidence file)

- `npm test` exits 0 with the widget suite passing
- `.gitignore` lists `.vercel` and `dist`
- the parser returns 3 rows for `fixtures/a.csv` (S10)

## Mandatory commands (run each via run-logged.sh — exit code + summary line go in the evidence file)

- npm test
- npm run lint

## Evidence required (recorded in the phase evidence file)

- Command exit codes
