#!/usr/bin/env bash
# run-logged.test.sh — fixture tests for scripts/run-logged.sh
#
# Proves the context-budget primitive behind "evidence lives on disk": a command's full
# stdout+stderr lands in a log file, while the caller (the executing agent) sees only the
# exit code, the log path, and a short tail. The headline assertion is the LONG-OUTPUT
# test — 5000 lines of output must reach stdout as a 7-line summary.
#
# Repo-only (not shipped in the plugin payload). Run from anywhere:
#   bash tests/run-logged.test.sh
# Exits 0 if every assertion passes, 1 otherwise.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RL="$REPO_ROOT/skills/goal/scripts/run-logged.sh"

if [ ! -f "$RL" ]; then
  echo "FATAL: run-logged.sh not found at $RL" >&2
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

count_lines() { printf '%s\n' "$1" | wc -l | tr -d ' '; }

# Each test runs in its own throwaway working directory so the repo is never touched.
new_workdir() { mktemp -d; }

echo "run-logged.test.sh — fixtures for $RL"
echo

# ---------------------------------------------------------------------------
echo "[1] Success — exit 0, 3-line tail on stdout, full output in the log"
w="$(new_workdir)"; cd "$w" || exit 1
run bash "$RL" "$w/logs/ok.log" 'for i in 1 2 3 4 5; do echo line-$i; done'
assert_rc "command succeeds (exit 0)" 0
assert_contains "echoes the command" '$ for i in 1 2 3 4 5' "$OUT"
assert_contains "reports exit code" "exit: 0" "$OUT"
assert_contains "reports log path and line count" "log: $w/logs/ok.log (5 lines)" "$OUT"
assert_contains "success tail is 3 lines" "--- last 3 lines ---" "$OUT"
assert_contains "tail includes the last line" "line-5" "$OUT"
assert_missing "tail omits early lines" "line-2" "$OUT"
assert_eq "log holds every line" "5" "$(grep -c '^line-' "$w/logs/ok.log")"
cd "$REPO_ROOT"; rm -rf "$w"

# ---------------------------------------------------------------------------
echo "[2] Failure — exit code propagated, 20-line tail"
w="$(new_workdir)"; cd "$w" || exit 1
run bash "$RL" "$w/fail.log" 'for i in $(seq 1 30); do echo row-$i; done; exit 3'
assert_rc "propagates the command's exit code" 3
assert_contains "reports non-zero exit" "exit: 3" "$OUT"
assert_contains "failure tail is 20 lines" "--- last 20 lines ---" "$OUT"
assert_contains "tail includes the last line" "row-30" "$OUT"
assert_missing "tail omits lines before the window" "row-5" "$OUT"
assert_eq "log holds all 30 lines" "30" "$(grep -c '^row-' "$w/fail.log")"
cd "$REPO_ROOT"; rm -rf "$w"

# ---------------------------------------------------------------------------
echo "[3] LONG OUTPUT — 5000 lines reach stdout as a 7-line summary"
w="$(new_workdir)"; cd "$w" || exit 1
run bash "$RL" "$w/long.log" 'seq 1 5000'
assert_rc "long command succeeds" 0
assert_eq "stdout is 4 header lines + 3 tail lines" "7" "$(count_lines "$OUT")"
assert_eq "log holds all 5000 lines" "5000" "$(wc -l < "$w/long.log" | tr -d ' ')"
cd "$REPO_ROOT"; rm -rf "$w"

# ---------------------------------------------------------------------------
echo "[4] stderr is captured in the log (and shows in the tail)"
w="$(new_workdir)"; cd "$w" || exit 1
run bash "$RL" "$w/err.log" 'echo to-out; echo to-err >&2'
assert_contains "log contains stderr" "to-err" "$(cat "$w/err.log")"
assert_contains "log contains stdout" "to-out" "$(cat "$w/err.log")"
assert_contains "tail shows stderr" "to-err" "$OUT"
cd "$REPO_ROOT"; rm -rf "$w"

# ---------------------------------------------------------------------------
echo "[5] Pipelines and quoted arguments work"
w="$(new_workdir)"; cd "$w" || exit 1
run bash "$RL" "$w/pipe.log" 'echo "hello world" | tr a-z A-Z'
assert_rc "pipeline succeeds" 0
assert_contains "pipeline output reaches the tail" "HELLO WORLD" "$OUT"
cd "$REPO_ROOT"; rm -rf "$w"

# ---------------------------------------------------------------------------
echo "[6] Missing parent directories are created; the log is overwritten on re-run"
w="$(new_workdir)"; cd "$w" || exit 1
run bash "$RL" "$w/deep/nested/dir/x.log" 'echo first-run'
[ -f "$w/deep/nested/dir/x.log" ] && ok "log created under missing dirs" || no "log created under missing dirs" "no file at $w/deep/nested/dir/x.log"
run bash "$RL" "$w/deep/nested/dir/x.log" 'echo second-run'
assert_contains "re-run writes new output" "second-run" "$(cat "$w/deep/nested/dir/x.log")"
assert_missing "re-run overwrites old output" "first-run" "$(cat "$w/deep/nested/dir/x.log")"
cd "$REPO_ROOT"; rm -rf "$w"

# ---------------------------------------------------------------------------
echo "[7] Usage errors exit 2 with a usage message"
w="$(new_workdir)"; cd "$w" || exit 1
run bash "$RL"
assert_rc "no arguments -> exit 2" 2
run bash "$RL" "$w/only-log.log"
assert_rc "missing command -> exit 2" 2
run bash "$RL" "$w/empty.log" ""
assert_rc "empty command -> exit 2" 2
assert_contains "usage message on stderr" "usage: run-logged.sh" "$(bash "$RL" 2>&1)"
cd "$REPO_ROOT"; rm -rf "$w"

# ---------------------------------------------------------------------------
echo "[8] RUN_LOGGED_TAIL overrides the tail length; non-numeric values are ignored"
w="$(new_workdir)"; cd "$w" || exit 1
OUT="$(RUN_LOGGED_TAIL=1 bash "$RL" "$w/t1.log" 'for i in 1 2 3 4 5; do echo line-$i; done' 2>/dev/null)"; RC=$?
assert_contains "override sets tail length" "--- last 1 lines ---" "$OUT"
assert_contains "override tail keeps the last line" "line-5" "$OUT"
assert_missing "override tail drops earlier lines" "line-4" "$OUT"
OUT="$(RUN_LOGGED_TAIL=lots bash "$RL" "$w/t2.log" 'echo x' 2>/dev/null)"; RC=$?
assert_contains "non-numeric override falls back to default" "--- last 3 lines ---" "$OUT"
cd "$REPO_ROOT"; rm -rf "$w"

# ---------------------------------------------------------------------------
echo "[9] stdin is closed — a command that reads stdin cannot hang or consume caller input"
w="$(new_workdir)"; cd "$w" || exit 1
OUT="$(printf 'leaked-input\n' | bash "$RL" "$w/stdin.log" 'cat' 2>/dev/null)"; RC=$?
assert_rc "stdin-reading command completes" 0
assert_missing "caller's stdin does not reach the command" "leaked-input" "$(cat "$w/stdin.log")"
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
