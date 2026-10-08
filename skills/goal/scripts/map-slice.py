#!/usr/bin/env python3
"""map-slice.py - print a compact, token-budgeted map of named symbols from a graphify graph.

Why: an executor starting a phase cold needs to know where the code it will touch lives -
members, what it uses, what uses it - with file:line citations, without reading a
multi-megabyte graph.json or grepping the whole tree. graphify
(https://github.com/Graphify-Labs/graphify) builds the graph locally with tree-sitter; this
script only reads the JSON (stdlib only, no graphify import), so querying never depends on
the graphify install.

Usage:
  python3 map-slice.py --graph <graph.json> [--budget TOKENS] SEED [SEED ...]

  Seeds are exact symbol labels (e.g. Scheduler); commas also separate seeds. Output is
  plain markdown on stdout. Exit 0 on success (unmatched seeds are reported inline with
  suggestions), 2 on a usage error, 3 when the graph is missing, unreadable, or malformed.
  Normally run through map-slice.sh, which picks a Python and degrades when there is none.

Approach credit: the seed -> expand -> confidence-tiered budget idea comes from
get-shit-done v1.42.3, bin/lib/graphify.cjs (gsd-build/get-shit-done, MIT License,
Copyright (c) 2025 Lex Christopherson). This is a reimplementation, not a copy, with
deliberate differences:
  - exact-label seeds (case-insensitive exact as a fallback), never substring matches
  - one hop only - two hops from one type on a real graph returned ~284k tokens
  - output projected to label + file:line and grouped by file, not raw nodes and edges
  - after shedding AMBIGUOUS, then INFERRED edges, a final even-truncation tier keeps the
    slice under budget while always keeping every seed's header
"""

import argparse
import json
import math
import sys

# Relations that make the neighbor part of the seed (children).
MEMBER_RELATIONS = {"method", "contains", "defines", "case_of"}
SUPERTYPE_RELATIONS = {"inherits", "implements"}

# Section order doubles as truncation priority: earlier sections survive longer.
SECTIONS = ["declared in", "nested in", "inherits", "uses", "used by", "members"]

# The relation a section implies; any other relation is tagged inline, e.g. "[calls]".
DEFAULT_RELATION = {
    "declared in": "contains",
    "nested in": "contains",
    "inherits": "inherits",
    "uses": "references",
    "used by": "references",
    "members": "method",
}

CONFIDENCE_TAG = {"INFERRED": " (inferred)", "AMBIGUOUS": " (ambiguous)"}
SHED_TIERS = ["AMBIGUOUS", "INFERRED"]
MAX_NODES_PER_SEED = 5
MAX_SUGGESTIONS = 5


def load_graph(path):
    try:
        with open(path, encoding="utf-8") as fh:
            graph = json.load(fh)
        nodes = graph["nodes"]
        links = graph["links"] if "links" in graph else graph["edges"]
        if not isinstance(nodes, list) or not isinstance(links, list):
            raise ValueError("nodes and links must be lists")
        return nodes, links
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print("map-slice: cannot read graph %s: %s" % (path, exc), file=sys.stderr)
        sys.exit(3)


def label_of(node):
    return str(node.get("label") or node.get("id") or "?")


def is_file_node(node):
    source = str(node.get("source_file") or "")
    return bool(source) and source.rsplit("/", 1)[-1] == label_of(node)


def loc_number(loc):
    digits = "".join(ch for ch in str(loc or "") if ch.isdigit())
    return int(digits) if digits else 0


def match_seed(seed, nodes):
    matches = [n for n in nodes if label_of(n) == seed]
    if not matches:
        lowered = seed.lower()
        matches = [n for n in nodes if label_of(n).lower() == lowered]
    code = [n for n in matches if n.get("file_type") == "code"]
    return code or matches


def normalize(label):
    """graphify's node-id shape: lowercased, non-alphanumerics dropped."""
    return "".join(ch for ch in str(label).lower() if ch.isalnum())


def collisions(seed, nodes):
    """Labels that normalize to the seed's node id. graphify gives two such symbols in one
    file the same id (`Options` and `_options()` -> `..._options`), so only one keeps a node:
    a seed naming the dropped one misses, and the survivor is what to seed instead."""
    target = normalize(seed)
    if not target:
        return []
    base = seed.rstrip("()")
    labels = {
        label_of(n) for n in nodes
        if n.get("file_type") == "code"
        and normalize(label_of(n)) == target
        # `_lonely` vs `_lonely()` is one symbol written two ways, not a collision.
        and label_of(n).rstrip("()") != base
    }
    return sorted(labels - {seed}, key=lambda s: (len(s), s))[:MAX_SUGGESTIONS]


def suggest(seed, nodes):
    lowered = seed.lower()
    labels = {label_of(n) for n in nodes if n.get("file_type") == "code" and lowered in label_of(n).lower()}
    ranked = sorted(labels, key=lambda s: (len(s), s))
    # Same-id collisions first: they are the likeliest intent, not just a substring neighbour.
    collided = collisions(seed, nodes)
    ordered = collided + [s for s in ranked if s not in collided]
    return ordered[:MAX_SUGGESTIONS]


def make_item(section, link, other, fallback_id):
    if other is None:
        label, source, loc = str(fallback_id), "", ""
    else:
        label, source, loc = label_of(other), str(other.get("source_file") or ""), str(other.get("source_location") or "")
    return {
        "section": section,
        "relation": str(link.get("relation") or ""),
        "confidence": str(link.get("confidence") or "EXTRACTED"),
        "label": label,
        "file": source,
        "loc": loc,
    }


def neighbor_items(node, by_id, outgoing, incoming):
    node_id = node.get("id")
    items = []
    for link in outgoing.get(node_id, []):
        target = link.get("target")
        if target == node_id:
            continue
        relation = link.get("relation")
        if relation in MEMBER_RELATIONS:
            section = "members"
        elif relation in SUPERTYPE_RELATIONS:
            section = "inherits"
        else:
            section = "uses"
        items.append(make_item(section, link, by_id.get(target), target))
    for link in incoming.get(node_id, []):
        source = link.get("source")
        if source == node_id:
            continue
        other = by_id.get(source)
        relation = link.get("relation")
        if relation in MEMBER_RELATIONS:
            section = "declared in" if other is not None and is_file_node(other) else "nested in"
        else:
            section = "used by"
        items.append(make_item(section, link, other, source))

    unique = {}
    for item in items:
        key = (item["section"], item["relation"], item["label"], item["file"], item["loc"])
        unique.setdefault(key, item)
    return sorted(
        unique.values(),
        key=lambda i: (SECTIONS.index(i["section"]), i["file"] == "", i["file"], loc_number(i["loc"]), i["label"]),
    )


def render_item(item):
    text = item["label"]
    if item["loc"]:
        text += " " + item["loc"]
    if item["relation"] and item["relation"] != DEFAULT_RELATION[item["section"]]:
        text += " [%s]" % item["relation"]
    return text + CONFIDENCE_TAG.get(item["confidence"], "")


def render_block(block, keep):
    lines = [block["header"]]
    lines.extend(block["notes"])
    kept = block["items"][:keep]
    for section in SECTIONS:
        section_items = [i for i in kept if i["section"] == section]
        if not section_items:
            continue
        if section == "declared in":
            lines.append("declared in: " + ", ".join(render_item(i).split(" ")[0] for i in section_items))
            continue
        lines.append(section + ":")
        by_file = {}
        for item in section_items:
            by_file.setdefault(item["file"] or "(external)", []).append(render_item(item))
        for source in sorted(by_file, key=lambda f: (f == "(external)", f)):
            lines.append("  %s: %s" % (source, ", ".join(by_file[source])))
    cut = block["items"][keep:]
    if cut:
        counts = {}
        for item in cut:
            counts[item["section"]] = counts.get(item["section"], 0) + 1
        detail = ", ".join("%s %d" % (s, counts[s]) for s in SECTIONS if s in counts)
        lines.append("[+%d more: %s]" % (len(cut), detail))
    return lines


def render(seeds, blocks, shed, keep):
    lines = ["## Map slice: " + ", ".join(seeds)]
    over_budget = 0
    for block in blocks:
        limit = len(block["items"]) if keep is None else keep
        over_budget += max(0, len(block["items"]) - limit)
        lines.append("")
        lines.extend(render_block(block, limit))
    omitted = []
    if shed["AMBIGUOUS"]:
        omitted.append("%d ambiguous" % shed["AMBIGUOUS"])
    if shed["INFERRED"]:
        omitted.append("%d inferred" % shed["INFERRED"])
    if over_budget:
        omitted.append("%d over budget" % over_budget)
    if omitted:
        lines.append("")
        lines.append("[omitted: %s]" % ", ".join(omitted))
    return "\n".join(lines)


def estimate_tokens(text):
    return int(math.ceil(len(text) / 4.0))


def fit_to_budget(seeds, blocks, budget):
    shed = {"AMBIGUOUS": 0, "INFERRED": 0}
    text = render(seeds, blocks, shed, None)
    if estimate_tokens(text) <= budget:
        return text
    for tier in SHED_TIERS:
        for block in blocks:
            before = len(block["items"])
            block["items"] = [i for i in block["items"] if i["confidence"] != tier]
            shed[tier] += before - len(block["items"])
        text = render(seeds, blocks, shed, None)
        if estimate_tokens(text) <= budget:
            return text
    # Final tier: keep the first `keep` items of every seed (highest-priority sections first).
    low, high = 0, max([len(b["items"]) for b in blocks] or [0])
    while low < high:
        mid = (low + high + 1) // 2
        if estimate_tokens(render(seeds, blocks, shed, mid)) <= budget:
            low = mid
        else:
            high = mid - 1
    return render(seeds, blocks, shed, low)


def build_blocks(seeds, nodes, links):
    by_id = {n.get("id"): n for n in nodes}
    outgoing, incoming = {}, {}
    for link in links:
        outgoing.setdefault(link.get("source"), []).append(link)
        incoming.setdefault(link.get("target"), []).append(link)

    blocks = []
    for seed in seeds:
        matches = match_seed(seed, nodes)
        if not matches:
            suggestions = suggest(seed, nodes)
            notes = ["suggestions: " + (", ".join(suggestions) if suggestions else "none")]
            collided = collisions(seed, nodes)
            if collided:
                notes.append(
                    "same node id as %s — graphify keeps one node per id, so this symbol has none; seed %s instead"
                    % (", ".join(collided), collided[0])
                )
            blocks.append({
                "header": "### %s - no match" % seed,
                "notes": notes,
                "items": [],
            })
            continue
        for index, node in enumerate(matches[:MAX_NODES_PER_SEED]):
            source = str(node.get("source_file") or "")
            where = "%s:%s" % (source, node.get("source_location") or "") if source else "external"
            notes = []
            if index == 0 and len(matches) > MAX_NODES_PER_SEED:
                notes.append("[%d more nodes labelled %s not shown]" % (len(matches) - MAX_NODES_PER_SEED, seed))
            blocks.append({
                "header": "### %s (%s)" % (label_of(node), where),
                "notes": notes,
                "items": neighbor_items(node, by_id, outgoing, incoming),
            })
    return blocks


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="map-slice.py",
        description="Print a compact, token-budgeted map of named symbols from a graphify graph.json.",
    )
    parser.add_argument("--graph", required=True, help="path to graphify graph.json")
    parser.add_argument("--budget", type=int, default=5000, help="token budget for the whole slice (default 5000)")
    parser.add_argument("seeds", nargs="+", help="exact symbol labels; commas also separate seeds")
    args = parser.parse_args(argv)
    if args.budget < 1:
        parser.error("--budget must be at least 1")

    seeds = []
    for arg in args.seeds:
        for seed in arg.split(","):
            seed = seed.strip()
            if seed and seed not in seeds:
                seeds.append(seed)
    if not seeds:
        parser.error("no seeds given")

    nodes, links = load_graph(args.graph)
    print(fit_to_budget(seeds, build_blocks(seeds, nodes, links), args.budget))
    return 0


if __name__ == "__main__":
    sys.exit(main())
