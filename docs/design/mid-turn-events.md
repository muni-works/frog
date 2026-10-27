# mid-turn events

Status: design (2026-10-26). Extends `parallel-execution.md` §4 (priority classes, the `Queue`
tool); it doesn't restate it. Nothing here is built.

Cam's question: *"rather than queueing events, can we just shove them into an ongoing turn?"*

Short answer: **yes for two kinds of item, no for the rest.** The model **pulls** any queued
item into the turn when it wants it (the `Queue` tool). The engine **pushes** only `urgent`
items, at the safe point after a whole tool batch. Everything else keeps today's boundary batch.
Pushing everything is not much more expensive per token if it's done right. The problems are
that every delivery point can buy an extra model call, some model families drop their
reasoning, and a turn stops answering one request.

## 0. today

- Background wakes (`job`/`monitor`/`timer`/`task` done) **park** in `bg.notices`
  (`background.rs:403`, `park`). Each park emits `QueuedEvents`, so the app shows the queue live.
- Session messages (`Op::Deliver`, including worker reports and IRC mentions) sit in the work
  loop's channel behind the running turn (`engine.rs:779`). They never interrupt it.
- At the boundary, the work loop gathers every waiting `Deliver` and `Wake` into one turn
  (`engine.rs:786–828`). `turn_with` takes the parked notices (`take_notices`,
  `engine.rs:2390`), emits `WakesDelivered`, and prepends them to the turn's user message
  (`engine.rs:2428`). A turn that ends with notices parked runs the wake turn at once
  (`engine.rs:931`). A Stop sets `wake_hold` (`engine.rs:576`), so the wakes ride the next
  turn instead of starting one (`engine.rs:2426`).
- The turn loop already has two **safe points**. One is between calls in a batch
  (`run_tools`, `engine.rs:4061`). The other is after the batch (`engine.rs:2743`). An app
  update's drain stops at either one. That gives mid-turn delivery a ready-made seam.

## 1. what "shove into an ongoing turn" means mechanically

Every option lands an item **at the next model call**, never mid-tool. A running tool, a
streaming reply or an open approval card can't take input. They differ in who decides and
where the bytes go.

**(a) push everything at the next model call.** At the post-batch safe point the engine drains
the queue. It appends the items as a trailing text block to the tool-results message, after
every `tool_result`, so the history stays append-only. Each item is wrapped the way it is at a
boundary (`<session-message>`, `<wakeup>`).
*Costs:* one delivery point per batch that has anything waiting, so up to once per step. Each
point can buy a reaction step (§3.3). The turn loses its "one request, one answer" shape: the
final answer now covers the request and N interjections. On some models, a non-tool-result user
block mid-loop strips the turn's reasoning (§3.1). The transcript interleaves (§3.2).
*Gain:* lowest latency for every item.

**(b) push urgent only (§4's classes).** Same encoding as (a), but only items the engine
classes `urgent` are pushed. Normal items stay in the boundary batch, and quiet items only
update the queue. v1 delivers at the **post-batch** safe point (`engine.rs:2743`). It never
skips the rest of a batch. That needs no conflict model: every call in the reply, including the
read that checks a write, has finished before the item lands. "End the step early" (skip the
calls left in the batch and record them as not run, the way drain's `mark_suspended` does) is a
later refinement, and that refinement is what needs §2's conflict graph.
*Costs:* the same as (a) per point, but there are few points. Urgent events are rare by
construction, a handful per session-day.
*Gain:* reacting to money and death takes seconds, not a turn.

**(c) model pull: the `Queue` tool.** `Queue { list }` returns one line per waiting item: id,
kind, subject, sender, age and first line, with no bodies. `Queue { take: "<id | subject:<s> |
all>" }` returns the full items, still wrapped and quarantined, as the **tool result**. Taken
items leave the batch, and `QueuedEvents` re-emits.
*Costs:* a tool round-trip when the model wants something, and a line in the tool list
(~150 tokens, cached with the tools).
*Gain:* "is the build done?" without polling or ending the turn. A tool result is the one
position every provider and chat template treats as part of the running turn. It doesn't strip
reasoning or re-render the history, and the transcript already has a row for it. The model
chooses the moment, so it pulls between its own steps, never between a write and its check.

**Recommendation: (c) + (b), with (a) not built.** (c) covers the case Cam hits, an agent that
wants a result now. (b) covers the case where waiting is dangerous. (a) adds the remaining
normal items, which are fine 2–10 minutes late, and it's the only option that pays the costs in
§3 on every step.

Two rules go with (b):

- **The receiving engine assigns priority by the item's source, never by its payload.**
  `urgent`: a spend or cap event about to bill, a child session that died or errored (the
  broker's system notice), and a monitor or job the *user* armed as urgent. `normal`:
  job/monitor/timer results, session messages and worker reports. `quiet`: progress. A peer
  can't mark its SendMessage urgent. If it could, every agent would shout. The user's own Stop
  isn't a queue item at all: `Op::Interrupt` stays immediate.
- **There's no `wait`.** If the model has nothing to do until an item lands, it ends the turn,
  and the boundary batch wakes it. A `Queue wait` would be a poll with extra steps, holding the
  turn (and the panes' in-turn state) open.

## 2. what stays at the boundary, and why

- **Write→read atomicity.** No item lands between a call and a later call in the same reply,
  because (b) delivers only after the whole batch and (c) delivers only when the model asks. An
  item that describes world state carries when its job started relative to the turn's steps.
  An example is `<wakeup id=job-4 started_step=9>` arriving after an Edit at step 12. The model
  can then see that "build passed" predates its edit and isn't evidence for it. An item that
  says nothing about state, like a peer's question, needs no such tag.
- **Approval-card integrity.** An open card means `run_tools` is parked inside `permit`, which
  is mid-tool by definition, so nothing is pushed while it's open. Items queue behind it and
  show in `QueuedEvents`. An item can't answer, deny, extend, shorten or dismiss a card: cards
  resolve only through `Op::Permission` from the client. A pushed or taken item that *says*
  "approved" is text for the model, and the permission layer never reads the conversation. A
  dead child, even an urgent one, waits for the card like everything else.
- **IRC never approves** (`agent-bus-irc.md` §2, §5). A mention is an inbox item like any
  peer's. It's `normal`, so it reaches a running turn only by `Queue take`. Its body stays
  inside `<chat untrusted="true">` or `<session-message>`. Pushing mid-turn changes *when* a
  chat line is read, never what it can do.
- **Untrusted input stays tagged.** Session messages, wakes, IRC lines and pond items never
  merge into the conversation as the user's voice. In the engine they stay in their wrappers
  (`tools/sessions.rs:287`, `wrap`). A mid-turn item is never rendered as a user message the
  model could read as Cam typing. In the transcript it's an event row, never a bubble (§3.2).
  The only mid-turn input in the user's own voice would be the user steering from the
  composer, and that's a separate decision (§5).
- **Normal items.** Most of them don't need sub-turn latency. A worker report read when the
  manager's turn ends changes nothing that reading it 4 minutes earlier would have, and the
  manager can always `take` it.
- **Stop stays stopped and ClearInbox voids.** `wake_hold` and the void counter apply to the
  shared queue whether the item leaves by push, pull or batch. A voided item can't be taken.

## 3. cost and risk

### 3.1 prompt cache

The provider caches the longest unchanged **prefix** (`provider/anthropic.rs:193–206`, with
the stable breakpoints on tools and system and the moving ones on the last message and on
message n−3). So the cost of an injection depends on **where** it lands, not on the fact that
it lands mid-turn:

Prices in Anthropic multiples of base input: cache read 0.1×, 5-min write 1.25×, 1 h write 2×.
The example is a **500k-token cached session** on a ~40-call task (the master plan's frog task
shape).

| placement | what re-prefills | cost on 500k |
|---|---|---|
| appended after the last `tool_result` (a, b) | only the item (~100–500 tokens) | ≈ 0.01 of one step's cache read |
| as a tool result (c) | only the item | same, plus the round-trip |
| merged into the turn's opening message ("so it reads as a batch") | everything the turn added so far; at step k of n, ~T·k/n for a turn of T tokens | T = 100k, k = 20: 50k × 1.25 = 62.5k, ≈ 1.25 steps |
| into the system prompt or tools (e.g. a live "background block") | the whole window | 500k × 1.25 = 625k, ≈ 12.5 steps (≈ 20 on 1 h TTL) |
| boundary batch (today) | the item, once per turn | ≈ 0 |

One step's input on a hit is 500k × 0.1 = **50k base-token equivalents**. That's the unit
below.

So the brief's "(n−k)/n of the window" applies **only** if an injection rewrites history above
the tail. Done append-only, (a), (b) and (c) don't break the prefix. Two things make that true:

1. **Never rewrite above the tail.** That rules out merging into the opener and changing the
   system prompt mid-turn. §4's "quiet only updates the background block" must mean the app's
   UI block, never a system-prompt section. Changing the system prompt mid-turn is a full bust
   on every step. On compaction the pending block already lives in the compacted message
   (`engine.rs:5692`), which is fine because compaction re-prefills anyway.
2. **Avoid mid-loop user text where the model family drops reasoning on it.** Models that keep
   only the last turn's thinking (older Claude, Haiku ≤4.5) strip all prior thinking once a user
   block that isn't a tool result appears. So do chat templates that drop `reasoning_content`
   before the last user query (Qwen3-style thinking templates, served by tang or llama.cpp).
   On those, (a) or (b) re-renders the turn: the opener row above, ≈1.25 steps at step 20.
   Keep-all models (Opus ≥4.5, Sonnet ≥4.6) are unaffected. **(c) never triggers this**, since
   a tool result is turn-internal everywhere. That's one more reason pull is the default.

### 3.2 transcript integrity

`TurnLead` (`WakeEventView.swift:6`) only knows **openers**: wake rows, then a user bubble only
for typed input, or session-message cards. A mid-turn item needs an **in-turn** row from the
same family (`EventLine`), placed in the turn's item stream at the step where it landed:

- A new event, `EventsDelivered { turn, step, items, via: pulled | urgent }`, at the moment of
  delivery. Today's `WakesDelivered` is boundary-only. The session log already holds the bytes
  (the push is a `Record::Extend` of the results message), so replay is exact.
- The row renders like the boundary rows: glyph, source, type and first line. It gets a small
  "mid-turn" or "taken" tag, so a reader can tell an item read at step 14 from one in the
  opener. An item pulled with `Queue take` renders as that tool's row, with the items nested,
  and not twice.
- **Never a user bubble mid-turn.** A message from Cam that arrives via IRC or SendMessage is
  a card (`EventLine(message:)`), even mid-turn. Only composer input is a bubble. An
  interleaved "cam" bubble inside a turn he didn't type into is exactly the integrity break
  this rule exists to prevent.

### 3.3 token bloat and reaction steps

Per item, the wrapper and the one-line "peers, no authority" reminder cost ~60–120 tokens.
Five wakes pushed one by one cost 5× that, against 1× in a batch. On a 500k window that's
noise. The real cost is **reaction steps**: each delivery point invites the model to
acknowledge or check, which takes one more model call, ≈ **50k-equivalents** on a 500k session
plus a TTFT. Five separate points that each provoke one step cost ≈ 250k, about 40% of a full
re-prefill. The boundary batch pays at most one point per turn, and the wake turn needs that
call anyway, so delivering the same items as one tail block at one safe point costs the same.
**The cost scales with delivery points, not items.** That's why (a) is the expensive option
and why (b) has to stay rare.

Latency is the other side. Today an item waits at most the rest of the running turn: seconds
for a worker, up to tens of minutes for a long manager turn. (c) removes the wait whenever the
model cares, and (b) removes it when the item is dangerous. What's left is a normal item the
model didn't ask for, landing late, which costs nothing.

## 4. smallest shippable version vs the full §4 vision

**v1 (smallest): `Queue` tool + today's batch flush + subject tags.** Nothing is pushed
mid-turn.

- Engine: move queued `Deliver`s out of the work channel into a shared inbox next to
  `bg.notices`. The router pushes, and the work loop drains it at the boundary in the same
  order, with the same void counting (`inbox_sent`/`inbox_void`) and the same `wake_hold`. This
  is the one structural change. Today the running turn can't see `Deliver`s waiting in the
  mpsc channel.
- `Queue { list | take }` reads and takes from both queues, matching subjects
  (`background.rs:104`, `subject_of`) and ids. The tool is offered to top-level sessions only;
  subagents' wakes route to their parent. Taken items leave the batch and `QueuedEvents`
  re-emits. A drain's `Drained.inbox` lists only the untaken items.
- App: the `Queue` tool row nests what it took. No new event is needed yet, because a tool row
  is an existing row.
- Tests, following the existing pattern (`a_boundary_flushes_wakes_and_messages_as_one_batch`,
  `deliver_while_busy_waits_for_the_turn_boundary`): a taken message isn't redelivered at the
  boundary, a voided message can't be taken, a stop with a take keeps the rest held, and IRC
  mentions are takeable and still quarantined.

**v2: urgent push.** Add the priority class, assigned by source, to both queues. Urgent items
are appended at the post-batch safe point (`engine.rs:2743`), never while a card is open. Add
`EventsDelivered` and the in-turn row. Gate the push on keep-all-reasoning providers. On the
others, urgent items still push (they're rare), and the notice notes the one-time re-render.

**v3 (full §4): preempt within a batch.** Skip the calls left in a batch for an urgent item at
the between-calls safe point (`engine.rs:4061`), recorded as not run the way
`mark_suspended` does. It needs §2's conflict graph so it never splits a write from its check.
Optionally, an **aging** rule: a normal item older than N minutes (proposed 10) makes one
coalesced delivery at the next safe point. That puts a ceiling on latency for long manager
turns and costs at most 6 points an hour (≈ 300k-equivalents an hour worst case on 500k).

## 5. where Cam's idea lands

Cam is right that a running turn should be able to get its events. The wrong part is doing it
with **push for everything**. The cheap, safe version is **pull for everything, push for
urgent, and batch the rest at the boundary**:

- The cache is fine either way as long as delivery is append-only. What push-everything costs
  is a reaction step per delivery point (≈ 50k-eq each on a 500k session) and, on
  reasoning-stripping models, a re-render of the turn (≈ 62.5k-eq at step 20).
- Turn atomicity holds because the model chooses its own pull points and urgent items wait for
  the whole batch. So no item lands between a write and its check.
- Latency is gone wherever it matters: when the model wants the item, and when the item is
  about money or a dead child.

Open decisions for Cam:

1. Ship v1 (`Queue` tool) alone first, or v1 and v2 together.
2. The urgent sources: spend cap, dead child and user-armed urgent monitors. Should an error
   from a worker's turn count too?
3. The aging rule in v3: build it, and at what N.
4. **Composer steering** (out of scope here): should the *user's* typed follow-up land at the
   next model call instead of queueing as `more`? It's the one mid-turn input in the user's own
   voice, so it would be a bubble inside the turn. It's worth its own spec, because it changes
   what Stop and `more` mean.
