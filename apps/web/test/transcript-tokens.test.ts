// The transcript's tokens (design/tokens.json → transcript) must equal what the Mac draws today:
// Tokens.Size for the type, TurnSpace.Scale for the gaps, TurnSpace for the column. Read from the
// Swift source, so a change on either side without the other fails here (spec: "One transcript").
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const root = new URL("../../../", import.meta.url);
const json = JSON.parse(readFileSync(new URL("design/tokens.json", root), "utf8"));
const turnSpace = readFileSync(new URL("apps/FrogKit/UI/Transcript/TurnSpace.swift", root), "utf8");
const tokens = readFileSync(new URL("apps/FrogKit/UI/Basics/Tokens.swift", root), "utf8");
const tx = json.transcript;

/** `static let comfortable = Scale(line: 7, …)` → { line: 7, … }. */
function scale(name: string): Record<string, number> {
  const m = new RegExp(`static let ${name} = Scale\\(([^)]*)\\)`).exec(turnSpace);
  assert.ok(m, `TurnSpace.Scale.${name} not found`);
  return Object.fromEntries(m[1].split(",").map((kv) => kv.split(":").map((s) => s.trim())).map(([k, v]) => [k, Number(v)]));
}

const gap = (name: string) => tx.gap.find((g: { name: string }) => g.name === name);

test("transcript type roles equal the Mac's Tokens.Size", () => {
  const size = tokens.slice(tokens.indexOf("enum Size"), tokens.indexOf("enum Radius"));
  for (const r of tx.type) {
    const m = new RegExp(`static let ${r.role}: CGFloat = ([\\d.]+)`).exec(size);
    assert.ok(m, `Tokens.Size.${r.role} missing`);
    assert.equal(r.size, Number(m[1]), `${r.role} size`);
  }
  assert.deepEqual(tx.type.map((r: { size: number; line: number }) => [r.size, r.line]), [[14, 22], [12.5, 20], [11.5, 16], [10.5, 14]]);
});

test("transcript gaps equal TurnSpace.Scale, comfortable and compact", () => {
  for (const density of ["comfortable", "compact"] as const) {
    const s = scale(density);
    for (const k of ["turn", "paragraph", "block", "activity"]) assert.equal(gap(k)[density], s[k], `${density} ${k}`);
    // The spec's footer gap is the whole distance; the Mac's Scale.footer is the extra on top of block.
    assert.equal(gap("footer")[density], s.block + s.footer, `${density} footer = block + Scale.footer`);
  }
});

test("transcript layout equals TurnSpace's column", () => {
  const v = (n: string) => tx.layout.find((l: { name: string }) => l.name === n).value;
  const swift = (n: string) => Number(new RegExp(`static let ${n}: CGFloat = (\\d+)`).exec(turnSpace)?.[1]);
  assert.equal(v("column"), swift("measure"));
  assert.equal(v("gutter"), swift("gutter"));
  assert.equal(v("prompt"), swift("promptWidth"));
  assert.ok(v("hang") <= v("gutter"), "a mark hangs inside the gutter");
});
