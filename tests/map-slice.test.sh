#!/usr/bin/env bash
# map-slice.test.sh — fixture tests for scripts/map-slice.py and its launcher scripts/map-slice.sh
#
# Proves the repo-map slice a cold-started phase reads: exact seeds resolve to their members,
# uses, and users with file:line citations; the token budget sheds AMBIGUOUS, then INFERRED
# edges, then truncates evenly while keeping every seed header; and the launcher degrades
# to file-name matches instead of failing when there is no graph or no Python.
# The headline assertion is the SHED-ORDER sweep — every budget from full size down to 1
# must respect the tier order.
#
# Repo-only (not shipped in the plugin payload). Run from anywhere:
#   bash tests/map-slice.test.sh
# Exits 0 if every assertion passes, 1 otherwise.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MS_PY="$REPO_ROOT/skills/goal/scripts/map-slice.py"
MS_SH="$REPO_ROOT/skills/goal/scripts/map-slice.sh"
FX="$REPO_ROOT/tests/fixtures/map-graph.json"

for f in "$MS_PY" "$MS_SH" "$FX"; do
  if [ ! -f "$f" ]; then
    echo "FATAL: missing $f" >&2
    exit 1
  fi
done
if ! command -v python3 >/dev/null 2>&1; then
  echo "FATAL: python3 is required to test map-slice.py" >&2
  exit 1
fi

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  \033[31m✗\033[0m %s\n      %s\n' "$1" "$2"; }

# run <cmd...> -> sets OUT (stdout only) and RC (exit code)
run() { OUT="$("$@" 2>/dev/null)"; RC=$?; }

assert_rc()       { if [ "$2" = "$RC" ]; then ok "$1"; else no "$1" "expected exit $2 got $RC (out: $OUT)"; fi; }
assert_contains() { case "$3" in *"$2"*) ok "$1";; *) no "$1" "[$3] missing substring [$2]";; esac; }
assert_missing()  { case "$3" in *"$2"*) no "$1" "[$3] unexpectedly contains [$2]";; *) ok "$1";; esac; }
assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "expected [$2] got [$3]"; fi; }

# Same estimate map-slice.py uses: ceil(characters / 4). Fixture output is ASCII, so bytes == chars.
tokens_of() { local n; n="$(printf '%s' "$1" | wc -c | tr -d ' ')"; echo $(( (n + 3) / 4 )); }
slice() { python3 "$MS_PY" --graph "$FX" "$@" 2>/dev/null; }

new_workdir() { mktemp -d; }

echo "map-slice.test.sh — fixtures for $MS_PY and $MS_SH"
echo

# ---------------------------------------------------------------------------
echo "[1] Exact seed -> header with file:line, grouped members / uses / users"
run python3 "$MS_PY" --graph "$FX" Scheduler
assert_rc "slice succeeds (exit 0)" 0
assert_contains "seed header cites file:line" "### Scheduler (Sources/App/Scheduler/Scheduler.swift:L8)" "$OUT"
assert_contains "declaring files listed" "declared in: " "$OUT"
assert_contains "extension file is a declaring file" "Scheduler+Actions.swift" "$OUT"
assert_contains "method from the extension file" "Sources/App/Scheduler/Scheduler+Actions.swift: .enterHeadsUp() L13" "$OUT"
assert_contains "methods from the main file, in line order" ".start() L20, .stop() L31" "$OUT"
assert_contains "nested type tagged with its relation" "Selection L40 [contains]" "$OUT"
assert_contains "supertypes section" "inherits:" "$OUT"
assert_contains "used type with location" "Sources/App/Routine/Routine.swift: Routine L66" "$OUT"
assert_contains "external type grouped last" "(external): TimeInterval" "$OUT"
assert_contains "users listed" "AppCoordinator L43" "$OUT"
assert_contains "non-default relation and INFERRED confidence tagged" ".init() L111 [calls] (inferred)" "$OUT"
assert_contains "AMBIGUOUS confidence tagged" "LegacyTimer L3 (ambiguous)" "$OUT"
assert_eq "document node with the same label is ignored" "1" "$(printf '%s\n' "$OUT" | grep -c '^### Scheduler')"
assert_missing "no omission footer when nothing was trimmed" "[omitted:" "$OUT"

# ---------------------------------------------------------------------------
echo "[2] Multiple seeds (comma-separated and separate args) and case-insensitive fallback"
run python3 "$MS_PY" --graph "$FX" "Scheduler, HistoryStore"
assert_contains "comma-separated seeds: first header" "### Scheduler (" "$OUT"
assert_contains "comma-separated seeds: second header" "### HistoryStore (Sources/App/History/HistoryStore.swift:L72)" "$OUT"
assert_contains "second seed's member" ".append() L90" "$OUT"
run python3 "$MS_PY" --graph "$FX" historystore
assert_contains "case-insensitive exact match resolves" "### HistoryStore (" "$OUT"

# ---------------------------------------------------------------------------
echo "[3] Unmatched seed -> reported with suggestions, still exit 0"
run python3 "$MS_PY" --graph "$FX" Sched
assert_rc "unmatched seed is not an error" 0
assert_contains "no-match header" "### Sched - no match" "$OUT"
assert_contains "shortest label suggestions first" "suggestions: Scheduler, SchedulerTests" "$OUT"
run python3 "$MS_PY" --graph "$FX" Zzz
assert_contains "no suggestions reported as none" "suggestions: none" "$OUT"

# ---------------------------------------------------------------------------
echo "[3b] Seed lost to a graphify node-id collision -> named, with the survivor to seed"
w="$(new_workdir)"
cat > "$w/collide.json" <<'GRAPH'
{"nodes": [
  {"id": "pkg_mod_options", "label": "Options", "file_type": "code", "source_file": "src/cli.py", "source_location": "L42", "_origin": "ast"},
  {"id": "pkg_mod_lonely", "label": "_lonely()", "file_type": "code", "source_file": "src/cli.py", "source_location": "L88", "_origin": "ast"}
], "links": []}
GRAPH
run python3 "$MS_PY" --graph "$w/collide.json" "_options()"
assert_rc "collided seed is not an error" 0
assert_contains "no-match header" "### _options() - no match" "$OUT"
assert_contains "the survivor is suggested" "suggestions: Options" "$OUT"
assert_contains "the collision is explained" "same node id as Options" "$OUT"
assert_contains "and what to do about it" "seed Options instead" "$OUT"
run python3 "$MS_PY" --graph "$w/collide.json" "_lonely"
assert_contains "a plain miss keeps substring suggestions" "suggestions: _lonely()" "$OUT"
assert_missing "and carries no collision note" "same node id as" "$OUT"
run python3 "$MS_PY" --graph "$w/collide.json" "OPTIONS"
assert_contains "case-only difference still resolves as a match" "### Options (src/cli.py:L42)" "$OUT"
rm -rf "$w"

# ---------------------------------------------------------------------------
echo "[4] Nested type -> 'nested in' its parent"
run python3 "$MS_PY" --graph "$FX" Selection
assert_contains "nested-in section" "nested in:" "$OUT"
assert_contains "parent type cited" "Scheduler L8" "$OUT"

# ---------------------------------------------------------------------------
echo "[5] Errors: usage -> 2; missing or malformed graph -> 3"
w="$(new_workdir)"
run python3 "$MS_PY" --graph "$FX"
assert_rc "no seeds -> exit 2" 2
run python3 "$MS_PY" --graph "$FX" --budget 0 Scheduler
assert_rc "budget below 1 -> exit 2" 2
run python3 "$MS_PY" --graph "$w/missing.json" Scheduler
assert_rc "missing graph -> exit 3" 3
printf 'not json' > "$w/bad.json"
run python3 "$MS_PY" --graph "$w/bad.json" Scheduler
assert_rc "malformed graph -> exit 3" 3
printf '[1, 2]' > "$w/list.json"
run python3 "$MS_PY" --graph "$w/list.json" Scheduler
assert_rc "graph without nodes/links -> exit 3" 3
rm -rf "$w"

# ---------------------------------------------------------------------------
echo "[6] SHED ORDER — every budget from full size down to 1 respects AMBIGUOUS -> INFERRED -> truncation"
full="$(slice Scheduler)"
full_tokens="$(tokens_of "$full")"
violations=""
over=""
saw_ambiguous_only=0
saw_inferred=0
b="$full_tokens"
while [ "$b" -ge 1 ]; do
  s="$(slice --budget "$b" Scheduler)"
  case "$s" in *"### Scheduler ("*) ;; *) violations="$violations b=$b:header-missing";; esac
  case "$s" in *"LegacyTimer"*)
    case "$s" in *".init() L111"*) ;; *) violations="$violations b=$b:ambiguous-kept-inferred-shed";; esac ;;
  esac
  case "$s" in *".init() L111"*)
    case "$s" in *"over budget"*) violations="$violations b=$b:inferred-kept-but-truncated";; esac ;;
  esac
  case "$s" in *"[omitted: 1 ambiguous]"*) saw_ambiguous_only=1;; esac
  case "$s" in *"1 inferred"*) saw_inferred=1;; esac
  t="$(tokens_of "$s")"
  headers_only="$(printf '%s\n' "$s" | grep -vc -e '^## ' -e '^### ' -e '^\[' -e '^$')"
  if [ "$t" -gt "$b" ] && [ "$headers_only" -gt 0 ]; then over="$over b=$b:t=$t"; fi
  b=$((b - 1))
done
assert_eq "no shed-order violations across $full_tokens budgets" "" "$violations"
assert_eq "output fits the budget whenever more than headers remain" "" "$over"
[ "$saw_ambiguous_only" -eq 1 ] && ok "some budget sheds only the AMBIGUOUS edge" || no "some budget sheds only the AMBIGUOUS edge" "never saw [omitted: 1 ambiguous]"
[ "$saw_inferred" -eq 1 ] && ok "some budget also sheds the INFERRED edge" || no "some budget also sheds the INFERRED edge" "never saw 1 inferred"
tiny="$(slice --budget 1 Scheduler HistoryStore)"
assert_contains "tiny budget keeps the first seed header" "### Scheduler (" "$tiny"
assert_contains "tiny budget keeps the second seed header" "### HistoryStore (" "$tiny"
assert_contains "tiny budget reports what was cut" "[+" "$tiny"
assert_contains "tiny budget footer counts truncation" "over budget]" "$tiny"

# ---------------------------------------------------------------------------
echo "[7] Launcher — forced runners produce the real slice"
w="$(new_workdir)"; cd "$w" || exit 1
OUT="$(RELAY_MAP_RUNNER=python3 bash "$MS_SH" "$FX" Scheduler 2>/dev/null)"; RC=$?
assert_rc "python3 runner exits 0" 0
assert_contains "python3 runner prints the slice" "### Scheduler (Sources/App/Scheduler/Scheduler.swift:L8)" "$OUT"
if command -v uv >/dev/null 2>&1; then
  OUT="$(RELAY_MAP_RUNNER=uv bash "$MS_SH" "$FX" Scheduler 2>/dev/null)"; RC=$?
  assert_rc "uv runner exits 0" 0
  assert_contains "uv runner prints the slice" "### Scheduler (Sources/App/Scheduler/Scheduler.swift:L8)" "$OUT"
else
  echo "  - uv runner checks skipped (uv not installed)"
fi
OUT="$(RELAY_MAP_RUNNER=python3 RELAY_MAP_BUDGET=1 bash "$MS_SH" "$FX" Scheduler 2>/dev/null)"
assert_contains "RELAY_MAP_BUDGET reaches map-slice.py" "over budget]" "$OUT"
OUT="$(RELAY_MAP_RUNNER=python3 bash "$MS_SH" "$FX" "Scheduler, HistoryStore" 2>/dev/null)"
assert_contains "launcher splits comma-separated seeds" "### HistoryStore (" "$OUT"
cd "$REPO_ROOT"; rm -rf "$w"

# ---------------------------------------------------------------------------
echo "[8] Launcher — degrades to file-name matches, exit 0"
w="$(new_workdir)"; cd "$w" || exit 1
git init -q .
mkdir -p Sources/App Tests
touch Sources/App/Scheduler.swift Tests/SchedulerTests.swift Sources/App/Other.swift
OUT="$(RELAY_MAP_RUNNER=none bash "$MS_SH" "$FX" Scheduler 2>/dev/null)"; RC=$?
assert_rc "no-runner fallback exits 0" 0
assert_contains "no-runner fallback says why" "Map slice unavailable (no Python runner)" "$OUT"
assert_contains "fallback lists matching files" "- Sources/App/Scheduler.swift" "$OUT"
assert_missing "fallback omits non-matching files" "Other.swift" "$OUT"
run bash "$MS_SH" "$w/no-graph.json" Scheduler
assert_rc "missing-graph fallback exits 0" 0
assert_contains "missing-graph fallback says why" "Map slice unavailable (no graph at" "$OUT"
printf 'not json' > "$w/bad.json"
OUT="$(RELAY_MAP_RUNNER=python3 bash "$MS_SH" "$w/bad.json" Scheduler 2>/dev/null)"
assert_contains "malformed-graph fallback says why" "Map slice unavailable (graph unreadable" "$OUT"
OUT="$(RELAY_MAP_RUNNER=none bash "$MS_SH" "$FX" Nothingmatches 2>/dev/null)"
assert_contains "fallback reports no matches" "- (no file names match)" "$OUT"
i=1
while [ "$i" -le 20 ]; do touch "Sources/App/Scheduler$i.swift"; i=$((i + 1)); done
OUT="$(RELAY_MAP_RUNNER=none bash "$MS_SH" "$FX" Scheduler 2>/dev/null)"
assert_contains "fallback caps matches at 15 per seed" "- (+7 more)" "$OUT"
cd "$REPO_ROOT"; rm -rf "$w"

# ---------------------------------------------------------------------------
echo "[9] Launcher — usage errors exit 2"
run bash "$MS_SH" "$FX"
assert_rc "graph without seeds -> exit 2" 2
run bash "$MS_SH" "$FX" ","
assert_rc "only separators -> exit 2" 2
OUT="$(RELAY_MAP_RUNNER=perl bash "$MS_SH" "$FX" Scheduler 2>/dev/null)"; RC=$?
assert_rc "unknown runner -> exit 2" 2

# ---------------------------------------------------------------------------
echo
echo "----------------------------------------"
printf 'Results: %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  exit 1
fi
echo "All fixture scenarios passed."
exit 0
