// The sidebar and the inspector are flush columns (docs/design/frog-web/README.md, 2026-11-17):
// full height, touching the window's edges, no margin, radius, shadow or glass, and a hairline
// on the inner edge. These read the stylesheet and the markup, so they run without a browser.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const read = (path: string) => readFileSync(new URL(path, import.meta.url), "utf8");
const app = read("../src/app.css");

type Rule = { selectors: string[]; decls: Map<string, string> };

/** The rules that apply at desktop width, in source order: top-level rules and the ones inside
 *  `@media (min-width: …)`; anything inside another at-rule (phone widths, reduced motion,
 *  @supports, keyframes) is left out. */
function desktopRules(css: string): Rule[] {
  const src = css.replace(/\/\*[\s\S]*?\*\//g, "");
  const rules: Rule[] = [];
  const walk = (s: string) => {
    let i = 0;
    while (i < s.length) {
      const open = s.indexOf("{", i);
      if (open < 0) break;
      const head = s.slice(i, open).trim();
      let depth = 1, j = open + 1;
      while (j < s.length && depth) { if (s[j] === "{") depth++; else if (s[j] === "}") depth--; j++ }
      const body = s.slice(open + 1, j - 1);
      if (head.startsWith("@")) {
        if (/^@media\s*\(\s*min-width:/.test(head)) walk(body);
      } else {
        const decls = new Map<string, string>();
        for (const d of body.split(";")) {
          const k = d.indexOf(":");
          if (k > 0) decls.set(d.slice(0, k).trim(), d.slice(k + 1).trim());
        }
        rules.push({ selectors: head.split(",").map((x) => x.trim()), decls });
      }
      i = j;
    }
  };
  walk(src);
  return rules;
}

/** The last value each property gets on exactly `selector` (not a descendant or state of it). */
function cascade(rules: Rule[], selector: string): Map<string, string> {
  const out = new Map<string, string>();
  for (const r of rules) if (r.selectors.includes(selector)) for (const [k, v] of r.decls) out.set(k, v);
  return out;
}

const rules = desktopRules(app);
const zero = (v: string | undefined) => v === undefined || /^0(px)?$/.test(v);

test("the window has no padding and no gap around its columns at desktop width", () => {
  for (const r of rules) {
    if (!r.selectors.includes(".win")) continue;
    for (const [k, v] of r.decls)
      if (/^(padding|gap|column-gap)(-|$)/.test(k)) assert.ok(zero(v), `.win sets ${k}: ${v}`);
  }
});

test("the sidebar and the inspector have no corner radius or shadow at desktop width", () => {
  for (const sel of [".side", ".insp"]) {
    for (const r of rules) {
      if (!r.selectors.includes(sel)) continue;
      const radius = r.decls.get("border-radius");
      assert.ok(zero(radius), `${sel} sets border-radius: ${radius}`);
    }
    const shadow = cascade(rules, sel).get("box-shadow");
    assert.ok(shadow === undefined || shadow === "none", `${sel} ends with box-shadow: ${shadow}`);
  }
});

test("each column has a hairline in --edge on its inner edge, and no other border", () => {
  const side = cascade(rules, ".side"), insp = cascade(rules, ".insp");
  assert.equal(side.get("border-right"), "1px solid var(--edge)");
  assert.equal(insp.get("border-left"), "1px solid var(--edge)");
  for (const k of ["border", "border-left", "border-top", "border-bottom"]) {
    const v = side.get(k);
    assert.ok(v === undefined || zero(v), `.side sets ${k}: ${v}`);
  }
  for (const k of ["border", "border-right", "border-top", "border-bottom"]) {
    const v = insp.get(k);
    assert.ok(v === undefined || zero(v), `.insp sets ${k}: ${v}`);
  }
  // The inspector's stored width is its outer width, hairline included.
  assert.equal(insp.get("box-sizing"), "border-box");
});

test("--edge is the quiet border: the column hairlines and the composer card at rest, nothing else", () => {
  // The whole stylesheet, every width: only the sidebar's right and the inspector's left use it.
  const all = app.replace(/\/\*[\s\S]*?\*\//g, "");
  const uses = [...all.matchAll(/([^{}]+)\{([^{}]*var\(--edge\)[^{}]*)\}/g)]
    .flatMap((m) => m[2].split(";").filter((d) => d.includes("var(--edge)")).map((d) => `${m[1].trim()} { ${d.trim()} }`));
  assert.deepEqual(uses, [
    ".side { border-right: 1px solid var(--edge) }",
    ".insp { border-left: 1px solid var(--edge) }",
    ".cz-card { border: 1px solid var(--edge) }",
  ]);
  // And it's quieter than --line in both themes (closer to the --sidebar fill).
  const tokens = read("../src/tokens.css");
  assert.match(tokens, /--edge:\s*#ededed;/);
  assert.match(tokens, /--edge:\s*#1a1a1a;/);
});

test("the sidebar's grip straddles its hairline and yields like the inspector's", () => {
  const grip = cascade(rules, ".side-grip");
  const left = parseFloat(grip.get("left") ?? "0"), width = parseFloat(grip.get("width") ?? "0");
  // The grip is a zero-width sibling at the sidebar's outer edge: the hairline is at -1…0.
  assert.equal(left + width / 2, -0.5);
  assert.ok(-left >= 4 && left + width >= 4, `grip spans ${left}…${left + width}`);
  assert.equal(cascade(rules, ".side").get("width"), "var(--side-w, 270px)");
  assert.equal(cascade(rules, ".side").get("box-sizing"), "border-box");
});

test("the conversation keeps 360px: the sidebar shrinks first, down to its 220 minimum", () => {
  const side = cascade(rules, ".side"), main = cascade(rules, "main.main"), insp = cascade(rules, ".insp");
  assert.equal(side.get("min-width"), "220px");
  assert.ok(Number(side.get("flex-shrink")) >= 1e5, `the sidebar gives way first: flex-shrink ${side.get("flex-shrink")}`);
  assert.equal(main.get("flex"), "1 1 360px", "the conversation asks for 360 before it grows");
  assert.equal(insp.get("flex"), "none", "the inspector keeps its width");
});

test("no grip on phones, and none while the sidebar is folded away", () => {
  const all = app.replace(/\/\*[\s\S]*?\*\//g, "");
  assert.match(all, /\.win\.collapsed\s*>\s*\.side-grip[^{]*\{[^}]*display:\s*none/);
  assert.match(all, /@media\s*\(max-width:\s*760px\)\s*\{[^{}]*\.side-grip[^{}]*\{\s*display:\s*none/);
});

test("the columns are filled with --sidebar at every width", () => {
  const all = app.replace(/\/\*[\s\S]*?\*\//g, "");
  assert.match(all, /(^|\n)\s*\.side,\s*\.insp\s*\{[^}]*background:\s*var\(--sidebar\)/);
  assert.doesNotMatch(all, /\.side\s*\{[^}]*background:\s*var\(--glass-fallback\)/, "the phone drawer is translucent");
});

test("the inspector's grip straddles its hairline", () => {
  const grip = cascade(rules, ".insp-grip");
  const left = parseFloat(grip.get("left") ?? "0"), width = parseFloat(grip.get("width") ?? "0");
  // The hairline sits at x = -1…0 of the inspector's padding box: centre -0.5.
  assert.equal(left + width / 2, -0.5);
  assert.ok(-left >= 4 && left + width >= 4, `grip spans ${left}…${left + width}`);
});

test("the sidebar and the inspector don't carry the glass class", () => {
  assert.doesNotMatch(read("../src/ui/Docs.tsx"), /className="side[^"]*\bf-glass\b/);
  assert.doesNotMatch(read("../src/ui/Inspector.tsx"), /className="insp[^"]*\bf-glass\b/);
});
