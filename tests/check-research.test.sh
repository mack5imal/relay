#!/usr/bin/env bash
# check-research.test.sh — fixture tests for scripts/check-research.sh
#
# Proves the Stage 2.6 research contract: an index of approved questions (or a reasoned
# `No research:`), one answer file per answered question with the sections the plan relies on,
# every finding sourced or flagged `unverified (training knowledge)`, a `Contradicts:` line on
# every answer, unanswered questions carried as known gaps, and --digest printing only what the
# planner reads (Answer, Implications, Contradicts).
#
# Repo-only (not shipped in the plugin payload). Run from anywhere:
#   bash tests/check-research.test.sh
# Exits 0 if every assertion passes, 1 otherwise.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CR="$REPO_ROOT/skills/goal/scripts/check-research.sh"
FIX="$REPO_ROOT/tests/fixtures/check-research"

for f in "$CR" "$FIX/research/README.md"; do
  [ -f "$f" ] || { echo "FATAL: missing $f" >&2; exit 1; }
done

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  \033[31m✗\033[0m %s\n      %s\n' "$1" "$2"; }

assert_rc()       { if [ "$2" = "$RC" ]; then ok "$1"; else no "$1" "expected exit $2 got $RC (out: $OUT)"; fi; }
assert_contains() { case "$3" in *"$2"*) ok "$1";; *) no "$1" "missing substring [$2] in [$3]";; esac; }
assert_missing()  { case "$3" in *"$2"*) no "$1" "unexpectedly contains [$2]";; *) ok "$1";; esac; }

run() { OUT="$("$@" 2>&1)"; RC=$?; }

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

# root <name> — a copy of the fixture run root; sets R
root() { R="$W/$1"; mkdir -p "$R"; cp -R "$FIX/research" "$R/research"; }

# ---------------------------------------------------------------------------
echo
echo "[1] A complete research set passes"
root good
run bash "$CR" "$R"
assert_rc "exits 0" 0
assert_contains "summary counts" "research: 3 questions, 2 answered, 1 unverified finding(s), 1 contradict the spec, 1 unanswered" "$OUT"
assert_contains "unanswered is a known gap, not an error" "vocal-dataset: unanswered — researcher failed twice (network) (a known gap)" "$OUT"
assert_missing "no errors" "❌" "$OUT"
run bash "$CR" "$R/"
assert_rc "trailing slash accepted" 0

# ---------------------------------------------------------------------------
echo
echo "[2] --digest prints only what the planner reads"
run bash "$CR" "$R" --digest
assert_rc "exits 0" 0
assert_contains "one heading per answered question, with confidence" "### pitch-detection (high)" "$OUT"
assert_contains "the answer" "McLeod (MPM) matches YIN's accuracy" "$OUT"
assert_contains "the implications" "- Phase 2 implements MPM, not YIN" "$OUT"
assert_contains "the contradiction" "Contradicts: S13 — \"capture starts on launch\" cannot hold on iOS" "$OUT"
assert_missing "no findings (sources stay in the file)" "oucs-2008-03.pdf" "$OUT"
assert_missing "no question section" "## Question" "$OUT"
run bash "$CR" "$R"
assert_missing "without --digest, no digest" "### pitch-detection" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[3] Answer files must have the plan's shape"
root nofile
rm "$R/research/ios-audio.md"
run bash "$CR" "$R"
assert_rc "missing answer file exits 1" 1
assert_contains "names it" "ios-audio: no " "$OUT"

root nosection
perl -0pi -e 's/## Implications for this plan\n\n- Add a .*?\n//s' "$R/research/ios-audio.md"
run bash "$CR" "$R"
assert_rc "missing section exits 1" 1
assert_contains "names the section" "ios-audio: missing '## Implications for this plan'" "$OUT"

root noimp
perl -0pi -e 's/- Add a "Tap to start".*?\n//' "$R/research/ios-audio.md"
run bash "$CR" "$R"
assert_rc "implications with no bullets exits 1" 1
assert_contains "says why it matters" "research the plan cannot use is not done" "$OUT"

root emptyans
perl -0pi -e 's/(## Answer\n\n)A user gesture.*?silently\.\n/$1/s' "$R/research/ios-audio.md"
run bash "$CR" "$R"
assert_rc "empty answer exits 1" 1
assert_contains "names it" "ios-audio: '## Answer' is empty" "$OUT"

root noconf
perl -pi -e 's/^medium — documented/fairly sure — documented/' "$R/research/ios-audio.md"
run bash "$CR" "$R"
assert_rc "confidence off the scale exits 1" 1
assert_contains "names the scale" "must start with high, medium or low" "$OUT"

root nocontra
perl -ni -e 'print unless /^Contradicts:/' "$R/research/pitch-detection.md"
run bash "$CR" "$R"
assert_rc "no Contradicts line exits 1" 1
assert_contains "asks for 'none'" "write 'Contradicts: none'" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[4] Every finding is sourced or flagged unverified"
root nosource
perl -pi -e 's# — https://developer.apple.com/documentation/webkit \(Safari 17\)##' "$R/research/ios-audio.md"
run bash "$CR" "$R"
assert_rc "an unsourced finding exits 1" 1
assert_contains "names the finding" "ios-audio: finding with no source — cite a URL, mark it 'derived: <from what>', or mark it 'unverified (training knowledge)': AudioContext starts suspended" "$OUT"

root allunverified
perl -pi -e 's#https://\S+ \([^)]*\)#unverified (training knowledge)#g' "$R/research/pitch-detection.md"
run bash "$CR" "$R"
assert_rc "flagged findings pass" 0
assert_contains "and are counted" "3 unverified finding(s)" "$OUT"

root derived
perl -pi -e 's#^(- AudioWorklet render quantum is 128 frames) — unverified \(training knowledge\)#$1 — derived: 2048-sample window / 16 quanta#' "$R/research/pitch-detection.md"
run bash "$CR" "$R"
assert_rc "a derived finding passes" 0
assert_contains "and is not counted unverified" "0 unverified finding(s)" "$OUT"

root longans
perl -0pi -e 's/(## Answer\n\n)/$1 . ("word " x 130) . "\n"/e' "$R/research/ios-audio.md"
run bash "$CR" "$R"
assert_rc "a long answer only warns" 0
assert_contains "warns with the count" "ios-audio: '## Answer' is " "$OUT"

root nofindings
perl -0pi -e 's/(## Findings\n\n)- AudioContext.*?\n/$1/s' "$R/research/ios-audio.md"
run bash "$CR" "$R"
assert_rc "findings with no bullets exits 1" 1
assert_contains "names it" "ios-audio: '## Findings' has no bullets" "$OUT"

# The two slips 5 of 6 tunez researchers made (fix 24): a note inside the unverified marker is
# still unverified; "same source" is not a source, and the ❌ says what to do instead.
root variant
perl -pi -e 's#unverified \(training knowledge\)#unverified (training knowledge; spec says 128)#' "$R/research/pitch-detection.md"
run bash "$CR" "$R"
assert_rc "a note inside the unverified marker passes" 0
assert_contains "and is counted unverified" "1 unverified finding(s)" "$OUT"

root samesource
perl -pi -e 's#— https://example.org/pitchy/README \(pitchy 4.1\)#— same source (2005 paper)#' "$R/research/pitch-detection.md"
run bash "$CR" "$R"
assert_rc "'same source' exits 1" 1
assert_contains "says to repeat the URL" "pitch-detection: finding cites 'same source' — repeat the URL" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[4b] --only: a researcher checks its own file before returning"
root only
perl -pi -e 's/\| answered \|/| pending |/' "$R/research/README.md"
run bash "$CR" "$R" --only pitch-detection
assert_rc "a good file passes whatever its index Status" 0
assert_contains "one-line verdict" "research pitch-detection: ok (1 unverified finding(s))" "$OUT"
assert_missing "no index summary" "questions," "$OUT"
perl -pi -e 's# — https://example.org/pitchy/README \(pitchy 4.1\)##' "$R/research/pitch-detection.md"
run bash "$CR" "$R" --only pitch-detection
assert_rc "a bad file exits 1" 1
assert_contains "names the problem" "pitch-detection: finding with no source" "$OUT"
assert_contains "counts the problems" "research pitch-detection: 1 problem(s)" "$OUT"
run bash "$CR" "$R" --only ios-audio
assert_rc "only the named file is checked" 0
rm "$R/research/README.md"
run bash "$CR" "$R" --only ios-audio
assert_rc "needs no index" 0
run bash "$CR" "$R" --only nope
assert_rc "a missing file exits 1" 1
assert_contains "names it" "nope: no " "$OUT"
run bash "$CR" "$R" --only
assert_rc "--only with no slug exits 2" 2
run bash "$CR" "$R" --only ios-audio --digest
assert_rc "--only with --digest exits 2" 2

# ---------------------------------------------------------------------------
echo
echo "[5] The index"
root badstatus
perl -pi -e 's/\| S13 \| answered \|/| S13 | done |/' "$R/research/README.md"
run bash "$CR" "$R"
assert_rc "unknown status exits 1" 1
assert_contains "names the allowed statuses" "use 'answered' or 'unanswered — <reason>'" "$OUT"

root noreason
perl -pi -e 's/unanswered — researcher failed twice \(network\)/unanswered/' "$R/research/README.md"
run bash "$CR" "$R"
assert_rc "unanswered with no reason exits 1" 1
assert_contains "asks for the reason" "vocal-dataset: 'unanswered' with no reason" "$OUT"

root noindex
rm "$R/research/README.md"
run bash "$CR" "$R"
assert_rc "no index exits 1" 1
assert_contains "says what to write" "write the question index (or 'No research: <reason>')" "$OUT"

root emptyindex
printf '# Research index\n\nnothing yet\n' > "$R/research/README.md"
run bash "$CR" "$R"
assert_rc "an index with no questions and no reason exits 1" 1

R="$W/none"; mkdir -p "$R/research"
printf '# Research index\n\nNo research: the change stays inside the stack the repo already uses (React 18, Vitest) — nothing unfamiliar.\n' > "$R/research/README.md"
run bash "$CR" "$R"
assert_rc "zero questions with a reason passes" 0
assert_contains "prints the reason" "research: none — the change stays inside the stack" "$OUT"

R="$W/nonebare"; mkdir -p "$R/research"
printf 'No research:\n' > "$R/research/README.md"
run bash "$CR" "$R"
assert_rc "zero questions without a reason exits 1" 1
assert_contains "asks why" "'No research:' has no reason" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[6] Usage errors"
run bash "$CR"
assert_rc "no args exits 2" 2
run bash "$CR" "$W/does-not-exist"
assert_rc "missing run root exits 2" 2
run bash "$CR" "$W/good" --bogus
assert_rc "unknown flag exits 2" 2

# ---------------------------------------------------------------------------
echo
echo "----------------------------------------"
printf 'Results: %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  exit 1
fi
echo "All fixture scenarios passed."
exit 0
