#!/usr/bin/env python3
"""run-report.py - one readable digest of a finished Relay run.

Why: after a run there are three separate sources of truth and no single view of them.
check-run.py says whether the orchestrator followed the protocol, contextmeter says what the
windows cost, and the run root holds what actually happened - which phases retried, what the
probe hypotheses were, which criteria the audit could not re-verify. Reading all three by hand
is why a long run's lessons get skimmed. This merges them.

The emphasis is development signal, not token accounting. The questions it answers first are
"where did this run struggle, and what does that say about the plan?" - retries, escalations,
no-report dispatches, audit rounds, and above all which criteria came back trust-prior, because
those are the parts of the plan the audit could not actually check. Window sizes come last.

Usage:
  python3 tools/run-report.py <run-root> [orchestrator.jsonl] [--json] [--contextmeter DIR]

  With a transcript, protocol conformance (check-run.py) and, if contextmeter is available,
  window metrics are folded in. Without one, everything that can be read from the run root is
  still reported. Exit 0 when the run looks clean, 1 when it recorded a failure, blocked state,
  or protocol violation, 2 on a usage error.

Repo-only (not shipped in the plugin). Stdlib only.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


# --- STATE.md ------------------------------------------------------------------------------

def field(state: str, name: str) -> str:
    m = re.search(rf"^\*\*{re.escape(name)}:\*\*[ \t]*(.*?)[ \t]*(?:<!--.*)?$", state, re.M)
    return m.group(1).strip() if m else ""


def section(state: str, heading: str) -> list[str]:
    out, inside = [], False
    for line in state.splitlines():
        if line.startswith("## "):
            inside = line.strip().lower() == f"## {heading}".lower()
            continue
        if inside and line.strip():
            out.append(line.rstrip())
    return out


def phase_rows(state: str) -> list[dict]:
    rows = []
    for line in section(state, "Phase progress"):
        if not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.split("|")[1:-1]]
        if len(cells) < 6 or not cells[0].isdigit():
            continue
        rows.append({"n": int(cells[0]), "name": cells[1], "status": cells[2],
                     "started": cells[3], "completed": cells[4], "notes": cells[5]})
    return rows


# --- evidence files ------------------------------------------------------------------------

def evidence_findings(run_root: Path) -> tuple[list[dict], list[dict]]:
    """Failed criteria (with the probe hypothesis when one was recorded), and attempt counts."""
    failures, attempts = [], []
    for path in sorted(run_root.glob("phases/phase-*.evidence.md")):
        m = re.search(r"phase-(\d+)\.evidence\.md$", path.name)
        if not m:
            continue
        n = int(m.group(1))
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        n_attempts = len(re.findall(r"^##[ \t]+Attempt\b", text, re.M))
        n_fix = len(re.findall(r"^##[ \t]+Fix attempt\b", text, re.M))
        attempts.append({"phase": n, "attempts": n_attempts, "fix": n_fix})

        # "#### C3 <criterion>" followed by "Result: fail"
        for cm in re.finditer(r"^####[ \t]+(C\d+[^\n]*)\n(.*?)(?=^####|\Z)", text, re.M | re.S):
            if re.search(r"^Result:[ \t]*fail\b", cm.group(2), re.M | re.I):
                failures.append({"phase": n, "criterion": cm.group(1).strip(), "hypothesis": ""})
        for pm in re.finditer(r"^###[ \t]+Failure probe\b(.*?)(?=^###|\Z)", text, re.M | re.S):
            hyp = re.search(r"^Hypothesis:[ \t]*(.+)$", pm.group(1), re.M)
            if hyp:
                for f in failures:
                    if f["phase"] == n and not f["hypothesis"]:
                        f["hypothesis"] = hyp.group(1).strip()
                        break
    return failures, attempts


def trust_prior(run_root: Path) -> list[dict]:
    """Criteria the audit could not re-verify. These are the plan-quality signal."""
    out = []
    for path in sorted(run_root.glob("phases/audit-*.evidence.md")):
        rnd = re.search(r"audit-(\d+)\.evidence\.md$", path.name)
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for line in text.splitlines():
            # Only a criterion whose RESULT is trust-prior-verify counts. An audit evidence
            # file also explains the term in prose and reports a "0 trust-prior-verify" total;
            # matching the bare substring turns both of those into phantom findings.
            if (re.search(r"Result:[ \t]*`?trust-prior-verify`?", line, re.I)
                    or re.search(r":[ \t]*`?trust-prior-verify`?[ \t]*$", line, re.I)):
                out.append({"round": int(rnd.group(1)) if rnd else 0,
                            "text": line.strip().lstrip("-* ").strip()})
    return out


# --- external tools ------------------------------------------------------------------------

def run_check(transcript: Path, run_root: Path) -> dict | None:
    script = HERE / "check-run.py"
    if not script.exists():
        return None
    try:
        p = subprocess.run([sys.executable, str(script), str(transcript), str(run_root)],
                           capture_output=True, text=True, timeout=300)
    except (OSError, subprocess.SubprocessError) as exc:
        return {"ok": False, "error": str(exc), "violations": [], "warnings": [], "raw": ""}
    out = p.stdout
    viol = re.findall(r"^\s*✗ (.+)$", out, re.M)
    warn = re.findall(r"^\s*! (.+)$", out, re.M)
    peak = re.search(r"peak ([\d,]+) tokens", out)
    return {"ok": p.returncode == 0, "violations": viol, "warnings": warn,
            "orchestrator_peak": peak.group(1) if peak else "", "raw": out}


def run_contextmeter(transcript: Path, directory: str | None) -> str:
    if not directory:
        return ""
    try:
        p = subprocess.run(["uv", "--directory", directory, "run", "contextmeter",
                            str(transcript), "--relay"],
                           capture_output=True, text=True, timeout=600)
    except (OSError, subprocess.SubprocessError):
        return ""
    return p.stdout if p.returncode == 0 else ""


# --- report --------------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("run_root")
    ap.add_argument("transcript", nargs="?")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--contextmeter", metavar="DIR",
                    help="optional: a contextmeter checkout to run for window metrics (omit it; the report works without)")
    args = ap.parse_args()

    run_root = Path(args.run_root).expanduser()
    state_path = run_root / "STATE.md"
    if not state_path.is_file():
        print(f"run-report.py: no STATE.md under {run_root}", file=sys.stderr)
        return 2
    state = state_path.read_text(encoding="utf-8", errors="replace")

    rows = phase_rows(state)
    failures, attempts = evidence_findings(run_root)
    trust = trust_prior(run_root)
    fail_log = [l for l in section(state, "Failure log")
                if l.startswith("- ") and "{{" not in l
                and l.strip().lower() not in ("- (none)", "- (none yet)", "- none", "- ...")]
    events = [l for l in section(state, "Notable events") if l.startswith("- ") and "{{" not in l]
    # "- <name> (phase N)" since the carryover change; a memory two phases saved is listed twice
    carry = [l for l in section(state, "Carryover") if l.startswith("- ") and "none yet" not in l]
    carry_names = {re.sub(r" \(phase \d+\)$", "", l[2:].strip()) for l in carry}
    spec = run_root / "SPEC.md"

    check = None
    ctx = ""
    if args.transcript:
        t = Path(args.transcript).expanduser()
        if not t.is_file():
            print(f"run-report.py: no transcript at {t}", file=sys.stderr)
            return 2
        check = run_check(t, run_root)
        ctx = run_contextmeter(t, args.contextmeter)

    status = field(state, "Status")
    retried = [a for a in attempts if a["attempts"] > 1 or a["fix"]]
    clean = (status == "COMPLETE" and not fail_log and (check is None or check["ok"]))

    if args.json:
        json.dump({"status": status, "phases": rows, "failures": failures,
                   "attempts": attempts, "trust_prior": trust, "failure_log": fail_log,
                   "carryover": carry, "has_spec": spec.is_file(),
                   "protocol": check, "clean": clean}, sys.stdout, indent=2)
        sys.stdout.write("\n")
        return 0 if clean else 1

    w = sys.stdout.write
    w(f"# Relay run report — {field(state, 'Run root') or run_root}\n\n")
    w(f"**Status:** {status or 'unknown'}  ·  **Phases:** {len(rows)}  ·  "
      f"**Baseline:** {field(state, 'Baseline ref') or 'unknown'}  ·  "
      f"**Spec:** {'yes' if spec.is_file() else 'no (pre-0.9 or hand-authored run)'}\n\n")

    w("## Where the run struggled\n\n")
    if not retried and not fail_log and not failures:
        w("Nothing retried, escalated, or blocked. Every phase passed on its first attempt.\n\n")
    else:
        for a in sorted(retried, key=lambda x: x["phase"]):
            extra = f", {a['fix']} fix window(s)" if a["fix"] else ""
            w(f"- **Phase {a['phase']}** — {a['attempts']} attempt(s){extra}\n")
        for f in failures:
            hyp = f" — hypothesis: {f['hypothesis']}" if f["hypothesis"] else ""
            w(f"  - failed `{f['criterion']}`{hyp}\n")
        for line in fail_log:
            w(f"- {line[2:]}\n")
        w("\n")

    w("## What the audit could not check\n\n")
    if trust:
        w(f"{len(trust)} criterion(a) came back `trust-prior-verify` — the audit took the "
          "phase's word for these. Each one is a place the plan was written in terms a verifier "
          "cannot settle; that is a spec-quality signal, not an audit failure.\n\n")
        for t in trust[:20]:
            w(f"- (round {t['round']}) {t['text']}\n")
        if len(trust) > 20:
            w(f"- … and {len(trust) - 20} more\n")
        w("\n")
    else:
        w("No `trust-prior-verify` criteria recorded — either every criterion was "
          "machine-checkable, or no audit evidence file was written.\n\n")

    w("## Phases\n\n| # | Phase | Status | Notes |\n|---|---|---|---|\n")
    for r in rows:
        w(f"| {r['n']} | {r['name']} | {r['status']} | {r['notes']} |\n")
    w("\n")

    if check:
        w("## Protocol conformance\n\n")
        w(f"**{'PASS' if check['ok'] else 'VIOLATIONS'}** — check-run.py\n\n")
        for v in check["violations"]:
            w(f"- ✗ {v}\n")
        for v in check["warnings"][:10]:
            w(f"- ! {v}\n")
        if check.get("orchestrator_peak"):
            w(f"\nOrchestrator peak: {check['orchestrator_peak']} tokens\n")
        w("\n")

    if carry:
        w(f"## Memory written ({len(carry_names)})\n\n")
        for c in carry:
            w(f"{c}\n")
        w("\n")

    if events:
        w("## Timeline\n\n")
        for e in events:
            w(f"{e}\n")
        w("\n")

    if ctx:
        w("## Window metrics (contextmeter)\n\n```\n" + ctx.strip() + "\n```\n\n")

    return 0 if clean else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BrokenPipeError:
        sys.exit(0)
