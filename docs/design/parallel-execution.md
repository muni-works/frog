# parallel execution in the engine

Status: layer 1 is built (branch `frog/sleep-events`); the rest is design only. Muxed sessions
(several work streams sharing one transcript) were dropped by Cam and are not part of this plan.

Ship order, each with what it needs first:

| # | layer | needs | state |
|---|---|---|---|
| 1 | parallel read-only tool calls | the events queue (wakes park, batch flush) | built |
| 2 | dependency-aware ordering | 1 | design |
| 3 | speculative tool prefetch while the model thinks | 1 | design |
| 4 | event queue with priorities and mid-turn addressing | 2, and the batch-flush queue | design |
| — | org fanning (managers as parallel schedulers) | prompt work, routed by the chief | sketch |

## 1. parallel read-only tool calls (built)

A reply's leading run of calls that change nothing starts together before the batch loop
(`run_tools`), and the loop takes their results in reply order, so history, events and the
session log are unchanged; only the waiting overlaps. The first call that could change
something closes the run: it waits for every read before it, and everything after it runs one
at a time. Reads the stream already started (`early.rs`) keep running.

Classification is the permission layers' own allow-without-a-card set (`auto::parallel_read`,
mirroring `permit`): Read, Grep, Glob, WebSearch, WebFetch of a public host, and shell commands
`shell::read_only` proves read-only (sandboxed, no credential paths, no `cd`, not a long wait).
So a call that runs early is one the user would never have been asked about. MCP reads stay
sequential for now (one connection per server, `&mut` client).

Impact: on a multi-tool turn of reads (3–6 greps/reads/fetches is the common shape) the tool
wait drops from the sum to roughly the slowest call: **about 2–4× less tool latency** on those
steps. Small local reads were already overlapped with streaming when the provider streams
`ToolReady`; the gain is largest for web reads and read-only shell commands, and for providers
that don't stream tool calls.

## 2. dependency-aware ordering

Today the first write ends the parallel run. Instead, treat a reply's calls as a graph with an
edge where two calls conflict, and run each call once everything it conflicts with ahead of it
has finished:

- **paths**: a Write/Edit to `p` conflicts with any read or write of `p` (and of a directory
  that contains it, for Glob/Grep); a shell command's paths come from `approval::missing` and
  the parser's arguments; unknown shell commands conflict with everything (they're the barrier
  they are today).
- **sessions**: SendMessage/StopSession to the same id stay ordered.
- **network**: calls to the same MCP server stay ordered (one connection); different servers
  can overlap.

Results still go back in reply order. Impact (estimate): replies that mix independent edits and
reads ("edit a.rs, read b.rs, grep c/") stop serializing behind the edit; maybe a further
1.2–1.5× on mixed turns. The risk is a wrong conflict set, so the fallback is "unknown means
barrier".

## 3. speculative tool prefetch

While the model is still thinking (prefill, the reasoning stream), guess the reads it will ask
for and start them on the side, the same way early calls run: result kept only if the reply
asks for exactly that call. Seeds: the files just edited (the model nearly always re-reads or
greps around an edit), the files named in the last tool output (compiler errors, test
failures), and prompt-lookup drafting applied to tool calls (the model's own earlier calls with
the same shape). Only `parallel_read` calls, so a wrong guess costs some I/O and nothing else.
Impact (estimate): hides one tool round-trip on maybe a third of steps; worth measuring with the
early-tool timing the turn already reports (`TurnTiming`).

## 4. event queue: priority and mid-turn addressing

Builds on the batch flush (wakes and session messages wait for the boundary and go as one
batch, `QueuedEvents` shows the queue live). Two additions:

- **priority classes**: `urgent` (a cap about to bill, a dead child, the user's own Stop),
  `normal` (job/monitor results, session messages), `quiet` (progress). Urgent items may end the
  current step early (never mid-tool): the model sees them at the next model call, not the next
  turn. Normal stays at the boundary. Quiet only updates the background block.
- **mid-turn addressing**: a `Queue` tool (`list`, `take <id>`) so the model can look at what's
  waiting and pull one item into the current turn when it needs it ("is the build done?"
  without polling). Taken items leave the batch.

Needs 2's conflict model to know when an urgent item may preempt (never between a write and
the read that checks it). Impact: fewer polling calls and faster reaction to money events; no
latency number worth guessing yet.

## org fanning (sketch)

The same idea one level up: a manager session is a scheduler. It already fans work out with
StartSession and gets reports back as session messages; the gap is prompt and policy, not
engine. A manager should split a brief into independent pieces up front (by files and
resources, the same conflict test as layer 2), start them at once in worktrees, and merge
reports as they land, instead of one worker at a time. The batch flush helps directly: reports
that land during a manager's turn arrive together at its next boundary. The chief is routing
the prompt side separately.
