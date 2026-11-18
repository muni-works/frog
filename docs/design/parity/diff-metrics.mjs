#!/usr/bin/env node
// Compares two transcript metrics dumps (metrics.mjs on the web, the Mac's -FrogMetrics) row by
// row, and fails on any difference in a row's kind or text, or a position (x, top, height) off by
// more than 1 point, or a font size that differs. Format: README.md, "Metrics".
//
//   node diff-metrics.mjs <a.json> <b.json> [--tolerance 1]
import { readFileSync } from "node:fs";

const args = process.argv.slice(2);
const tol = args.includes("--tolerance") ? Number(args[args.indexOf("--tolerance") + 1]) : 1;
const [aPath, bPath] = args.filter((x, i) => !x.startsWith("--") && args[i - 1] !== "--tolerance");
if (!aPath || !bPath) {
  console.error("usage: node diff-metrics.mjs <a.json> <b.json> [--tolerance 1]");
  process.exit(2);
}

/** The differences between two dumps, as lines; empty when they match. */
export function diff(a, b, tolerance = 1) {
  const out = [];
  for (const d of [a, b]) if (d.format !== "frog-transcript-metrics/1") out.push(`${d.app ?? "?"}: unknown format ${d.format}`);
  const n = Math.max(a.rows.length, b.rows.length);
  if (a.rows.length !== b.rows.length) out.push(`row count: ${a.app} ${a.rows.length}, ${b.app} ${b.rows.length}`);
  for (let i = 0; i < n; i++) {
    const x = a.rows[i], y = b.rows[i];
    if (!x || !y) { out.push(`row ${i}: only in ${x ? a.app : b.app}: ${JSON.stringify(x ?? y)}`); continue; }
    const at = `row ${i} (${x.kind} "${x.text.slice(0, 40)}")`;
    if (x.kind !== y.kind) out.push(`${at}: kind ${x.kind} vs ${y.kind}`);
    if (x.text !== y.text) out.push(`${at}: text\n    ${a.app}: ${x.text}\n    ${b.app}: ${y.text}`);
    for (const k of ["x", "top", "height"]) {
      if (Math.abs(x[k] - y[k]) > tolerance) out.push(`${at}: ${k} ${x[k]} vs ${y[k]} (off by ${Math.round(Math.abs(x[k] - y[k]) * 10) / 10})`);
    }
    if (Math.abs(x.fontSize - y.fontSize) > 0.01) out.push(`${at}: font size ${x.fontSize} vs ${y.fontSize}`);
  }
  return out;
}

const read = (p) => JSON.parse(readFileSync(p, "utf8"));
const a = read(aPath), b = read(bPath);
a.app ??= aPath; b.app ??= bPath;
if (a.app === b.app) { a.app = `${a.app}@${a.width}`; b.app = `${b.app}@${b.width}`; }
const problems = diff(a, b, tol);
if (problems.length) {
  console.error(`${problems.length} difference${problems.length === 1 ? "" : "s"} (tolerance ${tol} pt):\n  ${problems.join("\n  ")}`);
  process.exit(1);
}
console.log(`match: ${a.rows.length} rows, ${a.app} and ${b.app}, within ${tol} pt`);
