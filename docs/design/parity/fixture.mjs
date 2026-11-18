#!/usr/bin/env node
// The parity session: every kind of row the unified transcript specifies (your message, a thought,
// a fold of four steps, a failed test run, prose, an edit, a passing run, a two-paragraph reply, a
// finished footer, then a second turn on a card that needs you), as a frog session log both apps
// can play (docs/design/transcript/spec.md, "Parity is measured").
//
//   node docs/design/parity/fixture.mjs [cwd] > docs/design/parity/fixture.jsonl
//
// The Mac replays it with -FrogReplay; the web gets it from gateway.mjs. It ends on the ask,
// then holds (a long gap before the last event) so both captures catch the card open.
//   node docs/design/parity/fixture.mjs --file old|new   # src/retry.rs before or after the edit
const fileArg = process.argv[2] === "--file" ? process.argv[3] : null;
const cwd = (fileArg ? null : process.argv[2]) ?? "/tmp/lilypad";
const session = "20261111-120000-parity";
const model = "ollama/qwen3-coder:30b";
const t0 = Date.UTC(2026, 10, 11, 12, 0, 0);

// The one edit: lines 18 to 23 of src/retry.rs, before (" " and "-") and after (" " and "+").
const EDIT = [
  [" ", "impl Backoff {"],
  ["-", "    pub fn delay(&self, attempt: u32) -> Duration {"],
  ["+", "    pub fn delay(&self, attempt: u32, rng: &mut impl Rng) -> Duration {"],
  [" ", "        let base = self.base * 2u32.pow(attempt);"],
  ["-", "        let jitter = thread_rng().gen_range(0..=base.as_millis() as u64);"],
  ["+", "        let jitter = rng.gen_range(0..=base.as_millis() as u64 / 2);"],
  ["+", "        // Half the base at most, so the third retry stays under 500ms."],
  [" ", "        base + Duration::from_millis(jitter)"],
];
if (fileArg) {
  const keep = fileArg === "old" ? "-" : "+";
  const head = ["// Exponential backoff with jitter.", ...Array.from({ length: 16 }, () => "")];
  const body = EDIT.filter(([m]) => m === " " || m === keep).map(([, t]) => t);
  console.log([...head, ...body, "    }", "}"].join("\n"));
  process.exit(0);
}

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

const tests = (passed, total, names = []) => ({ runner: "cargo", passed, failed: total - passed, total, ...(names.length ? { failed_names: names } : {}) });
const toolT = (id, name, arg, opts) => {
  const [start, done] = tool(id, name, arg, opts);
  if (opts?.tests) done[1].item.tests = opts.tests;
  if (opts?.ms) done[0] = opts.ms;
  return [start, done];
};

// Turn 1 finishes (spec phase 1: a fold, a failed step, a two-paragraph reply, a footer); turn 2
// stops on a card that needs you.
const events = [
  [0, { event: "turn_started", turn: 1, input: "upload_retries_on_503 is flaky. Find out why and fix it." }],
  ...said("r1", "reasoning", "Probably timing. Read the test and the retry code, then run it.", 1200),
  // Four quiet steps in a row: one fold.
  ...toolT("t1", "Read", "src/retry.rs", { display: "Read 124 lines" }),
  ...toolT("t2", "Read", "src/store.rs", { display: "Read 57 lines" }),
  ...toolT("t3", "Grep", "thread_rng", { display: "3 matches in 2 files" }),
  ...toolT("t4", "Read", "tests/upload.rs", { display: "Read 88 lines" }),
  // The failed step: a recognised test run, 10 of 11.
  ...toolT("t5", "Bash", "cargo test -q upload", { outcome: "error", ms: 9000, tests: tests(10, 11, ["upload_retries_on_503"]),
    output: "running 11 tests\n..........F\nfailures:\n    upload_retries_on_503\n\nmock store: no request within 500ms\ntest result: FAILED. 10 passed; 1 failed; 0 ignored" }),
  ...said("m1", "message", "The jitter came from `thread_rng()`, so the third retry could wait 800 ms while the mock store gave up at 500 ms.", 900),
  ...toolT("t6", "Edit", "src/retry.rs", { diff: diff("src/retry.rs", 18, EDIT) }),
  ...toolT("t7", "Bash", "cargo test -q upload", { ms: 14000, tests: tests(11, 11), output: "running 11 tests\n...........\ntest result: ok. 11 passed; 0 failed; 0 ignored" }),
  // The two-paragraph reply.
  ...said("m2", "message", "`Backoff::delay` now takes the `Rng`, and the test passes a seeded one, so the retry timing is the same every run.\n\nAll eleven upload tests pass. I ran them once after the change, in the sandbox.", 900),
  [200, { event: "turn_ended", turn: 1, reason: { type: "complete" }, usage: { context_tokens: 9800, input_tokens: 31200, output_tokens: 1902, model_calls: 6, tokens_per_sec: 58,
    timing: { wall_ms: 56000, prefill_ms: 4100, decode_ms: 32800, think_ms: 0, tool_ms: 19100, user_ms: 0, classifier_ms: 0, compact_ms: 0, other_ms: 0 }, model: "cloud/qwen3-coder-next" } }],
  [4000, { event: "turn_started", turn: 2, input: "nice. open a PR" }],
  // The card that needs you.
  [250, { event: "item_started", id: "t8", kind: { type: "tool_call", name: "Bash", arg: "gh pr create --fill" } }],
  [100, { event: "permission_request", id: "p1", item: "t8", name: "Bash", arg: "gh pr create --fill", always: "always allow `gh` this session" }],
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
