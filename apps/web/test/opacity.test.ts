// Cam, 2026-11-12: a Frog Cloud turn reads as "Frog Cloud" whoever proxied it. Presentation is
// opaque; the data behind it (`served_by.id`, `served_by.name`, `third_party`) and the cost
// numbers stay truthful, because a cache miss or a cost spike is debugged from them.
import { test } from "node:test";
import assert from "node:assert/strict";
import { servedByName } from "../src/models";
import { turnCost } from "../src/usage";

const listed = { id: "workers-ai", name: "Cloudflare Workers AI", third_party: true };

test("an upstream never reaches the display name, and the data stays true", () => {
  assert.equal(servedByName(listed), "Frog Cloud");
  // The record itself is untouched: the log keeps who really answered.
  assert.deepEqual(listed, { id: "workers-ai", name: "Cloudflare Workers AI", third_party: true });
  // An upstream frog has never heard of, named however the gateway likes.
  assert.equal(servedByName({ id: "acme", name: "Acme Inference Ltd." }), "Frog Cloud");
  // Frog Cloud's own GPUs agree with the label, which is the one case they can.
  assert.equal(servedByName({ id: "frog", name: "Frog Cloud" }), "Frog Cloud");
});

test("cost display is not opacity: a cold overflow turn still shows its real price", () => {
  const m = { id: "qwen3-coder-next", context: 131072, input: 2e-7, output: 8e-7, cached: 2e-8 };
  const usage = {
    context_tokens: null, input_tokens: 10_000, output_tokens: 1_000, cached_tokens: 0,
    model_calls: 2, model: "cloud/qwen3-coder-next", served_by: listed,
  };
  // Everything cold: no cached input, so the full input rate applies (the ~3.7x case).
  const cold = turnCost(usage, m)!;
  assert.ok(Math.abs(cold.fresh - 10_000 * 2e-7) < 1e-12);
  assert.ok(Math.abs(cold.cached) < 1e-12);
  assert.ok(Math.abs(cold.total - (10_000 * 2e-7 + 1_000 * 8e-7)) < 1e-12);
  // The same turn warm costs what the cache says, and the served_by name changes nothing.
  const warm = turnCost({ ...usage, cached_tokens: 8_000 }, m)!;
  assert.ok(warm.total < cold.total);
  assert.equal(servedByName(usage.served_by), "Frog Cloud");
});
