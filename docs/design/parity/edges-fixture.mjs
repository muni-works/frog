#!/usr/bin/env node
// The edge fixture: one conversation with every kind of row the transcript draws, for the edge
// check (edges.mjs, check-edges.mjs; docs/design/transcript/spec.md, "Measure and the left edge").
// Every row's text must start on the column's left edge and everything that reaches the right
// must end on its right edge. fixture.mjs stays Cam's conversation, for the parity screenshots;
// this one is for the numbers.
//
//   node docs/design/parity/edges-fixture.mjs [cwd] > edges.jsonl
//
// Turn 1 finishes: a thought, a fold of four reads, a failed test run (it opens itself, so its
// output box and "Ran on…" caption show), a reply with a paragraph that opens with inline code, a
// heading, a list, a code block and a table, then one step of every kind (edit, passing test run,
// search, fetch, web search, agent, a command you said no to), an inline visual, prose and the
// footer. Turn 2 ends on an error, with a notice. Turn 3 holds open on a question card and a
// permission card, with the live "Waiting for you" row and its stats.
//
// The question is the engine's quiet-call question, anchored on the message before it; the web's
// gateway and `frog --replay` pass it through as logged, and the Mac's edge test feeds it to a
// hosted pane like every other event.
const cwd = process.argv[2] ?? "/tmp/lilypad";
const session = "20261118-120000-edges";
const model = "ollama/qwen3-coder:30b";
const t0 = Date.UTC(2026, 10, 18, 12, 0, 0);

const tool = (id, name, arg, { outcome = "ok", output = "", display = null, ms = 400, ...rest } = {}) => [
  [200, { event: "item_started", id, kind: { type: "tool_call", name, arg } }],
  [ms, { event: "item_completed", id, item: { type: "tool_call", name, arg, input: {}, outcome, output, display, ...rest } }],
];
const said = (id, type, text, ms = 900) => [
  [250, { event: "item_started", id, kind: { type } }],
  [ms, { event: "item_completed", id, item: { type, text } }],
];
const tests = (passed, total, names = []) => ({ runner: "cargo", passed, failed: total - passed, total, ...(names.length ? { failed_names: names } : {}) });
const diff = { path: "src/retry.rs", created: false, added: 1, removed: 1, hunks: [{ lines: [
  { kind: "context", old: 18, new: 18, text: "impl Backoff {" },
  { kind: "remove", old: 19, text: "    pub fn delay(&self, attempt: u32) -> Duration {" },
  { kind: "add", new: 19, text: "    pub fn delay(&self, attempt: u32, rng: &mut impl Rng) -> Duration {" },
] }] };
const widget = {
  title: "retry timing",
  code: "<svg viewBox='0 0 680 120'><rect x='0' y='40' width='680' height='40' rx='6' fill='#5c5'/></svg>",
  html: "<!doctype html><meta charset=utf-8><style>html,body{margin:0;background:transparent}</style><svg viewBox='0 0 680 120' width='100%'><rect x='0' y='40' width='680' height='40' rx='6' fill='#5c5'/></svg>",
};

const reply = [
  "`Backoff::delay` took no `Rng`, so the jitter was whatever `thread_rng()` gave it.",
  "## What changed",
  "- The delay takes an `Rng`, so a test can seed it.",
  "- `cargo test -q upload` passes eleven of eleven, every run.",
  "- The jitter is half the base at most.",
  "```rust\npub fn delay(&self, attempt: u32, rng: &mut impl Rng) -> Duration {\n    let base = self.base * 2u32.pow(attempt);\n    base + Duration::from_millis(rng.gen_range(0..=base.as_millis() as u64 / 2))\n}\n```",
  "| Attempt | Before | After |\n| --- | --- | --- |\n| 1 | 0 to 200 ms | 100 to 150 ms |\n| 3 | 0 to 800 ms | 400 to 600 ms |",
].join("\n\n");

const events = [
  [0, { event: "turn_started", turn: 1, input: "upload_retries_on_503 is flaky. Find out why and fix it." }],
  ...said("r1", "reasoning", "Probably timing. Read the test and the retry code, then run it.", 1200),
  ...tool("t1", "Read", "src/retry.rs", { display: "Read 124 lines" }),
  ...tool("t2", "Read", "src/store.rs", { display: "Read 57 lines" }),
  ...tool("t3", "Read", "tests/upload.rs", { display: "Read 88 lines" }),
  ...tool("t4", "Read", "Cargo.toml", { display: "Read 31 lines" }),
  ...tool("t5", "Bash", "cargo test -q upload", { outcome: "error", ms: 9000, tests: tests(10, 11, ["upload_retries_on_503"]),
    output: "running 11 tests\n..........F\nfailures:\n    upload_retries_on_503\n\ntest result: FAILED. 10 passed; 1 failed; 0 ignored" }),
  ...said("m1", "message", reply),
  ...tool("t6", "Edit", "src/retry.rs", { diff }),
  ...tool("t7", "Bash", "cargo test -q upload", { ms: 14000, tests: tests(11, 11), output: "running 11 tests\n...........\ntest result: ok. 11 passed; 0 failed; 0 ignored" }),
  ...tool("t8", "Grep", "thread_rng", { display: "3 matches in 2 files" }),
  // Prose between runs, so no run reaches four steps and folds: each kind keeps its own line.
  ...said("m1b", "message", "Then the docs, the web and one agent for the rest."),
  ...tool("t9", "WebFetch", "https://docs.rs/rand/latest/rand/trait.Rng.html", { display: "Fetched 12 KB" }),
  ...tool("t10", "WebSearch", "rust seeded rng test", { display: "8 results" }),
  ...tool("t11", "Task", "Check every other retry call site", { display: "Ran an agent · 6 tool calls" }),
  ...said("m1c", "message", "It wanted to force-push; you said no."),
  ...tool("t12", "Bash", "git push --force", { outcome: "denied" }),
  ...tool("t13", "Visualize", "retry timing", { output: "shown", widget }),
  ...said("m2", "message", "All eleven upload tests pass. I ran them once after the change, in the sandbox."),
  [200, { event: "turn_ended", turn: 1, reason: { type: "complete" }, usage: { context_tokens: 9800, input_tokens: 31200, output_tokens: 1902, model_calls: 6, tokens_per_sec: 58,
    timing: { wall_ms: 56000, prefill_ms: 4100, decode_ms: 32800, think_ms: 0, tool_ms: 19100, user_ms: 0, classifier_ms: 0, compact_ms: 0, other_ms: 0 },
    pace: { bucket_ms: 1000, tokens: [40, 58, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 600, 300, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 600, 304] },
    model: "cloud/qwen3-coder-next" } }],
  [3000, { event: "turn_started", turn: 2, input: "Push it." }],
  [100, { event: "notice", level: "warn", message: "Frog Cloud is busy; this turn may be slower than usual." }],
  [300, { event: "turn_ended", turn: 2, reason: { type: "error", error: { type: "connection", message: "connection reset by peer (os error 54)" } },
    usage: { context_tokens: 9800, input_tokens: 200, output_tokens: 0, model_calls: 1, model: "cloud/qwen3-coder-next" } }],
  [3000, { event: "turn_started", turn: 3, input: "nice. open a PR" }],
  ...said("m3", "message", "Which base should the PR go to?", 400),
  [100, { event: "question", id: "q1", item: "m3", question: "Which base should the PR go to?", options: [{ label: "main", detail: "the default branch" }, { label: "release/v0.7" }] }],
  [250, { event: "item_started", id: "t14", kind: { type: "tool_call", name: "Bash", arg: "gh pr create --fill" } }],
  [100, { event: "permission_request", id: "p1", item: "t14", name: "Bash", arg: "gh pr create --fill", always: "always allow `gh` this session" }],
  // Hold: the cards stay open while the apps are measured.
  [600_000, { event: "titled", title: "Line up the edges" }],
];

const lines = [JSON.stringify({ type: "header", version: 1, id: session, cwd, model, created: t0 })];
let t = t0;
events.forEach(([dt, e], i) => {
  t += dt;
  lines.push(JSON.stringify({ type: "event", env: { seq: i + 1, session, created: t, ...e } }));
});
console.log(lines.join("\n"));
