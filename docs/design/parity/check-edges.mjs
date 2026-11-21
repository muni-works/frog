#!/usr/bin/env node
// Checks a transcript edges dump (edges.mjs on the web, the Mac's -FrogEdges): every element with
// a claim sits on its line within the tolerance (0.5 pt), and every kind of row the edge fixture
// has is there, so a row that never drew can't pass by being absent. Prints the table either way.
// The lines (docs/design/transcript/spec.md, "One left line, flush"): marks, list markers, prose
// and boxes on the left line; a marked line's words one mark column (`hang`) in; a list item's one
// marker column (`marker`) in; whatever reaches the right on the right line.
//
//   node check-edges.mjs <edges.json> [more.json…] [--tolerance 0.5] [--no-require]
import { readFileSync } from "node:fs";

/** The kinds edges-fixture.mjs draws, each of which must appear in a dump of it. */
export const REQUIRED = [
  "prompt", "thought", "fold", "line:command", "line:edit", "line:search", "line:web", "line:other",
  "prose", "prose (opens with code)", "heading", "list item", "list marker", "code", "table", "visual", "footer",
  "error", "question card", "card", "live", "stats", "composer",
];

/** Where an element should be for a claim, and how far off it is (signed, points). */
function offBy(e, claim, d) {
  if (claim === "text" || claim === "box") return e.left;
  if (claim === "after") return e.left - d.hang;
  if (claim === "item") return e.left - d.marker;
  if (claim === "before") return Math.max(0, e.right - d.hang);
  if (claim === "right") return e.right - d.column;
  return Infinity;
}

/** Each claim's result: { e, claim, off, ok }. */
export function results(d, tolerance = 0.5) {
  return d.elements.flatMap((e) => e.claims.map((claim) => {
    const off = Math.round(offBy(e, claim, d) * 10) / 10;
    return { e, claim, off, ok: Math.abs(off) <= tolerance };
  }));
}

/** Problems with a dump, as lines; empty when it passes. */
export function check(d, { tolerance = 0.5, require = true } = {}) {
  const out = [];
  if (d.format !== "frog-transcript-edges/2") out.push(`unknown format ${d.format}`);
  for (const r of results(d, tolerance)) if (!r.ok) out.push(`${r.e.kind} ${r.e.part} "${r.e.text}": ${r.claim} off by ${r.off}`);
  if (require) {
    const seen = new Set(d.elements.map((e) => e.kind));
    for (const k of REQUIRED) if (!seen.has(k)) out.push(`no ${k} in the dump`);
  }
  return out;
}

/** The table for people: every element, its edges and how far each claim is off. */
export function table(d, tolerance = 0.5) {
  const rows = [`| element | left | right | off |`, `| --- | ---: | ---: | --- |`];
  for (const e of d.elements) {
    const offs = e.claims.map((c) => { const o = Math.round(offBy(e, c, d) * 10) / 10; return Math.abs(o) <= tolerance ? `${c} ✓` : `**${c} ${o > 0 ? "+" : ""}${o}**`; });
    rows.push(`| ${e.kind}: ${e.part}${e.text.trim() ? ` (${e.text.slice(0, 28)})` : ""} | ${e.left} | ${e.right} | ${offs.join(", ") || "(inside)"} |`);
  }
  return rows.join("\n");
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const args = process.argv.slice(2);
  const tolerance = args.includes("--tolerance") ? Number(args[args.indexOf("--tolerance") + 1]) : 0.5;
  const files = args.filter((x, i) => !x.startsWith("--") && args[i - 1] !== "--tolerance");
  let bad = 0;
  for (const f of files) {
    const d = JSON.parse(readFileSync(f, "utf8"));
    console.log(`\n### ${d.app} ${d.width} × ${d.height} (column ${d.column}, mark column ${d.hang}, marker column ${d.marker})\n\n${table(d, tolerance)}\n`);
    const p = check(d, { tolerance, require: !args.includes("--no-require") });
    if (p.length) { bad++; console.error(`${f}: ${p.length} off (tolerance ${tolerance} pt):\n  ${p.join("\n  ")}`); }
    else console.log(`${f}: every element on its line, within ${tolerance} pt`);
  }
  process.exit(bad ? 1 : 0);
}
