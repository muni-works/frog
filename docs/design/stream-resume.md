# Resumable streams

Status: design note (not built) · 2026-11-02

A model call that loses its stream mid-step today retries the whole step from scratch: the
partial reply is discarded (`ItemsDiscarded`), the request goes out again with the full context,
and the provider re-reads (and re-bills) the entire prefill. That is the right shape for most
calls — but at 143k input tokens the prefill is most of the cost and most of the latency, and a
reset that fires at the last SSE chunk throws all of it away. The better shape is **resuming
from the last complete item**: the stream's already-emitted events carry item ids, so a broken
attempt could record the last *completed* item (a finished tool call, a finished reasoning
block) and, on retry, resend the history up to that point, ask the provider to continue from
there (an assistant prefix the provider can key on, or frog cloud's `/v1/prefill` warm cache),
and keep the partials of only the one item that was still open. That turns a mid-body reset
from a full restart into a bounded tail retry — the difference between re-reading 143k tokens
and re-reading the last few hundred. It only works where the provider can honor an assistant
prefix honestly (no hallucinated continuation), so it belongs behind a capability flag like
`prompt_cache_key`/`prefill` already are; the safe default everywhere else stays today's
discard-and-retry. Blocked on: which providers accept a partial assistant message as history,
and how `ItemsDiscarded`'s client contract would grow an "items kept" counterpart.
