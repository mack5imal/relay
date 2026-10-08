#!/usr/bin/env bash
# leak-check.sh — fail when the repository would publish a private detail.
#
# Usage: leak-check.sh [--base <sha>] [<repo-dir>]
#
#   (a) Tracked files: an email address that is not a placeholder (`@example.com`, `*.invalid`,
#       a noreply address, an ssh `git@` remote), a macOS home path, a projects-folder or Desktop
#       path under `~`, a Claude Code project-dir name built from a home path, or a UUID
#       (transcript and session ids have that shape).
#   (b) Commits after <base>: author and committer email must be noreply addresses. <base> is the
#       upstream fork point by default — Supergoal's history before it is already public and keeps
#       its authors' addresses. Needs full history (CI: `fetch-depth: 0`).
#
# Exit 0 clean, 1 on any leak (each printed as `leak: <where>: <what>`), 2 on a usage error or a
# base that is not in the history.
#
# Why: relay's development history and journal stay private; this keeps a stray path, id or
# address out of the public repository. The patterns are assembled from fragments so this file
# does not match itself. Repo-only (not shipped in the plugin).

set -uo pipefail

base="ec2f6eb8eb3304a4ed32f1f18948a6c6198fcd67"
dir="."
while [ $# -gt 0 ]; do
  case "$1" in
    --base) [ $# -ge 2 ] || { echo "leak-check: --base needs a sha" >&2; exit 2; }; base="$2"; shift 2 ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    -*) echo "leak-check: unknown option $1" >&2; exit 2 ;;
    *) dir="$1"; shift ;;
  esac
done

git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || { echo "leak-check: $dir is not a git repository" >&2; exit 2; }
git -C "$dir" cat-file -e "$base^{commit}" 2>/dev/null \
  || { echo "leak-check: base $base is not in the history (shallow clone? fetch with full depth)" >&2; exit 2; }
git -C "$dir" merge-base --is-ancestor "$base" HEAD 2>/dev/null \
  || { echo "leak-check: base $base is not an ancestor of HEAD" >&2; exit 2; }

leaks=0
report() { echo "leak: $1"; leaks=$((leaks + 1)); }

# (a) tracked files — fixed-string patterns
home_mac='/User''s/'
proj_dir='~/pro''jects'
desk_dir='~/Desk''top'
proj_key='-User''s-'
for pat in "$home_mac" "$proj_dir" "$desk_dir" "$proj_key"; do
  while IFS= read -r hit; do
    [ -n "$hit" ] && report "$hit: contains '$pat'"
  done < <(git -C "$dir" grep -nIF -e "$pat" 2>/dev/null | cut -c1-200)
done

uuid='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
while IFS= read -r hit; do
  [ -n "$hit" ] && report "$hit: UUID-shaped id"
done < <(git -C "$dir" grep -nIoE -e "$uuid" 2>/dev/null)

email='[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}'
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  addr="${hit##*:}"
  domain="${addr#*@}"
  case "$addr" in
    *noreply*|git@*) continue ;;
  esac
  case "$domain" in
    example.com|*.example.com|*.invalid) continue ;;
  esac
  report "$hit: email address"
done < <(git -C "$dir" grep -nIoE -e "$email" 2>/dev/null)

# (b) commits after the base
commits=0
while IFS=' ' read -r sha author committer; do
  [ -n "$sha" ] || continue
  commits=$((commits + 1))
  case "$author" in *noreply*) ;; *) report "commit ${sha:0:12}: author email is not a noreply address" ;; esac
  case "$committer" in *noreply*) ;; *) report "commit ${sha:0:12}: committer email is not a noreply address" ;; esac
done < <(git -C "$dir" log --format='%H %ae %ce' "$base..HEAD")

files=$(git -C "$dir" ls-files | wc -l | tr -d ' ')
if [ "$leaks" -gt 0 ]; then
  echo "leak-check: $leaks leak(s) — $files tracked files, $commits commits after ${base:0:12}"
  exit 1
fi
echo "leak-check: clean — $files tracked files, $commits commits after ${base:0:12}"
exit 0
