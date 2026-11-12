#!/usr/bin/env node
// Fuzz cases for the transcript: session logs that stress how Mac and web draw a turn. Each is a
// frog session log both apps play (Mac: -FrogReplay; web: ../gateway.mjs --fixture). They are the
// regression cases for docs/design/parity/fuzz.sh and apps/web/test/parity-fuzz.test.ts.
//
//   node docs/design/parity/fuzz/cases.mjs --list            # case names, one per line
//   node docs/design/parity/fuzz/cases.mjs <case> [cwd]      # that case's log, on stdout
//   node docs/design/parity/fuzz/cases.mjs --wait <case>     # seconds the Mac replay needs
//
// A case that must hold mid-turn (streaming, a permission card) ends on an open permission
// request: the replay holds there (crates/frog/src/replay.rs). Every other case ends its turn.
import { deflateSync } from "node:zlib";

const t0 = Date.UTC(2026, 10, 12, 12, 0, 0);
const model = "cloud/glm-5.3-flash";
const served = { id: "frog", name: "Frog Cloud" };

// --- builders ------------------------------------------------------------------------------------
const say = (id, type, text) => [
  [250, { event: "item_started", id, kind: { type } }],
  [400, { event: "item_completed", id, item: { type, text } }],
];
const tool = (id, name, arg, { outcome = "ok", output = "", display = null, diff } = {}) => [
  [120, { event: "item_started", id, kind: { type: "tool_call", name, arg } }],
  [200, { event: "item_completed", id, item: { type: "tool_call", name, arg, input: {}, outcome, output, display, ...(diff ? { diff } : {}) } }],
];
const diff = (path, start, lines, created = false) => {
  let old = start, nu = start, added = 0, removed = 0;
  const out = lines.map(([mark, text]) => {
    if (mark === " ") return { kind: "context", old: old++, new: nu++, text };
    if (mark === "-") return removed++, { kind: "remove", old: old++, text };
    return added++, { kind: "add", new: nu++, text };
  });
  return { path, created, added, removed, hunks: [{ lines: out }] };
};
const usage = (o = {}) => ({ context_tokens: 18_400, input_tokens: 15_210, output_tokens: 812, model_calls: 3, tokens_per_sec: 142.6, model, served_by: served, ...o });
const turn = (n, input, body, { reason = { type: "complete" }, images, use = usage() } = {}) => [
  [0, { event: "turn_started", turn: n, input, ...(images ? { images } : {}) }],
  ...body,
  [300, { event: "turn_ended", turn: n, reason, usage: use }],
];
// Holds the turn open: an unanswered permission request is where the replay stops.
const hold = (item = "hold", name = "Bash", arg = "cargo test -q", extra = {}) => [
  [150, { event: "item_started", id: item, kind: { type: "tool_call", name, arg } }],
  [100, { event: "permission_request", id: `p-${item}`, item, name, arg, always: `always allow \`${arg.split(" ")[0]}\` this session`, ...extra }],
];

// A small PNG (a frog-green to blue gradient), so the image cases need no binary in the repo.
function png(w, h) {
  const crc = (b) => { let c, t = []; for (let n = 0; n < 256; n++) { c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; t[n] = c >>> 0; } let x = ~0; for (const v of b) x = t[(x ^ v) & 255] ^ (x >>> 8); return (~x) >>> 0; };
  const chunk = (type, data) => { const len = Buffer.alloc(4); len.writeUInt32BE(data.length); const td = Buffer.concat([Buffer.from(type), data]); const c = Buffer.alloc(4); c.writeUInt32BE(crc(td)); return Buffer.concat([len, td, c]); };
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 2;
  const raw = Buffer.alloc((w * 3 + 1) * h);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) { const i = y * (w * 3 + 1) + 1 + x * 3, f = x / w, g = y / h; raw[i] = 40 + 30 * g; raw[i + 1] = 200 - 80 * f; raw[i + 2] = 90 + 150 * f; }
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", ihdr), chunk("IDAT", deflateSync(raw)), chunk("IEND", Buffer.alloc(0))]).toString("base64");
}

const lorem = "Frog reads the code before it touches it, runs the tests after, and says what it changed in plain words. ";
const longRust = Array.from({ length: 80 }, (_, i) => i % 9 === 0 ? `\n/// Step ${i}: keep the retry under the mock's 500ms budget, whatever the jitter.` : `    let attempt_${i} = backoff.delay(${i}, &mut rng).min(Duration::from_millis(${400 + i}));`).join("\n");

// --- cases ---------------------------------------------------------------------------------------
export const CASES = {
  "long-strings": turn(1, "Why does this URL 404? https://frog.toys/v1/sessions/s_01JD8ZK4Q9X2M7W3N5P6R8T0VB/attachments/0123456789abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz?download=true&token=eyJhbGciOiJIUzI1NiJ9", [
    ...say("m1", "message", "The path has an unbroken id: `s_01JD8ZK4Q9X2M7W3N5P6R8T0VB_attachment_0123456789abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz` and the gateway only routes ids under 64 characters.\n\nSee https://github.com/muni-works/frog/blob/main/crates/frog-gateway/src/routes/sessions/attachments.rs#L120-L188?plain=1&very_long_query_parameter_name=and_an_even_longer_value_that_never_breaks for the route.\n\nAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"),
  ]),
  "code-and-tables": turn(1, "Show me the retry loop and a table of the attempts.", [
    ...say("m1", "message", "Here's the loop:\n\n```rust\n" + longRust + "\n```\n\nAnd the attempts:\n\n| attempt | base (ms) | jitter cap (ms) | worst case (ms) | under 500ms budget | notes about this particular attempt that go on |\n|---|---:|---:|---:|:---:|---|\n| 1 | 100 | 50 | 150 | yes | first retry, nothing to see |\n| 2 | 200 | 100 | 300 | yes | still fine |\n| 3 | 400 | 200 | 600 | **no** | this is the one the mock store gave up on, every time, in CI |\n| 4 | 800 | 400 | 1200 | no | never reached |\n\nA one-line block: `cargo test -q upload_retries_on_503 -- --nocapture --test-threads=1 --exact`"),
  ]),
  "markdown-structure": turn(1, "Summarize the plan.", [
    ...say("m1", "message", "# The plan\n\n## Retries\n\n1. Take the `Rng` as an argument.\n   - Seed it in tests: `StdRng::seed_from_u64(7)`\n     - Nested once more, with `inline code at the very end of a long line that wraps`\n   - Pass `thread_rng()` in production\n2. Halve the jitter.\n\n### Why\n\n> The mock store gives up at 500ms.\n> A quote can have **bold**, `code`, and a [link](https://frog.toys).\n>\n> > And a quote inside a quote.\n\n- [ ] todo item\n- [x] done item\n\n---\n\n#### Small heading\n\nA paragraph that ends in code: `Backoff::delay(&self, attempt: u32, rng: &mut impl Rng)`\n\n***Bold italic*** and ~~struck~~ and a footnote-ish thing[^1].\n\n[^1]: Not every renderer does footnotes."),
  ]),
  "scripts-and-emoji": turn(1, "日本語で説明して。 اشرح بالعربية. 🐸🚀", [
    ...say("r1", "reasoning", "ユーザーは日本語とアラビア語の両方で説明を求めている。"),
    ...say("m1", "message", "リトライのジッターが `thread_rng()` から来ていたので、三回目のリトライが 800ms 待つことがありました。修正しました。\n\nكان التأخير العشوائي يأتي من `thread_rng()`، لذلك كانت المحاولة الثالثة تنتظر أحياناً ٨٠٠ مللي ثانية. تم الإصلاح.\n\n中文也可以：重试抖动现在由调用者传入。한국어: 재시도 지연이 이제 500ms 미만입니다.\n\nEmoji: 🐸🐸🐸 ✅ ❌ 👩🏽‍💻 🏳️‍🌈 🇯🇵 — mixed with text 🐸and🐸no🐸spaces🐸🐸🐸🐸🐸🐸🐸🐸🐸🐸🐸🐸🐸🐸🐸🐸🐸🐸🐸🐸🐸🐸🐸🐸🐸🐸🐸🐸🐸🐸🐸🐸🐸🐸🐸🐸🐸🐸🐸🐸🐸🐸"),
  ]),
  "empty-messages": [
    ...turn(1, "   ", [...say("r1", "reasoning", ""), ...say("m1", "message", "")]),
    ...turn(2, "and now?", [...say("m2", "message", "   \n\n   \n"), ...say("m3", "message", "Only this one has words.")]),
  ],
  "tool-flood": turn(1, "Find every caller of delay and fix them.", [
    ...Array.from({ length: 14 }, (_, i) => tool(`g${i}`, i % 3 === 0 ? "Grep" : "Read", i % 3 === 0 ? `delay\\(` : `crates/lilypad-store/src/upload/retry_${i}.rs`, { display: i % 3 === 0 ? `${i + 2} matches in ${i + 1} files` : `Read ${40 + i * 7} lines` })).flat(),
    ...tool("b1", "Bash", "cargo test --workspace", { outcome: "error", output: Array.from({ length: 400 }, (_, i) => `test store::upload::retry::case_${i} ... ${i % 37 === 0 ? "FAILED" : "ok"}`).join("\n") }),
    ...tool("e1", "Edit", "crates/lilypad-store/src/upload/retry.rs", { diff: diff("crates/lilypad-store/src/upload/retry.rs", 10, Array.from({ length: 60 }, (_, i) => [i % 4 === 0 ? "-" : i % 4 === 1 ? "+" : " ", `        let value_${i} = compute(${i}, &mut rng); // a long trailing comment that pushes this line well past the width of any window at all`])) }),
    ...tool("w1", "Write", "crates/lilypad-store/src/upload/new_module_with_a_long_name.rs", { diff: diff("crates/lilypad-store/src/upload/new_module_with_a_long_name.rs", 1, Array.from({ length: 12 }, (_, i) => ["+", `pub fn f${i}() {}`]), true) }),
    ...say("m1", "message", "Fixed 14 call sites; 11 tests still fail for an unrelated reason."),
  ]),
  "thoughts": turn(1, "Think hard about this.", [
    ...say("r1", "reasoning", ""),
    ...tool("t1", "Read", "src/retry.rs", { display: "Read 54 lines" }),
    ...say("r2", "reasoning", Array.from({ length: 30 }, () => lorem).join("") + "\n\nSo the answer is jitter."),
    ...say("m1", "message", "It's the jitter."),
  ]),
  "streaming-fence": [
    [0, { event: "turn_started", turn: 1, input: "Write the fix." }],
    [250, { event: "item_started", id: "m1", kind: { type: "message" } }],
    [100, { event: "item_delta", id: "m1", delta: { type: "text", text: "Here's the change:\n\n```rust\nimpl Backoff {\n    pub fn delay(&self, attempt: u32, rng: &mut impl Rng) -> Duration {\n        let base = self.base * 2u32.pow(attempt);\n" } }],
    ...hold("t9", "Bash", "cargo build -q"),
  ],
  "errors-notices": [
    ...turn(1, "Run it.", [
      [100, { event: "notice", level: "info", message: "Context compacted: 182k → 24k tokens." }],
      ...tool("b1", "Bash", "cargo test", { outcome: "error", output: "error[E0308]: mismatched types\n  --> src/retry.rs:19:31\n   |\n19 |     pub fn delay(&self, attempt: u32) -> Duration {\n   |                               ^^^ expected `u64`, found `u32`" }),
      ...tool("b2", "Bash", "rm -rf target", { outcome: "denied" }),
      [100, { event: "notice", level: "warn", message: "Frog Cloud is busy; this turn may be slower than usual." }],
    ], { reason: { type: "error", error: { type: "connection", message: "connection reset by peer (os error 54)" } } }),
    ...turn(2, "Again.", [...say("m1", "message", "Stopped at the step limit.")], { reason: { type: "step_limit" } }),
  ],
  "child-sessions": turn(1, "Split this across agents.", [
    ...tool("a1", "Task", "Audit every retry call site in crates/lilypad-store", { display: "Ran an agent · 14 tool calls" }),
    ...tool("a2", "Task", "Write property tests for Backoff::delay with a seeded Rng and a very long description that wraps", { display: "Ran an agent · 6 tool calls" }),
    ...tool("a3", "Task", "Benchmark", { outcome: "error", output: "agent stopped: step limit" }),
    ...say("m1", "message", "Two agents finished; the benchmark agent hit its step limit."),
  ]),
  "permission-card": [
    [0, { event: "turn_started", turn: 1, input: "Apply the fix." }],
    ...say("m1", "message", "This edits `src/retry.rs`:"),
    ...hold("e1", "Edit", "src/retry.rs", { always: "allow all edits this session", preview: diff("src/retry.rs", 18, [[" ", "impl Backoff {"], ["-", "    pub fn delay(&self, attempt: u32) -> Duration {"], ["+", "    pub fn delay(&self, attempt: u32, rng: &mut impl Rng) -> Duration {"], [" ", "        let base = self.base * 2u32.pow(attempt);"]]) }),
  ],
  "images": turn(1, "What's wrong with this screenshot?", [
    ...say("m1", "message", "The bar on the left is the served-by rule; it should only be in the footer."),
  ], { images: [{ mime: "image/png", data: png(320, 200) }, { mime: "image/png", data: png(48, 300) }] }),
};

// --- output --------------------------------------------------------------------------------------
export function log(name, cwd = "/tmp/lilypad") {
  const events = CASES[name];
  if (!events) throw new Error(`no fuzz case ${name}`);
  const session = `20261112-120000-${name}`;
  const lines = [JSON.stringify({ type: "header", version: 1, id: session, cwd, model, created: t0 })];
  let t = t0;
  events.forEach(([dt, e], i) => {
    t += dt;
    lines.push(JSON.stringify({ type: "event", env: { seq: i + 1, session, created: t, ...e } }));
  });
  return lines.join("\n");
}

// Seconds the Mac replay needs (at speed 8): its 0.6s start, the clamped gaps, and the streamed words.
export function wait(name) {
  const ev = CASES[name];
  const words = ev.flatMap(([, e]) => (e.event === "item_completed" && (e.item.type === "message" || e.item.type === "reasoning") ? [e.item.text.split(" ").length] : []));
  const ms = 600 + ev.reduce((s, [dt]) => s + Math.min(dt, 1500), 0) + words.reduce((s, w) => s + (w / 2) * 28, 0) + ev.length * 300;
  return Math.ceil(ms / 8 / 1000) + 6;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const [a, b] = process.argv.slice(2);
  if (a === "--list") console.log(Object.keys(CASES).join("\n"));
  else if (a === "--wait") console.log(wait(b));
  else console.log(log(a, b));
}
