// The web's tokens.css and the Mac's Tokens.swift are generated from design/tokens.json; this
// fails when either drifts (someone edited the output, or the JSON without regenerating).
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const generator = fileURLToPath(new URL("../../../design/generate.mjs", import.meta.url));
const css = readFileSync(new URL("../src/tokens.css", import.meta.url), "utf8");
const app = readFileSync(new URL("../src/app.css", import.meta.url), "utf8");

test("tokens.css and Tokens.swift match design/tokens.json", () => {
  assert.doesNotThrow(() => execFileSync(process.execPath, [generator, "--check"], { stdio: "pipe" }));
});

test("the dark surfaces are the One look's", () => {
  const dark = css.slice(css.indexOf(':root[data-theme="dark"]'));
  for (const [name, value] of [["canvas", "#000000"], ["sidebar", "#0a0a0a"], ["card", "#121212"], ["well", "#1a1a1a"], ["hover", "rgba(255, 255, 255, 0.07)"]])
    assert.match(dark, new RegExp(`--${name}: ${value.replace(/[().]/g, "\\$&")};`));
});

test("app.css doesn't override the generated palette", () => {
  for (const name of ["canvas", "bg", "card", "well", "hover", "muted", "faint", "glass-fill", "glass-fallback", "font-sans", "font-mono"])
    assert.doesNotMatch(app, new RegExp(`--${name}\\s*:`), `app.css sets --${name}; change design/tokens.json instead`);
});
