#!/usr/bin/env python3
"""Where frog's turn time goes, measured on real sessions.

Reads frog session logs (JSONL) and splits each turn's wall time, per model, into:

  prefill      request sent → first streamed token (time to first token), per model call
  decode       first token → response done (of which: think, reasoning before any answer)
  tools       tools running, not counting permission prompts
  user         waiting on the user to answer permission prompts
  classifier   auto mode's classifier deciding whether a tool call may run
  compact      summarizing the conversation when the context filled up
  other        the rest: context fitting, MCP refresh, first-use profiling, retries, the engine

Also: median TTFT, median prefill and decode speed per model call, and the tool types that
take the most time. Prompt tokens include cached ones, so prefill tok/s is the effective rate:
a warm KV cache makes it look far higher than a cold prefill. Calls where frog switched thinking
off (`thinking = "auto"`, recorded as `no_think`) are compared with the rest.

Timing comes from `turn_ended` usage (`usage.timing`); turns logged by a frog too old to
record it are skipped and counted. A subagent's (`Task`) own model time counts as tool time.

    scripts/time_split.py [DIR ...] [--json] [--tools N]

DIR defaults to ~/.local/share/frog/sessions. Name a group with LABEL=DIR.
"""

import argparse
import glob
import json
import os
import sys
from collections import defaultdict

PARTS = ["prefill", "decode", "tools", "user", "classifier", "compact", "other"]
FIELDS = {
    "prefill": "prefill_ms",
    "decode": "decode_ms",
    "tools": "tool_ms",
    "user": "user_ms",
    "classifier": "classifier_ms",
    "compact": "compact_ms",
    "other": "other_ms",
}


def median(xs):
    xs = sorted(xs)
    if not xs:
        return None
    n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2


def turns(path):
    """(model, timing) for every turn in a session, timing None where it wasn't recorded."""
    model = None
    for line in open(path):
        try:
            r = json.loads(line)
        except ValueError:
            continue
        kind = r.get("type")
        if kind == "header":
            model = r.get("model")
        elif kind == "event":
            e = r["env"]
            ev = e.get("event")
            if ev == "model_changed":
                model = e.get("model") or model
            elif ev == "turn_ended":
                yield model or "?", (e.get("usage") or {}).get("timing")


class Stats:
    def __init__(self):
        self.turns = 0
        self.ms = defaultdict(int)
        self.think = 0
        self.ttft = []
        self.prefill_tps = []
        self.decode_tps = []
        self.calls = 0
        # Per model call, split by whether thinking was switched off (`no_think`):
        # [calls, output tokens, decode ms, think ms]
        self.by_think = {True: [0, 0, 0, 0], False: [0, 0, 0, 0]}
        self.tools = defaultdict(list)  # name -> [ms]

    def add(self, t):
        self.turns += 1
        self.ms["wall"] += t.get("wall_ms", 0)
        for part, field in FIELDS.items():
            self.ms[part] += t.get(field, 0)
        self.think += t.get("think_ms", 0)
        for c in t.get("calls", []):
            if c.get("compact"):
                continue
            self.calls += 1
            ttft, decode = c.get("ttft_ms", 0), c.get("decode_ms", 0)
            b = self.by_think[bool(c.get("no_think"))]
            b[0] += 1
            b[1] += c.get("output_tokens", 0)
            b[2] += decode
            b[3] += c.get("think_ms", 0)
            self.ttft.append(ttft)
            if ttft > 0 and c.get("prompt_tokens"):
                self.prefill_tps.append(c["prompt_tokens"] / (ttft / 1000))
            if decode > 0 and c.get("output_tokens"):
                self.decode_tps.append(c["output_tokens"] / (decode / 1000))
        for tool in t.get("tools", []):
            name = tool.get("name", "?")
            if name.startswith("mcp__"):
                name = "mcp__" + name.split("__")[1]
            self.tools[name].append(tool.get("ms", 0))

    def merge(self, other):
        self.turns += other.turns
        for k, v in other.ms.items():
            self.ms[k] += v
        self.think += other.think
        self.ttft += other.ttft
        self.prefill_tps += other.prefill_tps
        self.decode_tps += other.decode_tps
        self.calls += other.calls
        for k in self.by_think:
            self.by_think[k] = [a + b for a, b in zip(self.by_think[k], other.by_think[k])]
        for k, v in other.tools.items():
            self.tools[k] += v

    def summary(self, n_tools=8):
        wall = self.ms["wall"]
        share = {p: (self.ms[p] / wall if wall else 0) for p in PARTS}
        tools = sorted(
            (
                {
                    "tool": name,
                    "calls": len(ms),
                    "total_s": sum(ms) / 1000,
                    "median_s": median(ms) / 1000,
                    "max_s": max(ms) / 1000,
                }
                for name, ms in self.tools.items()
            ),
            key=lambda r: -r["total_s"],
        )[:n_tools]
        return {
            "turns": self.turns,
            "model_calls": self.calls,
            "thinking": {
                ("off" if off else "on"): {
                    "calls": n,
                    "output_tokens_per_call": out / n if n else 0,
                    "decode_s_per_call": dec / n / 1000 if n else 0,
                    "think_s_per_call": th / n / 1000 if n else 0,
                }
                for off, (n, out, dec, th) in self.by_think.items()
            },
            "wall_s": wall / 1000,
            "share": share,
            "think_share": self.think / wall if wall else 0,
            "median_ttft_s": (median(self.ttft) or 0) / 1000,
            "median_prefill_tps": median(self.prefill_tps),
            "median_decode_tps": median(self.decode_tps),
            "slowest_tools": tools,
        }


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("dirs", nargs="*", help="session folders, optionally LABEL=DIR")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--tools", type=int, default=8, help="how many tool types to list")
    a = ap.parse_args()
    specs = a.dirs or [f"interactive={os.path.expanduser('~/.local/share/frog/sessions')}"]
    rows = defaultdict(Stats)
    sessions, untimed_turns, untimed_sessions = 0, 0, 0
    for spec in specs:
        label, _, d = spec.rpartition("=")
        d = os.path.expanduser(d)
        label = label or os.path.basename(d.rstrip("/"))
        for f in sorted(glob.glob(os.path.join(d, "*.jsonl"))):
            timed = False
            for model, t in turns(f):
                if not t:
                    untimed_turns += 1
                    continue
                rows[(label, model)].add(t)
                timed = True
            sessions += timed
            untimed_sessions += not timed
    overall = Stats()
    for s in rows.values():
        overall.merge(s)
    per = [dict(group=g, model=m, **s.summary(a.tools)) for (g, m), s in sorted(rows.items())]
    o = overall.summary(a.tools)
    o.update(sessions=sessions, skipped_turns=untimed_turns, skipped_sessions=untimed_sessions)
    if a.json:
        print(json.dumps({"overall": o, "by_model": per}, indent=2))
        return
    print(f"{sessions} sessions, {o['turns']} turns, {o['model_calls']} model calls, {o['wall_s']:.1f}s of turns"
          f" (skipped {untimed_turns} turns without timing in {untimed_sessions} sessions)\n")
    if not o["turns"]:
        return
    tps = lambda x: f"{x:,.0f}" if x else "?"
    print("share of wall time")
    for p in PARTS:
        extra = f"   (think {o['think_share']:.1%})" if p == "decode" and o["think_share"] else ""
        print(f"  {p:<11} {o['share'][p]:6.1%}{extra}")
    print(f"\nmedian ttft {o['median_ttft_s']:.2f}s · prefill {tps(o['median_prefill_tps'])} tok/s"
          f" · decode {tps(o['median_decode_tps'])} tok/s")
    off = o["thinking"]["off"]
    if off["calls"]:
        on = o["thinking"]["on"]
        print(f"thinking off for {off['calls']} of {o['model_calls']} calls · per call, on vs off:"
              f" {on['output_tokens_per_call']:.0f} vs {off['output_tokens_per_call']:.0f} output tokens,"
              f" {on['decode_s_per_call']:.1f}s vs {off['decode_s_per_call']:.1f}s decode")
    print()
    head = "".join(f"{p[:7]:>8}" for p in PARTS)
    print(f"{'group':<12} {'model':<34} {'turns':>5}{head} {'ttft':>6} {'pf t/s':>7} {'dec t/s':>7}")
    for r in per:
        cells = "".join(f"{r['share'][p]:>8.1%}" for p in PARTS)
        print(f"{r['group'][:12]:<12} {r['model'][:34]:<34} {r['turns']:>5}{cells} {r['median_ttft_s']:>5.2f}s"
              f" {tps(r['median_prefill_tps']):>7} {tps(r['median_decode_tps']):>7}")
    if o["slowest_tools"]:
        print(f"\n{'tool':<24} {'calls':>6} {'total':>9} {'median':>8} {'max':>8}")
        for t in o["slowest_tools"]:
            print(f"{t['tool'][:24]:<24} {t['calls']:>6} {t['total_s']:>8.1f}s {t['median_s']:>7.2f}s {t['max_s']:>7.1f}s")


if __name__ == "__main__":
    sys.exit(main())
