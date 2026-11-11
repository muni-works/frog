#!/usr/bin/env node
// The parity session: one turn with every kind of row the One look specifies (your message,
// Thinking, Read, Search, Ran, an edit with a diff, a reply with inline code, an ask card),
// written as a frog session log both apps can play.
//
//   node docs/design/parity/fixture.mjs [cwd] > docs/design/parity/fixture.jsonl
//
// The Mac replays it with -FrogReplay; the web gets it from gateway.mjs. It ends on the ask,
// then holds (a long gap before the last event) so both captures catch the card open.
const cwd = process.argv[2] ?? "/tmp/lilypad";
const session = "20261111-120000-parity";
const model = "ollama/qwen3-coder:30b";
const t0 = Date.UTC(2026, 10, 11, 12, 0, 0);

const diff = (path, start, lines) => {
  let old = start, nu = start, added = 0, removed = 0;
  const out = lines.map(([mark, text]) => {
    if (mark === " ") return { kind: "context", old: old++, new: nu++, text };
    if (mark === "-") return removed++, { kind: "remove", old: old++, text };
    return added++, { kind: "add", new: nu++, text };
  });
  return { path, created: false, added, removed, hunks: [{ lines: out }] };
};
const tool = (id, name, arg, { outcome = "ok", output = "", display = null, diff: d } = {}) => [
  [200, { event: "item_started", id, kind: { type: "tool_call", name, arg } }],
  [400, { event: "item_completed", id, item: { type: "tool_call", name, arg, input: {}, outcome, output, display, ...(d ? { diff: d } : {}) } }],
];
const said = (id, type, text, ms) => [
  [250, { event: "item_started", id, kind: { type } }],
  [ms, { event: "item_completed", id, item: { type, text } }],
];

const events = [
  [0, { event: "turn_started", turn: 1, input: "upload_retries_on_503 is flaky. Find out why and fix it." }],
  ...said("r1", "reasoning", "Probably timing. Read the test and the retry code, then run it.", 1200),
  ...tool("t1", "Read", "src/retry.rs", { display: "Read 54 lines" }),
  ...tool("t2", "Grep", "thread_rng", { display: "3 matches in 2 files" }),
  ...tool("t3", "Bash", "cargo test upload_retries_on_503", { outcome: "error", output: "test upload_retries_on_503 ... FAILED\nmock store: no request within 500ms" }),
  ...tool("t4", "Edit", "src/retry.rs", {
    diff: diff("src/retry.rs", 18, [
      [" ", "impl Backoff {"],
      ["-", "    pub fn delay(&self, attempt: u32) -> Duration {"],
      ["+", "    pub fn delay(&self, attempt: u32, rng: &mut impl Rng) -> Duration {"],
      [" ", "        let base = self.base * 2u32.pow(attempt);"],
      ["-", "        let jitter = thread_rng().gen_range(0..=base.as_millis() as u64);"],
      ["+", "        let jitter = rng.gen_range(0..=base.as_millis() as u64 / 2);"],
      ["+", "        // Half the base at most, so the third retry stays under 500ms."],
      [" ", "        base + Duration::from_millis(jitter)"],
    ]),
  }),
  ...said("m1", "message", "The jitter came from `thread_rng()`, so the third retry could wait 800ms and the mock store gave up at 500ms. `Backoff::delay` now takes the `Rng`; the test passes a seeded one.", 900),
  [250, { event: "item_started", id: "t5", kind: { type: "tool_call", name: "Bash", arg: "cargo test -q upload" } }],
  [100, { event: "permission_request", id: "p1", item: "t5", name: "Bash", arg: "cargo test -q upload", always: "always allow `cargo` this session" }],
  // The hold: nothing for ten minutes, so the card stays open while both apps are captured.
  [600_000, { event: "titled", title: "Fix flaky upload retry" }],
];

const lines = [JSON.stringify({ type: "header", version: 1, id: session, cwd, model, created: t0 })];
let t = t0;
events.forEach(([dt, e], i) => {
  t += dt;
  lines.push(JSON.stringify({ type: "event", env: { seq: i + 1, session, created: t, ...e } }));
});
console.log(lines.join("\n"));
