#!/usr/bin/env bash
# check-design.test.sh — fixture tests for scripts/check-design.sh
#
# Proves the design-handoff contract Stage 2.7 verifies on the user's return: HANDOFF.md with
# approved screens and one PNG each is required, whatever tool made it; tokens, components and
# copy are recommended (warn, and yield no criterion, when absent); design/ must be committed,
# because repo-state.sh would count an untracked export as a run change. Also the drafted
# fidelity criteria (--criteria): numbering, which criteria appear, and that the screenshot
# criterion passes on a recorded reason so it can never stall a run.
#
# Repo-only (not shipped in the plugin payload). Run from anywhere:
#   bash tests/check-design.test.sh
# Exits 0 if every assertion passes, 1 otherwise.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CD="$REPO_ROOT/skills/goal/scripts/check-design.sh"
VS="$REPO_ROOT/skills/goal/scripts/validate-spec.sh"
FIX="$REPO_ROOT/tests/fixtures/check-design"

for f in "$CD" "$VS" "$FIX/HANDOFF.md"; do
  [ -e "$f" ] || { echo "FATAL: missing $f" >&2; exit 1; }
done

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  \033[31m✗\033[0m %s\n      %s\n' "$1" "$2"; }

assert_rc()       { if [ "$2" = "$RC" ]; then ok "$1"; else no "$1" "expected exit $2 got $RC (out: $OUT)"; fi; }
assert_contains() { case "$3" in *"$2"*) ok "$1";; *) no "$1" "missing substring [$2] in [$3]";; esac; }
assert_missing()  { case "$3" in *"$2"*) no "$1" "unexpectedly contains [$2]";; *) ok "$1";; esac; }
assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "expected [$2] got [$3]"; fi; }

run() { OUT="$("$@" 2>&1)"; RC=$?; }

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

g() { git -C "$R" -c user.email=t@example.com -c user.name=t "$@"; }

# repo <name> — a git repo with the fixture package committed at design/; sets R
repo() {
  R="$W/$1"
  mkdir -p "$R"
  git -C "$R" init -q
  cp -R "$FIX" "$R/design"
  g add design && g commit -qm "design: handoff"
}

# ---------------------------------------------------------------------------
echo
echo "[1] A complete, committed package passes"
repo good
run bash "$CD" "$R/design"
assert_rc "exits 0" 0
assert_contains "inventory line" "design: 3 screens, 4 tokens, 3 components, 5 copy strings @ " "$OUT"
assert_missing "records a sha, not uncommitted" "@ uncommitted" "$OUT"
assert_missing "no errors" "❌" "$OUT"
assert_missing "no warnings" "⚠" "$OUT"
run bash "$CD" "$R/design/"
assert_rc "trailing slash accepted" 0

# ---------------------------------------------------------------------------
echo
echo "[2] Required pieces: HANDOFF.md, approved screens, screen headings, one PNG per screen"
repo nohandoff
rm "$R/design/HANDOFF.md"; g add -A design && g commit -qm x
run bash "$CD" "$R/design"
assert_rc "missing HANDOFF.md exits 1" 1
assert_contains "names HANDOFF.md" "HANDOFF.md" "$OUT"

repo nopng
rm "$R/design/screens/heads-up.png"; g add -A design && g commit -qm x
run bash "$CD" "$R/design"
assert_rc "missing PNG exits 1" 1
assert_contains "names the screen" "screen 'heads-up': no" "$OUT"

repo statepng
rm "$R/design/screens/overlay.png"; g add -A design && g commit -qm x
run bash "$CD" "$R/design"
assert_rc "a state PNG alone (overlay--complete.png) satisfies the screen" 0

repo noheading
perl -0pi -e 's/### settings — Settings window\n//' "$R/design/HANDOFF.md"; g add -A design && g commit -qm x
run bash "$CD" "$R/design"
assert_rc "missing screen heading exits 1" 1
assert_contains "names the heading" "screen 'settings': no '### settings" "$OUT"

# A large ## Screens section with the heading near its top: `grep -q` stops at the match while
# awk is still writing, and under pipefail awk's SIGPIPE used to turn a found heading into
# "missing" (tunez, 2026-10-07). Run it several times — the old failure depended on timing.
repo bigscreens
awk '{ print } /^### overlay/ { for (i = 0; i < 6000; i++) print "Filler line " i " describing the overlay state in long enough prose to fill the pipe." }' \
  "$R/design/HANDOFF.md" > "$R/x" && mv "$R/x" "$R/design/HANDOFF.md"; g add -A design && g commit -qm x
big_fail=0
for i in 1 2 3 4 5; do
  run bash "$CD" "$R/design"
  case "$OUT" in *"no '### "*) big_fail=$((big_fail + 1)) ;; esac
done
assert_eq "large Screens section: no heading falsely reported missing (5 runs)" "0" "$big_fail"
assert_rc "… and the package passes" 0

repo noapproved
perl -0pi -e 's/## Approved screens/## Screens we liked/' "$R/design/HANDOFF.md"; g add -A design && g commit -qm x
run bash "$CD" "$R/design"
assert_rc "missing Approved screens exits 1" 1
assert_contains "names the section" "no ## Approved screens section" "$OUT"

repo emptytable
perl -0pi -e 's/\| `overlay`.*\n//; s/\| `heads-up`.*\n//; s/\| `settings`.*\n//' "$R/design/HANDOFF.md"; g add -A design && g commit -qm x
run bash "$CD" "$R/design"
assert_rc "empty approved table exits 1" 1
assert_contains "says no rows" "has no table rows" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[3] Recommended pieces only warn — any design tool works"
repo minimal
perl -0pi -e 's/## Design tokens.*?(?=## Components)//s; s/## Copy.*//s' "$R/design/HANDOFF.md"; g add -A design && g commit -qm x
run bash "$CD" "$R/design"
assert_rc "no tokens/copy still exits 0" 0
assert_contains "warns on tokens" "no ## Design tokens section" "$OUT"
assert_contains "warns on copy" "no ## Copy section" "$OUT"
assert_contains "components survive" "3 components" "$OUT"
run bash "$CD" "$R/design" --criteria
assert_missing "no token criterion" "tokens live in one theme file" "$OUT"
assert_missing "no copy criterion" "copy matches the design" "$OUT"
assert_contains "component criterion stays" "named components exist" "$OUT"

# The deviations list is recommended (fix 25): without it, reconciliation asks about every
# difference one by one, so it warns — never blocks.
repo nodeviations
perl -0pi -e 's/## Deviations from the brief\n.*?(?=## Copy)//s' "$R/design/HANDOFF.md"; g add -A design && g commit -qm x
run bash "$CD" "$R/design"
assert_rc "no deviations list still exits 0" 0
assert_contains "warns on a missing deviations list" "no ## Deviations from the brief section" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[4] design/ must be committed"
repo untracked
echo "console.log('x')" > "$R/design/source.js"
run bash "$CD" "$R/design"
assert_rc "untracked file exits 1" 1
assert_contains "names the script that commits it" "commit it: prepare-design.sh design (Stage 2.7d)" "$OUT"
assert_contains "and the plain git command" "git add design && git commit" "$OUT"
assert_missing "no longer says relay never commits" "never commits" "$OUT"
assert_contains "sha reads uncommitted" "@ uncommitted" "$OUT"

repo modified
echo "extra" >> "$R/design/HANDOFF.md"
run bash "$CD" "$R/design"
assert_rc "modified file exits 1" 1
assert_contains "names the file" "design/HANDOFF.md" "$OUT"

R="$W/fresh"; mkdir -p "$R"; git -C "$R" init -q; cp -R "$FIX" "$R/design"
run bash "$CD" "$R/design"
assert_rc "never-committed package exits 1" 1

R="$W/nogit"; mkdir -p "$R"; cp -R "$FIX" "$R/design"
run env GIT_CEILING_DIRECTORIES="$W" bash "$CD" "$R/design"
assert_rc "no git: exits 0" 0
assert_contains "no git: warns" "not a git repository" "$OUT"
assert_contains "no git: sha" "@ no-git" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[5] --criteria drafts the fidelity criteria"
repo crit
run bash "$CD" "$R/design" --criteria --start 7 --run-root .relay/demo-Ab3Kx9
assert_rc "exits 0" 0
assert_contains "screens first, numbered from --start" "**S7 — Design: every approved screen is built**" "$OUT"
assert_contains "lists the ids" '(`overlay`, `heads-up`, `settings`)' "$OUT"
assert_contains "screens criterion names the verify command" "bash .relay/demo-Ab3Kx9/check-design.sh design --verify screens --except .relay/demo-Ab3Kx9/SPEC.md" "$OUT"
assert_contains "exemption note" "resolved \"spec wins\" in \`## Design reconciliation\` are exempt" "$OUT"
assert_contains "no --theme: placeholder" "--theme <theme file>" "$OUT"
assert_contains "capture dir comes from the env var" "RELAY_DESIGN_CHECK_DIR" "$OUT"
assert_contains "no run path in the product" "git grep --untracked -lF '.relay/'" "$OUT"
assert_contains "components inline" "(TimerDisc, PrimaryButton, SequenceStrip)" "$OUT"
assert_contains "S8 components" "**S8 — Design: named components exist**" "$OUT"
assert_contains "S9 tokens" "**S9 — Design: tokens live in one theme file**" "$OUT"
assert_contains "hex values listed, rgba not" "(#08161f, #7fc8b7)" "$OUT"
assert_contains "S10 copy" "**S10 — Design: copy matches the design**: all 5 strings" "$OUT"
assert_contains "S11 capture" "**S11 — Design: screens captured for review**" "$OUT"
assert_contains "run root substituted" ".relay/demo-Ab3Kx9/design-check/<id>.png" "$OUT"
assert_contains "reason passes the capture" "capture unavailable: <id>" "$OUT"
assert_contains "the evidence records the capture command for the audit" "\`Capture command: <command>\`, which the audit re-runs" "$OUT"
assert_contains "comparison is never a gate" "never a gate" "$OUT"
n="$(printf '%s\n' "$OUT" | grep -c '^  - Acceptance:')"
if [ "$n" = 5 ]; then ok "every criterion has an Acceptance line"; else no "every criterion has an Acceptance line" "got $n"; fi

run bash "$CD" "$R/design" --criteria
assert_contains "default numbering starts at S1" "**S1 — Design: every approved screen is built**" "$OUT"
assert_contains "default run-root placeholder" "<run-root>/design-check/<id>.png" "$OUT"

repo critfail
rm "$R/design/screens/settings.png"; g add -A design && g commit -qm x
run bash "$CD" "$R/design" --criteria
assert_rc "no criteria on a failing package" 1
assert_missing "nothing drafted" "**S1" "$OUT"

# The drafted criteria plus the drafted edge rows must pass validate-spec.sh outright — the edge
# probe raises ~30 edges on them, and the rows are what keep the planner from hand-writing each.
repo spec
bash "$CD" "$R/design" --criteria > "$W/crit.md" 2>/dev/null
rows="$(grep -c '^| S' "$W/crit.md")"
if [ "$rows" -gt 0 ]; then ok "edge rows drafted ($rows)"; else no "edge rows drafted" "none in $(cat "$W/crit.md")"; fi
assert_missing "no drafted row is left unresolved" "| unresolved |" "$(cat "$W/crit.md")"
assert_contains "rows come under a header" "Edge coverage rows (append to ## Edge coverage):" "$(cat "$W/crit.md")"
assert_contains "screens boundary is resolved by the exact count" "| S1 | boundary — at the limit and one past it | resolved |" "$(cat "$W/crit.md")"
assert_contains "copy encoding explains escapes" "stored as escapes" "$(cat "$W/crit.md")"
{
  printf '# Spec: demo\n\n## Goal\n\nBuild it.\n\n## In scope\n\n- the screens\n\n'
  printf '## Out of scope\n\n- sync\n\n## Constraints\n\n- macOS 14\n\n## Success criteria\n\n'
  sed -n '/^- \*\*S/,/^$/p' "$W/crit.md" | sed '/^$/d'
  printf '\n## Edge coverage\n\n| Criterion | Edge | Status | Reason / where covered |\n|---|---|---|---|\n'
  grep '^| S' "$W/crit.md"
  printf '\n## Ambiguity report\n\nfine\n'
} > "$W/SPEC.md"
run bash "$VS" "$W/SPEC.md"
assert_rc "criteria + rows pass validate-spec.sh" 0
assert_contains "validate-spec counts them" "5 success criteria, 0 unresolved edge(s)" "$OUT"

# Without python3 the rows cannot be drafted; the criteria still are, with a pointer to validate-spec.
NOPY="$W/bin-nopy"; mkdir -p "$NOPY"
for tool in bash git awk sed grep mktemp cat rm head tr dirname sort wc; do
  p="$(command -v "$tool" 2>/dev/null)" && ln -sf "$p" "$NOPY/$tool"
done
run env PATH="$NOPY" bash "$CD" "$R/design" --criteria
assert_rc "no python3: exits 0" 0
assert_contains "no python3: criteria still drafted" "**S1 — Design: every approved screen is built**" "$OUT"
assert_contains "no python3: says rows were skipped" "edge rows not drafted" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[5b] --criteria fills the theme file and the generated-file allowances"
repo crittheme
run bash "$CD" "$R/design" --criteria --theme src/theme/tokens.ts --allow index.html --allow 'public/*.json' --run-root .relay/r
assert_rc "exits 0" 0
assert_contains "theme named in the statement" "are defined in \`src/theme/tokens.ts\`" "$OUT"
assert_contains "allowances named" "files generated from it (index.html, public/*.json)" "$OUT"
assert_contains "verify command carries theme + allows" "--verify tokens --theme src/theme/tokens.ts --allow 'index.html' --allow 'public/*.json' --except .relay/r/SPEC.md" "$OUT"
assert_missing "no placeholder left" "<theme file>" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[5c] --verify holds built code to the package"
# built <name> — a repo with the fixture package committed and a small source tree that
# satisfies every aspect; sets R
built() {
  repo "$1"
  mkdir -p "$R/src/theme" "$R/.relay/run1"
  cat > "$R/src/theme/tokens.ts" <<'TS'
export const tokens = { ink: '#08161f', accent: '#7fc8b7', panelBorder: 'rgba(127,200,183,.28)', radius_panel: 20 };
TS
  cat > "$R/src/Overlay.tsx" <<'TS'
// design: overlay
export function TimerDisc() { return null }
export function PrimaryButton() { return null }
export function SequenceStrip() { return null }
const a = 'Snooze 5 min'; const b = `Four movements done. Next break at ${t}.`; const c = 'Back to work';
TS
  printf '// design: heads-up\nconst s = "Hip reset in a minute";\n' > "$R/src/HeadsUp.tsx"
  printf '// design: settings\nconst l = "Launch at login";\n' > "$R/src/Settings.tsx"
  printf '<meta name="theme-color" content="#08161f">\n' > "$R/index.html"
  printf 'design: overlay\n' > "$R/.relay/run1/notes.md"
  g add -A src index.html && g commit -qm build
}
V="--theme src/theme/tokens.ts --allow index.html"

built vall
run bash "$CD" "$R/design" --verify all $V
assert_rc "a faithful build passes --verify all" 0
assert_contains "summary line" "verify all: " "$OUT"
assert_contains "nothing failed" ", 0 failed" "$OUT"
assert_missing "no errors" "❌" "$OUT"

built vuntracked
printf '// design: overlay\n' > "$R/src/Dup.tsx"
run bash "$CD" "$R/design" --verify screens
assert_rc "an untracked duplicate marker counts (exit 1)" 1
assert_contains "names both files" "'overlay' — marked in 2 files" "$OUT"

built vnomarker
perl -pi -e 's#// design: settings##' "$R/src/Settings.tsx"
run bash "$CD" "$R/design" --verify screens
assert_rc "missing marker exits 1" 1
assert_contains "names the screen" "'settings' — no file carries 'design: settings'" "$OUT"
assert_missing ".relay/ is never source" "'overlay' — marked in 2" "$OUT"

built vcomp
perl -pi -e 's/SequenceStrip/Sequence/' "$R/src/Overlay.tsx"
run bash "$CD" "$R/design" --verify components
assert_rc "missing component exits 1" 1
assert_contains "names it" "'SequenceStrip' — not found in source" "$OUT"

built vhex
printf '.btn { color: #7FC8B7; }\n' > "$R/src/button.css"
run bash "$CD" "$R/design" --verify tokens $V
assert_rc "hard-coded hex exits 1 (case-insensitive)" 1
assert_contains "names the file" "'accent' value #7fc8b7 hard-coded in src/button.css" "$OUT"
assert_missing "index.html is allowed" "index.html" "$OUT"
run bash "$CD" "$R/design" --verify tokens $V --allow 'src/*.css'
assert_rc "an --allow glob clears it" 0

built vtokname
perl -pi -e 's/radius_panel/radiusPanl/' "$R/src/theme/tokens.ts"
run bash "$CD" "$R/design" --verify tokens $V
assert_rc "token missing from the theme exits 1" 1
assert_contains "names the token" "'radius-panel' — not defined in src/theme/tokens.ts" "$OUT"
run bash "$CD" "$R/design" --verify tokens
assert_rc "no --theme exits 1" 1
assert_contains "says why" "no --theme <file> given" "$OUT"

built vcopy
perl -pi -e "s/Back to work/Back to the grind/" "$R/src/Overlay.tsx"
run bash "$CD" "$R/design" --verify copy
assert_rc "changed copy exits 1" 1
assert_contains "names the fragment" '"Back to work" — not found verbatim' "$OUT"
assert_missing "placeholder split: the templated string passes" "Four movements" "$OUT"

# The spec can override the design; those items are exempt.
cat > "$W/SPEC-except.md" <<'MD'
# Spec
## Design reconciliation

| # | Area | Spec said | Design shows | Resolution |
|---|---|---|---|---|
| 1 | `copy: Back to work` | "Done" | "Back to work" | spec wins — button reads "Done" |
| 2 | `screen: settings` | no settings screen | settings | spec wins |
| 3 | `component: TimerDisc` | x | y | design wins |

Reconciled: 3 conflicts
MD
run bash "$CD" "$R/design" --verify copy --except "$W/SPEC-except.md"
assert_rc "spec-wins copy is exempt" 0
built vexcept
perl -pi -e 's#// design: settings##' "$R/src/Settings.tsx"
perl -pi -e 's/TimerDisc/Timer/' "$R/src/Overlay.tsx"
run bash "$CD" "$R/design" --verify all $V --except "$W/SPEC-except.md"
assert_rc "design-wins rows are not exempt" 1
assert_missing "spec-wins screen exempt" "'settings'" "$OUT"
assert_contains "design-wins component still checked" "'TimerDisc' — not found" "$OUT"
run bash "$CD" "$R/design" --verify copy --except "$W/nope.md"
assert_rc "missing --except file exits 2" 2

# A fragment contained in a longer fragment is still found (grep -o reports non-overlapping matches).
built vnested
printf '\n### settings\n- `Back`\n' >> "$R/design/HANDOFF.md"; g add -A design && g commit -qm x
run bash "$CD" "$R/design" --verify copy
assert_rc "nested fragment found" 0

# No git: the same check over the filesystem, skipping .git/, node_modules/, design/, .relay/.
built vnogit
rm -rf "$R/.git"; mkdir -p "$R/node_modules/x"; printf 'design: overlay\n' > "$R/node_modules/x/i.js"
run env GIT_CEILING_DIRECTORIES="$W" bash "$CD" "$R/design" --verify all $V
assert_rc "no git: passes" 0
assert_missing "node_modules is not source" "marked in 2" "$OUT"

built vbroken
rm "$R/design/screens/settings.png"; g add -A design && g commit -qm x
run bash "$CD" "$R/design" --verify all $V
assert_rc "a broken package cannot be verified against" 1
assert_contains "says so" "the design package itself is broken" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[5d] A section holding several tables (fix 20)"
# Real packages split tokens into Colour / Type / Space tables, each with its own header row.
repo multitable
perl -0pi -e 's/(\| `settings` \| Settings window \| `settings.png` \|\n)/$1\n### Secondary\n\n| id | name | files |\n|---|---|---|\n| `about` | About | `about.png` |\n/' "$R/design/HANDOFF.md"
perl -0pi -e 's/(\| `radius-panel` \| `20px` \| panels \|\n)/$1\n### Themed colour\n\n| name | value | usage |\n|---|---|---|\n| `paper` | light `#F4EFE4` · dark `#16140F` | app background |\n/' "$R/design/HANDOFF.md"
perl -0pi -e 's/\n## Deviations from the brief\n/\n### about — About\n\nOne panel.\n\n## Deviations from the brief\n/' "$R/design/HANDOFF.md"
cp "$R/design/screens/settings.png" "$R/design/screens/about.png"
g add -A design && g commit -qm x
run bash "$CD" "$R/design"
assert_rc "exits 0" 0
assert_contains "later tables' rows counted, headers not" "design: 4 screens, 5 tokens, 3 components" "$OUT"
assert_missing "a later header is not a screen" "screen 'id'" "$OUT"
run bash "$CD" "$R/design" --criteria
assert_contains "the second screens table reaches the criterion" '`settings`, `about`)' "$OUT"
assert_missing "a later header is not a token" "value |" "$OUT"
# A reconciliation section with two tables: the second header is not read as a row either.
cat > "$W/SPEC-two.md" <<'MD'
## Design reconciliation

| # | Area | Spec said | Design shows | Resolution |
|---|---|---|---|---|
| 1 | `screen: about` | none | about | spec wins |

| # | Area | Spec said | Design shows | Resolution |
|---|---|---|---|---|
| 2 | `screen: settings` | none | settings | spec wins |
MD
printf '// design: overlay\n// design: heads-up\n' > "$R/src.tsx"; g add -A && g commit -qm x
run bash "$CD" "$R/design" --verify screens --except "$W/SPEC-two.md"
assert_rc "rows from both reconciliation tables are exempt" 0

# ---------------------------------------------------------------------------
echo
echo "[5e] Every hex in a token value cell is checked (fix 21)"
# themed <name> — built, plus a light/dark token, a short-hex token and a second token sharing it
themed() {
  built "$1"
  perl -0pi -e 's/(\| `radius-panel` \| `20px` \| panels \|\n)/$1| `paper` | light `#F4EFE4` · dark `#16140F` | app background |\n| `glow` | `#FFF` | highlights |\n| `snow` | `#fff` | card fill |\n/' "$R/design/HANDOFF.md"
  printf 'export const more = { paper: "#F4EFE4 #16140F", glow: "#FFF", snow: "#fff" };\n' >> "$R/src/theme/tokens.ts"
  g add -A && g commit -qm x
}
themed vthemed
run bash "$CD" "$R/design" --verify tokens $V
assert_rc "a faithful themed build passes" 0
printf '.a { background: #F4EFE4; }\n' > "$R/src/light.css"
printf '.b { color: #16140f }\n' > "$R/src/dark.css"
run bash "$CD" "$R/design" --verify tokens $V
assert_rc "light and dark leaks exit 1" 1
assert_contains "light value caught" "'paper' value #F4EFE4 hard-coded in src/light.css" "$OUT"
assert_contains "dark value caught, case-insensitively" "'paper' value #16140F hard-coded in src/dark.css" "$OUT"

themed vshorthex
printf '.c { background: #FFFDF8; border-color: #ffff00; }\n' > "$R/src/near.css"
run bash "$CD" "$R/design" --verify tokens $V
assert_rc "#FFF is not found inside #FFFDF8 or #ffff00" 0
printf '.d { color: #fff; }\n' > "$R/src/short.css"
run bash "$CD" "$R/design" --verify tokens $V
assert_rc "a real #fff leak exits 1" 1
assert_contains "one line names every token sharing the value" "'glow', 'snow' value #FFF hard-coded in src/short.css" "$OUT"
n="$(printf '%s\n' "$OUT" | grep -c 'src/short.css')"
if [ "$n" = 1 ]; then ok "a shared value is reported once"; else no "a shared value is reported once" "got $n lines"; fi

run bash "$CD" "$R/design" --criteria
assert_contains "criterion lists every distinct hex, light and dark" "(#08161f, #7fc8b7, #F4EFE4, #16140F, #FFF)" "$OUT"
assert_contains "criterion says light and dark are checked" "light and dark alike" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[5f] One-word copy must match as a whole word (fix 22)"
built vword
printf '\n### settings\n- `Close`\n- `{count} songs`\n' >> "$R/design/HANDOFF.md"; g add -A design && g commit -qm x
printf 'export const Settings = () => <button onClick={onClose}>{n}</button>; const songsList = [];\n' > "$R/src/Words.tsx"
run bash "$CD" "$R/design" --verify copy
assert_rc "a word present only inside identifiers exits 1" 1
assert_contains "Close inside onClose does not count" '"Close" — not found as a whole word' "$OUT"
assert_contains "a one-word placeholder fragment is a word too" '"songs" — not found as a whole word' "$OUT"
printf 'export const Settings = () => <button aria-label="x" onClick={onClose}>Close</button>;\nconst s = `${count} songs`;\n' > "$R/src/Words.tsx"
run bash "$CD" "$R/design" --verify copy
assert_rc "rendered words pass" 0
run bash "$CD" "$R/design" --criteria
assert_contains "criterion says one-word strings are only presence-checked" "one-word strings are only presence-checked" "$OUT"
assert_contains "edge reason explains whole-word matching" "\`Close\` inside \`onClose\` does not count" "$OUT"
assert_missing "criteria still leave no edge unresolved" "| unresolved |" "$OUT"

# ---------------------------------------------------------------------------
echo
echo "[6] Usage errors"
run bash "$CD"
assert_rc "no args exits 2" 2
run bash "$CD" "$W/does-not-exist"
assert_rc "missing dir exits 2" 2
run bash "$CD" "$W/good/design" --start x
assert_rc "non-numeric --start exits 2" 2
run bash "$CD" "$W/good/design" --bogus
assert_rc "unknown flag exits 2" 2
run bash "$CD" "$W/good/design" --verify everything
assert_rc "unknown --verify aspect exits 2" 2
run bash "$CD" "$W/good/design" --verify all --criteria
assert_rc "--verify with --criteria exits 2" 2

# ---------------------------------------------------------------------------
echo
echo "----------------------------------------"
printf 'Results: %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  exit 1
fi
echo "All fixture scenarios passed."
exit 0
