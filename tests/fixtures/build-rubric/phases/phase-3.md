RELAY_PHASE_START
Phase: 3 of 3 — Polish & Harden
Task: Harden.
Type: ui
Mandatory commands: npm test, npm run build
Acceptance criteria: 2
Evidence required: command summaries
Depends on phases: 1, 2
Map seeds: none
Estimated files: 3

## Why

Every aspect verified.

## Work

- do the phase work

## Acceptance criteria (all must pass — one pass|fail line each in VERIFY; evidence in the evidence file)

- every error state renders its message (unit tested)
- `npm test` and `npm run build` exit 0

## Mandatory commands (run each via run-logged.sh — exit code + summary line go in the evidence file)

## Evidence required (recorded in the phase evidence file)

- Command exit codes
