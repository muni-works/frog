#!/usr/bin/env python3
"""Agent-like load (derived from tang scripts/prefix-replay.py) for any OpenAI-compatible server.
Sessions share a SYS_TOK-word system block, open with FIRST_TOK words, then TURNS turns of
MAX_TOKENS output + TOOL_TOK-word tool result. CONC requests in flight, SESSIONS = max(2*CONC, 4).
Reports aggregate output tok/s, per-stream decode tok/s, TTFT p50/p95, prefix hit rate."""
import json, os, random, threading, time, urllib.request

URL = os.environ.get("URL", "http://127.0.0.1:8000")
MODEL = os.environ.get("MODEL", "coder")
CONC = int(os.environ.get("CONC", 4))
SESSIONS = int(os.environ.get("SESSIONS", max(2 * CONC, 4)))
TURNS = int(os.environ.get("TURNS", 6))
SYS_TOK = int(os.environ.get("SYS_TOK", 3000))
FIRST_TOK = int(os.environ.get("FIRST_TOK", 800))
TOOL_TOK = int(os.environ.get("TOOL_TOK", 700))
MAX_TOKENS = int(os.environ.get("MAX_TOKENS", 256))
LABEL = os.environ.get("LABEL", "run")
OUT = os.environ.get("OUT", ".")

WORDS = ("file function return value error test module import class struct impl trait async "
         "await buffer index token cache slot state layer kernel prefix session request parse "
         "build check config path line column string number vector matrix tensor shape batch "
         "decode prefill window memory device host copy write read open close lock queue").split()


def text(rng, n):
    lines, line = [], []
    for _ in range(n):
        line.append(rng.choice(WORDS))
        if len(line) == 12:
            lines.append(" ".join(line)); line = []
    return "\n".join(lines + [" ".join(line)])


SYSTEM = ("You are a coding agent. Tools:\n<IMPORTANT>\n" + text(random.Random(7), SYS_TOK)
          + "\n</IMPORTANT>\nWorking directory: /repo\n")


def post(body):
    req = urllib.request.Request(URL + "/v1/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    t0 = time.time(); ttft = None; content = []; usage = None
    with urllib.request.urlopen(req, timeout=3600) as r:
        for raw in r:
            line = raw.decode().strip()
            if not line.startswith("data:"):
                continue
            d = line[5:].strip()
            if d == "[DONE]":
                break
            j = json.loads(d)
            if j.get("usage"):
                usage = j["usage"]
            for c in j.get("choices") or []:
                piece = (c.get("delta") or {}).get("content")
                if piece:
                    if ttft is None:
                        ttft = time.time() - t0
                    content.append(piece)
    return ttft, "".join(content), usage, time.time() - t0


rows, lock = [], threading.Lock()
sem = threading.Semaphore(CONC)


def session(i):
    rng = random.Random(1000 + i)
    msgs = [{"role": "system", "content": SYSTEM},
            {"role": "user", "content": f"Task {i}:\n" + text(rng, FIRST_TOK)}]
    for turn in range(TURNS):
        body = {"model": MODEL, "messages": msgs, "max_tokens": MAX_TOKENS, "stream": True,
                "stream_options": {"include_usage": True}, "temperature": 0,
                "ignore_eos": True, "min_tokens": MAX_TOKENS,
                "prompt_cache_key": f"session-{i}", "user": "bench"}
        with sem:
            ttft, content, usage, wall = post(body)
        u = usage or {}
        cached = (u.get("prompt_tokens_details") or {}).get("cached_tokens") or 0
        with lock:
            rows.append({"session": i, "turn": turn, "ttft": ttft, "wall": wall,
                         "prompt": u.get("prompt_tokens", 0), "cached": cached,
                         "out": u.get("completion_tokens", 0), "t": time.time()})
        msgs = msgs + [{"role": "assistant", "content": content},
                       {"role": "user", "content": f"Tool result {turn}:\n" + text(rng, TOOL_TOK)}]
        time.sleep(rng.uniform(0.2, 1.5))


def pct(xs, p):
    xs = sorted(xs)
    return round(xs[min(len(xs) - 1, int(p * len(xs)))], 3) if xs else None


t0 = time.time()
ths = [threading.Thread(target=session, args=(i,)) for i in range(SESSIONS)]
for t in ths:
    t.start(); time.sleep(0.2)
for t in ths:
    t.join()
wall = time.time() - t0
prompt = sum(r["prompt"] for r in rows); cached = sum(r["cached"] for r in rows)
out = sum(r["out"] for r in rows)
ttfts = [r["ttft"] for r in rows if r["ttft"] is not None]
stream = [(r["out"] - 1) / (r["wall"] - r["ttft"]) for r in rows
          if r["ttft"] is not None and r["out"] > 1 and r["wall"] > r["ttft"]]
s = {"label": LABEL, "conc": CONC, "sessions": SESSIONS, "requests": len(rows),
     "prompt_tokens": prompt, "cached_tokens": cached, "hit_rate": round(cached / max(prompt, 1), 4),
     "prompt_per_out": round(prompt / max(out, 1), 1),
     "ttft_p50_s": pct(ttfts, 0.5), "ttft_p95_s": pct(ttfts, 0.95),
     "stream_tok_s_p50": pct(stream, 0.5), "wall_s": round(wall, 1), "output_tokens": out,
     "agg_out_tok_s": round(out / wall, 1),
     "agg_total_tok_s": round((out + prompt - cached) / wall, 1)}
os.makedirs(OUT, exist_ok=True)
json.dump({"summary": s, "rows": rows}, open(os.path.join(OUT, f"load-{LABEL}-c{CONC}.json"), "w"))
print(json.dumps(s), flush=True)
