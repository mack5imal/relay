#!/usr/bin/env bash
# run-all.sh — runs every tests/*.test.sh and checks each pass count against CLAUDE.md
#
# A suite passes only when it exits 0 AND its "N passed, M failed" line shows exactly the N
# that CLAUDE.md's pre-ship block expects ("bash tests/<suite>.test.sh  # expects: N passed").
# The count check is the point: zsh and uv checks skip when the tool is missing, which lowers
# the count instead of failing, so a bare machine would otherwise pass while testing less.
# It also catches a test added without updating CLAUDE.md.
#
# Used by CI (.github/workflows/ci.yml) and locally. Repo-only (not shipped in the plugin).
#   bash tests/run-all.sh
# RELAY_EXPECTATIONS=<file> reads the expected counts from another file (for testing this
# script). Exits 0 if every suite passes with its expected count, 1 otherwise.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPECT_FILE="${RELAY_EXPECTATIONS:-$REPO_ROOT/CLAUDE.md}"

if [ ! -f "$EXPECT_FILE" ]; then
  echo "FATAL: expectations file not found: $EXPECT_FILE" >&2
  exit 1
fi

ESC="$(printf '\033')"
LOG_DIR="$(mktemp -d)"
trap 'rm -rf "$LOG_DIR"' EXIT

ok_count=0
bad_count=0
bad_names=""

for suite in "$REPO_ROOT"/tests/*.test.sh; do
  name="$(basename "$suite")"
  log="$LOG_DIR/$name.log"

  expected="$(grep -F "bash tests/$name " "$EXPECT_FILE" | grep -E '# expects: [0-9]+ passed' \
    | sed -E 's/.*# expects: ([0-9]+) passed.*/\1/' | head -1)"

  bash "$suite" >"$log" 2>&1
  rc=$?

  # Strip colour codes, then take the last "N passed, M failed" line the suite printed.
  counts="$(sed "s/${ESC}\[[0-9;]*m//g" "$log" | grep -E '(^|[^0-9])[0-9]+ passed, [0-9]+ failed' | tail -1)"
  got="$(printf '%s\n' "$counts" | sed -E 's/(^|.*[^0-9])([0-9]+) passed, ([0-9]+) failed.*/\2/')"
  failed="$(printf '%s\n' "$counts" | sed -E 's/(^|.*[^0-9])([0-9]+) passed, ([0-9]+) failed.*/\3/')"
  [ -n "$counts" ] || { got=""; failed=""; }

  problem=""
  if [ "$rc" -ne 0 ]; then
    problem="exit $rc"
  elif [ -z "$counts" ]; then
    problem="no 'N passed, M failed' line"
  elif [ "$failed" != "0" ]; then
    problem="$failed failed"
  elif [ -z "$expected" ]; then
    problem="no '# expects:' line for it in $(basename "$EXPECT_FILE")"
  elif [ "$got" != "$expected" ]; then
    problem="$got passed, expected $expected (a skipped check, or a stale count in $(basename "$EXPECT_FILE"))"
  fi

  if [ -z "$problem" ]; then
    ok_count=$((ok_count + 1))
    printf '  ok    %-26s %s passed\n' "$name" "$got"
  else
    bad_count=$((bad_count + 1))
    bad_names="$bad_names $name"
    printf '  FAIL  %-26s %s\n' "$name" "$problem"
    echo "  ---- last 40 lines of $name ----"
    tail -40 "$log" | sed 's/^/  | /'
    echo "  ----"
  fi
done

echo
echo "$ok_count suites ok, $bad_count failed"
if [ "$bad_count" -eq 0 ]; then
  echo "All suites passed with their expected counts."
  exit 0
fi
echo "Failed:$bad_names"
exit 1
