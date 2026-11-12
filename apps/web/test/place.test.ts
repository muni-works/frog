// Cam's rule (docs/models.md, "Place color"): a model's name, place tag and "where it runs" chip
// are colored by where it runs. Cloud green (any cloud), local blue, everywhere, through one function.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { placeColor, placeOf } from "../src/models";

const tokens = JSON.parse(readFileSync(new URL("../../../design/tokens.json", import.meta.url), "utf8"));
const color = (name: string) => tokens.color.find((c: { css?: string; swift?: string }) => c.css === name || c.swift === name);

test("cloud green is frog green, local is a blue in both modes", () => {
  const cloud = color("place-cloud"), frog = color("frog"), local = color("place-local");
  assert.equal(cloud.light, frog.light);
  assert.equal(cloud.dark, frog.dark);
  assert.equal(cloud.swift, "placeCloud");
  assert.equal(local.swift, "placeLocal");
  for (const hex of [local.light, local.dark]) {
    const [r, g, b] = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16));
    assert.ok(b > r && b > g, `${hex} is blue`);
  }
});

test("every cloud is cloud, this Mac and nodes are local", () => {
  for (const s of ["cloud/qwen3-coder-next", "anthropic/claude-sonnet-5", "openai/gpt-5", "frog-api/tree"]) assert.equal(placeOf(s), "cloud", s);
  for (const s of ["local/qwen3-8b", "apple/foundation", "node/abc@q4", "ollama/llama3"]) assert.equal(placeOf(s), "local", s);
  assert.equal(placeColor("cloud"), "var(--place-cloud)");
  assert.equal(placeColor("local"), "var(--place-local)");
});

test("place colors come only from placeColor", () => {
  const dirs = [new URL("../src/", import.meta.url), new URL("../src/ui/", import.meta.url)];
  const files = dirs.flatMap((d) => readdirSync(d).filter((f) => f.endsWith(".tsx")).map((f) => new URL(f, d)));
  const bad = files.flatMap((f) =>
    readFileSync(f, "utf8").split("\n").flatMap((l, i) => (/var\(--place-|servedClass|served-(frog|third)/.test(l) ? [`${f}:${i + 1}`] : [])),
  );
  assert.deepEqual(bad, []);
});
