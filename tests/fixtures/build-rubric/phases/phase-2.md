RELAY_PHASE_START
Phase: 2 of 3 — Ship the site
Task: Deploy and screenshot.
Type: ui
Mandatory commands: npm run build
Acceptance criteria: 3
Evidence required: screenshot path
Depends on phases: 1
Map seeds: none
Estimated files: 1

## Why

Delivers S3.

## Work

- do the phase work

## Acceptance criteria (all must pass — one pass|fail line each in VERIFY; evidence in the evidence file)

- `vercel deploy --prod` prints a production URL
- a `/browse` screenshot of the home page at 390×844 is saved
- `npm run build` exits 0

## Mandatory commands (run each via run-logged.sh — exit code + summary line go in the evidence file)

- npm run build

## Evidence required (recorded in the phase evidence file)

- Screenshot path
