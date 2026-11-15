"""vLLM coder-next baseline: prefill and decode tok/s at context L, batch B.
Random token-id prompts (like llama-bench), prefix cache off, greedy, ignore_eos.
prefill_tok_s = B*L / t(max_tokens=1); decode = B*(N-1) / (t(N) - t(1)).
Each point: 1 warmup + best of 3."""
import json, sys, time, random
from vllm import LLM, SamplingParams
from vllm.inputs import TokensPrompt

MODEL = sys.argv[1]
N = 129
llm = LLM(MODEL, max_model_len=33024, gpu_memory_utilization=0.92, enable_prefix_caching=False,
          enable_chunked_prefill=True, max_num_seqs=64, max_num_batched_tokens=16384)
rng = random.Random(0)
def prompts(b, L):
    return [TokensPrompt(prompt_token_ids=[rng.randrange(1000, 150000) for _ in range(L)]) for _ in range(b)]
def run(b, L, n):
    sp = SamplingParams(max_tokens=n, temperature=0, ignore_eos=True)
    p = prompts(b, L)
    t = time.perf_counter(); llm.generate(p, sp, use_tqdm=False); return time.perf_counter() - t
for L in (4096, 32768):
    for b in (1, 4, 16):
        run(b, L, 2)  # warm
        tp = min(run(b, L, 1) for _ in range(3))
        tn = min(run(b, L, N) for _ in range(3))
        dec = b * (N - 1) / max(tn - tp, 1e-9)
        r = {"context": L, "batch": b, "prefill_s": round(tp, 3), "prefill_tok_s": round(b * L / tp, 1),
             "decode_tok_s": round(dec, 1), "decode_stream_tok_s": round(dec / b, 1), "gen_tokens": N - 1}
        print("ROW " + json.dumps(r), flush=True)
print("BENCHDONE", flush=True)
