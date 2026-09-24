#!/usr/bin/env python3
"""How much agent-aware speculative decoding could speed up decode, replayed on real frog sessions.

Replays frog session logs (JSONL) into model calls, as gateway_stats.py does, and simulates
drafting strategies on what each call actually generated: its text and its tool calls, written
the way Qwen3 emits them (`<tool_call>\\n{"name": ..., "arguments": {...}}\\n</tool_call>`, which
is what the chat template renders for native calls and what frog's text mode asks for). The
context each call sees is its prompt as logged, with earlier tool calls in the same format.
Thinking is left out unless --thinking; earlier thinking is never part of later prompts.

  lookup        Naive prompt lookup, as in gateway_stats.py: find the latest earlier occurrence
                of the last 3 tokens, draft the 10 tokens that followed it.
  suffix/P      SuffixDecoding (arXiv 2411.04975): find the longest suffix of what's been
                generated (up to --max-depth tokens) that occurs in a source, and draft its most
                frequent continuation, token by token, while the path's estimated probability
                stays above --min-prob, up to --alpha x match length (capped at --max-spec).
                Sources: the prompt (plus this call's output so far), then also all earlier
                outputs in the session (/S, includes earlier thinking with --thinking), then also
                all outputs of earlier sessions, in time order, across every folder (/G). The
                source whose draft has the higher expected accepted length wins. Suffix
                automata stand in for the paper's suffix trees (same matches and counts).
  tree/G        As suffix/G, but drafting a tree of up to --max-spec candidate tokens (best
                first by path probability), verified in one pass with tree attention.
  grammar       Grammar-forced tokens only (jump-forward decoding): text that the tool-call
                format and tool schemas fully determine is drafted, and always accepted.
  sfx/G+gram    suffix/G, with forced text overriding the draft where it applies.
  copy          Headroom: every output token inside an exact match of >= --copy-k tokens with
                earlier context (prompt + output so far) is drafted perfectly, each copied
                run in one step. copy/G also matches against every suffix source; +gram adds
                forced tokens. An oracle bound on copying, not a bound on drafting: shorter
                matches (which suffix drafting also exploits) don't count.

What counts as forced (conservative). Frog's tool schemas are read from crates/frog-engine/src,
unioned with every tool name and argument key seen in the logs (a bigger set forces less).
Forced: `\\n{"name": "` after `<tool_call>`; the rest of a tool name once its prefix is
unique among known tools; `", "arguments": {`; ` "` after a comma between arguments; the
rest of a key once its prefix is unique among the tool's keys not used yet; `": `; the
opening quote of a string argument; the rest of `true`/`false`; `}` when no known keys
remain; and the closing `}\\n</tool_call>`. Never forced: deciding to call a tool, the first
token of a name or key, argument values, the choice between `,` and `}`, anything nested
inside an argument, and anything for tools with no known schema. A token counts as forced only
if every character in it is forced. Forced text is fed as draft tokens, so it still costs
verify width.

Speedup model. Each step verifies the last token plus a draft of m tokens and yields the
accepted draft tokens plus one token of the model's own. tok/step is output tokens / steps.
Wall-clock speedup is output tokens / sum of cost(1 + m), with cost(k) the time to verify k
tokens relative to decoding one, from --verify-cost (piecewise linear, extrapolated past the
last point). Drafting itself is assumed free (it runs on the CPU). Defaults:
  3090-like  1:1,4:1.05,8:1.15,16:1.4,32:2.0. Nothing measured yet; the research note says
             verifying 4-16 tokens on a 3090 at batch 1 costs close to one token.
  Mac-like   cost(k) = 1 + 0.085 (k - 1). From the MLX EAGLE-3 prototype (mlx-lm discussion
             #890): 113.7 tok/s (8.8 ms/token) with 0.5-1 ms per extra verified token on an
             M3 Ultra; 0.75 ms / 8.8 ms = 0.085.
Measure the real curves (a forward pass at k = 1..32, at 2K and 20K context) before trusting
the speedups.

Tokens. With --tokenizer auto (default) the Qwen3 tokenizer is used if a tokenizer.json is in
the Hugging Face cache (a small pure-Python byte-level BPE; its pre-tokenizer regex is
approximated with Python's re), otherwise the word/punctuation/space split gateway_stats.py
uses. The system prompt and tool schemas aren't logged, so they aren't in the context (fewer
matches for tool names and keys than a real prompt would give).

    scripts/draft_replay.py [DIR ...] [--json] [--thinking] [--tokenizer auto|approx|PATH]
                            [--verify-cost [NAME=]K:COST,...] ...

DIR defaults to ~/.local/share/frog/sessions. Name a group with LABEL=DIR.
"""

import argparse
import glob
import heapq
import json
import os
import re
import sys
import unicodedata
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.dont_write_bytecode = True
import gateway_stats as gs  # noqa: E402

CURVES = {
    "3090-like": "1:1,4:1.05,8:1.15,16:1.4,32:2.0",
    "Mac-like": "1:1,2:1.085,4:1.255,8:1.595,16:2.275,32:3.635",
}
STRATEGIES = [
    ("lookup", "prompt lookup (3-gram, 10 tokens)"),
    ("suffix/P", "suffix, prompt"),
    ("suffix/S", "suffix, prompt + session outputs"),
    ("suffix/G", "suffix, + earlier sessions' outputs"),
    ("tree/G", "suffix tree drafts, global"),
    ("grammar", "grammar-forced tokens only"),
    ("sfx/G+gram", "suffix/G + grammar-forced"),
    ("copy", "bound: copyable from context"),
    ("copy/G", "bound: copyable from any source"),
    ("copy/G+gram", "bound: copy/G + grammar-forced"),
]
BUCKETS = [(0, 0), (1, 1), (2, 2), (3, 3), (4, 7), (8, 15), (16, 31), (32, 10**9)]


# ---- tokenizers ----


class Approx:
    name = "approx (word/punct/space split)"

    def __init__(self):
        self.ids = {}

    def encode(self, text):
        """[(id, start, end)] over `text`."""
        ids = self.ids
        return [(ids.setdefault(m.group(), len(ids)), m.start(), m.end()) for m in gs.TOKEN.finditer(text)]


def bytes_to_unicode():
    bs = list(range(ord("!"), ord("~") + 1)) + list(range(ord("¡"), ord("¬") + 1)) + list(range(ord("®"), ord("ÿ") + 1))
    cs = bs[:]
    n = 0
    for b in range(256):
        if b not in bs:
            bs.append(b)
            cs.append(256 + n)
            n += 1
    return dict(zip(bs, map(chr, cs)))


class QwenBPE:
    """Qwen2/3 byte-level BPE. \\p{L} and \\p{N} are approximated with Python's re classes."""

    PAT = re.compile(r"(?i:'s|'t|'re|'ve|'m|'ll|'d)|(?:[^\r\n\w]|_)?[^\W\d_]+|\d| ?(?:[^\s\w]|_)+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+")

    def __init__(self, path):
        self.name = f"Qwen3 BPE ({path})"
        t = json.load(open(path))
        self.vocab = t["model"]["vocab"]
        merges = t["model"]["merges"]
        self.ranks = {tuple(m) if isinstance(m, list) else tuple(m.split(" ", 1)): i for i, m in enumerate(merges)}
        added = sorted((a["content"] for a in t.get("added_tokens", [])), key=len, reverse=True)
        self.added = {a["content"]: a["id"] for a in t.get("added_tokens", [])}
        self.special = re.compile("|".join(map(re.escape, added)))
        self.byte = bytes_to_unicode()
        self.cache = {}

    def bpe(self, word):
        parts = list(word)
        ranks = self.ranks
        while len(parts) > 1:
            best, at = None, -1
            for i in range(len(parts) - 1):
                r = ranks.get((parts[i], parts[i + 1]))
                if r is not None and (best is None or r < best):
                    best, at = r, i
            if best is None:
                break
            pair = (parts[at], parts[at + 1])
            merged, i = [], 0
            while i < len(parts):
                if i < len(parts) - 1 and (parts[i], parts[i + 1]) == pair:
                    merged.append(parts[i] + parts[i + 1])
                    i += 2
                else:
                    merged.append(parts[i])
                    i += 1
            parts = merged
        return parts

    def piece(self, s):
        """(id, char start, char end) for one pre-token, relative to it."""
        hit = self.cache.get(s)
        if hit is not None:
            return hit
        raw = s.encode("utf-8")
        char_at = [ci for ci, ch in enumerate(s) for _ in ch.encode("utf-8")]
        out, b = [], 0
        for p in self.bpe("".join(self.byte[x] for x in raw)):
            e = b + len(p)
            out.append((self.vocab.get(p, -1), char_at[b], char_at[e - 1] + 1))
            b = e
        self.cache[s] = out
        return out

    def encode(self, text):
        out, pos = [], 0
        for m in list(self.special.finditer(text)) + [None]:
            end = m.start() if m else len(text)
            for pm in self.PAT.finditer(text, pos, end):
                o = pm.start()
                out.extend((i, o + a, o + b) for i, a, b in self.piece(pm.group()))
            if m:
                out.append((self.added[m.group()], m.start(), m.end()))
                pos = m.end()
        return out


def find_qwen_tokenizer():
    hub = os.path.expanduser("~/.cache/huggingface/hub")
    for pat in ("models--mlx-community--Qwen3-*", "models--Qwen--Qwen3-*"):
        for p in sorted(glob.glob(os.path.join(hub, pat, "snapshots", "*", "tokenizer.json"))):
            return p
    return None


# ---- tool schemas and rendering ----


def load_schemas(src):
    """{tool name: {key: json type or None}} from frog's own ToolSpecs (best effort)."""
    tools = {}
    for f in glob.glob(os.path.join(src, "**", "*.rs"), recursive=True):
        text = open(f).read()
        consts = dict(re.findall(r'const (\w+): &str = "([^"]+)"', text))
        for m in re.finditer(r'\bname:\s*(?:"([A-Za-z_]\w*)"|([A-Z_]+))\.into\(\)', text):
            name = m.group(1) or consts.get(m.group(2))
            rest = text[m.end():]
            nxt = re.search(r"\bname:\s*\S+\.into\(\)", rest)
            rest = rest[: nxt.start()] if nxt else rest
            s, p = rest.find("schema:"), rest.find('"properties"')
            if not name or s < 0 or p < s:
                continue
            lit = re.match(r'"properties"\s*:\s*\{', rest[p:])  # else built in code: keys come from the logs
            tools.setdefault(name, top_level_props(rest[p + lit.end() - 1 :]) if lit else {})
    return tools


def top_level_props(s):
    """Keys (and "type"s) of the object literal at the start of `s`."""
    props, depth, i, key, last_str = {}, 0, 0, None, None
    while i < len(s):
        c = s[i]
        if c == '"':
            j = i + 1
            while s[j] != '"':
                j += 2 if s[j] == "\\" else 1
            last_str = s[i + 1 : j]
            i = j
        elif c == ":" and last_str is not None:
            if depth == 1:
                key = last_str
                props[key] = None
            elif depth == 2 and last_str == "type" and key:
                t = re.match(r'\s*"(\w+)"', s[i + 1 :])
                props[key] = t.group(1) if t else None
            last_str = None
        elif c in "{[":
            depth += 1
            last_str = None
        elif c in "}]":
            depth -= 1
            if depth == 0:
                break
            last_str = None
        elif not c.isspace() and c != ",":
            last_str = None
        i += 1
    return props


def forced_chars(value, alternatives):
    """Per character of `value`: forced if every alternative sharing the prefix before it
    agrees on it (the first character is always the model's)."""
    out = []
    for i in range(len(value)):
        alts = {a[i] for a in alternatives if len(a) > i and a[:i] == value[:i]}
        out.append(i > 0 and len(alts) == 1)
    return out


class Renderer:
    def __init__(self, schemas, observed):
        # A tool's known keys: its schema plus every key seen; unknown tools get no forcing.
        self.names = set(schemas) | set(observed)
        self.keys = {n: dict(observed.get(n, {}), **{k: t for k, t in schemas.get(n, {}).items() if t}) for n in self.names}
        for n in self.names:
            for k in schemas.get(n, {}):
                self.keys[n].setdefault(k, None)
        self.schema_tools = set(schemas)

    def tool_call(self, name, args):
        """[(text, forced)] for one call."""
        segs = [("<tool_call>", False), ('\n{"name": "', True)]
        term = [n + '"' for n in self.names]
        f = forced_chars(name + '"', term)
        segs += [(c, x) for c, x in zip(name + '"', f)]
        segs.append((', "arguments": {', True))
        known = self.keys.get(name) if name in self.schema_tools else None
        if not isinstance(args, dict):
            args = {}
        used = []
        for idx, (k, v) in enumerate(args.items()):
            if idx:
                segs += [(",", False), (' "', True)]
            else:
                segs.append(('"', False))
            if known is not None and k in known:
                remaining = [x + '"' for x in known if x not in used]
                segs += [(c, x) for c, x in zip(k + '"', forced_chars(k + '"', remaining))]
                segs.append((": ", True))
                vt = json.dumps(v, ensure_ascii=False)
                typ = known.get(k)
                if typ == "string" and isinstance(v, str):
                    segs += [('"', True), (vt[1:], False)]
                elif typ == "boolean" and isinstance(v, bool):
                    segs += [(c, x) for c, x in zip(vt, forced_chars(vt, ["true", "false"]))]
                else:
                    segs.append((vt, False))
            else:
                segs.append((json.dumps(k, ensure_ascii=False)[1:] + ": " + json.dumps(v, ensure_ascii=False), False))
            used.append(k)
        done = known is not None and all(x in used for x in known)
        segs += [("}", done), ("}\n</tool_call>", True)]
        return segs

    def message(self, msg, thinking):
        """[(text, forced)] for an assistant message as generated (thinking optional)."""
        segs = []
        for b in msg.get("content", []):
            t = b.get("type")
            if t == "thinking" and thinking and b.get("text"):
                segs += [("<think>", False), (b["text"], False), ("</think>\n\n", True)]
            elif t == "text" and b.get("text"):
                segs.append((b["text"], False))
            elif t == "tool_use":
                if segs:
                    segs.append(("\n", False))
                segs += self.tool_call(b.get("name", ""), b.get("input") or {})
        return segs


def tokenize(tok, segs):
    """Token ids and per-token forced flags (every character forced)."""
    text, mask = [], []
    for s, f in segs:
        s = unicodedata.normalize("NFC", s)
        text.append(s)
        mask.extend([f] * len(s))
    toks = tok.encode("".join(text))
    return [t for t, _, _ in toks], [all(mask[a:b]) and b > a for _, a, b in toks]


# ---- replay ----


def replay(path, tok, render, thinking):
    """Yield ("call", model, context ids, output ids, forced flags) per model call, then
    ("done", all output ids of the session)."""
    model, ctx = None, []
    outs = []

    def ids(text):
        return [t for t, _, _ in tok.encode(unicodedata.normalize("NFC", text))]

    def context_of(m):
        if m.get("role") == "assistant":
            return tokenize(tok, render.message(m, False))[0]
        return ids("".join(gs.block_text(b) for b in m.get("content", [])))

    for line in open(path):
        try:
            r = json.loads(line)
        except ValueError:
            continue
        kind = r.get("type")
        if kind == "header":
            model = r.get("model")
        elif kind == "reset":
            ctx = [t for m in r.get("messages", []) for t in context_of(m)]
        elif kind == "push":
            m = r["message"]
            if m.get("role") == "assistant":
                out, forced = tokenize(tok, render.message(m, thinking))
                if out:
                    yield "call", model, ctx, out, forced
                    outs.append(out)
            ctx.extend(context_of(m))
        elif kind == "extend":
            ctx.extend(ids("".join(gs.block_text(b) for b in r.get("blocks", []))))
        elif kind == "event" and r["env"].get("event") == "model_changed":
            model = r["env"].get("model") or model
    yield "done", outs


# ---- suffix automaton ----


class SAM:
    """Suffix automaton with occurrence counts kept online: a suffix tree's matches and
    continuation frequencies, in linear space."""

    def __init__(self):
        self.nxt, self.link, self.len, self.cnt = [{}], [-1], [0], [0]
        self.last = 0

    def add(self, c):
        nxt, link, ln, cnt = self.nxt, self.link, self.len, self.cnt
        cur = len(ln)
        nxt.append({})
        ln.append(ln[self.last] + 1)
        link.append(0)
        cnt.append(0)
        p = self.last
        while p != -1 and c not in nxt[p]:
            nxt[p][c] = cur
            p = link[p]
        if p != -1:
            q = nxt[p][c]
            if ln[p] + 1 == ln[q]:
                link[cur] = q
            else:
                clone = len(ln)
                nxt.append(dict(nxt[q]))
                ln.append(ln[p] + 1)
                link.append(link[q])
                cnt.append(cnt[q])
                while p != -1 and nxt[p].get(c) == q:
                    nxt[p][c] = clone
                    p = link[p]
                link[q] = clone
                link[cur] = clone
        self.last = cur
        s = cur
        while s > 0:  # every state on the suffix path now ends here too
            cnt[s] += 1
            s = link[s]

    def extend(self, seq):
        for c in seq:
            self.add(c)

    def self_match(self, depth):
        """Longest suffix of the whole text that also occurs earlier: (state, length)."""
        s = self.link[self.last] if self.last else 0
        return self.cap(s, self.len[s], depth)

    def cap(self, s, n, depth):
        if n > depth:
            n = depth
            while self.len[self.link[s]] >= n:
                s = self.link[s]
        return s, n


class Matcher:
    """Longest suffix of a token stream that occurs in a fixed SAM."""

    def __init__(self, sam, depth):
        self.sam, self.depth, self.s, self.n = sam, depth, 0, 0

    def feed(self, c):
        sam, s, n = self.sam, self.s, self.n
        while s and c not in sam.nxt[s]:
            s = sam.link[s]
            n = sam.len[s]
        if c in sam.nxt[s]:
            s, n = sam.nxt[s][c], n + 1
        else:
            s, n = 0, 0
        self.s, self.n = sam.cap(s, n, self.depth)


def draft_path(sam, s, n, cfg):
    """Most frequent continuation of the match: (tokens, expected accepted)."""
    if n == 0:
        return [], 0.0
    limit = min(cfg.max_spec, max(1, int(cfg.alpha * n)))
    out, p, score = [], 1.0, 0.0
    nxt, cnt = sam.nxt, sam.cnt
    while len(out) < limit:
        ch = nxt[s]
        if not ch:
            break
        total = 0
        best, bt = None, -1
        for c, t in ch.items():
            total += cnt[t]
            if cnt[t] > bt:
                best, bt = c, cnt[t]
        p *= bt / total
        if p < cfg.min_prob:
            break
        out.append(best)
        score += p
        s = ch[best]
    return out, score


def draft_tree(sam, s, n, cfg):
    """Best-first tree of continuations: (children dict per node, size, expected accepted)."""
    if n == 0:
        return {}, 0, 0.0
    limit = min(cfg.max_spec, max(1, int(cfg.alpha * n)))
    nxt, cnt = sam.nxt, sam.cnt
    tree = {0: {}}  # node -> {token: node}
    heap, size, score, uid = [], 0, 0.0, 0

    def push(node, state, p):
        nonlocal uid
        ch = nxt[state]
        total = sum(cnt[t] for t in ch.values())
        for c, t in ch.items():
            q = p * cnt[t] / total
            if q >= cfg.min_prob:
                uid += 1
                heapq.heappush(heap, (-q, uid, node, c, t))

    push(0, s, 1.0)
    while heap and size < limit:
        negq, _, node, c, t = heapq.heappop(heap)
        size += 1
        score += -negq
        tree[node][c] = size
        tree[size] = {}
        push(size, t, -negq)
    return tree, size, score


# ---- simulation ----


class Stat:
    def __init__(self):
        self.tokens = self.steps = self.drafted = self.accepted = 0
        self.width = defaultdict(int)  # verify width -> steps
        self.hist = defaultdict(int)  # accepted draft tokens -> steps

    def step(self, m, a, take):
        self.steps += 1
        self.tokens += take
        self.drafted += m
        self.accepted += a
        self.width[1 + m] += 1
        self.hist[a] += 1

    def merge(self, o):
        for k in ("tokens", "steps", "drafted", "accepted"):
            setattr(self, k, getattr(self, k) + getattr(o, k))
        for k, v in o.width.items():
            self.width[k] += v
        for k, v in o.hist.items():
            self.hist[k] += v


def accept(draft, out, j):
    a = 0
    while a < len(draft) and j + a < len(out) and draft[a] == out[j + a]:
        a += 1
    return a


def simulate(ctx, out, forced, sess_sam, glob_sam, cfg, stats):
    n = len(out)
    prompt = SAM()
    prompt.extend(ctx)
    matchers = []
    for src in (sess_sam, glob_sam):
        m = Matcher(src, cfg.max_depth)
        for c in ctx[-cfg.max_depth:]:
            m.feed(c)
        matchers.append(m)
    # prompt lookup: n-gram -> where its latest earlier occurrence's continuation starts
    seq, index, ng = list(ctx), {}, 3
    for i in range(len(seq) - ng):
        index[tuple(seq[i : i + ng])] = i + ng
    start = {k: 0 for k, _ in STRATEGIES}
    match_end, match_any = [], []  # longest earlier match ending at each output token

    for j in range(n):
        live = [k for k in start if start[k] == j and not k.startswith("copy")]
        if live:
            cands = {}
            ps, pn = prompt.self_match(cfg.max_depth)
            srcs = [("P", prompt, ps, pn), ("S", sess_sam, matchers[0].s, matchers[0].n), ("G", glob_sam, matchers[1].s, matchers[1].n)]
            for k in live:
                if k == "lookup":
                    key = tuple(seq[-ng:]) if len(seq) >= ng else None
                    d = seq[index[key] : index[key] + 10] if key in index else []
                elif k.startswith("tree"):
                    best = max((draft_tree(sam, s, m_, cfg) for _, sam, s, m_ in srcs), key=lambda x: x[2])
                    tree, size, _ = best
                    node, a = 0, 0
                    while j + a < n and out[j + a] in tree.get(node, {}):
                        node = tree[node][out[j + a]]
                        a += 1
                    record(stats[k], size, a, n, j, start, k)
                    continue
                elif k == "grammar":
                    d = []
                    while j + len(d) < n and forced[j + len(d)]:
                        d.append(out[j + len(d)])
                else:
                    use = {"suffix/P": "P", "suffix/S": "PS"}.get(k, "PSG")
                    if use not in cands:
                        cands[use] = max((draft_path(sam, s, m_, cfg) for name, sam, s, m_ in srcs if name in use),
                                         key=lambda x: x[1])[0]
                    d = cands[use]
                    if k.endswith("+gram"):
                        g, i = [], 0
                        while j + i < n and (forced[j + i] or i < len(d)):
                            g.append(out[j + i] if forced[j + i] else d[i])
                            i += 1
                        d = g
                record(stats[k], len(d), accept(d, out, j), n, j, start, k)
        # the token is generated: every source sees it
        c = out[j]
        if len(seq) >= ng:
            index[tuple(seq[-ng:])] = len(seq)
        seq.append(c)
        prompt.add(c)
        match_end.append(prompt.len[prompt.link[prompt.last]])
        for m in matchers:
            m.feed(c)
        match_any.append(max(match_end[-1], *(m.n for m in matchers)))

    for k, ends, extra in (("copy", match_end, None), ("copy/G", match_any, None), ("copy/G+gram", match_any, forced)):
        cov, reach = [False] * n, n  # reach: earliest start of a match ending at or after i
        for i in range(n - 1, -1, -1):
            if ends[i] >= cfg.copy_k:
                reach = min(reach, i - ends[i] + 1)
            cov[i] = reach <= i
        if extra:
            cov = [a or b for a, b in zip(cov, extra)]
        j = 0
        while j < n:
            r = j
            while r < n and cov[r]:
                r += 1
            stats[k].step(r - j, r - j, min(r - j + 1, n - j))
            j = r + 1


def record(stat, m, a, n, j, start, k):
    take = min(a + 1, n - j)
    stat.step(m, min(a, take), take)
    start[k] = j + take


# ---- reporting ----


def parse_curve(spec):
    pts = sorted((float(k), float(v)) for k, v in (p.split(":") for p in spec.split(",")))
    if pts[0][0] > 1:
        pts.insert(0, (1.0, 1.0))
    return pts


def cost(pts, k):
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        if k <= x1:
            return y0 + (y1 - y0) * (k - x0) / (x1 - x0)
    (x0, y0), (x1, y1) = pts[-2], pts[-1]
    return y1 + (y1 - y0) * (k - x1) / (x1 - x0)


def summary(st, curves):
    r = {
        "output_tokens": st.tokens,
        "steps": st.steps,
        "tokens_per_step": st.tokens / st.steps if st.steps else 1.0,
        "draft_per_step": st.drafted / st.steps if st.steps else 0.0,
        "acceptance": st.accepted / st.drafted if st.drafted else 0.0,
    }
    for name, pts in curves.items():
        c = sum(cost(pts, w) * v for w, v in st.width.items())
        r["speedup_" + name] = st.tokens / c if c else 1.0
    return r


def histogram(st):
    rows = []
    for lo, hi in BUCKETS:
        steps = sum(v for k, v in st.hist.items() if lo <= k <= hi)
        rows.append({"accepted": f"{lo}" if lo == hi else (f"{lo}+" if hi > 10**6 else f"{lo}-{hi}"),
                     "steps": steps, "share": steps / st.steps if st.steps else 0.0})
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("dirs", nargs="*", help="session folders, optionally LABEL=DIR")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--thinking", action="store_true", help="count thinking as output (it is decoded)")
    ap.add_argument("--tokenizer", default="auto", help="auto, approx, or a tokenizer.json path")
    ap.add_argument("--verify-cost", action="append", metavar="[NAME=]K:COST,...",
                    help="cost of verifying K tokens relative to 1; repeatable (default: 3090-like and Mac-like)")
    ap.add_argument("--alpha", type=float, default=1.0, help="suffix draft length per matched token")
    ap.add_argument("--max-spec", type=int, default=32, help="most tokens in a suffix draft or tree")
    ap.add_argument("--min-prob", type=float, default=0.1, help="stop drafting below this path probability")
    ap.add_argument("--max-depth", type=int, default=64, help="longest suffix match considered")
    ap.add_argument("--copy-k", type=int, default=4, help="shortest match that counts as copyable")
    a = ap.parse_args()

    curves = {}
    for i, spec in enumerate(a.verify_cost or [f"{k}={v}" for k, v in CURVES.items()]):
        name, _, pts = spec.rpartition("=")
        curves[name or f"curve{i + 1}"] = parse_curve(pts)

    if a.tokenizer == "approx":
        tok = Approx()
    else:
        path = find_qwen_tokenizer() if a.tokenizer == "auto" else a.tokenizer
        tok = QwenBPE(path) if path else Approx()

    specs = a.dirs or [f"interactive={os.path.expanduser('~/.local/share/frog/sessions')}"]
    sessions = []
    for spec in specs:
        label, _, d = spec.rpartition("=")
        d = os.path.expanduser(d)
        for f in sorted(glob.glob(os.path.join(d, "*.jsonl"))):
            created = 0
            try:
                created = json.loads(open(f).readline()).get("created", 0)
            except ValueError:
                pass
            sessions.append((created, f, label or os.path.basename(d.rstrip("/"))))
    sessions.sort()

    observed = defaultdict(dict)
    for _, f, _ in sessions:
        for line in open(f):
            if '"tool_use"' not in line:
                continue
            try:
                r = json.loads(line)
            except ValueError:
                continue
            for b in (r.get("message") or {}).get("content", []):
                if b.get("type") == "tool_use" and isinstance(b.get("input"), dict):
                    for k in b["input"]:
                        observed[b.get("name", "")].setdefault(k, None)
    src = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "crates", "frog-engine", "src")
    render = Renderer(load_schemas(src), observed)

    glob_sam = SAM()
    rows = defaultdict(lambda: {k: Stat() for k, _ in STRATEGIES})
    meta = defaultdict(lambda: {"sessions": set(), "calls": 0, "forced": 0})
    sep = 0
    for _, f, label in sessions:
        sess_sam = SAM()
        for ev in replay(f, tok, render, a.thinking):
            if ev[0] == "done":
                for out in ev[1]:
                    sep -= 1
                    glob_sam.add(sep)  # a separator no match can cross
                    glob_sam.extend(out)
                continue
            _, model, ctx, out, forced = ev
            key = (label, model or "?")
            per = {k: Stat() for k, _ in STRATEGIES}
            simulate(ctx, out, forced, sess_sam, glob_sam, a, per)
            for k, st in per.items():
                rows[key][k].merge(st)
            meta[key]["sessions"].add(f)
            meta[key]["calls"] += 1
            meta[key]["forced"] += sum(forced)
            sep -= 1
            sess_sam.add(sep)
            sess_sam.extend(out)

    total = {k: Stat() for k, _ in STRATEGIES}
    by_model = []
    for key in sorted(rows):
        for k in total:
            total[k].merge(rows[key][k])
        m = meta[key]
        by_model.append({
            "group": key[0], "model": key[1], "sessions": len(m["sessions"]), "model_calls": m["calls"],
            "output_tokens": rows[key]["lookup"].tokens, "forced_share": m["forced"] / max(1, rows[key]["lookup"].tokens),
            "strategies": {k: summary(rows[key][k], curves) for k, _ in STRATEGIES},
        })
    n_sessions = len({f for m in meta.values() for f in m["sessions"]})
    n_calls = sum(m["calls"] for m in meta.values())
    forced_total = sum(m["forced"] for m in meta.values())
    overall = {k: summary(total[k], curves) for k, _ in STRATEGIES}
    hists = {k: histogram(total[k]) for k in ("lookup", "suffix/P", "suffix/G", "sfx/G+gram", "tree/G")}
    config = {"tokenizer": tok.name, "thinking": a.thinking, "alpha": a.alpha, "max_spec": a.max_spec,
              "min_prob": a.min_prob, "max_depth": a.max_depth, "copy_k": a.copy_k,
              "verify_cost": {k: [list(p) for p in v] for k, v in curves.items()},
              "sessions": n_sessions, "model_calls": n_calls, "output_tokens": total["lookup"].tokens,
              "forced_share": forced_total / max(1, total["lookup"].tokens)}
    if a.json:
        print(json.dumps({"config": config, "overall": overall, "by_model": by_model, "histograms": hists}, indent=2))
        return

    names = list(curves)
    print(f"{n_sessions} sessions, {n_calls} model calls, {config['output_tokens']:,} output tokens"
          f" ({'with' if a.thinking else 'without'} thinking), {config['forced_share']:.1%} grammar-forced")
    print(f"tokens: {tok.name}\n")
    print(f"{'strategy':<14} {'':<38} {'tok/step':>8} {'draft':>6} {'accept':>7} " + " ".join(f"{n:>10}" for n in names))
    for k, desc in STRATEGIES:
        o = overall[k]
        print(f"{k:<14} {desc:<38} {o['tokens_per_step']:>8.2f} {o['draft_per_step']:>6.1f} {o['acceptance']:>6.0%} "
              + " ".join(f"{o['speedup_' + n]:>9.2f}x" for n in names))

    short = [k for k, _ in STRATEGIES]
    for title, field in [("tokens per verify step", "tokens_per_step")] + [(f"est. speedup, {n}", "speedup_" + n) for n in names]:
        print(f"\n{title}")
        print(f"{'group':<12} {'model':<34} {'tokens':>7} " + " ".join(f"{k:>11}" for k in short))
        for r in by_model:
            print(f"{r['group'][:12]:<12} {r['model'][:34]:<34} {r['output_tokens']:>7} "
                  + " ".join(f"{r['strategies'][k][field]:>11.2f}" for k in short))

    print("\naccepted draft tokens per step (share of steps)")
    print(f"{'accepted':>8} " + " ".join(f"{k:>12}" for k in hists))
    for i, (lo, hi) in enumerate(BUCKETS):
        print(f"{hists['lookup'][i]['accepted']:>8} " + " ".join(f"{hists[k][i]['share']:>11.1%} " for k in hists))
    k = "sfx/G+gram"
    print(f"\n{k}, share of steps by accepted draft tokens")
    for row in hists[k]:
        print(f"{row['accepted']:>6} {row['share']:>6.1%} {'#' * round(row['share'] * 60)}")


if __name__ == "__main__":
    sys.exit(main())
