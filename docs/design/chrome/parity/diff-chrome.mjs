#!/usr/bin/env node
// Compares two chrome dumps (frog-chrome-metrics/1): every control the spec puts on both apps
// must be on both, with its top, width, height and distance from the window's right edge within
// 1 point. (Its x follows from the right edge at a given width; the title is measured from the
// left, where the sidebar sets it.) Controls the spec keeps on one app only are listed in
// ONE_APP with the reason, and pass when they are missing from the other.
//
//   node diff-chrome.mjs <web.json> <mac.json> [--json out.json]
import { readFileSync, writeFileSync } from "node:fs";

const [a, b] = process.argv.slice(2).filter((x) => !x.startsWith("--"));
const outAt = process.argv.indexOf("--json");
const web = JSON.parse(readFileSync(a, "utf8"));
const mac = JSON.parse(readFileSync(b, "utf8"));
/** docs/design/chrome/spec.md: on the Mac only, for now. */
const ONE_APP = { split: "mac" };
const TOL = 1;
const fromLeft = new Set(["title"]);
const ids = [...new Set([...web.controls, ...mac.controls].map((c) => c.id))];
const rows = [];
let bad = 0;
for (const id of ids) {
  const w = web.controls.find((c) => c.id === id);
  const m = mac.controls.find((c) => c.id === id);
  if (!w || !m) {
    const ok = ONE_APP[id] === (w ? "web" : "mac");
    if (!ok) bad++;
    rows.push({ id, ok, note: `${w ? "web" : "mac"} only${ok ? " (spec: one app)" : ""}`, web: w ?? null, mac: m ?? null });
    continue;
  }
  const keys = ["top", "width", "height", fromLeft.has(id) ? "x" : "right"];
  const off = keys.filter((k) => Math.abs(w[k] - m[k]) > TOL).map((k) => `${k} ${w[k]} vs ${m[k]}`);
  if (off.length) bad++;
  rows.push({ id, ok: !off.length, note: off.join(", ") || "same", web: w, mac: m });
}
for (const r of rows) console.log(`${r.ok ? "ok  " : "DIFF"} ${r.id.padEnd(10)} ${r.note}`);
if (outAt > 0) writeFileSync(process.argv[outAt + 1], JSON.stringify({ format: "frog-chrome-diff/1", web: a, mac: b, ok: !bad, rows }, null, 2) + "\n");
console.log(bad ? `${bad} control(s) differ` : "chrome matches");
process.exit(bad ? 1 : 0);
