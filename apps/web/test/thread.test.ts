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
  assert.equal(humanize("context window: 32768 tokens"), "context window: 32768 tokens");
});
