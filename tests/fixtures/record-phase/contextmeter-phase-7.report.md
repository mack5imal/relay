RELAY_PHASE_START
Phase: 7 of 7 — Polish & Harden
Task: A JSON contract test pinning every reported number, README usage docs, large-file streaming and perf proof, a real-transcript sweep, edge/error sweep, a Python 3.12 check and a final diff review
Type: brownfield
Mandatory commands: uv run pytest -q, uv run ruff check ., uv run ruff format --check ., uv run mypy, uv run --python 3.12 --isolated --with pytest pytest -q
Acceptance criteria: 12
Evidence required: command results, number-to-test coverage map, perf measurements, real sweep output, edge sweep table, README example verification, diff review
Depends on phases: 1, 2, 3, 4, 5, 6
Map seeds: main(), render_table(), analyze_relay(), summarize(), load_session()
Estimated files: 5

RELAY_PHASE_VERIFY
Acceptance (evidence: .relay/contextmeter-session-transcript-context-AsGfac/phases/phase-7.evidence.md):
- C1 tests/test_json_contract.py exists, ≥4 full-document equality assertions, no json.load of expected files: pass
- C2 coverage map lists every numeric JSON key path (58 file-mode + 15 list-mode) with pinning tests, 0 unmapped: pass
- C3 README ≥5 fenced examples (file report, --relay, --project+--top+--since, --json, --csv --table); 7 fixture examples ran, all exit 0: pass
- C4 33 MB transcript: exit 0, 0.29 s wall, 25.1 MB max RSS; whole-file-read grep in src/ → 0: pass
- C5 real sweep over 12 dirs + 37 session files: 61 invocations, 0 non-zero exits, 0 Tracebacks: pass
- C6 edge sweep: 12 cases, 0 Tracebacks, expected exits (missing path/--since garbage/--top 0 → 2, rest → 0): pass
- C7 input-safety grep in src/ → 0 hits: pass
- C8 dependencies = [] unchanged; .relay untracked; every diff path under src/contextmeter/, tests/ or README.md; Phase 1..6 subjects in order: pass
- C9 TODO|FIXME|XXX in src/ and tests/ code → 0 (sole tree hit is "TODOS" inside the verbatim real fixture, phase-2 byte-pinned): pass
- C10 uv run --python 3.12 --isolated --with pytest pytest -q → exit 0, 154 passed (no fallback): pass
- C11 all five mandatory commands exit 0: pass
- C12 one commit 051b527588dc3a3d1f7779946adb3ad38df7bb55 "Phase 7: Polish & Harden" with the §5 trailer; status clean; git ls-files .relay empty: pass
Engineering: build pass · typecheck pass · lint pass · tests pass (154 passed)
Cleanliness: debug prints 1 (cli.py stderr error path, covered by the spec's override; 0 added this phase) · TODO/FIXME 0 (1 pre-existing hit inside the verbatim real fixture, non-code) · dead imports 0
Files changed: 2 (this phase: README.md, tests/test_json_contract.py; 34 run-wide vs baseline)

MEMORY_SAVED: project_contextmeter, contextmeter-verification-grep-traps

RELAY_PHASE_DONE
Phase 7 complete. STATE.md updated.
Evidence: .relay/contextmeter-session-transcript-context-AsGfac/phases/phase-7.evidence.md
