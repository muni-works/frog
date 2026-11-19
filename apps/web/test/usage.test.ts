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

test("formats like the Mac app (FrogKit Dollars.format: costs are dollars)", () => {
  assert.equal(money(0), "Free");
  assert.equal(money(0.004), "<$0.01");
  assert.equal(money(0.11), "$0.11");
  assert.equal(money(1.844), "$1.84");
  assert.equal(money(15), "$15", "cents only when there are any");
  assert.equal(money(0.999), "$1");
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

// The parity fixture's waiting row read "11011m 29s · waited 11011m 29s" (2026-11-18): a week in
// minutes. Past an hour it's hours and minutes, past a day days and hours, as the sidebar writes
// ages; every live clock (the stats, the wait) and every turn time goes through the one formatter.
import { secs } from "../src/ui/rows.ts";

test("a long wait reads in days and hours, not minutes", () => {
  const day = 86_400_000, hour = 3_600_000;
  assert.equal(secs(42_000), "42s");
  assert.equal(secs(125_000), "2m 5s");
  assert.equal(secs(58 * 60_000 + 59_000), "58m 59s");
  assert.equal(secs(hour), "1h 0m");
  assert.equal(secs(15 * hour + 58 * 60_000 + 40_000), "15h 58m");
  assert.equal(secs(7 * day + 15 * hour + 29_000), "7d 15h");
  assert.equal(seconds(7 * day + 15 * hour), "7d 15h", "a turn's time too");
  assert.equal(seconds(2 * hour + 5 * 60_000), "2h 5m");
});
