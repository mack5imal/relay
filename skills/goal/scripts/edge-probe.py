#!/usr/bin/env python3
"""edge-probe.py - raise the edge cases that genuinely apply to a spec's success criteria.

Why: a goal-backward verifier only checks assertions that exist, and an assertion only exists
for a requirement someone wrote down. Omitted edges are therefore invisible to verification -
the verifier reports success with high confidence while the defect ships. The fix is not a
better verifier or a confidence threshold; it is spec completeness. This script is the
deterministic half of that: it classifies each success criterion by shape and emits the edge
categories that apply to that shape, so the planner starts from a floor it must cover rather
than from whatever it happened to think of.

Two rules make the output meaningful rather than noise:

  1. Relevance filter. A pure-text criterion is never asked about numeric overflow, and a
     stateless read is never asked about idempotency. Because only applicable edges are
     raised, an unresolved edge is a real gap rather than an unticked box.
  2. Dismissal needs a reason. This script only raises; SPEC.md records the disposition, and
     validate-spec.sh rejects a dismissal with no reason string. Silence is not a disposition.

The output is a FLOOR. The planner unions its own judgement with these rows; it never narrows
the list. Dropping a raised edge requires writing down why.

`--check` enforces the floor. It re-probes the spec's current criteria and fails when a raised
(criterion, category) pair has no row in `## Edge coverage`. Any status covers a pair --
`unresolved` included, since an honest known gap is always a legal answer. The first three
planning sessions each narrowed the floor silently (1 of 91, 6 of 49 and 7 of 38 raised edges
had no row) while the prose rule said never to, so the rule is now a check.

Usage:
  python3 edge-probe.py --from-spec <SPEC.md> [--json]
  python3 edge-probe.py --criteria <file.json> [--json]      # [{"id": "S1", "text": "..."}]
  cat criteria.json | python3 edge-probe.py --criteria - [--json]
  python3 edge-probe.py --check <SPEC.md> [--json]

  Default output is markdown rows for SPEC.md's "## Edge coverage" table. Exit 0 on success
  (including "no criteria matched a shape", which prints a loud warning), 2 on a usage error,
  1 when the input file is missing or malformed. `--check` prints each uncovered pair as a
  ready-to-paste `unresolved` row and exits 1 when any are missing, 0 when none are.

Approach credit: the shape-classification / closed-taxonomy / relevance-filter design comes
from get-shit-done v1.42.3, bin/lib/edge-probe.cjs and references/edge-probe.md
(gsd-build/get-shit-done, MIT License, Copyright (c) 2025 Lex Christopherson). This is a
reimplementation, not a copy: the taxonomy is the same eight categories, but the shape
detection is regex-over-criterion-text rather than a typed requirement schema, and the output
targets relay's SPEC.md table instead of a JSON report.
"""

from __future__ import annotations

import argparse
import json
import re
import sys

# The closed taxonomy. Nothing outside this list is ever raised -- an open-ended "what else
# could go wrong" prompt produces noise, and noise is what makes a checklist get skipped.
TAXONOMY = (
    "boundary",      # the limits of a range, and just past them
    "adjacency",     # the values either side of a threshold
    "empty",         # zero-length, absent, null, no results
    "encoding",      # unicode, escaping, normalisation, charset
    "ordering",      # sequence, sort stability, out-of-order arrival
    "precision",     # rounding, float error, truncation, units
    "idempotency",   # running it twice, retry, resume, replay
    "concurrency",   # simultaneous access, races, partial writes
)

# Shape -> the edges that can apply to it. This mapping IS the relevance filter.
# `concurrency` comes only from shapes that genuinely share something: stored data
# (`stored`) or an explicit simultaneity signal (`concurrent`). A criterion that merely
# repeats (`repeatable`) or talks to a network (`io`) is asked about running twice, not
# about races. `io` never raises `encoding` -- that belongs to the `text` shape.
SHAPE_EDGES = {
    "numeric-range": ("boundary", "adjacency", "precision"),
    "collection":    ("empty", "ordering", "boundary"),
    "text":          ("empty", "encoding", "boundary"),
    "repeatable":    ("idempotency", "ordering"),
    "stored":        ("idempotency", "concurrency"),
    "concurrent":    ("concurrency", "ordering"),
    "io":            ("empty", "idempotency"),
}

# Deliberately conservative: a shape is claimed only on an explicit signal. Over-claiming a
# shape raises edges that do not apply, which trains the reader to dismiss rows unread.
#
# The tunez run (22 criteria) showed what over-claiming looks like: 136 edges, ~77% of all
# (criterion, category) pairs, a third of them dismissed as nonsense. The triggers were generic
# words -- "each", "every", "state", "name", "input", "message", "reads", "dB", "over" /
# "under" as prepositions, "command" -- and file names inside commands (`latency.json` raised
# `encoding` on a latency criterion). So: backticked spans are removed before classifying
# (a command or a file name is how a criterion is checked, not what it is about), and each
# shape below lists only words that name the shape itself.
#
# Each entry is one alternative; WORD entries are matched as whole words, SYMBOL entries
# anywhere (`\b` never fires around `≤`, `%` or `¢`, which is why `≥ 99%` used to be missed).
UNIT = r"(?:ms|s|secs?|seconds?|mins?|minutes?|h|hrs?|hours?|days?|kb|mb|gb|tb|px|pt|hz|khz|db|fps|cents?)"
SHAPE_PATTERNS = {
    "numeric-range": {
        "word": [
            r"\d+(?:[.,]\d+)?\s*" + UNIT, r"p\d{2}", r"within", r"at\s+most", r"at\s+least",
            r"no\s+(?:more|fewer|less)\s+than", r"(?:fewer|more|greater|less)\s+than",
            r"exceed(?:s|ed|ing)?", r"limits?", r"maximum", r"minimum", r"timeouts?",
            r"thresholds?", r"budgets?", r"percent(?:age)?", r"exactly\s+(?:one|two|three|\d+)",
        ],
        "symbol": [r"\d\s*%", r"\d\s*¢", r"≤", r"≥", r"<=", r">=", r"±", r"[<>]\s*\d"],
    },
    "collection": {
        "word": [
            r"(?:a|the|its|their|each)\s+list", r"lists?\s+of", r"arrays?", r"collections?",
            r"queues?", r"batch(?:es)?", r"set\s+of", r"multiple", r"entr(?:y|ies)",
            r"tables?\s+of", r"per[- ][\w-]+\s+tables?", r"sort(?:s|ed|ing)?", r"order(?:ed|ing)?",
            r"newest", r"oldest", r"chronological(?:ly)?", r"alphabetical(?:ly)?",
            r"pagina(?:te|ted|tion)", r"filter(?:s|ed|ing)?", r"timeline", r"all\s+of",
        ],
        "symbol": [],
    },
    "text": {
        "word": [
            r"strings?", r"pars(?:e|es|ed|ing|er|eable|able)", r"unicode", r"emoji",
            r"(?:en|de)cod(?:e|es|ed|ing)", r"escap(?:e|es|ed|ing)", r"charset", r"utf-?8",
            r"verbatim", r"wording", r"spell(?:s|ed|ing)?", r"free[- ]text",
            r"text\s+(?:input|field|box|area)", r"search\s+(?:terms?|box|quer(?:y|ies))",
            r"titles?", r"file\s?names?", r"user[- ](?:entered|supplied|provided|typed)",
            r"special\s+characters", r"whitespace", r"case[- ]insensitive(?:ly)?",
            r"locales?", r"translat(?:e|ed|ion|ions)",
        ],
        "symbol": [],
    },
    "repeatable": {
        "word": [
            r"again", r"twice", r"retr(?:y|ies|ied|ying)", r"resum(?:e|es|ed|ing)",
            r"restart(?:s|ed|ing)?", r"re-?runs?", r"re-?open(?:s|ed|ing)?",
            r"re-?load(?:s|ed|ing)?", r"replay(?:s|ed)?", r"idempoten(?:t|cy)",
            r"double[- ]?(?:taps?|clicks?|submits?)", r"toggle[sd]?", r"undo", r"(?:each|every)\s+time",
        ],
        "symbol": [],
    },
    "stored": {
        "word": [
            r"persist(?:s|ed|ence|ent)?", r"stor(?:e|es|ed|age)", r"sav(?:e|es|ed|ing)",
            r"cach(?:e|es|ed|ing)", r"precach(?:e|es|ed|ing)", r"databases?", r"indexeddb",
            r"localstorage", r"migrat(?:e|es|ed|ion|ions)", r"sync(?:s|ed|ing)?",
            r"upload(?:s|ed|ing)?", r"submit(?:s|ted|ting)?",
        ],
        "symbol": [],
    },
    "concurrent": {
        "word": [
            r"concurren(?:t|tly|cy)", r"simultaneous(?:ly)?", r"at\s+the\s+same\s+time",
            r"(?:in\s+)?parallel", r"races?", r"race\s+conditions?", r"two\s+tabs",
            r"multiple\s+(?:tabs|users|devices|windows|clients|processes)", r"at\s+a\s+time",
            r"double[- ]?(?:taps?|clicks?|submits?)", r"interrupt(?:s|ed|ion|ions)?", r"deadlocks?",
        ],
        "symbol": [],
    },
    "io": {
        "word": [
            r"apis?", r"endpoints?", r"requests?", r"responses?", r"https?", r"network",
            r"offline", r"online", r"sockets?", r"websockets?", r"fetch(?:es|ed|ing)?",
            r"download(?:s|ed|ing)?", r"upload(?:s|ed|ing)?", r"quer(?:y|ies)", r"stdout",
            r"stderr", r"exit\s+codes?", r"subprocess(?:es)?", r"disk",
            r"(?:writ(?:e|es|ing|ten)|read(?:s|ing)?)\s+(?:to|from)",
        ],
        "symbol": [],
    },
}


def _compile(spec: dict) -> re.Pattern:
    alts = [r"(?<!\w)(?:" + w + r")(?!\w)" for w in spec["word"]] + spec["symbol"]
    return re.compile("|".join(alts), re.I)


_COMPILED = {k: _compile(v) for k, v in SHAPE_PATTERNS.items()}
BACKTICK_RE = re.compile(r"`[^`]*`")

# Why each edge is worth a sentence in the spec. Shown in the markdown output so the reader
# can dispose of a row without going and looking the category up.
EDGE_PROMPT = {
    "boundary":    "at the limit and one past it",
    "adjacency":   "either side of the threshold",
    "empty":       "zero-length, absent, or no results",
    "encoding":    "unicode, escaping, or charset",
    "ordering":    "sequence or out-of-order arrival",
    "precision":   "rounding, truncation, or units",
    "idempotency": "run twice / retried / resumed",
    "concurrency": "simultaneous or interrupted access",
}


def shapes_of(text: str) -> list[str]:
    """Every shape whose signal appears in the criterion's prose. Order follows SHAPE_EDGES.
    Backticked spans (commands, file names, identifiers) are removed first."""
    prose = BACKTICK_RE.sub(" ", text)
    return [s for s in SHAPE_EDGES if _COMPILED[s].search(prose)]


def edges_for(text: str) -> list[str]:
    """The applicable edge categories for one criterion, in taxonomy order, deduplicated."""
    applicable = set()
    for shape in shapes_of(text):
        applicable.update(SHAPE_EDGES[shape])
    return [e for e in TAXONOMY if e in applicable]


CRIT_RE = re.compile(
    r"^\s*-\s+\*\*(?P<id>S\d+)\s*(?:[-—:]\s*(?P<label>[^*]*?))?\*\*\s*:?\s*(?P<text>.*)$"
)
SUB_RE = re.compile(r"^\s{2,}-\s*(?P<key>Current|Target|Acceptance)\s*:\s*(?P<val>.*)$", re.I)


def parse_spec(path: str) -> list[dict]:
    """Pull the success criteria out of a SPEC.md.

    A criterion's shape usually shows up in its `Acceptance:` line (that is where the
    measurable predicate lives), so the sub-bullets are folded into the text we classify.
    Placeholder rows ({{...}}) are skipped -- an unfilled template must not raise edges.
    """
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError as exc:
        sys.exit(f"edge-probe.py: cannot read {path}: {exc}")

    out: list[dict] = []
    in_section = False
    for line in lines:
        if line.startswith("## "):
            in_section = line.strip().lower().startswith("## success criteria")
            continue
        if not in_section:
            continue
        m = CRIT_RE.match(line)
        if m:
            label = (m.group("label") or "").strip()
            out.append({
                "id": m.group("id"),
                "label": label,
                "text": " ".join(x for x in (label, m.group("text").strip()) if x),
            })
            continue
        sub = SUB_RE.match(line)
        if sub and out:
            out[-1]["text"] += " " + sub.group("val").strip()

    return [c for c in out if "{{" not in c["text"]]


def load_criteria(path: str) -> list[dict]:
    try:
        raw = sys.stdin.read() if path == "-" else open(path, encoding="utf-8").read()
        data = json.loads(raw)
    except OSError as exc:
        sys.exit(f"edge-probe.py: cannot read {path}: {exc}")
    except json.JSONDecodeError as exc:
        sys.exit(f"edge-probe.py: {path} is not valid JSON: {exc}")
    if not isinstance(data, list):
        sys.exit("edge-probe.py: expected a JSON array of {id, text} objects")
    out = []
    for i, item in enumerate(data, 1):
        if not isinstance(item, dict) or "text" not in item:
            sys.exit(f"edge-probe.py: entry {i} needs at least a 'text' field")
        out.append({"id": str(item.get("id") or f"S{i}"),
                    "label": str(item.get("label") or ""),
                    "text": str(item["text"])})
    return out


COMMENT_RE = re.compile(r"<!--.*?-->", re.S)
RANGE_RE = re.compile(r"S(\d+)\s*[-–—]\s*S?(\d+)")
SINGLE_RE = re.compile(r"S(\d+)")
TAXONOMY_RE = re.compile(r"\b(" + "|".join(TAXONOMY) + r")\b", re.I)


def criterion_ids(cell: str) -> set[str]:
    """Expand a criterion cell into ids. Planners write `S3`, `S1, S2, S4` and `S1–S10`."""
    ids: set[str] = set()
    for m in RANGE_RE.finditer(cell):
        lo, hi = sorted((int(m.group(1)), int(m.group(2))))
        ids.update(f"S{k}" for k in range(lo, hi + 1))
    rest = RANGE_RE.sub(" ", cell)
    ids.update(f"S{m.group(1)}" for m in SINGLE_RE.finditer(rest))
    return ids


def edge_categories(cell: str) -> set[str]:
    """The taxonomy words that name a row's edges. Only the text before the first dash counts:
    `boundary — range endpoints` is one edge, and the description after the dash is free text
    that may mention another category in passing. `ordering, idempotency, concurrency` is three."""
    head = re.split(r"\s[—–-]\s", cell, maxsplit=1)[0]
    return {m.group(1).lower() for m in TAXONOMY_RE.finditer(head)}


def parse_coverage(path: str) -> set[tuple[str, str]]:
    """Every (criterion, category) pair that has a row in `## Edge coverage`, any status."""
    try:
        with open(path, encoding="utf-8") as fh:
            text = COMMENT_RE.sub("", fh.read())
    except OSError as exc:
        sys.exit(f"edge-probe.py: cannot read {path}: {exc}")

    covered: set[tuple[str, str]] = set()
    in_section = False
    for line in text.splitlines():
        if line.startswith("## "):
            in_section = line.strip().lower().startswith("## edge coverage")
            continue
        if not in_section or not line.lstrip().startswith("|") or "{{" in line:
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 2 or re.fullmatch(r"(criterion|:?-+:?)", cells[0], re.I):
            continue
        for crit in criterion_ids(cells[0]):
            for cat in edge_categories(cells[1]):
                covered.add((crit, cat))
    return covered


def check_floor(path: str, as_json: bool) -> int:
    criteria = parse_spec(path)
    raised = [(c["id"], e) for c in criteria for e in edges_for(c["text"])]
    covered = parse_coverage(path)
    missing = [(crit, e) for crit, e in raised if (crit, e) not in covered]
    rows = [f"| {crit} | {e} — {EDGE_PROMPT[e]} | unresolved | |" for crit, e in missing]

    if as_json:
        json.dump({"criteria": len(criteria), "raised": len(raised),
                   "missing": [{"criterion": c, "edge": e, "row": r}
                               for (c, e), r in zip(missing, rows)]}, sys.stdout, indent=2)
        sys.stdout.write("\n")
    elif not criteria:
        print("edge-probe: floor ok — no success criteria to check.")
    elif missing:
        print(f"edge-probe: floor NOT met — {len(missing)} of {len(raised)} raised edge(s) have no "
              "row in ## Edge coverage. Add each as resolved, dismissed with a reason, or "
              "unresolved (a known gap). Ready to paste:")
        for r in rows:
            print(r)
    else:
        print(f"edge-probe: floor ok — all {len(raised)} raised edge(s) have a row.")
    return 1 if missing else 0


def main() -> int:
    ap = argparse.ArgumentParser(add_help=True, description=__doc__.splitlines()[0])
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--from-spec", metavar="SPEC.md", help="parse ## Success criteria out of a SPEC.md")
    src.add_argument("--criteria", metavar="FILE", help="JSON array of {id, text}; '-' for stdin")
    src.add_argument("--check", metavar="SPEC.md",
                     help="fail if a raised edge has no row in the spec's ## Edge coverage")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    args = ap.parse_args()

    if args.check:
        return check_floor(args.check, args.json)

    criteria = parse_spec(args.from_spec) if args.from_spec else load_criteria(args.criteria)

    rows = []
    for c in criteria:
        for edge in edges_for(c["text"]):
            rows.append({"criterion": c["id"], "label": c["label"], "edge": edge,
                         "prompt": EDGE_PROMPT[edge], "status": "unresolved", "reason": ""})

    if args.json:
        json.dump({"criteria": len(criteria), "edges": rows}, sys.stdout, indent=2)
        sys.stdout.write("\n")
    else:
        if rows:
            print("| Criterion | Edge | Status | Reason / where covered |")
            print("|---|---|---|---|")
            for r in rows:
                print(f"| {r['criterion']} | {r['edge']} — {r['prompt']} | unresolved | |")
        print()
        print(f"edge-probe: {len(rows)} edge(s) apply across {len(criteria)} criterion(a).")

    if not criteria:
        print("edge-probe: WARNING — no success criteria found. Nothing was probed; this is "
              "almost certainly a parsing or authoring problem, not a clean bill of health.",
              file=sys.stderr)
    elif not rows:
        print("edge-probe: WARNING — criteria were found but none matched a known shape, so no "
              "edges were raised. Check the criteria are concrete enough to classify before "
              "treating this as complete.", file=sys.stderr)

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BrokenPipeError:
        sys.exit(0)
