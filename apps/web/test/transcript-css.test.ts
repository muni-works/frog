// The transcript reads its sizes and gaps from the tokens, never hard-codes them (spec phase 1,
// "Tokens": "neither hard-codes a size or a gap"). Every font size, line height, margin, padding
// and gap in transcript.css is a var(); only 0 and hairlines are written out. And the layout
// constants rows.ts works with are the tokens' own.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { GUTTER, HANG, NARROW_GUTTER } from "../src/ui/rows.ts";

const css = readFileSync(new URL("../src/transcript.css", import.meta.url), "utf8");
const tokens = JSON.parse(readFileSync(new URL("../../../design/tokens.json", import.meta.url), "utf8"));

const SPACING = /^(font-size|line-height|font|margin(-\w+)?|padding(-\w+)?|gap|row-gap|column-gap|margin-inline|padding-inline)$/;

/** Each `prop: value` in a stylesheet whose value writes a size in px other than 0 or 1px. */
export function rawSizes(sheet: string): string[] {
  const out: string[] = [];
  const body = sheet.replace(/\/\*[\s\S]*?\*\//g, "");
  for (const m of body.matchAll(/([a-z-]+)\s*:\s*([^;{}]+)/g)) {
    const [, prop, value] = m;
    if (!SPACING.test(prop)) continue;
    const bare = value.replace(/var\([^)]*\)/g, "");
    const px = bare.match(/-?\d*\.?\d+px/g)?.filter((v) => !/^-?(0|1)px$/.test(v));
    if (px?.length) out.push(`${prop}: ${value.trim()}`);
  }
  return out;
}

test("no transcript rule writes a raw px size or gap", () => {
  assert.deepEqual(rawSizes(css), [], "use a --tx-*, --gap-* or --space-* token");
});

test("the checker catches what the old transcript rules did", () => {
  // The rules phase 1 replaced, from app.css: 13px everywhere, ad hoc 12 and 10 gaps.
  const before = ".turn { display: flex; flex-direction: column; gap: 12px; }\n.md p { margin: 0 0 10px; }\nbutton.tool { font: 13px/20px var(--font-sans); }";
  assert.equal(rawSizes(before).length, 3);
});

/** A selector list's members, split on commas outside parentheses (`:is(p, ul)` is one). */
function topLevel(sel: string): string[] {
  const out: string[] = [];
  let depth = 0, cur = "";
  for (const ch of sel) {
    if (ch === "(") depth++;
    if (ch === ")") depth--;
    if (ch === "," && depth === 0) { out.push(cur); cur = ""; } else cur += ch;
  }
  return [...out, cur];
}

test("every rule is scoped to the transcript", () => {
  const body = css.replace(/\/\*[\s\S]*?\*\//g, "").replace(/@(container|media)[^{]*\{/g, "");
  for (const m of body.matchAll(/(^|\})\s*([^{}@]+)\{/g)) {
    const sel = m[2].trim();
    if (!sel || sel === ".scroll") continue;
    for (const one of topLevel(sel)) assert.match(one.trim(), /^\.tx\b/, `unscoped: ${one.trim()}`);
  }
});

test("rows.ts's gutter and hang are the tokens'", () => {
  const v = (n: string) => tokens.transcript.layout.find((l: { name: string }) => l.name === n).value;
  assert.equal(GUTTER, v("gutter"));
  assert.equal(NARROW_GUTTER, v("gutter-narrow"));
  assert.equal(HANG, v("hang"));
});
