#!/usr/bin/env python3
"""What a harness-aware inference gateway could save, measured on real frog sessions.

Reads frog session logs (JSONL) and estimates, per model:

  cacheable input   With a session pinned to one server that keeps its KV cache between
                    steps, each model call only has to prefill what's new since the last
                    call (tool results, the user's next message). Everything else is a
                    cache hit. Compaction, a reset or a model switch breaks the cache.
  copyable output   How much of each response (text and tool-call arguments, e.g. edit
                    contents) prompt-lookup decoding would draft correctly from text
                    already in the context, and the resulting decode speedup.
  tool errors       How often tool calls fail, by kind: schema (bad name or arguments, which
                    constrained decoding would prevent), contract (e.g. editing a file it
                    hasn't read), repeat (loops), other. Permission denials are left out.

Token counts are estimates: characters become tokens at 3.5 chars/token (frog's own default,
with the cache estimate also shown at 3 and 4), and each session's fixed prompt size (system
prompt and tool schemas) is fitted to the real per-turn usage frog logs (turn_ended). Context
pruning isn't logged, so long sessions are treated as if never pruned; each prune would cost
one full re-prefill. Output tokens for prompt lookup are approximated by a word/punctuation
split.

    scripts/gateway_stats.py [DIR ...] [--json]

DIR defaults to ~/.local/share/frog/sessions. Name a group with LABEL=DIR.
"""

import argparse
import glob
import json
import os
import re
import sys
from collections import defaultdict

TOKEN = re.compile(r"\w+|[^\w\s]|\s+")
# Why a tool call failed, from frog's own messages. "denied" isn't the model's fault and is left
# out of error rates; "schema" is what constrained decoding would prevent.
ERRORS = [
    ("denied", re.compile(r"Not permitted|rejected this tool call|Interrupted by user", re.I)),
    ("repeat", re.compile(r"already ran \d+ times", re.I)),
    ("schema", re.compile(r"unknown tool|no such tool|unknown arguments|unrecognized arg|invalid (?:arguments|input|json|parameters)"
                          r"|missing (?:required )?(?:field|argument|parameter)|failed to parse|couldn't parse", re.I)),
    ("contract", re.compile(r"must Read .* before|old_string|new_string", re.I)),
]


def error_kind(text):
    for kind, pattern in ERRORS:
        if pattern.search(text):
            return kind
    return "other"


def block_text(b):
    """The text a block contributes to the prompt."""
    t = b.get("type")
    if t == "text":
        return b.get("text", "")
    if t == "tool_use":
        return b.get("name", "") + json.dumps(b.get("input", {}), ensure_ascii=False)
    if t == "tool_result":
        c = b.get("content", "")
        if isinstance(c, list):
            return "".join(x.get("text", "") for x in c if isinstance(x, dict))
        return str(c)
    # Earlier reasoning isn't sent back (only Anthropic replays signed thinking), so it isn't
    # part of later prompts.
    return ""


def output_text(msg):
    """What the model generated: its text and tool-call arguments (not thinking)."""
    parts = []
    for b in msg.get("content", []):
        if b.get("type") == "text":
            parts.append(b.get("text", ""))
        elif b.get("type") == "tool_use":
            for v in (b.get("input") or {}).values():
                parts.append(v if isinstance(v, str) else json.dumps(v, ensure_ascii=False))
    return "\n".join(parts)


def msg_chars(msg):
    return sum(len(block_text(b)) for b in msg.get("content", []))


class Session:
    """A session replayed into model calls."""

    def __init__(self, path):
        self.path = path
        self.model = None
        self.calls = []  # dicts: prefix (chars before the call), out (chars), fresh (cache broken)
        self.turns = []  # (input_tokens, [call indexes])
        self.tools = []  # error kind, or None for a success
        self.lookup = []  # (output tokens, verify steps with prompt lookup)
        messages, context_tokens = [], []
        broken, turn_calls = True, []
        for line in open(path):
            try:
                r = json.loads(line)
            except ValueError:
                continue
            kind = r.get("type")
            if kind == "header":
                self.model = r.get("model")
            elif kind == "reset":
                messages = list(r.get("messages", []))
                context_tokens = tokens_of(messages)
                broken = True
            elif kind == "push":
                m = r["message"]
                if m.get("role") == "assistant":
                    prefix = sum(msg_chars(x) for x in messages)
                    self.calls.append({"prefix": prefix, "out": msg_chars(m), "fresh": broken})
                    turn_calls.append(len(self.calls) - 1)
                    broken = False
                    out = TOKEN.findall(output_text(m))
                    if out:
                        self.lookup.append((len(out), lookup_steps(context_tokens, out)))
                    context_tokens += TOKEN.findall("".join(block_text(b) for b in m.get("content", [])))
                else:
                    context_tokens += TOKEN.findall("".join(block_text(b) for b in m.get("content", [])))
                messages.append(m)
            elif kind == "extend" and messages:
                blocks = r.get("blocks", [])
                messages[-1] = dict(messages[-1], content=messages[-1].get("content", []) + blocks)
                for b in blocks:
                    if b.get("type") == "tool_result":
                        self.tools.append(error_kind(block_text(b)) if b.get("is_error") else None)
                context_tokens += TOKEN.findall("".join(block_text(b) for b in blocks))
            elif kind == "event":
                e = r["env"]
                ev = e.get("event")
                if ev == "turn_ended" and e.get("usage"):
                    self.turns.append((e["usage"].get("input_tokens", 0), turn_calls))
                    turn_calls = []
                elif ev in ("model_changed", "compacted"):
                    broken = True
                    if ev == "model_changed":
                        self.model = e.get("model") or self.model


def tokens_of(messages):
    return TOKEN.findall("".join(block_text(b) for m in messages for b in m.get("content", [])))


def lookup_steps(context, out, ngram=3, draft=10):
    """Decode steps for `out` with prompt-lookup decoding: at each step, find the latest
    earlier occurrence of the last `ngram` tokens and propose up to `draft` tokens that
    followed it; the model accepts the matching prefix plus one token of its own."""
    seq = list(context)
    # n-gram -> where its latest earlier occurrence's continuation starts
    index = {}
    for i in range(len(seq) - ngram):
        index[tuple(seq[i : i + ngram])] = i + ngram
    steps, j = 0, 0
    while j < len(out):
        key = tuple(seq[-ngram:]) if len(seq) >= ngram else None
        accepted = 0
        if key in index:
            start = index[key]
            proposal = seq[start : start + draft]
            while accepted < len(proposal) and j + accepted < len(out) and proposal[accepted] == out[j + accepted]:
                accepted += 1
        take = min(accepted + 1, len(out) - j)
        for t in out[j : j + take]:
            if len(seq) >= ngram:
                index[tuple(seq[-ngram:])] = len(seq)
            seq.append(t)
        j += take
        steps += 1
    return steps


def fit(sessions, chars_per_token):
    """Each session's fixed prompt size (system prompt and tool schemas), fitted to the real
    per-turn input token counts: input = calls x fixed + Σ prefix chars / chars_per_token."""
    ratio = 1 / chars_per_token
    fixed = {}
    for s in sessions:
        turns = [(t, [s.calls[i]["prefix"] for i in idx]) for t, idx in s.turns if idx and t]
        n = sum(len(p) for _, p in turns)
        if n:
            fixed[s.path] = max(0.0, sum(t - ratio * sum(p) for t, p in turns) / n)
    typical = sorted(fixed.values())[len(fixed) // 2] if fixed else 3000.0
    return ratio, {s.path: fixed.get(s.path, typical) for s in sessions}


def analyze(groups, chars_per_token=3.5):
    sessions = [s for _, ss in groups for s in ss]
    ratio, fixed = fit(sessions, chars_per_token)
    rows = defaultdict(lambda: defaultdict(float))
    for label, ss in groups:
        for s in ss:
            if not s.calls:
                continue
            r = rows[(label, s.model or "?")]
            r["sessions"] += 1
            f = fixed[s.path]
            prev_total = None
            for c in s.calls:
                prompt = f + ratio * c["prefix"]
                new = prompt if c["fresh"] or prev_total is None else max(0.0, prompt - prev_total)
                r["calls"] += 1
                r["prompt"] += prompt
                r["new"] += new
                prev_total = prompt + ratio * c["out"]
            actual = sum(t for t, _ in s.turns)
            r["actual"] += actual
            r["out_tokens"] += sum(n for n, _ in s.lookup)
            r["lookup_steps"] += sum(k for _, k in s.lookup)
            for kind in s.tools:
                if kind == "denied":
                    continue
                r["tool_calls"] += 1
                if kind:
                    r["tool_errors"] += 1
                    r["err_" + kind] += 1
    return ratio, rows


def summarize(ratio, rows):
    out = []
    totals = defaultdict(float)
    for (label, model), r in sorted(rows.items()):
        row = {
            "group": label,
            "model": model,
            "sessions": int(r["sessions"]),
            "model_calls": int(r["calls"]),
            "prompt_tokens_est": int(r["prompt"]),
            "prompt_tokens_logged": int(r["actual"]),
            "cacheable": 1 - r["new"] / r["prompt"] if r["prompt"] else 0,
            "output_tokens": int(r["out_tokens"]),
            "lookup_speedup": r["out_tokens"] / r["lookup_steps"] if r["lookup_steps"] else 1,
            "tool_calls": int(r["tool_calls"]),
            "tool_error_rate": r["tool_errors"] / r["tool_calls"] if r["tool_calls"] else 0,
            "schema_error_rate": r["err_schema"] / r["tool_calls"] if r["tool_calls"] else 0,
        }
        out.append(row)
        for k, v in r.items():
            totals[k] += v
    t = totals
    overall = {
        "sessions": int(t["sessions"]),
        "model_calls": int(t["calls"]),
        "cacheable": 1 - t["new"] / t["prompt"] if t["prompt"] else 0,
        "prompt_tokens_est": int(t["prompt"]),
        "prompt_tokens_logged": int(t["actual"]),
        "prefill_saved_x": t["prompt"] / t["new"] if t["new"] else 1,
        "lookup_speedup": t["out_tokens"] / t["lookup_steps"] if t["lookup_steps"] else 1,
        "tool_error_rate": t["tool_errors"] / t["tool_calls"] if t["tool_calls"] else 0,
        "errors_by_kind": {k[4:]: int(v) for k, v in t.items() if k.startswith("err_")},
        "tool_calls": int(t["tool_calls"]),
        "chars_per_token": 1 / ratio,
    }
    return overall, out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("dirs", nargs="*", help="session folders, optionally LABEL=DIR")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    specs = a.dirs or [f"interactive={os.path.expanduser('~/.local/share/frog/sessions')}"]
    groups = []
    for spec in specs:
        label, _, d = spec.rpartition("=")
        d = os.path.expanduser(d)
        files = sorted(glob.glob(os.path.join(d, "*.jsonl")))
        groups.append((label or os.path.basename(d.rstrip("/")), [Session(f) for f in files]))
    ratio, rows = analyze(groups)
    overall, per = summarize(ratio, rows)
    # How much the cache estimate depends on the chars/token assumption.
    overall["cacheable_range"] = [summarize(*analyze(groups, c))[0]["cacheable"] for c in (3.0, 4.0)]
    if a.json:
        print(json.dumps({"overall": overall, "by_model": per}, indent=2))
        return
    o = overall
    lo, hi = sorted(o["cacheable_range"])
    print(f"{o['sessions']} sessions, {o['model_calls']} model calls\n")
    print(f"cacheable input      {o['cacheable']:6.1%}   prefill work cut {o['prefill_saved_x']:.1f}x with session-pinned KV"
          f" ({lo:.0%}–{hi:.0%} at 3–4 chars/token)")
    print(f"prompt-lookup        {o['lookup_speedup']:6.2f}x  decode speedup (tokens per verify step)")
    kinds = ", ".join(f"{k} {v}" for k, v in sorted(o["errors_by_kind"].items(), key=lambda x: -x[1]))
    print(f"tool call errors     {o['tool_error_rate']:6.1%}   of {o['tool_calls']} calls (denials excluded): {kinds}")
    print(f"prompt tokens        {o['prompt_tokens_est']:,} estimated vs {o['prompt_tokens_logged']:,} logged\n")
    print(f"{'group':<14} {'model':<38} {'sess':>4} {'calls':>6} {'cache':>7} {'lookup':>7} {'tool err':>9} {'schema':>7}")
    for r in per:
        print(f"{r['group'][:14]:<14} {r['model'][:38]:<38} {r['sessions']:>4} {r['model_calls']:>6} "
              f"{r['cacheable']:>6.1%} {r['lookup_speedup']:>6.2f}x {r['tool_error_rate']:>8.1%} {r['schema_error_rate']:>6.1%}")


if __name__ == "__main__":
    sys.exit(main())
