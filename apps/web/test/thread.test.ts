import { test } from "node:test";
import assert from "node:assert/strict";
import { emptyThread, reduce } from "../src/engine/thread.ts";
import type { Envelope, Event } from "../src/cloud/protocol.ts";

let seq = 0;
const env = (e: Event) => ({ ...e, seq: ++seq, session: "s1", created: 0 }) as Envelope;

test("model, mode and context follow status and the *_changed events", () => {
  let t = emptyThread;
  assert.equal(t.model, null);
  t = reduce(t, env({ event: "status", model: "cloud/qwen3-coder-next", mode: "default", context_tokens: 12_000, context_window: 128_000 }));
  assert.equal(t.model, "cloud/qwen3-coder-next");
  assert.equal(t.mode, "default");
  assert.deepEqual(t.context, { used: 12_000, window: 128_000 });
  t = reduce(t, env({ event: "mode_changed", mode: "accept-edits" }));
  t = reduce(t, env({ event: "model_changed", model: "cloud/qwen3-8b" }));
  assert.equal(t.mode, "accept-edits");
  assert.equal(t.model, "cloud/qwen3-8b");
});

test("an ask replayed after a reconnect is answerable, and its answer clears it", () => {
  let t = emptyThread;
  t = reduce(t, env({ event: "turn_started", turn: 1, input: "go" }));
  t = reduce(t, env({ event: "item_started", id: "i1", kind: { type: "tool_call", name: "Bash", arg: "npm test" } }));
  t = reduce(t, env({ event: "permission_request", id: "p1", item: "i1", name: "Bash", arg: "npm test", always: "" }));
  assert.equal(t.ask?.id, "p1");
  t = reduce(t, env({ event: "permission_resolved", id: "p1", decision: "allow" }));
  assert.equal(t.ask, null);
});

test("progress and notices show what a running turn is doing, until output or the end", () => {
  let t = reduce(emptyThread, env({ event: "turn_started", turn: 1, input: "hi" }));
  t = reduce(t, env({ event: "progress", label: "thinking" }));
  assert.deepEqual(t.activity, { text: "thinking", warn: false });
  t = reduce(t, env({ event: "notice", level: "warn", message: "429 too many concurrent requests — retrying in 4s (2/6)" }));
  assert.equal(t.activity?.warn, true);
  t = reduce(t, env({ event: "item_started", id: "m", kind: { type: "message" } }));
  t = reduce(t, env({ event: "item_delta", id: "m", delta: { type: "text", text: "Hi!" } }));
  assert.equal(t.activity, null);
  t = reduce(t, env({ event: "progress", label: "thinking" }));
  t = reduce(t, env({ event: "turn_ended", turn: 1, reason: { type: "complete" } }));
  assert.equal(t.activity, null);
});

test("a finished turn keeps its usage and end reason for the footer", () => {
  let t = reduce(emptyThread, env({ event: "turn_started", turn: 7, input: "hi" }));
  const usage = { context_tokens: 8000, input_tokens: 8000, output_tokens: 12, cached_tokens: 6000, model_calls: 1, tokens_per_sec: 74, model: "cloud/qwen3-coder-next", timing: { wall_ms: 400, prefill_ms: 250, decode_ms: 150, tool_ms: 0 } };
  t = reduce(t, env({ event: "turn_ended", turn: 7, reason: { type: "complete" }, usage }));
  assert.equal(t.turns[0].usage?.tokens_per_sec, 74);
  assert.equal(t.turns[0].reason?.type, "complete");
});

test("questions and MCP prompts wait for an answer and clear when resolved or the turn ends", () => {
  let t = reduce(emptyThread, env({ event: "turn_started", turn: 1, input: "go" }));
  t = reduce(t, env({ event: "question", id: "q1", item: "i1", question: "Which?", options: [{ label: "A" }, { label: "B" }], allow_other: true }));
  assert.equal(t.question?.allowOther, true);
  t = reduce(t, env({ event: "question_resolved", id: "q1", choices: ["A"] }));
  assert.equal(t.question, null);
  t = reduce(t, env({ event: "elicitation", id: "e1", server: "linear", message: "Pick a team" }));
  assert.equal(t.elicitation?.server, "linear");
  t = reduce(t, env({ event: "turn_ended", turn: 1, reason: { type: "complete" } }));
  assert.equal(t.elicitation, null);
});

test("the plan comes from status todos", () => {
  const t = reduce(emptyThread, env({ event: "status", model: "cloud/x", mode: "auto", context_tokens: null, context_window: 1, todos: [{ content: "write it", status: "in_progress" }] }));
  assert.equal(t.todos[0].status, "in_progress");
});

test("a turn keeps its images and the follow-ups sent with it", () => {
  const img = { mime: "image/png", data: "iVBOR" };
  const t = reduce(emptyThread, env({ event: "turn_started", turn: 1, input: "look", images: [img], more: [{ text: "and this" }] }));
  assert.equal(t.turns[0].images?.[0].mime, "image/png");
  assert.equal(t.turns[0].more?.[0].text, "and this");
});

test("retry notices read as what happened and when it tries again", async () => {
  const { humanize } = await import("../src/engine/thread.ts");
  assert.equal(
    humanize('HTTP 429: {"error":{"message":"too many concurrent requests","type":"rate_limit_error","code":429}} — retrying in 4s (2/6)'),
    "Frog Cloud is busy right now. Trying again in 4s (2 of 6).",
  );
  assert.equal(humanize("HTTP 503: no inference capacity right now — retrying in 8s (3/6)"), "No model is free on Frog Cloud right now. Trying again in 8s (3 of 6).");
  assert.equal(humanize("deepseek-v4.1-flash is busy right now — still trying (3/6)"), "Frog Cloud is busy right now. Still trying (3 of 6).");
  assert.equal(humanize("context window: 32768 tokens"), "context window: 32768 tokens");
});

test("a finished call's gist lands on its own row, not on its command", () => {
  const t = [
    { event: "turn_started", turn: 1, input: "check the branch" },
    { event: "item_started", id: "t1", kind: { type: "tool_call", name: "Bash", arg: "git log --oneline -5" } },
    { event: "item_completed", id: "t1", item: { type: "tool_call", name: "Bash", arg: "git log --oneline -5", input: {}, outcome: "ok", output: "abc fix", display: null } },
    { event: "item_gisted", item: "t1", gist: "git log of the sleep-events worktree" },
    // A second row, the same command, no gist of its own: it keeps its argument.
    { event: "item_started", id: "t2", kind: { type: "tool_call", name: "Bash", arg: "git log --oneline -5" } },
    { event: "item_completed", id: "t2", item: { type: "tool_call", name: "Bash", arg: "git log --oneline -5", input: {}, outcome: "ok", output: "abc fix", display: null } },
    { event: "turn_ended", turn: 1, reason: { type: "complete" } },
  ].reduce((t, e) => reduce(t, env(e as Event)), emptyThread);
  const [a, b] = t.turns[0].entries;
  assert.equal(a.gist, "git log of the sleep-events worktree");
  assert.equal(b.gist, undefined);
  // An empty gist is no gist: the row falls back to its argument.
  const cleared = reduce(t, env({ event: "item_gisted", item: "t1", gist: "" }));
  assert.equal(cleared.turns[0].entries[0].gist, null);
});

test("next_suggested holds the model's suggestion until the next turn starts", () => {
  let t = [
    { event: "turn_started", turn: 1, input: "fix it" },
    { event: "next_suggested", turn: 1, text: "push it", act: true },
    { event: "turn_ended", turn: 1, reason: { type: "complete" } },
  ].reduce((t, e) => reduce(t, env(e as Event)), emptyThread);
  assert.deepEqual(t.next, { text: "push it", act: true });
  t = reduce(t, env({ event: "turn_started", turn: 2, input: "push it" }));
  assert.equal(t.next, null);
});

test("a woken engine's restarted seqs still land, by time; real replays stay dropped", () => {
  const at = (e: Event, seq: number, created: number) => ({ ...e, seq, session: "s1", created }) as Envelope;
  let t = [
    at({ event: "turn_started", turn: 1, input: "hi" }, 1, 100),
    at({ event: "turn_ended", turn: 1, reason: { type: "complete" } }, 2, 200),
  ].reduce(reduce, emptyThread);
  t = reduce(t, at({ event: "turn_ended", turn: 1, reason: { type: "complete" } }, 2, 200)); // replay
  assert.equal(t.turns.length, 1);
  t = reduce(t, at({ event: "turn_started", turn: 2, input: "try again" }, 1, 900)); // new process
  t = reduce(t, at({ event: "turn_ended", turn: 2, reason: { type: "complete" } }, 2, 950));
  assert.deepEqual(t.turns.map((u) => u.input), ["hi", "try again"]);
  assert.equal(t.running, false);
  assert.equal(t.lastSeq, 2);
});

test("a file edited twice keeps both edits' hunks and summed counts", () => {
  const diff = (n: number) => ({ path: "src/a.ts", created: n === 1, added: n, removed: 1, hunks: [{ lines: [{ kind: "add", old: null, new: n, text: `line ${n}` }] }] });
  const done = (id: string, n: number) => ({ event: "item_completed", id, item: { type: "tool_call", name: "Edit", arg: "src/a.ts", outcome: "ok", diff: diff(n) } });
  const t = [
    { event: "turn_started", turn: 1, input: "edit" },
    { event: "item_started", id: "e1", kind: { type: "tool_call", name: "Edit", arg: "src/a.ts" } },
    done("e1", 1),
    { event: "item_started", id: "e2", kind: { type: "tool_call", name: "Edit", arg: "src/a.ts" } },
    done("e2", 2),
  ].reduce((t, e) => reduce(t, env(e as Event)), emptyThread);
  assert.equal(t.changes.length, 1);
  assert.equal(t.changes[0].added, 3);
  assert.equal(t.changes[0].removed, 2);
  assert.equal(t.changes[0].created, true);
  assert.equal(t.changes[0].hunks.length, 2);
});

test("compaction leaves a mark after the turn it followed", () => {
  const t = [
    { event: "turn_started", turn: 1, input: "hi" },
    { event: "turn_ended", turn: 1, reason: { type: "complete" } },
    { event: "compacted", tokens_before: 82_000, tokens_after: 9_100 },
  ].reduce((t, e) => reduce(t, env(e as Event)), emptyThread);
  assert.deepEqual(t.marks, [{ after: 1, text: "Compacted · 82k → 9k tokens" }]);
});

test("a repeated turn_started is the same turn, and a reused number after an ending is a new one", () => {
  let t = reduce(emptyThread, env({ event: "turn_started", turn: 1, input: "go" }));
  t = reduce(t, env({ event: "item_started", id: "i1", kind: { type: "tool_call", name: "Bash", arg: "ls" } }));
  t = reduce(t, env({ event: "turn_started", turn: 1, input: "go" }));
  assert.equal(t.turns.length, 1);
  assert.equal(t.turns[0].entries.length, 1);
  t = reduce(t, env({ event: "turn_ended", turn: 1, reason: { type: "complete" } }));
  t = reduce(t, env({ event: "turn_started", turn: 1, input: "again" }));
  assert.equal(t.turns.length, 2);
  t = reduce(t, env({ event: "turn_ended", turn: 1, reason: { type: "cancelled" } }));
  assert.equal(t.turns[0].reason?.type, "complete");
  assert.equal(t.turns[1].reason?.type, "cancelled");
});

test("the model's speed follows status, in tokens per second", () => {
  let t = emptyThread;
  t = reduce(t, env({ event: "status", model: "cloud/qwen3-coder-next", mode: "default", context_tokens: 1, context_window: 2, tokens_per_sec: 41.6 }));
  assert.equal(t.speed, 41.6);
  t = reduce(t, env({ event: "status", model: "cloud/qwen3-coder-next", mode: "default", context_tokens: 1, context_window: 2 }));
  assert.equal(t.speed, 41.6, "a status without a speed keeps the last one");
});
