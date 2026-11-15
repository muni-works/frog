import { test } from "node:test";
import assert from "node:assert/strict";
import { money, seconds, tokens, turnCost } from "../src/usage.ts";

const m = { id: "qwen3-coder-next", context: 131072, input: 2e-7, output: 8e-7, cached: 2e-8 };
const u = { context_tokens: null, input_tokens: 10_000, output_tokens: 1_000, cached_tokens: 8_000, model_calls: 2 };

test("cost splits fresh input, cached input and output at list price", () => {
  const c = turnCost(u, m)!;
  assert.ok(Math.abs(c.fresh - 2_000 * 2e-7) < 1e-12);
  assert.ok(Math.abs(c.cached - 8_000 * 2e-8) < 1e-12);
  assert.ok(Math.abs(c.output - 1_000 * 8e-7) < 1e-12);
  assert.equal(turnCost(u, undefined), null);
});

test("formats like the Mac app", () => {
  assert.equal(money(0), "Free");
  assert.equal(money(0.004), "<1¢");
  assert.equal(money(0.11), "11¢");
  assert.equal(money(1.844), "$1.84");
  assert.equal(tokens(8400), "8.4k");
  assert.equal(seconds(400), "0.4s");
  assert.equal(seconds(125_000), "2m 5s");
});

// frog.toys review: the ring read "Usage and context, 100%" with context at 1% (the weekly plan
// was full), and "Compact now" was offered at 1% context.
import { canCompact, ringLabel } from "../src/usage.ts";
test("the usage ring names the plan and the context apart", () => {
  assert.equal(ringLabel(1, 0.01), "Plan 100% used, context 1% full");
  assert.equal(ringLabel(null, 0.4), "Context 40% full");
});
test("compacting isn't offered at trivial context", () => {
  assert.equal(canCompact(1_000, 128_000), false);
  assert.equal(canCompact(64_000, 128_000), true);
});
