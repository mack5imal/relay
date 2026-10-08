#!/usr/bin/env bash
# build-graph.test.sh — fixture tests for scripts/build-graph.sh
#
# Proves the graph build is safe to run anywhere: output is pinned to <run-root>/graph via an
# absolute GRAPHIFY_OUT (a user's own graphify-out/ is never touched), graphify runs from the
# repository top level with --no-cluster --force, and every outcome — not installed, up to
# date, failed — prints one line and exits 0 so a missing graph never blocks a run.
# A stub `graphify` on PATH records how it was invoked; the real tool is never called.
#
# Repo-only (not shipped in the plugin payload). Run from anywhere:
#   bash tests/build-graph.test.sh
# Exits 0 if every assertion passes, 1 otherwise.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BG="$REPO_ROOT/skills/goal/scripts/build-graph.sh"

if [ ! -f "$BG" ]; then
  echo "FATAL: build-graph.sh not found at $BG" >&2
  exit 1
fi

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  \033[31m✗\033[0m %s\n      %s\n' "$1" "$2"; }

assert_rc()       { if [ "$2" = "$RC" ]; then ok "$1"; else no "$1" "expected exit $2 got $RC (out: $OUT)"; fi; }
assert_contains() { case "$3" in *"$2"*) ok "$1";; *) no "$1" "[$3] missing substring [$2]";; esac; }
assert_missing()  { case "$3" in *"$2"*) no "$1" "[$3] unexpectedly contains [$2]";; *) ok "$1";; esac; }

new_workdir() { mktemp -d; }

# make_stub <dir> — a fake graphify that records args, GRAPHIFY_OUT, and cwd, then behaves per STUB_MODE.
make_stub() {
  mkdir -p "$1/bin"
  cat > "$1/bin/graphify" <<'STUB'
#!/usr/bin/env bash
{ echo "args=$*"; echo "out=${GRAPHIFY_OUT:-}"; echo "pwd=$(pwd)"; } > "$STUB_RECORD"
case "${STUB_MODE:-ok}" in
  ok)
    mkdir -p "$GRAPHIFY_OUT"
    echo '{"nodes": [], "links": []}' > "$GRAPHIFY_OUT/graph.json"
    echo "[graphify watch] Rebuilt (no clustering): 12 nodes, 34 edges"
    exit 0 ;;
  nothing)
    echo "Nothing to update or rebuild failed — check output above." >&2
    exit 1 ;;
  fail)
    echo "boom" >&2
    exit 1 ;;
esac
STUB
  chmod +x "$1/bin/graphify"
}

# with_stub <workdir> <cmd...> — run with only the stub, /usr/bin, and /bin on PATH.
with_stub() { local d="$1"; shift; OUT="$(env PATH="$d/bin:/usr/bin:/bin" STUB_RECORD="$d/record" "$@" 2>/dev/null)"; RC=$?; }

echo "build-graph.test.sh — fixtures for $BG"
echo

# ---------------------------------------------------------------------------
echo "[1] Usage errors exit 2"
OUT="$(bash "$BG" 2>/dev/null)"; RC=$?
assert_rc "no argument -> exit 2" 2
OUT="$(bash "$BG" a b 2>/dev/null)"; RC=$?
assert_rc "two arguments -> exit 2" 2

# ---------------------------------------------------------------------------
echo "[2] graphify not installed -> one skip line, exit 0, nothing created"
w="$(new_workdir)"; cd "$w" || exit 1
mkdir -p run
OUT="$(env PATH="/usr/bin:/bin" bash "$BG" run 2>/dev/null)"; RC=$?
assert_rc "skip exits 0" 0
assert_contains "skip line explains why" "graph: skipped - graphify not installed" "$OUT"
[ -e run/graph ] && no "no graph dir created" "found $w/run/graph" || ok "no graph dir created"
cd "$REPO_ROOT"; rm -rf "$w"

# ---------------------------------------------------------------------------
echo "[3] Success -> absolute GRAPHIFY_OUT under the run root, update --no-cluster --force, summary line"
w="$(new_workdir)"; cd "$w" || exit 1
git init -q . && mkdir -p .relay/run-x && make_stub "$w"
with_stub "$w" bash "$BG" .relay/run-x
assert_rc "build exits 0" 0
assert_contains "summary names the graph and counts" "graph/graph.json (12 nodes, 34 edges)" "$OUT"
record="$(cat "$w/record" 2>/dev/null)"
assert_contains "graphify invoked with update . --no-cluster --force" "args=update . --no-cluster --force" "$record"
out_line="$(printf '%s\n' "$record" | grep '^out=')"
assert_contains "GRAPHIFY_OUT points at <run-root>/graph" "/.relay/run-x/graph" "$out_line"
case "$out_line" in out=/*) ok "GRAPHIFY_OUT is absolute";; *) no "GRAPHIFY_OUT is absolute" "[$out_line]";; esac
[ -f .relay/run-x/logs/graph-build.log ] && ok "graphify output captured in logs/graph-build.log" || no "graphify output captured in logs/graph-build.log" "no log"
assert_contains "log holds graphify's output" "Rebuilt (no clustering)" "$(cat .relay/run-x/logs/graph-build.log 2>/dev/null)"
[ -e graphify-out ] && no "no graphify-out/ in the project" "found $w/graphify-out" || ok "no graphify-out/ in the project"
cd "$REPO_ROOT"; rm -rf "$w"

# ---------------------------------------------------------------------------
echo "[4] Invoked from a subdirectory -> graphify still runs from the repository top level"
w="$(new_workdir)"; cd "$w" || exit 1
git init -q . && mkdir -p .relay/run-x sub && make_stub "$w"
top="$(pwd -P)"
cd sub || exit 1
with_stub "$w" bash "$BG" ../.relay/run-x
assert_rc "build from subdirectory exits 0" 0
assert_contains "graphify cwd is the repo top level" "pwd=$top" "$(cat "$w/record" 2>/dev/null)"
assert_missing "graphify cwd is not the subdirectory" "pwd=$top/sub" "$(cat "$w/record" 2>/dev/null)"
cd "$REPO_ROOT"; rm -rf "$w"

# ---------------------------------------------------------------------------
echo "[5] Outside git -> graphify runs from the current directory"
w="$(new_workdir)"; cd "$w" || exit 1
mkdir -p run && make_stub "$w"
here="$(pwd)"   # outside git the script keeps the caller's (logical) cwd; git's toplevel in [4] is physical
with_stub "$w" bash "$BG" run
assert_rc "build outside git exits 0" 0
assert_contains "graphify cwd is the current directory" "pwd=$here" "$(cat "$w/record" 2>/dev/null)"
cd "$REPO_ROOT"; rm -rf "$w"

# ---------------------------------------------------------------------------
echo "[6] Nothing to update with an existing graph -> 'up to date', exit 0"
w="$(new_workdir)"; cd "$w" || exit 1
git init -q . && mkdir -p .relay/run-x/graph && make_stub "$w"
echo '{"nodes": [], "links": []}' > .relay/run-x/graph/graph.json
STUB_MODE=nothing with_stub "$w" env STUB_MODE=nothing bash "$BG" .relay/run-x
assert_rc "up-to-date exits 0" 0
assert_contains "up-to-date summary" "graph/graph.json (up to date)" "$OUT"
cd "$REPO_ROOT"; rm -rf "$w"

# ---------------------------------------------------------------------------
echo "[7] Build failure -> one failure line pointing at the log, still exit 0"
w="$(new_workdir)"; cd "$w" || exit 1
git init -q . && mkdir -p .relay/run-x && make_stub "$w"
with_stub "$w" env STUB_MODE=fail bash "$BG" .relay/run-x
assert_rc "failure exits 0" 0
assert_contains "failure line names the exit code" "graph: build failed (exit 1)" "$OUT"
assert_contains "failure line points at the log" "logs/graph-build.log" "$OUT"
cd "$REPO_ROOT"; rm -rf "$w"

# ---------------------------------------------------------------------------
echo "[8] Run root that does not exist -> skip line, exit 0"
w="$(new_workdir)"; cd "$w" || exit 1
make_stub "$w"
with_stub "$w" bash "$BG" does-not-exist
assert_rc "missing run root exits 0" 0
assert_contains "missing run root explained" "graph: skipped - run root not found: does-not-exist" "$OUT"
[ -e "$w/record" ] && no "graphify not invoked" "stub was called" || ok "graphify not invoked"
cd "$REPO_ROOT"; rm -rf "$w"

# ---------------------------------------------------------------------------
echo
echo "----------------------------------------"
printf 'Results: %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  exit 1
fi
echo "All fixture scenarios passed."
exit 0
