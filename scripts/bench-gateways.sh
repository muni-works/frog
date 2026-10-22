#!/usr/bin/env bash
# TTFT and output tok/s for a fixed ~2k-token prompt against Cloudflare Workers AI
# and the Vercel AI Gateway, at 1 and 4 concurrent streams. Part of the eval in
# docs/research/cloudflare-ai-gateway-eval.md.
#
# Keys come from the environment only (never printed, logged or written):
#   CLOUDFLARE_API_TOKEN + CLOUDFLARE_ACCOUNT_ID        (Cloudflare Workers AI)
#   AI_GATEWAY_API_KEY (or VERCEL_AI_GATEWAY_API_KEY)  (Vercel AI Gateway)
#
# Usage: scripts/bench-gateways.sh [rounds-per-cell]   (default 4; each round
# runs `conc` streams in flight, so a cell at c=4 and 4 rounds = 16 requests)

set -euo pipefail

N="${1:-4}"
tmp_dir="$(mktemp -d)"
PROMPT_FILE="$tmp_dir/prompt.txt"
trap 'rm -rf "$tmp_dir"' EXIT

# A fixed ~2k-token prompt (60 lines x ~32 tokens of greek-letter filler + instruction).
{
  printf 'Summarize the numbered list below as one paragraph of prose, then stop. Do not restate the list.\n\n'
  for i in $(seq 1 60); do
    printf '%s. alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma tau upsilon phi chi psi omega.\n' "$i"
  done
} >"$PROMPT_FILE"

stream_one() { # $1 out_file  $2 base_url  $3 model  -> writes "ttft_s tok_per_s"
  local out="$1" base="$2" model="$3"
  python3 - "$base" "$model" "$PROMPT_FILE" >"$out" 2>"$out.err" <<'PY'
import json, sys, time, urllib.request

base, model, prompt_file = sys.argv[1:4]
with open(prompt_file) as f:
    prompt = f.read()

body = {
    "model": model,
    "messages": [{"role": "user", "content": prompt}],
    "stream": True,
    "max_completion_tokens": 256,
    "reasoning_effort": "low",
}
req = urllib.request.Request(
    base.rstrip("/") + "/chat/completions",
    data=json.dumps(body).encode(),
    headers={"Authorization": __import__("os").environ["BENCH_KEY"],
             "Content-Type": "application/json",
             "Accept": "text/event-stream"},
)
start = time.monotonic()
ttft = None
tokens = 0
with urllib.request.urlopen(req, timeout=180) as resp:
    for raw in resp:
        line = raw.decode("utf-8", "replace").strip()
        if not line.startswith("data:") or line[5:].strip() == "[DONE]":
            if line[5:].strip() == "[DONE]":
                break
            continue
        try:
            chunk = json.loads(line[5:])
        except ValueError:
            continue
        choices = chunk.get("choices") or []
        piece = (choices[0].get("delta", {}) or {}).get("content") if choices else None
        if piece:
            if ttft is None:
                ttft = time.monotonic() - start
            tokens += 1
end = time.monotonic()
if ttft is None or tokens == 0:
    raise RuntimeError("no content tokens received")
print(f"{ttft:.3f} {tokens / (end - start):.1f}")
PY
}

RESULTS="$tmp_dir/results.tsv"
touch "$RESULTS"  # report reads it even when every cell was skipped

run_cell() { # $1 label  $2 base_url  $3 key  $4 model  $5 concurrency
  local label="$1" base="$2" key="$3" model="$4" conc="$5"
  export BENCH_KEY="$key" # passed to python by env; never echoed
  for _ in $(seq 1 "$N"); do
    local files=()
    for i in $(seq 1 "$conc"); do
      local f="$tmp_dir/w.$RANDOM"
      stream_one "$f" "$base" "$model" &
      files+=("$f")
    done
    wait
    for f in "${files[@]}"; do
      if [ -s "$f" ] && [ ! -s "$f.err" ]; then
        printf '%s\t%s\n' "$label" "$(cat "$f")" >>"$RESULTS"
      else
        printf 'error in [%s]: %s\n' "$label" "$(tail -c 200 "$f.err" 2>/dev/null || echo unknown)" >&2
      fi
      rm -f "$f" "$f.err"
    done
  done
  unset BENCH_KEY
}

report() { # $1 label
  python3 - "$RESULTS" "$1" <<'PY'
import sys

path, label = sys.argv[1:3]
rows = []
with open(path) as f:
    for line in f:
        parts = line.rstrip("\n").split("\t")
        if len(parts) == 2 and parts[0] == label:
            ttft, rate = parts[1].split()
            rows.append((float(ttft), float(rate)))

def median(v):
    s = sorted(v)
    n = len(s)
    return None if not n else (s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2)

def p90(v):
    s = sorted(v)
    return None if not s else s[min(len(s) - 1, max(0, int(round(0.9 * len(s))) - 1))]

if not rows:
    print(f"{label}: no successful samples")
else:
    ttfts = [r[0] for r in rows]
    rates = [r[1] for r in rows]
    print(f"{label}: n={len(rows)}  ttft median {median(ttfts):.2f}s p90 {p90(ttfts):.2f}s  "
          f"tok/s median {median(rates):.1f} p90 {p90(rates):.1f}")
PY
}

CF_RAN=0
VERCEL_RAN=0

# --- Cloudflare -------------------------------------------------------------
if [ -n "${CLOUDFLARE_API_TOKEN:-}" ] && [ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ]; then
  CF_BASE="https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/ai/v1"
  for conc in 1 4; do
    run_cell "cloudflare @cf/zai-org/glm-5.3 c=$conc" "$CF_BASE" "$CLOUDFLARE_API_TOKEN" \
      "@cf/zai-org/glm-5.3" "$conc"
    run_cell "cloudflare @cf/deepseek-ai/deepseek-v4.1-flash-1017 c=$conc" "$CF_BASE" \
      "$CLOUDFLARE_API_TOKEN" "@cf/deepseek-ai/deepseek-v4.1-flash-1017" "$conc"
  done
  CF_RAN=1
else
  echo "skipped cloudflare: CLOUDFLARE_API_TOKEN / CLOUDFLARE_ACCOUNT_ID not set" >&2
fi

# --- Vercel -------------------------------------------------------------------
VKEY="${AI_GATEWAY_API_KEY:-${VERCEL_AI_GATEWAY_API_KEY:-}}"
if [ -n "$VKEY" ]; then
  for conc in 1 4; do
    run_cell "vercel zai/glm-5.3 c=$conc" "https://ai-gateway.vercel.sh/v1" "$VKEY" \
      "zai/glm-5.3" "$conc"
  done
  VERCEL_RAN=1
else
  echo "skipped vercel: AI_GATEWAY_API_KEY not set" >&2
fi

echo
echo "=== results ($N round(s) per cell) ==="
for label in \
  "cloudflare @cf/zai-org/glm-5.3 c=1" \
  "cloudflare @cf/zai-org/glm-5.3 c=4" \
  "cloudflare @cf/deepseek-ai/deepseek-v4.1-flash-1017 c=1" \
  "cloudflare @cf/deepseek-ai/deepseek-v4.1-flash-1017 c=4" \
  "vercel zai/glm-5.3 c=1" \
  "vercel zai/glm-5.3 c=4"; do
  report "$label"
done
[ "$CF_RAN" = 1 ] || echo "cloudflare: not run"
[ "$VERCEL_RAN" = 1 ] || echo "vercel: not run"
