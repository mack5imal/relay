#!/usr/bin/env bash
# check-design.sh — verify a design handoff package and draft its fidelity criteria
#
# Usage: check-design.sh <design-dir> [--criteria] [--start <k>] [--run-root <path>]
#                          [--theme <path>] [--allow <glob>]... [--except <SPEC.md>]
#        check-design.sh <design-dir> --verify <screens|components|tokens|copy|all>
#                          [--theme <path>] [--allow <glob>]... [--except <SPEC.md>]
#
# Why this exists: Stage 2.7 hands the user a design brief and stops. They come back with a
# package from Claude Design (recommended) or any other tool or designer, committed at design/.
# The run builds against that package, so before it shapes a single phase the planner needs to
# know the package is usable and the build can be held to it. Two things are required, whatever
# made the design:
#
#   design/HANDOFF.md     `## Approved screens` (table: id | name | files) and `## Screens`
#                         (one `### <id> — <name>` per approved id)
#   design/screens/       at least one `<id>.png` or `<id>--<state>.png` per approved id
#
# `## Design tokens` (table: name | value | usage), `## Components` (one bullet per name) and
# `## Copy` (exact strings in backticks) are recommended: each one present yields a fidelity
# criterion, each one missing is a warning. `## Deviations from the brief` is recommended too
# (fix 25): the departures the owner approved in the design session, which Stage 2.7e confirms in
# one question instead of one each; missing, it warns. design/source/ is optional, never read here.
#
# design/ must also be committed: repo-state.sh counts every untracked file as a change the run
# made and greps it for debug output, so an uncommitted export would fail cleanliness checks.
# The planner commits it with prepare-design.sh (Stage 2.7d, fix 30) — the one thing relay
# commits during planning; this only checks.
#
# --criteria  after a clean check, print SPEC.md success criteria for the package (S<k>
#             numbered from --start, default 1). Structural only: screens marked, components
#             present, tokens centralized, copy verbatim, plus a screenshot-or-reason capture
#             that cannot fail a phase on an environment without screenshots. Then the
#             `## Edge coverage` rows for every edge edge-probe.py raises on them, each with a
#             disposition and a reason specific to the criterion (any pair it has no reason for
#             stays `unresolved`, so the probe remains the floor). Needs python3 for the rows.
#
# --verify   check the BUILT code against the package (fix 19) — the command the fidelity
#            criteria's Acceptance lines name, so phases and the audit run one deterministic check
#            instead of hundreds of agent greps. Source = every tracked and untracked file outside
#            design/ and .relay/ (git), or outside design/, .relay/, .git/, node_modules/ (no git).
#              screens     each approved id is marked `design: <id>` in exactly one file
#              components  each §Components name appears as a whole word
#              tokens      each token name (lowercased, - and _ removed) appears in --theme, and no
#                          hex value in a token's value cell (every one: `light #… · dark #…`)
#                          appears outside --theme and the --allow globs (files generated from
#                          the theme, e.g. index.html's theme-color)
#              copy        each §Copy string, split on {name} placeholders, has every fragment of
#                          3+ characters present verbatim, a one-word fragment as a whole word
#            --except reads SPEC.md's `## Design reconciliation` rows resolved "spec wins" and
#            exempts the `screen:` / `component:` / `token:` / `copy:` item each names.
#
# Deterministic. Planner (verification, --criteria) and run (--verify; copied into the run root
# at Stage 7).
# Prints `design: <S> screens, <T> tokens, <C> components, <P> copy strings @ <sha>` plus one line
# per problem. Exits 0 when usable (warnings allowed), 1 on a contract violation, 2 on a usage error.

set -uo pipefail

usage() {
  echo "usage: check-design.sh <design-dir> [--criteria] [--start <k>] [--run-root <path>] [--theme <path>] [--allow <glob>]... [--except <SPEC.md>]" >&2
  echo "       check-design.sh <design-dir> --verify <screens|components|tokens|copy|all> [--theme <path>] [--allow <glob>]... [--except <SPEC.md>]" >&2
  exit 2
}

[[ $# -ge 1 && -n "$1" ]] || usage
dir="${1%/}"; shift
criteria=0; start=1; runroot="<run-root>"; verify=""; theme=""; allows=(); except_spec=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --criteria) criteria=1; shift ;;
    --verify) [[ $# -ge 2 && "$2" =~ ^(screens|components|tokens|copy|all)$ ]] || usage; verify="$2"; shift 2 ;;
    --theme) [[ $# -ge 2 && -n "$2" ]] || usage; theme="$2"; shift 2 ;;
    --allow) [[ $# -ge 2 && -n "$2" ]] || usage; allows+=("$2"); shift 2 ;;
    --except) [[ $# -ge 2 && -n "$2" ]] || usage; except_spec="$2"; shift 2 ;;
    --start) [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || usage; start="$2"; shift 2 ;;
    --run-root) [[ $# -ge 2 && -n "$2" ]] || usage; runroot="${2%/}"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -d "$dir" ]] || { echo "check-design.sh: no design directory at $dir" >&2; exit 2; }
[[ -z "$verify" || $criteria -eq 0 ]] || usage

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
handoff="$dir/HANDOFF.md"
errors=0; warnings=0
err()  { echo "❌ $*"; errors=$((errors + 1)); }
warn() { echo "⚠  $*"; warnings=$((warnings + 1)); }

# section <name> — the body of `## <name>` (case-insensitive), up to the next `## ` heading
section() {
  awk -v want="$1" '
    /^##[[:space:]]/ && !/^###/ {
      h = $0; sub(/^##[[:space:]]+/, "", h); sub(/[[:space:]]+$/, "", h)
      on = (tolower(h) == tolower(want)); next
    }
    on { print }
  ' "$handoff"
}
has_section() { grep -qiE "^##[[:space:]]+$1[[:space:]]*$" "$handoff"; }

# table_rows — the body rows of every markdown table on stdin. Each table's first row (its
# header) and every separator row are skipped, and the count restarts at any non-table line, so
# a section holding several tables (Colour, Type, Space…) never reads a later header as a row
# (fix 20: the tunez package's second and third `| name | value | usage |` became tokens).
table_rows() {
  awk '
    /^[[:space:]]*\|/ {
      if (intable++ == 0 || $0 ~ /^[[:space:]]*\|[[:space:]:|-]+\|?[[:space:]]*$/) next
      print; next
    }
    { intable = 0 }'
}

# table_col <n> — column n of the body rows of every markdown table on stdin
table_col() {
  table_rows | awk -F'|' -v n="$1" '
    { c = $(n + 1); gsub(/`/, "", c); gsub(/^[[:space:]]+|[[:space:]]+$/, "", c); if (c != "") print c }'
}

# hexes <text> — every hex colour literal in <text> (#rgb, #rgba, #rrggbb, #rrggbbaa), one per
# line. A themed cell (`light #F4EFE4 · dark #16140F`) yields both (fix 21).
hexes() {
  printf '%s\n' "$1" | grep -oE '#[0-9A-Fa-f]+' | grep -xE '#([0-9A-Fa-f]{3,4}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})'
}

ids=(); tokens=(); values=(); components=(); copies=(); copy_count=0

if [[ ! -f "$handoff" ]]; then
  err "no $handoff — the package needs HANDOFF.md with ## Approved screens and ## Screens"
else
  if has_section "Approved screens"; then
    while IFS= read -r id; do ids+=("$id"); done < <(section "Approved screens" | table_col 1)
    [[ ${#ids[@]} -gt 0 ]] || err "HANDOFF.md ## Approved screens has no table rows (| id | name | files |)"
  else
    err "HANDOFF.md has no ## Approved screens section (table: | id | name | files |)"
  fi
  if ! has_section "Screens"; then
    err "HANDOFF.md has no ## Screens section (one ### <id> — <name> per approved screen)"
  fi

  for id in ${ids[@]+"${ids[@]}"}; do
    # grep -E >/dev/null, not grep -q: -q exits at the first match while awk is still writing a
    # large section, and under pipefail awk's SIGPIPE made a found heading read as missing.
    if has_section "Screens" && ! section "Screens" | grep -E "^###[[:space:]]+\`?$(printf '%s' "$id" | sed 's/[][\.*^$/]/\\&/g')\`?([[:space:]]|$)" >/dev/null; then
      err "screen '$id': no '### $id — <name>' heading under ## Screens"
    fi
    shopt -s nullglob
    pngs=("$dir/screens/$id.png" "$dir/screens/$id--"*.png)
    shopt -u nullglob
    found=0
    for p in ${pngs[@]+"${pngs[@]}"}; do [[ -f "$p" ]] && found=1; done
    [[ $found -eq 1 ]] || err "screen '$id': no $dir/screens/$id.png (or $id--<state>.png)"
  done

  if has_section "Design tokens"; then
    # name and value from the same row, so the two arrays stay aligned even with an empty cell
    while IFS=$'\t' read -r t v; do tokens+=("$t"); values+=("$v"); done < <(
      section "Design tokens" | table_rows | awk -F'|' '
        {
          n = $2; v = $3; gsub(/`/, "", n); gsub(/`/, "", v)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", n); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
          if (n != "") print n "\t" v
        }'
    )
    [[ ${#tokens[@]} -gt 0 ]] || warn "## Design tokens has no table rows — no token criterion"
  else
    warn "no ## Design tokens section — no token criterion (recommended: | name | value | usage |)"
  fi
  if has_section "Components"; then
    while IFS= read -r c; do components+=("$c"); done < <(
      # The name is the leading `backticked` span, else the first word (up to space, colon, comma).
      section "Components" | awk '
        /^[[:space:]]*[-*][[:space:]]+/ {
          s = $0; sub(/^[[:space:]]*[-*][[:space:]]+/, "", s)
          if (substr(s, 1, 1) == "`") { s = substr(s, 2); sub(/`.*/, "", s) }
          else { sub(/[[:space:]:,(].*/, "", s) }
          if (s != "") print s
        }'
    )
    [[ ${#components[@]} -gt 0 ]] || warn "## Components has no bullets — no component criterion"
  else
    warn "no ## Components section — no component criterion (recommended: one bullet per name)"
  fi
  if has_section "Copy"; then
    while IFS= read -r c; do copies+=("$c"); done < <(
      section "Copy" | grep -E '^[[:space:]]*[-*]' | grep -oE '`[^`]+`' | sed 's/^`//; s/`$//'
    )
    copy_count=${#copies[@]}
    [[ $copy_count -gt 0 ]] || warn "## Copy has no backticked strings — no copy criterion"
  else
    warn "no ## Copy section — no copy criterion (recommended: exact strings in backticks, variables as {name})"
  fi
  has_section "Deviations from the brief" \
    || warn "no ## Deviations from the brief section — reconciliation will ask about every difference from the spec one by one"
fi

# ---------------------------------------------------------------------------------------------
# --verify: hold the built code to the package. Runs inside the build, so design/ being
# committed is not re-checked here; a broken package still fails (nothing to verify against).
if [[ -n "$verify" ]]; then
  [[ $errors -eq 0 ]] || { echo "verify: the design package itself is broken — fix it first"; exit 1; }
  if git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    top="$(git -C "$dir" rev-parse --show-toplevel)"; vgit=1
  else
    top="$(cd "$dir/.." && pwd)"; vgit=0
  fi
  drel="$(cd "$dir" && pwd -P)"; drel="${drel#"$(cd "$top" && pwd -P)"/}"

  # Exemptions: `## Design reconciliation` rows whose Resolution starts "spec wins".
  ex_screen=""; ex_comp=""; ex_token=""; exfile="$(mktemp)"
  if [[ -n "$except_spec" ]]; then
    [[ -f "$except_spec" ]] || { echo "check-design.sh: --except file not found: $except_spec" >&2; rm -f "$exfile"; exit 2; }
    awk '
      /^##[[:space:]]/ && !/^###/ { on = (tolower($0) ~ /^##[[:space:]]+design reconciliation[[:space:]]*$/); next }
      on { print }' "$except_spec" | table_rows | awk -F'|' '
      {
        area = $3; res = $(NF - 1)
        gsub(/`/, "", area); gsub(/^[[:space:]]+|[[:space:]]+$/, "", area)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", res)
        if (tolower(res) ~ /^spec wins/) print area
      }' > "$exfile.rows"
    while IFS= read -r a; do
      kind="${a%%:*}"; item="${a#*:}"; item="${item#"${item%%[![:space:]]*}"}"
      case "$kind" in
        screen) ex_screen="$ex_screen|$item|" ;;
        component) ex_comp="$ex_comp|$item|" ;;
        token) ex_token="$ex_token|$item|" ;;
        copy) printf '%s\n' "$item" >> "$exfile" ;;
      esac
    done < "$exfile.rows"
    rm -f "$exfile.rows"
  fi

  # Source files, NUL-separated, relative to $top.
  srclist="$(mktemp)"
  if [[ $vgit -eq 1 ]]; then
    git -C "$top" ls-files -z --cached --others --exclude-standard -- . ":!$drel" ':!.relay' > "$srclist.all"
    : > "$srclist"
    while IFS= read -r -d '' f; do [[ -f "$top/$f" ]] && printf '%s\0' "$f" >> "$srclist"; done < "$srclist.all"
    rm -f "$srclist.all"
  else
    (cd "$top" && find . -type f -not -path './.git/*' -not -path './node_modules/*' \
      -not -path "./$drel/*" -not -path './.relay/*' | sed 's#^\./##' | tr '\n' '\0') > "$srclist"
  fi
  # files_with <grep-args...> — the source files matching, one per line (pass patterns with -e)
  files_with() { (cd "$top" && xargs -0 grep -lI "$@" < "$srclist" 2>/dev/null) | sort -u; }

  vfail=0; vchecked=0
  vbad() { echo "❌ $*"; vfail=$((vfail + 1)); }

  if [[ "$verify" == screens || "$verify" == all ]]; then
    for id in "${ids[@]}"; do
      [[ "$ex_screen" == *"|$id|"* ]] && continue
      vchecked=$((vchecked + 1))
      hits="$(files_with -wF -e "design: $id")"
      n="$(printf '%s' "$hits" | grep -c .)"
      if [[ $n -eq 0 ]]; then vbad "screens: '$id' — no file carries 'design: $id'"
      elif [[ $n -gt 1 ]]; then vbad "screens: '$id' — marked in $n files ($(printf '%s' "$hits" | tr '\n' ' ' | sed 's/ $//'))"; fi
    done
  fi

  if [[ "$verify" == components || "$verify" == all ]]; then
    for c in ${components[@]+"${components[@]}"}; do
      [[ "$ex_comp" == *"|$c|"* ]] && continue
      vchecked=$((vchecked + 1))
      [[ -n "$(files_with -wF -e "$c")" ]] || vbad "components: '$c' — not found in source"
    done
  fi

  if [[ ( "$verify" == tokens || "$verify" == all ) && ${#tokens[@]} -gt 0 ]]; then
    if [[ -z "$theme" ]]; then
      vbad "tokens: no --theme <file> given — the token check needs the theme file"
    elif [[ ! -f "$top/$theme" ]]; then
      vbad "tokens: theme file $theme does not exist"
    else
      norm_theme="$(tr '[:upper:]' '[:lower:]' < "$top/$theme" | tr -d '_-')"
      hexmap="$(mktemp)"; : > "$hexmap"   # "<hex>\t<token>" for every hex in every value cell
      for i in "${!tokens[@]}"; do
        t="${tokens[$i]}"
        [[ "$ex_token" == *"|$t|"* ]] && continue
        vchecked=$((vchecked + 1))
        nt="$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]' | tr -d '_-')"
        [[ "$norm_theme" == *"$nt"* ]] || vbad "tokens: '$t' — not defined in $theme"
        while IFS= read -r h; do [[ -n "$h" ]] && printf '%s\t%s\n' "$h" "$t" >> "$hexmap"; done < <(hexes "${values[$i]:-}")
      done
      # One leak check per distinct value (case-insensitive), naming every token that carries it.
      # A value only matches when no hex digit follows, so `#FFF` is not found inside `#FFFDF8`.
      while IFS=$'\t' read -r h names; do
        while IFS= read -r f; do
          [[ -z "$f" || "$f" == "$theme" ]] && continue
          ok=0
          for g in ${allows[@]+"${allows[@]}"}; do [[ "$f" == $g ]] && ok=1; done
          [[ $ok -eq 1 ]] || vbad "tokens: $names value $h hard-coded in $f (outside $theme)"
        done < <(files_with -iE -e "$h([^0-9A-Fa-f]|\$)")
      done < <(awk -F'\t' '
        { k = tolower($1); if (!(k in shown)) { shown[k] = $1; order[++n] = k }
          if (index(names[k] ",", "'\''" $2 "'\''" ",") == 0) names[k] = (names[k] == "" ? "" : names[k] ", ") "'\''" $2 "'\''" }
        END { for (i = 1; i <= n; i++) print shown[order[i]] "\t" names[order[i]] }' "$hexmap")
      rm -f "$hexmap"
    fi
  fi

  if [[ "$verify" == copy || "$verify" == all ]]; then
    frags="$(mktemp)"; : > "$frags"
    for c in ${copies[@]+"${copies[@]}"}; do
      grep -qxF -- "$c" "$exfile" 2>/dev/null && continue
      vchecked=$((vchecked + 1))
      printf '%s\n' "$c" | awk '{ gsub(/\{[^}]*\}/, "\n"); print }' \
        | awk '{ sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); if (length($0) >= 3) print }' >> "$frags"
    done
    sort -u "$frags" -o "$frags"
    # A one-word fragment ("Trends", "Close") must match as a whole word (fix 22), so `onClose`
    # does not satisfy `Close`. Correctly rendered copy always sits between non-word characters
    # (`>Close<`, `'Close'`), so this cannot fail a correct build; it is still only a presence
    # check, and the rendered screen is left to the owner's post-run comparison.
    words="$(mktemp)"; phrases="$(mktemp)"
    grep -v '[[:space:]]' "$frags" > "$words"; grep '[[:space:]]' "$frags" > "$phrases"
    for kind in words phrases; do
      list="$words"; wflag=-w
      [[ $kind == phrases ]] && { list="$phrases"; wflag=""; }
      [[ -s "$list" ]] || continue
      found="$(mktemp)"
      (cd "$top" && xargs -0 grep -ohIF $wflag -f "$list" -- < "$srclist" 2>/dev/null) | sort -u > "$found"
      while IFS= read -r fr; do
        grep -qxF -- "$fr" "$found" && continue
        # -o reports non-overlapping leftmost matches, so a fragment inside a longer one can hide.
        [[ -n "$(files_with -F $wflag -e "$fr" | head -1)" ]] || vbad "copy: \"$fr\" — not found $([[ -n $wflag ]] && printf 'as a whole word' || printf 'verbatim') in source"
      done < "$list"
      rm -f "$found"
    done
    rm -f "$frags" "$words" "$phrases"
  fi

  rm -f "$srclist" "$exfile"
  echo "verify $verify: $vchecked checked, $vfail failed"
  [[ $vfail -eq 0 ]] && exit 0 || exit 1
fi

# design/ must be committed, with nothing untracked or modified under it.
sha="uncommitted"
if git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  top="$(git -C "$dir" rev-parse --show-toplevel)"
  rel="$(cd "$dir" && pwd -P)"; rel="${rel#"$(cd "$top" && pwd -P)"/}"
  untracked="$(git -C "$top" ls-files --others --exclude-standard -- "$rel" | head -3)"
  modified="$(git -C "$top" status --porcelain --untracked-files=no -- "$rel" | head -3)"
  if [[ -n "$untracked" || -n "$modified" ]]; then
    err "$rel/ has uncommitted files (e.g. $(printf '%s' "$untracked$modified" | head -1 | sed 's/^ *[A-Z?]* *//')) — commit it: prepare-design.sh $rel (Stage 2.7d), or git add $rel && git commit -m \"design: handoff\""
  fi
  s="$(git -C "$top" log -1 --format=%h -- "$rel" 2>/dev/null)"
  [[ -n "$s" && -z "$untracked$modified" ]] && sha="$s"
else
  warn "not a git repository — cannot confirm design/ is committed; cleanliness checks run without git history anyway"
  sha="no-git"
fi

echo "design: ${#ids[@]} screens, ${#tokens[@]} tokens, ${#components[@]} components, $copy_count copy strings @ $sha"
[[ $errors -eq 0 ]] || exit 1
[[ $criteria -eq 1 ]] || exit 0

# ---------------------------------------------------------------------------------------------
# Draft criteria. Lists that are short go inline; long ones are cited from HANDOFF.md, which is
# committed and therefore stable for the audit.
join() { local IFS=','; local s="$*"; printf '%s' "${s//,/, }"; }
quoted_ids="$(for id in "${ids[@]}"; do printf '`%s` ' "$id"; done | sed 's/ $//; s/` `/`, `/g')"
k=$start
# The command every Acceptance line names: the copy of this script Stage 7 puts in the run root.
thm="${theme:-<theme file>}"
vcmd="bash $runroot/check-design.sh design"
vargs=" --except $runroot/SPEC.md"
tokargs=" --theme $thm"
for g in ${allows[@]+"${allows[@]}"}; do tokargs="$tokargs --allow '$g'"; done
exnote="Items resolved \"spec wins\" in \`## Design reconciliation\` are exempt."
kinds=""   # "S7=screens S8=components ..." — which reason table each drafted criterion uses

emit() {
echo "- **S$k — Design: every approved screen is built**: each approved screen in \`design/HANDOFF.md\` ($quoted_ids) is marked by a \`design: <id>\` comment in exactly one source file outside \`design/\`."
echo "  - Current: the screens exist only as the design package at \`design/\` ($sha)."
echo "  - Target: the file that builds each screen carries its \`design: <id>\` marker."
echo "  - Acceptance: \`$vcmd --verify screens$vargs\` exits 0 (each id marked in exactly one file). $exnote"
kinds="$kinds S$k=screens"; k=$((k + 1))

if [[ ${#components[@]} -gt 0 ]]; then
  if [[ ${#components[@]} -le 12 ]]; then list="$(join "${components[@]}")"; else list="${#components[@]} names"; fi
  echo "- **S$k — Design: named components exist**: every component in \`design/HANDOFF.md\` §Components ($list) exists as an identifier in source outside \`design/\`."
  echo "  - Current: the components are named only in the design package."
  echo "  - Target: each has a definition under the name the design uses."
  echo "  - Acceptance: \`$vcmd --verify components$vargs\` exits 0 (each name present as a whole word). $exnote"
  kinds="$kinds S$k=components"; k=$((k + 1))
fi

if [[ ${#tokens[@]} -gt 0 ]]; then
  hex=()
  while IFS= read -r h; do [[ -n "$h" ]] && hex+=("$h"); done < <(
    for v in ${values[@]+"${values[@]}"}; do hexes "$v"; done | awk '!seen[tolower($0)]++'
  )
  echo "- **S$k — Design: tokens live in one theme file**: all ${#tokens[@]} tokens in \`design/HANDOFF.md\` §Design tokens are defined in \`$thm\`, and no token colour value$([[ ${#hex[@]} -gt 0 && ${#hex[@]} -le 12 ]] && printf ' (%s)' "$(join "${hex[@]}")") is hard-coded outside it$([[ ${#allows[@]} -gt 0 ]] && printf ' or the files generated from it (%s)' "$(join "${allows[@]}")")."
  echo "  - Current: the tokens are defined only in the design package."
  echo "  - Target: one theme file defines every token; everything else references it, and platform colour values (manifest, theme-color) are generated from it, never duplicated."
  echo "  - Acceptance: \`$vcmd --verify tokens$tokargs$vargs\` exits 0 (names compared case-insensitively with \`-\`/\`_\` removed, so \`panel-border\` matches \`panelBorder\`; every hex in a value cell is checked, light and dark alike)."
  kinds="$kinds S$k=tokens"; k=$((k + 1))
fi

if [[ $copy_count -gt 0 ]]; then
  echo "- **S$k — Design: copy matches the design**: all $copy_count strings in \`design/HANDOFF.md\` §Copy appear verbatim in source outside \`design/\`."
  echo "  - Current: the copy exists only in the design package."
  echo "  - Target: the built UI uses the designed wording."
  echo "  - Acceptance: \`$vcmd --verify copy$vargs\` exits 0 (each string split on \`{name}\` placeholders; every fragment of 3+ characters present verbatim, a one-word fragment as a whole word — one-word strings are only presence-checked, so their rendering is left to the post-run screen comparison). $exnote"
  kinds="$kinds S$k=copy"; k=$((k + 1))
fi

echo "- **S$k — Design: screens captured for review**: for each approved screen, \`$runroot/design-check/<id>.png\` exists, or the polish phase's evidence file records \`capture unavailable: <id> — <reason>\`; the capture code takes its output directory from \`RELAY_DESIGN_CHECK_DIR\`, so no run path is written into the product."
echo "  - Current: no captures exist."
echo "  - Target: the owner can compare each built screen against \`design/screens/<id>.png\` after the run; the comparison itself is never a gate."
echo "  - Acceptance: for each id, \`test -f $runroot/design-check/<id>.png\` exits 0 or \`grep -F 'capture unavailable: <id>' $runroot/phases/phase-*.evidence.md\` prints a line; and \`git grep --untracked -lF '.relay/' -- . ':!design' ':!.relay' ':!**/.gitignore'\` returns no files."
kinds="$kinds S$k=capture"
}

# emit runs in this shell (not $(…)) so the kinds it records survive.
critfile="$(mktemp)"
emit > "$critfile"
crit_text="$(cat "$critfile")"; rm -f "$critfile"
echo
printf '%s\n' "$crit_text"

# ---------------------------------------------------------------------------------------------
# Edge rows. edge-probe.py raises edges on these criteria from their wording (every, exactly 1,
# 3+ characters…), and most do not apply to a static source grep. Rather than leave the planner
# ~30 dismissals to write per run, give each raised pair its disposition with a reason specific
# to the criterion. The probe stays the floor: a pair it raises that the table below does not
# know is emitted `unresolved`, never dropped.
reason() {  # reason <kind> <edge> -> "status|reason"
  case "$1:$2" in
    screens:boundary|screens:adjacency) echo "resolved|Acceptance demands exactly \`1\` file per id: a missing marker (0) and a duplicate (2) both fail" ;;
    screens:empty|capture:empty)        echo "resolved|check-design.sh refuses a package with no approved screens" ;;
    screens:encoding|capture:encoding)  echo "dismissed|screen ids are slugs from the handoff table; the marker is ASCII" ;;
    components:boundary|components:adjacency) echo "dismissed|presence check (at least one file per name); there is no limit to sit on" ;;
    components:empty) echo "resolved|drafted only when §Components lists at least one name" ;;
    components:encoding) echo "dismissed|component names are code identifiers; \`-w\` whole-word matching avoids partial hits" ;;
    tokens:boundary|tokens:adjacency) echo "dismissed|every token must be present and no hex literal may leak; there is no threshold" ;;
    tokens:empty) echo "resolved|drafted only when §Design tokens has rows" ;;
    tokens:encoding) echo "dismissed|token names are ASCII; hex values are matched case-insensitively (\`-i\`) and only where no hex digit follows, so \`#FFF\` is not found inside \`#FFFDF8\`" ;;
    tokens:precision) echo "dismissed|values are compared as literal strings; a platform that converts hex to floats has no literal to leak" ;;
    copy:boundary|copy:adjacency) echo "dismissed|the 3-character floor only skips punctuation between \`{name}\` placeholders; a one-word fragment must match as a whole word, so \`Close\` inside \`onClose\` does not count" ;;
    copy:empty) echo "resolved|drafted only when §Copy has strings" ;;
    copy:encoding) echo "resolved|fixed-string grep matches UTF-8 literally; copy stored as escapes (\`\\u{2192}\`) fails, which keeps strings literal as designed" ;;
    copy:precision) echo "dismissed|numbers inside copy are matched as text" ;;
    capture:boundary|capture:adjacency) echo "dismissed|one capture or recorded reason per id; there is no threshold" ;;
    capture:idempotency) echo "dismissed|re-capturing overwrites \`<id>.png\`; the check only tests existence" ;;
    capture:concurrency) echo "dismissed|captures are written by one phase subagent" ;;
    *:ordering)    echo "dismissed|a static per-item check over the source tree; order cannot change the result" ;;
    *:idempotency) echo "dismissed|a read-only grep; re-running the check cannot change its result" ;;
    *:concurrency) echo "dismissed|a static source check; no runtime or shared state is involved" ;;
    *:precision)   echo "dismissed|no numeric value beyond an exact count" ;;
    *) echo "unresolved|" ;;
  esac
}

probe="$here/edge-probe.py"
if command -v python3 >/dev/null 2>&1 && [[ -f "$probe" ]]; then
  tmpspec="$(mktemp)"
  printf '## Success criteria\n\n%s\n' "$crit_text" > "$tmpspec"
  rows="$(python3 "$probe" --from-spec "$tmpspec" 2>/dev/null | grep -E '^\| S[0-9]+ \|')"
  rm -f "$tmpspec"
  if [[ -n "$rows" ]]; then
    echo
    echo "Edge coverage rows (append to ## Edge coverage):"
    while IFS= read -r row; do
      id="$(printf '%s' "$row" | awk -F'|' '{gsub(/ /, "", $2); print $2}')"
      cell="$(printf '%s' "$row" | awk -F'|' '{sub(/^ +/, "", $3); sub(/ +$/, "", $3); print $3}')"
      edge="${cell%% *}"
      kind=""
      for kv in $kinds; do [[ "${kv%%=*}" == "$id" ]] && kind="${kv#*=}"; done
      r="$(reason "$kind" "$edge")"
      echo "| $id | $cell | ${r%%|*} | ${r#*|} |"
    done <<< "$rows"
  fi
else
  echo
  echo "⚠  edge rows not drafted (needs python3 and edge-probe.py beside this script) — run validate-spec.sh and add the rows it asks for"
fi
exit 0
