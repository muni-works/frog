// frog.toys review: the cloud list showed raw ids (qwen3-8b, qwen3-vl-8b) and only an output price.
import { test } from "node:test";
import assert from "node:assert/strict";
import { inOutPrice, modelName } from "../src/models.ts";

test("raw cloud ids read as names", () => {
  assert.equal(modelName("qwen3-8b"), "Qwen3 8B");
  assert.equal(modelName("qwen3-vl-8b"), "Qwen3 VL 8B");
  assert.equal(modelName("cloud/glm-5.3-air"), "GLM 5.3 Air");
  assert.equal(modelName("qwen3-coder-next"), "Qwen3 Coder Next");
});

test("the picker shows input and output prices per million tokens", () => {
  assert.equal(inOutPrice({ id: "x", context: null, input: 2e-7, output: 8e-7, cached: null }), "$0.20 in · $0.80 out /M");
});
