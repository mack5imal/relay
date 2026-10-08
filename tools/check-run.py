#!/usr/bin/env python3
"""check-run.py — check a finished relay run's transcripts against the orchestrator protocol.

Why: contextmeter measures a run (windows, peaks, tool costs), but the protocol rules the
orchestrator must follow — echo every hand-back verbatim before any tool call, record with
record-phase.sh, never read briefs / report files / subagent task output, never edit STATE.md
by hand, answer check-ins in one line — are only visible by walking the transcript record by
record. This script does that walk, plus per-subagent read hygiene and the order of the 0.10
checks (a phase marked `Review: yes` is reviewed before the run moves on, findings are followed
by their fix, the tidy-up and security pass run before the audit), and prints a verdict.

Usage:
    python3 tools/check-run.py <orchestrator.jsonl> <run-root>

    <orchestrator.jsonl>  the /goal session transcript; subagents are read from the sibling
                          <session-id>/subagents/ directory
    <run-root>            the run's artifact dir (absolute, or relative to the worktree the
                          run executed in), e.g. <project>/.relay/x-run-Ab3Kx9

    Exit 0 when no rule is violated, 1 when any is, 2 on a usage error. Warnings (deviations
    that do not break the protocol) never change the exit code.

Repo-only (not shipped in the plugin). Stdlib only.
"""

from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

MARKER_RE = re.compile(
    r"^\s*(RELAY_PHASE_START|RELAY_PHASE_VERIFY|RELAY_PHASE_DONE|RELAY_RUN_COMPLETE|MEMORY_SAVED"
    r"|FAILURE_PROBE|FAILURE_ESCALATE|FAILURE_HANDOFF"
    r"|AUDIT_START|AUDIT_VERIFY|AUDIT_GAPS|AUDIT_COMPLETE|AUDIT_HANDOFF|AUDIT_FIX"
    r"|REVIEW_START|REVIEW_CLEAN|REVIEW_FINDINGS|REVIEW_FIX|CLEANUP_START|CLEANUP_DONE"
    r"|SECURITY_START|SECURITY_CLEAN|SECURITY_FINDINGS|SECURITY_FIX)(?![A-Za-z0-9_])",
    re.M,
)
HANDBACK = "[Subagent hand-back]"
REPORT_INTRO = "The report follows:\n"
CANONICAL_PROMPT = "Read `{brief}` and follow it exactly."
FORBIDDEN_READ = re.compile(r"\.brief\.md|\.report\.md|/tasks/[^ ]*\.output|tool-results/")
BACKGROUNDED = "did not complete within"  # the harness's auto-background notice
# git writes only relay-git.sh may make: a subagent commits through it, the orchestrator only
# pushes through it (after AUDIT_COMPLETE). Matched at the start of a shell segment; the
# segment's arguments run to the next ; & | or newline. The orchestrator may make none of these
# (PROTOCOL.md); a subagent may stage, move, remove and restore files but never commit, push,
# stash, reset, rebase or change branch (PHASE-BRIEF.md). Read-only stash / branch / tag forms
# are let through for both.
RAW_GIT_WRITE = re.compile(
    r"(?:^|[;&|\n(]\s*)git\s+(?:(?:-C|-c)\s+\S+\s+)*"
    r"(commit|push|stash|switch|checkout|rebase|reset|restore|clean|merge|cherry-pick|revert|am|add|rm|mv|branch|tag)\b"
    r"([^;&|\n)]*)"
)
BRANCH_WRITE_OPTS = {"-d", "-D", "-m", "-M", "-c", "-C", "-f", "-u", "--delete", "--move", "--copy",
                     "--force", "--set-upstream-to", "--unset-upstream", "--edit-description"}


SUBAGENT_ALLOWED = {"add", "rm", "mv", "restore", "clean"}
CHECKOUT_BRANCH_OPTS = {"-b", "-B", "--orphan", "--detach"}


def raw_git_writes(cmd: str, subagent: bool = False) -> list[str]:
    """`git <sub>` writes in a shell command the role may not make, e.g. ["git commit"]."""
    hits = []
    for m in RAW_GIT_WRITE.finditer(cmd):
        sub, args = m.group(1), m.group(2).split()
        if subagent and (sub in SUBAGENT_ALLOWED
                         or (sub == "checkout" and not CHECKOUT_BRANCH_OPTS & set(args))):
            continue  # `git checkout <branch>` is indistinguishable from a file checkout here
        if sub == "stash" and args and args[0] in ("list", "show"):
            continue
        if sub == "branch" and ("--list" in args or "-l" in args or "--show-current" in args
                                or (all(a.startswith("-") for a in args)
                                    and not BRANCH_WRITE_OPTS & {a.split("=")[0] for a in args})):
            continue
        if sub == "tag" and (not args or "-l" in args or "--list" in args):
            continue
        hits.append(f"git {sub}")
    return hits


def whole_file_cats(cmd: str) -> list[str]:
    """`cat <file>` segments that print a whole file into the window (not heredocs, not
    redirected into another file, not the window's own brief)."""
    hits = []
    for seg in re.split(r"&&|\|\||[;|\n]", cmd):
        seg = seg.strip()
        m = re.match(r"(?:cat|bat)\s+(.+)$", seg)
        if not m or "<<" in seg or ">" in seg:
            continue
        files = [w for w in m.group(1).split() if not w.startswith("-")]
        files = [w for w in files if not w.endswith(".brief.md")]
        if files:
            hits.append(seg[:100])
    return hits


def changes_directory(cmd: str) -> list[str]:
    """Command segments that change the shell's directory (`cd` / `pushd`). The orchestrator
    must stay where the session started: a subagent inherits its directory, and on three
    runs its first command moved from the worktree into the main checkout."""
    hits = []
    for seg in re.split(r"&&|\|\||[;|\n(]", cmd):
        seg = seg.strip()
        if re.match(r"(?:cd|pushd)(?:\s|$)", seg):
            hits.append(seg[:100])
    return hits


@dataclass
class Findings:
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)

    def err(self, msg: str) -> None:
        self.errors.append(msg)

    def warn(self, msg: str) -> None:
        self.warnings.append(msg)

    def note(self, msg: str) -> None:
        self.notes.append(msg)


def load(path: Path) -> list[tuple[int, dict]]:
    out = []
    for i, line in enumerate(path.open(encoding="utf-8"), 1):
        try:
            out.append((i, json.loads(line)))
        except json.JSONDecodeError:
            continue
    return out


def content_items(rec: dict) -> list[dict]:
    msg = rec.get("message") or {}
    c = msg.get("content")
    if isinstance(c, str):
        return [{"type": "text", "text": c}]
    return [x for x in c if isinstance(x, dict)] if isinstance(c, list) else []


def markers(text: str) -> list[str]:
    return MARKER_RE.findall(text)


def report_from_handback(text: str) -> str:
    body = text.split(REPORT_INTRO, 1)[1] if REPORT_INTRO in text else text
    body = body.split("\n</agent-message>")[0]
    lines = [ln[2:] if ln.startswith("  ") else ln for ln in body.split("\n")]
    return "\n".join(lines).strip("\n")


def norm(text: str) -> str:
    return "\n".join(ln.rstrip() for ln in text.strip("\n").split("\n"))


def block_span(text: str) -> tuple[str, str, str]:
    """(prose before first marker, blocks from first marker to end, '')."""
    m = MARKER_RE.search(text)
    if not m:
        return text, "", ""
    return text[: m.start()], text[m.start():], ""


def tool_input_text(item: dict) -> str:
    inp = item.get("input") or {}
    return inp.get("command") or inp.get("file_path") or inp.get("prompt") or json.dumps(inp)


# --- orchestrator ---------------------------------------------------------------------------


@dataclass
class Turn:
    """Assistant content between two real user messages (tool results do not split a turn)."""

    trigger_line: int
    trigger: str
    items: list[tuple[int, dict]] = field(default_factory=list)


def orchestrator_turns(recs: list[tuple[int, dict]]) -> list[Turn]:
    turns: list[Turn] = []
    cur: Turn | None = None
    for line, rec in recs:
        kind = rec.get("type")
        if kind == "user":
            items = content_items(rec)
            if items and all(x.get("type") == "tool_result" for x in items):
                continue
            text = "".join(x.get("text", "") for x in items if x.get("type") == "text")
            cur = Turn(line, text)
            turns.append(cur)
        elif kind == "assistant" and cur is not None:
            for it in content_items(rec):
                if it.get("type") in ("text", "tool_use"):
                    cur.items.append((line, it))
    return turns


def record_mode_for(description: str) -> str | None:
    """Expected record-phase.sh argument tail for an Agent description."""
    m = re.fullmatch(r"Relay phase (\d+) fix", description)
    if m:
        return rf"\s{m.group(1)}\s+--fix\b"
    m = re.fullmatch(r"Relay phase (\d+) review fix", description)
    if m:
        return rf"\s{m.group(1)}\s+--review-fix\b"
    m = re.fullmatch(r"Relay phase (\d+) review", description)
    if m:
        return rf"\s{m.group(1)}\s+--review(?![\w-])"
    m = re.fullmatch(r"Relay phase (\d+)", description)
    if m:
        return rf"\s{m.group(1)}(?!\d)(?!\s+--(?:fix|review))"
    if description == "Relay cleanup":
        return r"\s--cleanup\b"
    if description == "Relay security pass":
        return r"\s--security(?![\w-])"
    if description == "Relay security fix":
        return r"\s--security-fix\b"
    m = re.fullmatch(r"Relay audit round (\d+)", description)
    if m:
        return rf"\s--audit\s+{m.group(1)}\b"
    m = re.fullmatch(r"Relay audit fix (\d+)", description)
    if m:
        return rf"\s--audit-fix\s+{m.group(1)}\b"
    return None


def step_rules(run_root: Path) -> tuple[dict[int, bool], bool | None, bool | None]:
    """What the run's plan asks for: {phase: review?}, cleanup on?, security on?  A phase with
    no `Review:` line, and a STATE.md without the fields (runs planned before 0.10, the
    hand-authored run roots), gives None / no entry — no rule."""
    reviews: dict[int, bool] = {}
    for spec in sorted((run_root / "phases").glob("phase-*.md")):
        m = re.fullmatch(r"phase-(\d+)\.md", spec.name)
        if not m:
            continue
        line = re.search(r"^Review:\s*(.*?)\s*$", spec.read_text(encoding="utf-8"), re.M)
        if line:
            reviews[int(m.group(1))] = line.group(1).lower() == "yes"
    state_path = run_root / "STATE.md"
    state = state_path.read_text(encoding="utf-8") if state_path.exists() else ""

    def field(name: str) -> str | None:
        fm = re.search(rf"^\*\*{re.escape(name)}:\*\*\s*(.*?)\s*(?:<!--.*)?$", state, re.M)
        return fm.group(1).lower() if fm else None

    cleanup, security = field("Cleanup"), field("Security pass")
    return (reviews,
            None if cleanup is None else cleanup.split(" ")[0] == "on",
            None if security is None else security.split(" ")[0] == "yes")


def check_steps(events: list[tuple[str, object]], run_root: Path) -> list[str]:
    """Order violations of the 0.10 checks. `events` is the orchestrator's timeline in order:
    ("dispatch", <Agent description>) and ("echo", [marker names in one echoed text])."""
    reviews, cleanup_on, security_on = step_rules(run_root)
    errors: list[str] = []
    dispatches: list[str] = []
    for kind, val in events:
        if kind == "dispatch" and (not dispatches or dispatches[-1] != val):
            dispatches.append(str(val))  # a re-dispatch of the same step is one step

    def phase_of(desc: str) -> int | None:
        m = re.fullmatch(r"Relay phase (\d+)(?: fix)?", desc)
        return int(m.group(1)) if m else None

    for n, wanted in sorted(reviews.items()):
        if not wanted:
            continue
        own = [i for i, d in enumerate(dispatches) if phase_of(d) == n]
        if not own:
            continue
        later = [d for d in dispatches[own[-1] + 1:] if phase_of(d) != n]
        if later and later[0] not in (f"Relay phase {n} review",):
            errors.append(f"phase {n} says Review: yes, but {later[0]!r} was dispatched before its review")

    # A FINDINGS echo must be followed by its fix window, before any other step.
    for i, (kind, val) in enumerate(events):
        if kind != "echo":
            continue
        marks = val if isinstance(val, list) else []
        for marker, fix in (("REVIEW_FINDINGS", r"Relay phase \d+ review fix"), ("SECURITY_FINDINGS", r"Relay security fix")):
            if marker not in marks:
                continue
            nxt = next((v for k, v in events[i + 1:] if k == "dispatch"), None)
            if nxt is not None and not re.fullmatch(fix, str(nxt)):
                errors.append(f"{marker} was echoed, but the next dispatch was {nxt!r}, not its fix")

    def first(desc: str) -> int | None:
        return next((i for i, d in enumerate(dispatches) if d == desc), None)

    cleanup_i, security_i, audit_i = first("Relay cleanup"), first("Relay security pass"), first("Relay audit round 1")
    if cleanup_on:
        after = [i for i in (security_i, audit_i) if i is not None]
        if after and (cleanup_i is None or cleanup_i > min(after)):
            errors.append("STATE.md says Cleanup: on, but no tidy-up was dispatched before the security pass / audit")
    if security_on and audit_i is not None and (security_i is None or security_i > audit_i):
        errors.append("STATE.md says Security pass: yes, but no security pass was dispatched before audit round 1")
    if cleanup_i is not None and security_i is not None and cleanup_i > security_i:
        errors.append("the tidy-up was dispatched after the security pass (order: cleanup → security → audit)")
    return errors


def check_orchestrator(recs: list[tuple[int, dict]], run_root: Path, f: Findings) -> dict[str, dict]:
    agents: dict[str, dict] = {}  # tool_use_id -> {description, prompt, line}
    events: list[tuple[str, object]] = []  # dispatches and echoed markers, in order (check_steps)
    state_read_seen = False
    audit_complete_seen = False
    pushed = False
    for line, rec in recs:
        if rec.get("type") != "assistant":
            continue
        for it in content_items(rec):
            if it.get("type") == "text" and markers(it.get("text", "")):
                events.append(("echo", markers(it.get("text", ""))))
            if it.get("type") == "text" and "AUDIT_COMPLETE" in markers(it.get("text", "")):
                audit_complete_seen = True
            if it.get("type") != "tool_use":
                continue
            name, inp = it.get("name"), it.get("input") or {}
            text = tool_input_text(it)
            if name == "Agent":
                agents[it["id"]] = {"description": inp.get("description", ""), "prompt": inp.get("prompt", ""), "line": line}
                events.append(("dispatch", inp.get("description", "")))
                m = re.search(r"`([^`]*\.brief\.md)`", inp.get("prompt", ""))
                brief = m.group(1) if m else None
                if not brief or CANONICAL_PROMPT.format(brief=brief) not in inp.get("prompt", ""):
                    f.err(f"line {line}: Agent prompt for {inp.get('description')!r} lacks the protocol's brief instruction")
                elif not inp.get("prompt", "").lstrip().startswith("Read `"):
                    f.warn(f"line {line}: Agent prompt for {inp.get('description')!r} adds text to the protocol prompt: {inp['prompt'].split(chr(10))[0][:120]!r}")
            if name in ("Edit", "Write", "NotebookEdit") and str(inp.get("file_path", "")).endswith("STATE.md"):
                if not (name == "Write" and False):
                    f.err(f"line {line}: {name} on STATE.md — only record-phase.sh may change it")
            if name == "Write" and str(inp.get("file_path", "")).endswith(".report.md"):
                f.warn(f"line {line}: orchestrator wrote a report file (the 'report not found' fallback): {inp['file_path']}")
            if name == "Bash":
                cmd = inp.get("command", "")
                scrubbed = re.sub(r"\S*(assemble-brief|record-phase)\.sh[^;&|\n]*", "", cmd)
                if FORBIDDEN_READ.search(scrubbed):
                    f.err(f"line {line}: orchestrator Bash touches a brief / report / task output / tool-results: {cmd[:160]!r}")
                if "STATE.md" in scrubbed:
                    if re.search(r">\s*\S*STATE\.md|sed\s+-i|perl\s+-p?i|open\([^)]*STATE\.md[^)]*['\"]w|tee\s+\S*STATE\.md|\.write\(", cmd):
                        f.err(f"line {line}: Bash writes STATE.md outside record-phase.sh: {cmd[:160]!r}")
                    elif re.search(r"grep[^\n]*Notable events", cmd):
                        pass
                    elif not state_read_seen:
                        state_read_seen = True
                    else:
                        f.warn(f"line {line}: Bash reads STATE.md again (protocol: once at start, then grep Notable events at completion): {cmd[:120]!r}")
                for hit in changes_directory(cmd):
                    f.err(f"line {line}: orchestrator changes directory (the /goal line and PROTOCOL.md: never cd elsewhere): {hit!r}")
                for w in raw_git_writes(cmd):
                    f.err(f"line {line}: orchestrator runs {w} — subagents commit via relay-git.sh; the orchestrator only pushes: {cmd[:120]!r}")
                if re.search(r"relay-git\.sh\s+commit", cmd):
                    f.err(f"line {line}: orchestrator runs relay-git.sh commit — committing is the subagent's job")
                if re.search(r"relay-git\.sh\s+push", cmd):
                    pushed = True
                    if not audit_complete_seen:
                        f.err(f"line {line}: relay-git.sh push before AUDIT_COMPLETE was echoed")
                    else:
                        f.note(f"line {line}: relay-git.sh push after AUDIT_COMPLETE")
            if name == "Read":
                path = str(inp.get("file_path", ""))
                if FORBIDDEN_READ.search(path):
                    f.err(f"line {line}: orchestrator Read of {path}")
                elif not path.endswith(("PROTOCOL.md", "STATE.md")):
                    f.warn(f"line {line}: orchestrator Read of {path}")
            if name == "TaskStop":
                f.note(f"line {line}: TaskStop {inp}")

    turns = orchestrator_turns(recs)
    for line, rec in recs:
        att = rec.get("attachment") or {}
        if att.get("type") == "queued_command" and "<task-notification>" in (att.get("prompt") or ""):
            f.note(f"line {line}: task notification queued mid-turn (no reply needed): {re.search(r'<summary>(.*?)</summary>', att['prompt']).group(1) if '<summary>' in att['prompt'] else '?'}")
    echoed_done = 0
    # After an interruption (0.11): a turn that starts while a hand-back is still outstanding,
    # on anything but that hand-back, a check-in or a task notification (the user's "continue"
    # in a reopened session), must run recover.sh before anything else. Only for run roots that
    # carry recover.sh — runs planned before 0.11 have no such step.
    has_recover = (run_root / "recover.sh").exists()
    outstanding = 0
    for turn in turns:
        trig = turn.trigger
        texts = [(ln, it["text"]) for ln, it in turn.items if it["type"] == "text"]
        tools = [(ln, it) for ln, it in turn.items if it["type"] == "tool_use"]
        bash_cmds = [it["input"].get("command", "") for _, it in tools if it["name"] == "Bash"]
        recovered = any("recover.sh" in c for c in bash_cmds)
        # Claude Code's notice for an agent the previous session left running ("didn't finish
        # before the previous session ended", <status>stopped</status>) is an interruption signal
        stopped_notice = "<task-notification>" in trig and "<status>stopped</status>" in trig
        is_other = (HANDBACK not in trig and "Goal check-in" not in trig
                    and (stopped_notice or "<task-notification>" not in trig))
        if HANDBACK in trig:
            outstanding = max(0, outstanding - 1)
        elif is_other and outstanding > 0 and has_recover and tools:
            # a turn that does nothing is harmless; one that acts must settle the dispatch first
            first_tool = tools[0][1]
            if not (first_tool["name"] == "Bash" and "recover.sh" in first_tool["input"].get("command", "")):
                f.err(f"turn line {turn.trigger_line}: started while waiting on a hand-back, but recover.sh was not run first")
            else:
                f.note(f"turn line {turn.trigger_line}: recover.sh run after an interruption")
        for _, it in tools:
            if it["name"] == "SendMessage" and has_recover:
                f.err(f"turn line {turn.trigger_line}: SendMessage from the orchestrator — never revive a stopped Relay agent; recover.sh re-dispatches it")
        if recovered:
            outstanding = 0
            # a report recover.sh found on disk is echoed here, not in a hand-back turn
            done_here = sum(markers(t).count("RELAY_PHASE_DONE") for _, t in texts)
            echoed_done += done_here
            if done_here and not any("record-phase.sh" in c for c in bash_cmds):
                f.err(f"turn line {turn.trigger_line}: echoed a recovered report but never recorded it")
        outstanding += sum(1 for _, it in tools if it["name"] == "Agent")
        if HANDBACK in trig:
            report = report_from_handback(trig)
            m = re.search(r'<agent-message from="([^"]+)"', trig)
            agent_id = m.group(1) if m else "?"
            rmarks = markers(report)
            where = f"hand-back line {turn.trigger_line} ({agent_id})"
            record_calls = [(ln, it) for ln, it in tools if it["name"] == "Bash" and "record-phase.sh" in it["input"].get("command", "")]
            if not rmarks:
                printed = [m for _, t in texts for m in markers(t)]
                authored_handoff = printed and set(printed) <= {"FAILURE_HANDOFF", "AUDIT_HANDOFF"}
                if printed and not authored_handoff:
                    f.err(f"{where}: report had no blocks but the reply printed {printed}")
                if authored_handoff:
                    f.note(f"{where}: orchestrator authored {printed[0]} after the second no-report")
                if not any(re.search(r"--(no-report|interrupted)\b", it["input"]["command"]) for _, it in record_calls):
                    f.err(f"{where}: no-report hand-back not recorded with record-phase.sh --no-report (or --interrupted, for an API error)")
                f.note(f"{where}: no-report hand-back → {'recorded' if record_calls else 'NOT recorded'}")
                continue
            echoes = [(ln, t) for ln, t in texts if set(markers(t)) & set(rmarks)]
            if not echoes:
                f.err(f"{where}: report with {len(rmarks)} blocks was never echoed")
                continue
            if len(echoes) > 1:
                f.err(f"{where}: report echoed {len(echoes)} times")
            first_ln, first = echoes[0]
            before_tools = [it for ln, it in turn.items[: [i for i, (ln, it) in enumerate(turn.items) if it.get("type") == "text" and it.get("text") == first][0]] if it["type"] == "tool_use"]
            if before_tools:
                f.err(f"{where}: {len(before_tools)} tool call(s) before the echo ({', '.join(t['name'] for t in before_tools)})")
            prose_before_items = [it for ln, it in turn.items[: [i for i, (ln, it) in enumerate(turn.items) if it.get("type") == "text" and it.get("text") == first][0]] if it["type"] == "text"]
            if prose_before_items:
                f.warn(f"{where}: prose before the echo: {prose_before_items[0]['text'][:80]!r}")
            pre, blocks, _ = block_span(first)
            if pre.strip():
                f.warn(f"{where}: prose before the first marker inside the echo: {pre.strip()[:80]!r}")
            if norm(blocks) != norm(report):
                if norm(report) in norm(blocks):
                    f.err(f"{where}: echo adds text after the report: {norm(blocks)[len(norm(report)):].strip()[:80]!r}")
                elif markers(blocks) != rmarks:
                    f.err(f"{where}: echo blocks {markers(blocks)} differ from report blocks {rmarks}")
                else:
                    f.err(f"{where}: echo text differs from the report (same blocks; content or indentation changed)")
            if "RELAY_PHASE_DONE" in rmarks:
                echoed_done += 1
            # recording after the echo, right mode
            agent = next((a for a in agents.values() if a.get("agent_id") == agent_id), None)
            if not record_calls:
                f.err(f"{where}: echoed but never recorded with record-phase.sh in the same turn")
            else:
                desc = agent["description"] if agent else None
                pat = record_mode_for(desc) if desc else None
                cmd = record_calls[0][1]["input"]["command"]
                if pat and not re.search(pat, cmd.split("record-phase.sh", 1)[1]):
                    f.err(f"{where}: record-phase.sh mode does not match dispatch {desc!r}: {cmd[:120]!r}")
                f.note(f"{where}: echoed {rmarks} → {cmd.split('record-phase.sh', 1)[1].split(';')[0].strip()[:90]}")
        elif "Goal check-in" in trig:
            listed_sub = "· subagent ·" in trig
            stops = [it for _, it in tools if it["name"] == "TaskStop"]
            other = [it for _, it in tools if it["name"] != "TaskStop"]
            lines = sum(len([x for x in t.split("\n") if x.strip()]) for _, t in texts)
            if listed_sub and tools:
                f.err(f"check-in line {turn.trigger_line}: a subagent was listed but the reply made {len(tools)} tool call(s)")
            if not listed_sub and other:
                f.err(f"check-in line {turn.trigger_line}: reply made non-TaskStop tool calls: {[t['name'] for t in other]}")
            if lines > 1:
                f.warn(f"check-in line {turn.trigger_line}: reply is {lines} lines, not one")
            f.note(f"check-in line {turn.trigger_line}: subagent listed={listed_sub}, TaskStop={len(stops)}, reply lines={lines}")
        elif "<task-notification>" in trig and "finished" in trig:
            if tools:
                f.warn(f"task notification line {turn.trigger_line}: reply made {len(tools)} tool call(s)")

    for e in check_steps(events, run_root):
        f.err(e)
    return {"agents": agents, "echoed_done": echoed_done, "pushed": pushed}


# --- subagents ------------------------------------------------------------------------------


def check_subagents(session_dir: Path, run_root: Path, f: Findings) -> list[dict]:
    rows = []
    sub_dir = session_dir / "subagents"
    for path in sorted(sub_dir.glob("agent-*.jsonl"), key=lambda p: p.stat().st_mtime):
        meta_path = path.with_suffix(".meta.json")
        meta = json.loads(meta_path.read_text()) if meta_path.exists() else {}
        desc = meta.get("description", path.stem)
        peak, requests = 0, set()
        bash = run_logged = cats = tool_results = backgrounded = denied = 0
        raw_git: list[str] = []
        relay_commits = 0
        reports_written: list[tuple[str, str]] = []
        cat_hits: list[str] = []
        uses: dict[str, dict] = {}
        final_text = ""
        handback_text: str | None = None
        for _, rec in load(path):
            msg = rec.get("message") or {}
            if rec.get("type") == "assistant":
                u = msg.get("usage") or {}
                if u:
                    requests.add(msg.get("id"))
                    peak = max(peak, u.get("input_tokens", 0) + u.get("cache_read_input_tokens", 0) + u.get("cache_creation_input_tokens", 0))
            for it in content_items(rec):
                t = it.get("type")
                if t == "tool_use":
                    uses[it["id"]] = it
                    name, inp = it.get("name"), it.get("input") or {}
                    if name == "Bash":
                        bash += 1
                        cmd = inp.get("command", "")
                        run_logged += "run-logged.sh" in cmd
                        relay_commits += bool(re.search(r"relay-git\.sh\s+commit", cmd))
                        raw_git.extend(raw_git_writes(cmd, subagent=True))
                        for hit in whole_file_cats(cmd):
                            cats += 1
                            cat_hits.append(hit)
                        if re.search(r"cat\s*>>?\s*\S*\.report\.md|>\s*\S*\.report\.md", cmd):
                            reports_written.append(("bash", cmd))
                        tool_results += "tool-results/" in cmd or "/tasks/" in cmd
                    if name == "Read":
                        tool_results += "tool-results/" in str(inp.get("file_path", "")) or "/tasks/" in str(inp.get("file_path", ""))
                    if name == "Write" and str(inp.get("file_path", "")).endswith(".report.md"):
                        reports_written.append(("write", inp.get("content", "")))
                    if name == "SubagentHandback":
                        handback_text = inp.get("message") or ""
                elif t == "tool_result":
                    s = json.dumps(it.get("content"))
                    backgrounded += BACKGROUNDED in s
                    denied += bool(it.get("is_error") and "denied" in s)
                elif t == "text" and rec.get("type") == "assistant":
                    final_text = it.get("text", "")
        # The hand-back tool call is what the orchestrator receives; text after it is chatter.
        if handback_text is not None:
            final_text = handback_text
        rmarks = markers(final_text)
        row = dict(desc=desc, peak=peak, requests=len(requests), bash=bash, run_logged=run_logged, cats=cats,
                   tool_results=tool_results, backgrounded=backgrounded, denied=denied, blocks=len(rmarks),
                   report_file=bool(reports_written))
        rows.append(row)
        if tool_results:
            f.err(f"subagent {desc!r}: {tool_results} read(s) of tool-results/ or tasks/*.output")
        if raw_git:
            f.err(f"subagent {desc!r}: ran {', '.join(sorted(set(raw_git)))} itself — relay-git.sh commit is the only way a subagent commits, and it never changes branch")
        if "RELAY_PHASE_DONE" in rmarks and not relay_commits:
            f.warn(f"subagent {desc!r}: reported RELAY_PHASE_DONE without running relay-git.sh commit")
        if backgrounded:
            f.warn(f"subagent {desc!r}: {backgrounded} Bash call(s) moved to the background")
        if cats:
            f.warn(f"subagent {desc!r}: {cats} whole-file cat(s): {'; '.join(repr(h) for h in cat_hits[:4])}")
        if rmarks and not reports_written:
            f.err(f"subagent {desc!r}: returned marker blocks but never wrote a .report.md")
        if reports_written:
            how, body = reports_written[-1]
            if how == "bash":
                f.warn(f"subagent {desc!r}: wrote its .report.md with a Bash redirect/heredoc, not the Write tool")
            else:
                _, blocks, _ = block_span(final_text)
                if rmarks and norm(body) != norm(blocks):
                    f.warn(f"subagent {desc!r}: last .report.md write differs from its final message")
        if not rmarks and reports_written:
            f.warn(f"subagent {desc!r}: returned no blocks but wrote a .report.md")
    return rows


# --- end state ------------------------------------------------------------------------------


def check_end_state(recs: list[tuple[int, dict]], run_root: Path, echoed_done: int, f: Findings,
                    pushed: bool = False) -> None:
    state_path = run_root / "STATE.md"
    if not state_path.exists():
        f.err(f"STATE.md not found at {state_path}")
        return
    state = state_path.read_text()
    status = re.search(r"^\*\*Status:\*\*\s*(\S+)", state, re.M)
    status = status.group(1) if status else "?"
    rows = re.findall(r"^\|\s*(\d+)\s*\|[^|]*\|\s*([a-z_]+)\s*\|", state, re.M)
    total = len(rows)
    assistant_text = "\n".join(it["text"] for _, r in recs if r.get("type") == "assistant" for it in content_items(r) if it.get("type") == "text")
    all_marks = markers(assistant_text)
    run_complete = "RELAY_RUN_COMPLETE" in all_marks
    handoff = [m for m in all_marks if m in ("FAILURE_HANDOFF", "AUDIT_HANDOFF")]
    f.note(f"STATE.md: Status {status}; rows {rows}; echoed RELAY_PHASE_DONE {echoed_done}; RELAY_RUN_COMPLETE {'yes' if run_complete else 'no'}; handoffs {handoff or 'none'}")
    if run_complete:
        if status != "COMPLETE":
            f.err(f"RELAY_RUN_COMPLETE printed but STATE.md Status is {status}")
        if "AUDIT_COMPLETE" not in all_marks[: all_marks.index("RELAY_RUN_COMPLETE")]:
            f.err("RELAY_RUN_COMPLETE printed without a preceding AUDIT_COMPLETE")
        if echoed_done != total:
            f.err(f"RELAY_RUN_COMPLETE with {echoed_done} echoed RELAY_PHASE_DONE for {total} phases")
        if handoff:
            f.err(f"RELAY_RUN_COMPLETE despite {handoff}")
    branch = re.search(r"^\*\*Branch:\*\*\s*(.+?)\s*(?:<!--.*)?$", state, re.M)
    branch = branch.group(1) if branch else ""
    if branch and branch != "no-git":
        uncommitted = [n for n, st in rows if st == "completed"
                       and "Commit:" not in (re.search(rf"^\|\s*{n}\s*\|.*$", state, re.M) or [""])[0]]
        if uncommitted:
            f.warn(f"completed phase row(s) {uncommitted} carry no Commit: sha (branch {branch})")
    push_field = re.search(r"^\*\*Push:\*\*\s*(.*?)\s*(?:<!--.*)?$", state, re.M)
    push_off = bool(push_field) and push_field.group(1).lower().startswith("off")
    if run_complete and not pushed:
        # The push is the one step nothing but the orchestrator enforces. relay-git.sh push
        # skips itself on the owner's branch and when **Push:** is off, so it always runs;
        # missing it on a branch relay created with push on (or no Push: field — runs planned
        # before 0.11) leaves the owner's reviewable branch local.
        if "(created by relay" in branch and push_off:
            f.warn("RELAY_RUN_COMPLETE without running relay-git.sh push (push is off; its skipped line hands the owner the command)")
        elif "(created by relay" in branch:
            f.err(f"RELAY_RUN_COMPLETE without running relay-git.sh push (branch {branch})")
        elif branch and branch != "no-git":
            f.warn("RELAY_RUN_COMPLETE without running relay-git.sh push (it would have skipped the owner's branch)")
    if run_complete:
        complete_block = assistant_text.split("RELAY_RUN_COMPLETE")[-1]
        if not re.search(r"^\s*Push:\s*push:", complete_block, re.M):
            f.warn("RELAY_RUN_COMPLETE has no `Push:` line carrying relay-git.sh push's output")
    if handoff and status != "BLOCKED":
        f.err(f"{handoff[0]} printed but STATE.md Status is {status}")
    if status == "BLOCKED" and not handoff:
        f.err("STATE.md is BLOCKED but no FAILURE_HANDOFF / AUDIT_HANDOFF was printed")
    if status == "BLOCKED" and handoff:
        after = assistant_text.split(handoff[-1])[-1]
        f.note(f"after the last handoff the orchestrator wrote {len(after.strip())} more characters")


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__.split("Usage:")[1].split("Repo-only")[0].rstrip(), file=sys.stderr)
        return 2
    transcript = Path(argv[1]).expanduser()
    run_root = Path(argv[2]).expanduser()
    if not transcript.is_file():
        print(f"check-run.py: no transcript at {transcript}", file=sys.stderr)
        return 2
    recs = load(transcript)
    if not run_root.is_absolute() or not run_root.exists():
        cwd = next((r.get("cwd") for _, r in recs if r.get("cwd")), None)
        if cwd and (Path(cwd) / argv[2]).exists():
            run_root = Path(cwd) / argv[2]
    if not run_root.is_dir():
        print(f"check-run.py: no run root at {run_root}", file=sys.stderr)
        return 2

    f = Findings()
    orch = check_orchestrator(recs, run_root, f)
    session_dir = transcript.with_suffix("")
    rows = check_subagents(session_dir, run_root, f) if (session_dir / "subagents").is_dir() else []
    check_end_state(recs, run_root, orch["echoed_done"], f, orch["pushed"])

    peak = 0
    reqs = set()
    for _, r in recs:
        u = (r.get("message") or {}).get("usage") or {}
        if r.get("type") == "assistant" and u:
            reqs.add(r["message"].get("id"))
            peak = max(peak, u.get("input_tokens", 0) + u.get("cache_read_input_tokens", 0) + u.get("cache_creation_input_tokens", 0))

    print(f"Run: {run_root}")
    print(f"Orchestrator: {len(reqs)} requests, peak {peak:,} tokens, {len(orch['agents'])} dispatches\n")
    print("Subagents")
    hdr = f"  {'dispatch':<22} {'peak':>8} {'reqs':>4} {'bash':>4} {'logged':>6} {'cats':>4} {'bg':>2} {'deny':>4} {'blocks':>6} {'report':>6}"
    print(hdr)
    for r in rows:
        print(f"  {r['desc']:<22} {r['peak']:>8,} {r['requests']:>4} {r['bash']:>4} {r['run_logged']:>6} {r['cats']:>4} {r['backgrounded']:>2} {r['denied']:>4} {r['blocks']:>6} {'yes' if r['report_file'] else 'no':>6}")
    print("\nSequence")
    for n in f.notes:
        print(f"  · {n}")
    print(f"\nWarnings ({len(f.warnings)})")
    for w in f.warnings:
        print(f"  ! {w}")
    print(f"\nViolations ({len(f.errors)})")
    for e in f.errors:
        print(f"  ✗ {e}")
    print("\nResult:", "PASS" if not f.errors else "FAIL")
    return 0 if not f.errors else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
