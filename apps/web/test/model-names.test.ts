// frog.toys review: the cloud list showed raw ids (qwen3-8b, qwen3-vl-8b) and only an output price.
import { test } from "node:test";
import assert from "node:assert/strict";
import { agentModels, inOutPrice, modelName, usdPerM } from "../src/models.ts";

test("raw cloud ids read as names", () => {
  assert.equal(modelName("qwen3-8b"), "Qwen3 8B");
  assert.equal(modelName("qwen3-vl-8b"), "Qwen3 VL 8B");
  assert.equal(modelName("cloud/glm-5.3-air"), "GLM 5.3 Air");
  assert.equal(modelName("qwen3-coder-next"), "Qwen3 Coder Next");
});

test("the picker shows input and output prices per million tokens", () => {
  assert.equal(inOutPrice({ id: "x", context: null, input: 2e-7, output: 8e-7, cached: null }), "$0.20 in · $0.80 out /M");
});

// First-run audit (2026-11-17): the picker read "from $0.17/M" for GLM-5.3 Flash's $0.165, listed
// the 8B side-job helpers, and put the default model last.
test("prices keep three significant figures, as the pricing page does", () => {
  assert.equal(usdPerM(1.65e-7), "$0.165");
  assert.equal(usdPerM(3.96e-8), "$0.0396");
  assert.equal(usdPerM(5.5e-7), "$0.55");
  assert.equal(usdPerM(2e-7), "$0.20");
  assert.equal(usdPerM(1.5e-6), "$1.50");
  assert.equal(inOutPrice({ id: "x", context: null, input: 3.96e-8, output: 5.5e-7, cached: null }), "$0.0396 in · $0.55 out /M");
});

test("the picker offers agent-sized models, the default first", () => {
  const m = (id: string, context: number | null) => ({ id, context, input: null, output: null, cached: null });
  const live = [m("qwen3-coder-next", null), m("qwen3-8b", null), m("qwen3-vl-8b", null), m("glm-5.3-flash", 1048576), m("deepseek-v4.1-flash", 1048576), m("tiny", 32000)];
  assert.deepEqual(agentModels(live).map((x) => x.id), ["deepseek-v4.1-flash", "qwen3-coder-next", "glm-5.3-flash"]);
});
