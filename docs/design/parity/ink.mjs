#!/usr/bin/env node
// Ink edges in a capture: for each band of rows with anything drawn, the leftmost and rightmost
// pixel that differs from the background, in points from a column's left line. A check on the
// edges dumps that doesn't trust the apps' own hooks (a mark hung with SwiftUI's `offset` reports
// where it would have been; NSTextView clips what it draws to its container).
//
//   node ink.mjs <capture.png> <column-left-pt> <column-right-pt>
//   W=1280 (the capture's width in points; 2x PNGs)  G=6 (points scanned left of the line)
//   T=60 (how far from the background a pixel must be to count: 12 picks up card fills)
//
// Glyphs carry side bearings: "T" inks at +0.0, "E" and "R" at +1.0 in Plex Sans at 12.5, so ink
// a point right of the line is a letter on it.
import { readFileSync } from "node:fs"; import { inflateSync } from "node:zlib";
const [f, L, R] = process.argv.slice(2); const buf = readFileSync(f);
let p = 8, w, h, ct, idat = [];
while (p < buf.length) { const len = buf.readUInt32BE(p), type = buf.toString("ascii", p + 4, p + 8), d = buf.subarray(p + 8, p + 8 + len);
  if (type === "IHDR") { w = d.readUInt32BE(0); h = d.readUInt32BE(4); ct = d[9]; } if (type === "IDAT") idat.push(d); p += 12 + len; }
const bpp = ct === 6 ? 4 : 3, raw = inflateSync(Buffer.concat(idat)), stride = w * bpp, px = Buffer.alloc(h * stride);
for (let y = 0; y < h; y++) { const ft = raw[y * (stride + 1)]; for (let x = 0; x < stride; x++) {
  const a = x >= bpp ? px[y * stride + x - bpp] : 0, b = y ? px[(y - 1) * stride + x] : 0, c = x >= bpp && y ? px[(y - 1) * stride + x - bpp] : 0;
  let v = raw[y * (stride + 1) + 1 + x]; if (ft === 1) v += a; else if (ft === 2) v += b; else if (ft === 3) v += (a + b) >> 1; else if (ft === 4) { const pp = a + b - c, pa = Math.abs(pp - a), pb = Math.abs(pp - b), pc = Math.abs(pp - c); v += pa <= pb && pa <= pc ? a : pb <= pc ? b : c; }
  px[y * stride + x] = v & 255; } }
const s = w / (process.env.W ?? 1280); const x0 = Math.round((+L - (+process.env.G || 6)) * s), x1 = Math.round((+R + 12) * s);
const bg = (y) => { const i = y * stride + (x0 - 120) * bpp; return [px[i], px[i + 1], px[i + 2]]; };
const ink = (x, y) => { const i = y * stride + x * bpp, g = bg(y); return Math.abs(px[i] - g[0]) + Math.abs(px[i + 1] - g[1]) + Math.abs(px[i + 2] - g[2]) > (+process.env.T || 60); };
let band = null; const out = [];
for (let y = 0; y < h; y++) { let lo = -1, hi = -1; for (let x = x0; x < x1; x++) if (ink(x, y)) { if (lo < 0) lo = x; hi = x; }
  if (lo >= 0) { if (!band) band = { y0: y, lo, hi }; else { band.lo = Math.min(band.lo, lo); band.hi = Math.max(band.hi, hi); } }
  else if (band) { if (y - band.y0 > 4) out.push(band); band = null; } }
for (const b of out) console.log(`y ${(b.y0 / s).toFixed(1)}  left ${(b.lo / s - L).toFixed(1)}  right ${((b.hi + 1) / s - L).toFixed(1)}`);
