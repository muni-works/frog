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
