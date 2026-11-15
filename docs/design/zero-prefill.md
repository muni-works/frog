# Zero-prefill turns

Roadmap bet 1: when you send a message to a model frog serves itself, the server has already
read everything before it, so time to first token is close to zero. It applies to tang (this
Mac's sidecar, `frog node` pools, Frog Cloud). Third-party providers can't be prefilled.

Status (2026-11-15): most of it shipped on 2026-10-01 for the Mac's own tang (roadmap
"Zero-prefill turns", M1, M3, M4) and tang has since replaced per-slot caches with paged,
content-addressed blocks (M5). This doc records how it works end to end, what this change
adds, and what's left, mostly Frog Cloud and tang's Flash backend.

## What exists

frog:

- `Op::Warm { draft }` (`crates/frog-engine/src/protocol.rs`): prefill this conversation now,
  with `draft` as the next user message. Emits nothing.
- The Mac composer sends it when a conversation is shown, when the app comes to the front,
  and after each pause in typing, with at most 32k characters of draft
  (`apps/macos/Frog/Views/ComposerView.swift`, `warm()`).
- `Agent::warm` (`engine/window.rs`) builds the request exactly as `turn` will: pending `!cmd`
  output, then the draft, merged into a trailing user message. It sends it in the background,
  one at a time; a newer draft replaces a queued one. The turn drops a queued draft when it
  starts (`turn.rs`).
- The engine also warms after a model switch (`window.rs`, end of model setup) and after
  pruning at a turn's end (`turn.rs`), so the next turn doesn't pay for the rewrite.
- `prompt_cache_key = session_id` on every call and warm-up (`call.rs`), sent only when the
  server takes it (`Provider::extensions`: tang lists `prompt_cache_key` and `prefill` among
  the model's capabilities in `/v1/models`).
- `openai::Client::prefill` posts the chat body, minus `stream`, to `{base}/prefill`.
- Every call records `extends` and `reusable` against the last request sent to the same
  conversation, whether a call or a warm-up (`CallTiming`, `engine/mod.rs` `reuse`).
  `frog-bench`'s cache report reads them: hit rate, prefill per call, cold calls, rewrites,
  reopened conversations (`crates/frog-bench/src/cache.rs`, `bench/cache/*`).
- Prompt byte stability: the repo map is fixed after the first turn, MCP tools are taken on
  only between turns, and pruning happens at turn boundaries (roadmap, shipped 2026-10-04).

tang (`~/Developer/tang`, `crates/tang-llm`):

- Dense engine. `prompt_cache_key` picks the conversation's sequence (`slots.rs`,
  `engine.rs`), with `TANG_KV_SLOTS=auto` budgeting half of RAM. KV lives in paged blocks of
  256 positions, content-addressed by a hash chain over token ids and shared across
  conversations (`blocks.rs`, `docs/paged-kv.md`).
- `/v1/prefill` (`server.rs` `prefill`): a chat body with `prefill_only`, answered with
  `{usage}` once the cache holds it.
- Background requests (`x-frog-priority: background`) yield between prefill chunks to
  interactive ones, and resume where they stopped (`queue.rs`, `tests/yield_prefill.rs`).
- Disk tier (`kvstore.rs`, `~/.cache/tang/kv/`): `blocks/<hash>.kvb` holds sealed blocks,
  written once; `<key-hash>.tail` holds a conversation's private tail, rewritten each turn.
  `TANG_KV_DISK=<GB>` (default 8, 0 = off) sets the size, evicting least recently used first.
  Restoring a prompt walks its hash chain: pool, then disk, then the tail.
- `--kv-ttl` bounds how long any of that outlives its last use (`docs/retention.md`).
- `/node` reports `kv.prompt_cache_keys` (each key's cached length). `frog node` placement
  uses it, and the node holding the key wins ties (`frog-engine/src/nodes.rs`).
- Flash backend (`flash/serve.rs`, prod coder-next): keeps the live sequence plus saved
  `RunningState`s at the system prompt (pinned), at turn boundaries and at the end of each
  request. It honours `prefill_only` and `prompt_cache_key` (slots under `--batch`). Its disk
  tier is `flash/kvstore.rs`: content-addressed segments, with hot NVMe and an optional cold
  volume. It does **not** yield a background prefill (`server.rs` header).

Measured on the Mac (roadmap, 2026-10-01): switching between two 7k-token conversations
re-prefills in about 250 ms instead of 9 s; a resumed 7.3k-token session's first turn takes
0.1 s instead of 13 s; a 13.5k-token message with a pasted log, typed ahead, takes 0.1 s
instead of 36 s.

## Slot lifecycle

A slot is tang's state for one `prompt_cache_key`: a block table, its tokens, and a private
tail. frog never manages slots directly. It sends whole prompts, and tang reuses the longest
prefix it holds.

1. **Open.** The client shows a conversation and sends `Warm {}`. The engine warms the
   history as it stands. tang restores the slot from the pool or from disk, or prefills it.
2. **Typing.** On each pause the client sends `Warm { draft }`. tang extends the slot with the
   draft. A shorter or edited draft is truncated back to the common prefix
   (copy-on-write), so only the changed tail is prefilled again.
3. **Send.** The turn's first request is the warmed one, byte for byte (tested), so tang
   prefills nothing it already read. The draft's end-of-message and generation-prompt tokens
   are new, a handful at most.
4. **During the turn.** Each call appends to the last one. A draft typed now is held until the
   turn ends (this change), because a warm-up would queue behind the turn's own calls.
5. **Between turns.** If pruning rewrote the history, the engine warms the result while you
   read the reply.
6. **Idle and evicted.** tang drops the least recently used parked conversation when the pool
   needs room. Its sealed blocks stay on disk until the disk budget or the TTL removes them.
7. **Resume or restart.** A reopened session sends the prompt it last logged (the repo map is
   logged), and `Warm {}` on show restores it from disk.

## Wire

| hop | what | status |
| --- | --- | --- |
| app → engine | `{"op":"warm"}` and `{"op":"warm","draft":"…"}` | shipped 2026-10-01 |
| engine → tang | `POST {base}/prefill`: chat body, `prompt_cache_key`, no `stream` | shipped 2026-10-01 |
| engine → tang | `x-frog-priority: background` on every warm-up | **this change** |
| engine → tang node | the same, on the node placement picks; that node is preferred next | **this change** |
| tang → engine | `/v1/models` `capabilities: ["prompt_cache_key", "prefill", …]` | shipped |
| tang → frog node | `/node` `kv.prompt_cache_keys: [{key, cached_tokens}]` | shipped |

No new protocol op was needed: "draft in progress" is `Warm { draft }`.

## What invalidates a slot

frog sends the whole prompt every time. "Invalidated" means the next request stops extending
the last one at some point, and tang prefills from that point on. `CallTiming.extends = false`
records it, and the bench counts these calls as rewrites.

| change | what's re-prefilled | handled |
| --- | --- | --- |
| draft edited before send | the draft from the first changed token | next warm-up |
| draft sent with `@path` or named files | the inlined file text (appended after the draft) | on send (gap 4) |
| draft sent with images | the image tokens | on send (images are never sealed in tang) |
| a background job finished before send | the draft (the wake notice goes ahead of it) | on send (gap 5) |
| MCP server connected between warm and send | everything after the tools block | on send (gap 6) |
| pruning at a turn's end | from the first pruned result | warmed at turn end |
| compaction | the whole history | the compacting turn pays |
| edit or rewind of an earlier message | from that message | on send |
| model switch | everything (a different model, a different cache) | warmed on switch |
| system prompt change (harness tier, mode) | everything | on send |
| tool list change (mode, MCP) | everything after the tools | on send |
| file edits | nothing: the repo map is fixed after the first turn | — |
| server restart | nothing if the disk tier holds it | `Warm {}` on show |

## Disk format and eviction

tang owns all of it. frog keeps no KV.

- Dense: `blocks/<hash>.kvb` holds a sealed 256-position block (its tokens plus bf16 K/V rows,
  position-major), written once and only touched after that. `<key-hash>.tail` holds the
  private tail. Budget `TANG_KV_DISK` (8 GB), least recently used out first; `--kv-ttl`
  deletes files older than the TTL. RAM: half of RAM with `--kv-slots auto`, the least
  recently used parked conversation dropped first.
- Flash: `kv/{H}-{from}-{to}.kv` holds K/V row segments shared by prefix, and
  `states/{n}-{H}.state` the running state. Hot budget `TANG_FLASH_DISK_GB` (8), with an
  optional cold tier (`TANG_KV_COLD_DIR`, 64 GB); least recently used files move hot → cold →
  deleted. Zest runs `--kv-ttl 3600`.

## Measuring it

- `frog-bench run --tasks bench/cache`: per call, prompt, cached and prefilled tokens and time
  to first token. Per task: hit rate, prefill per call, cold calls, rewrites, reopened hit rate.
- New: a `[[then]]` turn with `typed_secs = N` sends its prompt as `Warm { draft }`, waits N
  seconds, then sends it. Its first call is marked `typed`, and the report's `typed s` column
  is those calls' mean time to first token. `bench/cache/typed-ahead` sends a long message
  with a pasted log typed ahead, then an equally long one cold. The bet holds when `typed s`
  is a small fraction of the cold turn's time to first token and the typed call is neither
  cold nor a rewrite.
- Engine tests (`engine/tests.rs`, "Warm-ups") check the invariant the bench measures: the
  warmed request is byte for byte the start of the turn's request.

## This change (frog)

- The scripted provider can prefill (`with_prefill`, with an optional gate), so warm-ups are
  tested for the first time: draft is the prefix of the send, a new session's first message,
  pending shell output, coalescing, a send dropping a queued draft, mid-turn drafts.
- A draft typed mid-turn is warmed when the turn ends, unless a message sent meanwhile made it
  stale. Before, it was dropped, and the composer never sends the same text twice.
- Warm-ups are `x-frog-priority: background` on every server, so a stale draft or another
  conversation's warm-up never holds up a turn.
- `frog node` pooled models warm on the node placement picks; that node is preferred next. A
  warm-up never starts this Mac's tang.
- `frog-bench` typed-ahead turns and the `typed s` column.

## Gaps, smallest first

1. tang: a `/v1/prefill` without a priority is background, which covers frog 0.5 clients
   already out. Done: muni-works/tang#282 (CPU-tested, not merged).
2. Frog Cloud (zest, private): the edge and router have no `/v1/prefill` route, and the
   router's `/v1/models` doesn't list `prefill`. So Frog Cloud gets no warm-ups at all today.
   The route needs the same `prompt_cache_key` affinity as chat (`edge/src/fleet.ts`). Small,
   but see question 1.
3. tang Flash backend: yield a background prefill to an interactive request (dense does).
   Without it, a typed-ahead warm of a long draft on coder-next delays the send when the user
   is faster than the prefill, and delays other users' turns. Needs a GPU to verify. Plan:
   pass the queue-aware `Control` into the non-batch `generate` (today `&mut ()`), stop at a
   wide-prefill chunk boundary, and save a `RunningState` there so the resume continues from
   it, as `tests/yield_prefill.rs` does for dense; then the same for `serve_batch.rs` slots.
4. Warm with expansions: run `@path`, named-file and skill expansion on the draft (read-only)
   so the inlined text is warmed too. That costs file reads on every pause, so it may want a
   size cap.
5. Wake notices go ahead of the user's words at turn start; putting them after would keep the
   draft a prefix. This changes what the model sees, so it needs a check against the bench
   first.
6. Take MCP tools on before a warm-up (as turn start does), so a server that finished
   connecting between warm and send doesn't invalidate the tools block.
7. tang dense: seal blocks as they fill rather than at the end of a request, and give pool
   memory back (`docs/paged-kv.md` "Not done").
8. Clients: the CLI TUI and the web app don't send `Warm` yet. The web app is cloud-only, so
   it waits on gap 2.

## Open questions for Cam

1. **Frog Cloud warm-ups cost GPU time, including drafts that are never sent.** Do we bill
   prefill-only tokens (dollars per token, maybe at a cached or discounted rate), absorb them,
   or cap warm-ups per user? This decides whether gap 2 ships.
2. **Drafts leave the machine before send.** On the Mac's tang that's local. On a paired node
   or Frog Cloud, text the user may delete is sent and held for the KV TTL. Is that fine as
   is, or does it want a setting or a mention in `docs/privacy.md`?
3. **Flash yield (gap 3) before typed-ahead on coder-next?** Or ship gap 2 with warm-on-open
   only (`Warm {}`, no draft) until the Flash backend yields.
4. **Should warm-ups expand `@mentions` and named files (gap 4)?** The trade is file reads on
   every typing pause against prefilling those files on send.
5. **The roadmap still lists M2 (bf16) and M5 (paged blocks) as to do;** tang's
   `docs/paged-kv.md` says both are done. Update the roadmap line?
