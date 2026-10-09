#!/usr/bin/env bash
# preflight.test.sh — fixture tests for skills/goal/scripts/preflight.sh
#
# Proves Stage 6.5's pre-flight runs end to end without the planner writing a loop: the phase
# specs' mandatory commands are unioned and deduplicated, each runs once with its output in a
# log, a failure shows its exit code and tail (plus `run: ! <login>` for an account check), the
# working tree is checked after the commands, one event line lands in STATE.md, and the
# PREFLIGHT_GREEN / PREFLIGHT_RED block is printed by the script itself — also when called
# from zsh, the Bash tool's shell.
#
# Repo-only (not shipped in the plugin payload).
#   bash tests/preflight.test.sh
# Exits 0 if every assertion passes, 1 otherwise.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PF="$REPO_ROOT/skills/goal/scripts/preflight.sh"
[ -f "$PF" ] || { echo "FATAL: missing $PF" >&2; exit 1; }

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  \033[31m✗\033[0m %s\n      %s\n' "$1" "$2"; }
assert_rc()       { if [ "$2" = "$RC" ]; then ok "$1"; else no "$1" "expected exit $2 got $RC (out: $OUT)"; fi; }
assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "expected [$2] got [$3]"; fi; }
assert_contains() { case "$3" in *"$2"*) ok "$1";; *) no "$1" "missing substring [$2] in [$3]";; esac; }
assert_missing()  { case "$3" in *"$2"*) no "$1" "unexpectedly contains [$2]";; *) ok "$1";; esac; }

W="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$W"' EXIT
export RELAY_DATE=2026-09-23

# project <dir> <cmds for phase 1> <cmds for phase 2> — a committed git repo holding a run root
# whose two phase specs list the given commands (one per line, "|"-separated). The run root is
# excluded as claim-run.sh would, and HEAD sits on a feature branch so no remote is probed.
project() {
  local d="$1" rr="$1/.relay/run-Ab3"
  mkdir -p "$rr/phases"
  git init -q -b main "$d"
  printf '/.relay/\n' >> "$d/.git/info/exclude"
  git -C "$d" config user.email t@example.com; git -C "$d" config user.name t
  git -C "$d" config commit.gpgsign false
  printf 'x\n' > "$d/README.md"; git -C "$d" add README.md; git -C "$d" commit -qm init
  git -C "$d" switch -q -c feature
  cat > "$rr/STATE.md" <<'EOF'
# State: test

**Status:** PLANNED

## Notable events

Append-only log.

- 2026-09-22 — Plan locked, 2 phases.

## Carryover
EOF
  local n=1 list
  for list in "$2" "$3"; do
    { printf '# Phase %s\n\n## Mandatory commands\n\n' "$n"
      printf '%s' "$list" | tr '|' '\n' | sed 's/^/- /'
      printf '\n\n## Acceptance criteria\n\n- [ ] something\n'
    } > "$rr/phases/phase-$n.md"
    n=$((n + 1))
  done
  printf '# brief\n## Mandatory commands\n- should-not-run\n' > "$rr/phases/phase-1.brief.md"
}
run() { OUT="$(cd "$1" && bash "$PF" "${@:2}" 2>&1)"; RC=$?; }
events() { awk '/^## Notable events/{f=1; next} /^## /{f=0} f && /^- /' "$1/.relay/run-Ab3/STATE.md"; }

# ---------------------------------------------------------------------------
echo "[1] Green — commands unioned, deduplicated, run once each"
P="$W/green"
project "$P" "echo one|echo shared" "echo shared|touch .relay/run-Ab3/ran-two"
run "$P" .relay/run-Ab3
assert_rc "exits 0" 0
assert_eq "the block opens with PREFLIGHT_GREEN" "PREFLIGHT_GREEN" "$(printf '%s\n' "$OUT" | head -1)"
assert_contains "counts the deduplicated commands" "Commands: 3 clean" "$OUT"
assert_eq "the shared command runs once" "1" "$(printf '%s\n' "$OUT" | grep -c 'ok    echo shared')"
assert_missing "a brief's commands are not phase specs" "should-not-run" "$OUT"
assert_contains "passes relay-git.sh's tree line on" "git: working tree clean" "$OUT"
assert_contains "… and its branch plan" "git: on feature → one commit per phase lands on feature" "$OUT"
[ -f "$P/.relay/run-Ab3/ran-two" ] && ok "commands run from the project root" || no "commands run from the project root" "ran-two missing"
assert_eq "one log per command" "3" "$(ls "$P/.relay/run-Ab3/logs/preflight" | grep -c '\.log$')"
assert_eq "logs the green event after the last one" "- 2026-09-22 — Plan locked, 2 phases.
- 2026-09-23 — Pre-flight green: 3 commands clean." "$(events "$P")"

# ---------------------------------------------------------------------------
echo
echo "[2] Red command — exit code, tail, log; tree clean"
P="$W/red"
project "$P" "echo fine" "printf 'l1\nl2\nl3\nl4\nl5\nl6\n'; exit 3"
run "$P" .relay/run-Ab3
assert_rc "exits 1" 1
assert_eq "the block opens with PREFLIGHT_RED" "PREFLIGHT_RED" "$(printf '%s\n' "$OUT" | head -1)"
assert_contains "counts clean and failed" "Commands: 2 run — 1 clean, 1 failed" "$OUT"
assert_contains "names the failing command and its exit code" "- FAIL  printf 'l1\nl2\nl3\nl4\nl5\nl6\n'; exit 3 — exit 3 (log: " "$OUT"
assert_contains "shows the last 5 lines" "      l2" "$OUT"
assert_missing "… and no more" "      l1" "$OUT"
assert_contains "the event names the command" "Pre-flight red: printf 'l1\nl2\nl3\nl4\nl5\nl6\n'; exit 3 exited 3." "$(events "$P")"

# ---------------------------------------------------------------------------
echo
echo "[3] Account checks — appended after the phase commands; a red one says how to sign in"
P="$W/acct"
project "$P" "echo a" "echo b"
run "$P" .relay/run-Ab3 --account "echo signed-in" "never-shown login" --account "echo 'not logged in' >&2; exit 1" "gh auth login"
assert_rc "exits 1" 1
assert_contains "a green account check is listed" "- ok    echo signed-in" "$OUT"
assert_missing "… without a login hint" "never-shown login" "$OUT"
assert_contains "the red one shows its output" "      not logged in" "$OUT"
assert_contains "… and the login command" "      run: ! gh auth login" "$OUT"
assert_contains "4 commands in all" "Commands: 4 run — 3 clean, 1 failed" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[4] Dirty tree — exit 3 whatever the commands did; the paths are listed"
P="$W/dirty"
project "$P" "echo a" "touch made-by-a-command.txt"
printf 'y\n' >> "$P/README.md"
run "$P" .relay/run-Ab3
assert_rc "exits 3" 3
assert_contains "PREFLIGHT_RED" "PREFLIGHT_RED" "$OUT"
assert_contains "lists the owner's change" " M README.md" "$OUT"
assert_contains "… and a file a command created" "made-by-a-command.txt" "$OUT"
assert_contains "the tree event wins" "Pre-flight red: working tree has 2 uncommitted changes." "$(events "$P")"
assert_eq "the run root never counts" "0" "$(printf '%s\n' "$OUT" | grep -c 'run-Ab3/')"
git -C "$P" checkout -q README.md; rm -f "$P/made-by-a-command.txt"
sed -i.bak 's/touch made-by-a-command.txt/echo b/' "$P/.relay/run-Ab3/phases/phase-2.md" && rm -f "$P/.relay/run-Ab3/phases/phase-2.md.bak"
run "$P" .relay/run-Ab3
assert_rc "re-check after cleaning up → green" 0
assert_eq "both outcomes are in the log" "2" "$(events "$P" | grep -c 'Pre-flight')"

# ---------------------------------------------------------------------------
echo
echo "[5] --bypass logs the owner's choice"
P="$W/bypass"
project "$P" "false" "echo b"
run "$P" .relay/run-Ab3 --bypass
assert_rc "exits 0" 0
assert_contains "says it logged" "Pre-flight bypassed by user" "$OUT"
assert_contains "the event" "- 2026-09-23 — Pre-flight bypassed by user." "$(events "$P")"
[ -d "$P/.relay/run-Ab3/logs" ] && no "runs no command" "logs/ exists" || ok "runs no command"

# ---------------------------------------------------------------------------
echo
echo "[6] Edges — no git, no commands, no Notable events section, usage"
P="$W/nogit"; mkdir -p "$P/.relay/run-Ab3/phases"
printf '# State\n\n**Status:** PLANNED\n' > "$P/.relay/run-Ab3/STATE.md"
printf '# Phase 1\n\n## Mandatory commands\n\n- echo hi\n' > "$P/.relay/run-Ab3/phases/phase-1.md"
run "$P" .relay/run-Ab3
assert_rc "no git → green" 0
assert_contains "says relay will not commit" "git: not a repository — relay will not commit" "$OUT"
assert_contains "creates Notable events when it is missing" "## Notable events

- 2026-09-23 — Pre-flight green: 1 command clean." "$(cat "$P/.relay/run-Ab3/STATE.md")"
rm "$P/.relay/run-Ab3/phases/phase-1.md"
run "$P" .relay/run-Ab3
assert_rc "no commands → green" 0
assert_contains "says so" "Commands: none found in the phase specs" "$OUT"
run "$W" "$W/none"
assert_rc "no STATE.md exits 2" 2
run "$P"
assert_rc "no run root exits 2" 2
run "$P" .relay/run-Ab3 --account "gh auth status"
assert_rc "--account needs a login command" 2
run "$P" .relay/run-Ab3 --bypass --account a b
assert_rc "--bypass takes nothing else" 2
run "$P" .relay/run-Ab3 --bogus
assert_rc "unknown option exits 2" 2

# ---------------------------------------------------------------------------
echo
echo "[8] Bullet shapes — backtick-wrapped or with a trailing description run only the command"
P="$W/shapes"
project "$P" "echo a" "echo b"
cat > "$P/.relay/run-Ab3/phases/phase-1.md" <<'EOF'
# Phase 1

## Mandatory commands

- `echo built` — vite build summary line; exit 0
- echo plain — trailing description
- echo dash – en-dash description
- `echo spaced  out`

## Acceptance criteria

- [ ] something
EOF
run "$P" .relay/run-Ab3
assert_rc "exits 0" 0
assert_contains "the backticked command runs bare" "- ok    echo built" "$OUT"
assert_missing "… its description never runs" "summary line" "$OUT"
assert_contains "an em-dash description is dropped" "- ok    echo plain" "$OUT"
assert_contains "… and an en-dash one" "- ok    echo dash" "$OUT"
assert_contains "spacing inside the backticks is kept" "- ok    echo spaced  out" "$OUT"
assert_contains "4 + 1 commands" "Commands: 5 clean" "$OUT"
cat > "$P/.relay/run-Ab3/phases/phase-1.md" <<'EOF'
# Phase 1

## Mandatory commands

- `false` — must fail; exit 0

## Acceptance criteria

- [ ] something
EOF
run "$P" .relay/run-Ab3
assert_rc "the tunez false pass is gone — a failing command stays red" 1
assert_contains "it is reported as itself" "- FAIL  false — exit 1" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[9] Not runnable yet — what the build creates is listed, not run, and stays green"
BIN="$W/bin"; mkdir -p "$BIN"
for t in npm pnpm npx; do printf '#!/bin/sh\necho "%s $*" >> "$PF_STUB_LOG"\nexit 0\n' "$t" > "$BIN/$t"; chmod +x "$BIN/$t"; done
export PF_STUB_LOG="$W/stub.log"
runp() { OUT="$(cd "$1" && PATH="$BIN:$PATH" bash "$PF" "${@:2}" 2>&1)"; RC=$?; }
P="$W/green-field"
project "$P" "npm run build|npm test|bash .relay/run-Ab3/check-design.sh design --verify tokens --theme src/theme.ts|./scripts/gen.sh|python3 tools/check.py|cargo test|make lint|go test ./...|echo real" "npm run build|FOO=1 ./bin/missing --flag|swift build|poetry run pytest|mvn test"
: > "$PF_STUB_LOG"
runp "$P" .relay/run-Ab3
assert_rc "exits 0" 0
assert_eq "PREFLIGHT_GREEN" "PREFLIGHT_GREEN" "$(printf '%s\n' "$OUT" | head -1)"
assert_contains "counts them apart" "Commands: 13 — 1 clean, 12 not runnable yet (what they need comes from the build)" "$OUT"
assert_contains "no package.json" "- later npm run build — no package.json yet; first used by phase 1" "$OUT"
assert_eq "a command in two phases is listed once" "1" "$(printf '%s\n' "$OUT" | grep -c 'later npm run build')"
assert_contains "check-design --verify waits for the build" "- later bash .relay/run-Ab3/check-design.sh design --verify tokens --theme src/theme.ts — checks the built screens, so it runs during the build; first used by phase 1" "$OUT"
assert_contains "a missing script path" "- later ./scripts/gen.sh — ./scripts/gen.sh doesn't exist yet" "$OUT"
assert_contains "an interpreter's missing script" "- later python3 tools/check.py — tools/check.py doesn't exist yet" "$OUT"
assert_contains "cargo with no Cargo.toml" "cargo test — no Cargo.toml yet" "$OUT"
assert_contains "make with no Makefile" "make lint — no Makefile yet" "$OUT"
assert_contains "go with no go.mod" "go test ./... — no go.mod yet" "$OUT"
assert_contains "a VAR=value prefix is skipped" "FOO=1 ./bin/missing --flag — ./bin/missing doesn't exist yet; first used by phase 2" "$OUT"
assert_contains "swift" "swift build — no Package.swift yet" "$OUT"
assert_contains "poetry" "poetry run pytest — no pyproject.toml yet" "$OUT"
assert_contains "mvn" "mvn test — no pom.xml yet" "$OUT"
assert_contains "everything else runs" "- ok    echo real" "$OUT"
assert_eq "nothing waiting was run" "" "$(cat "$PF_STUB_LOG")"
assert_eq "only the run command has a log" "1" "$(ls "$P/.relay/run-Ab3/logs/preflight" | grep -c '\.log$')"
assert_contains "the event counts both" "Pre-flight green: 1 command clean, 12 not runnable yet." "$(events "$P")"

P="$W/brown-field"
project "$P" "npm run build|npm run check:bundle|pnpm lint|pnpm install|npm ci|npx tsc --noEmit|npm test" "cd sub && npm run nothing-here|python3 -c 'import sys; sys.exit(4)'"
printf '{"name":"x","scripts":{"build":"tsc","test":"vitest"}}\n' > "$P/package.json"
git -C "$P" add package.json; git -C "$P" commit -qm pkg; mkdir -p "$P/sub"
: > "$PF_STUB_LOG"
runp "$P" .relay/run-Ab3
assert_rc "a real failure is still red" 1
assert_contains "a script package.json has runs" "- ok    npm run build" "$OUT"
assert_contains "a script a later phase adds waits" "- later npm run check:bundle — package.json has no \"check:bundle\" script yet; first used by phase 1" "$OUT"
assert_contains "… for pnpm's short form too" "- later pnpm lint — package.json has no \"lint\" script yet" "$OUT"
assert_contains "a package-manager built-in runs" "- ok    pnpm install" "$OUT"
assert_contains "npm's own commands run" "- ok    npm ci" "$OUT"
assert_contains "npx never waits" "- ok    npx tsc --noEmit" "$OUT"
assert_contains "npm test with a test script runs" "- ok    npm test" "$OUT"
assert_contains "a command starting with cd runs" "- ok    cd sub && npm run nothing-here" "$OUT"
assert_contains "an interpreter's -c is a command, not a path" "- FAIL  python3 -c 'import sys; sys.exit(4)' — exit 4" "$OUT"
assert_contains "counts all three kinds" "Commands: 9 — 6 clean, 1 failed, 2 not runnable yet" "$OUT"

printf '{ not json\n' > "$P/package.json"; git -C "$P" commit -qam broken
P2="$W/brown-broken"; project "$P2" "npm run build" "echo b"
printf '{ not json\n' > "$P2/package.json"; git -C "$P2" add package.json; git -C "$P2" commit -qm broken
runp "$P2" .relay/run-Ab3
assert_contains "an unreadable package.json is the baseline's problem — the command runs" "- ok    npm run build" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[10] A phase command that is also an account check runs once, as the account check"
P="$W/dup-acct"
project "$P" "echo who|echo a" "echo who"
run "$P" .relay/run-Ab3 --account "echo who" "who login"
assert_rc "exits 0" 0
assert_eq "runs once" "1" "$(printf '%s\n' "$OUT" | grep -c 'ok    echo who')"
assert_contains "2 commands in all" "Commands: 2 clean" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[7] Called from zsh (the Bash tool's shell)"
if command -v zsh >/dev/null 2>&1; then
  P="$W/zsh"
  project "$P" "echo 'a b'  c|echo shared" "echo shared"
  OUT="$(cd "$P" && zsh -c "bash '$PF' .relay/run-Ab3" 2>&1)"; RC=$?
  assert_rc "exits 0 under zsh" 0
  assert_contains "a command with spaces stays one command" "- ok    echo 'a b'  c" "$OUT"
  assert_contains "prints the block" "PREFLIGHT_GREEN" "$OUT"
else
  echo "  (zsh not installed — skipped)"
fi

# ---------------------------------------------------------------------------
echo
echo "----------------------------------------"
printf 'Results: %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  exit 1
fi
echo "All fixture scenarios passed."
exit 0
