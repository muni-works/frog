// Two lines down the conversation column (docs/design/transcript/spec.md, "Measure and the left
// edge"): every row's text starts on the column's left edge, everything that reaches the right
// ends on its right edge, and marks hang in the gutter. The edge fixture
// (docs/design/parity/edges-fixture.mjs, every kind of row) is served by the parity gateway, the
// real App draws it in headless Chrome, docs/design/parity/edges.mjs measures each element and
// check-edges.mjs fails on anything more than 0.5 pt off its line or any kind of row missing.
// 2026-11-18: an opening code chip pushed its paragraph 4 pt in, list items started 22 pt in
// behind their bullets, and the footer's turn line stopped short of the edge. Skips without Chrome.
import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { spawn, execFileSync, type ChildProcess } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { createServer as listen } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { chrome, serve } from "./chrome.ts";
import { measureURL } from "../../../docs/design/parity/edges.mjs";
import { check, table } from "../../../docs/design/parity/check-edges.mjs";

const skip = chrome ? false : "no Chrome on this machine";
const parity = fileURLToPath(new URL("../../../docs/design/parity/", import.meta.url));
const freePort = () => new Promise<number>((r) => { const s = listen().listen(0, "127.0.0.1", () => { const p = (s.address() as { port: number }).port; s.close(() => r(p)); }); });

let gateway: ChildProcess | undefined;
let site: Awaited<ReturnType<typeof serve>> | undefined;
let dir = "";
before(async () => {
  if (!chrome) return;
  dir = mkdtempSync(join(tmpdir(), "frog-edges-test-"));
  const fixture = join(dir, "edges.jsonl");
  writeFileSync(fixture, execFileSync("node", [join(parity, "edges-fixture.mjs")]).toString());
  const port = await freePort();
  gateway = spawn("node", [join(parity, "gateway.mjs"), "--port", String(port), "--fixture", fixture, "--title", "Line up the edges"], { stdio: "ignore" });
  await new Promise((r) => setTimeout(r, 500));
  // The page's /v1 goes to vite, which proxies to the gateway (vite.config.ts reads GATEWAY).
  process.env.GATEWAY = `http://127.0.0.1:${port}`;
  process.env.VITE_DEV_KEY = "parity";
  process.env.VITE_API = "";
  site = await serve();
});
after(async () => {
  await site?.close();
  gateway?.kill();
  if (dir) rmSync(dir, { recursive: true, force: true });
});

async function edges(w: number, h: number, storage?: Record<string, string>) {
  const d = await measureURL(`${site!.origin}/s/s_parity`, w, h, "dark", { wait: 30_000, storage });
  const problems = check(d);
  assert.deepEqual(problems, [], `${problems.length} off at ${w} × ${h}:\n${table(d)}`);
}

test("every element of the edge fixture sits on the column's two lines (1280 wide)", { skip, timeout: 90_000 }, () => edges(1280, 2600));

test("and with the inspector open (the column centred in a narrower pane)", { skip, timeout: 90_000 }, () =>
  edges(1600, 2600, { "frog.inspector": "1" }));

// The phone: a 16 gutter, under the hang, so marks come inside and all text indents by 26
// together; boxes and the composer keep the column's edges (the composer sat 8 pt outside them).
test("and on a phone, where marks come inside and text indents by the hang", { skip, timeout: 90_000 }, () => edges(375, 2600));

test("edges.jsonl is edges-fixture.mjs's output (the Mac's edge test reads the file)", () => {
  const fresh = execFileSync("node", [join(parity, "edges-fixture.mjs")]).toString().trim();
  assert.equal(readFileSync(join(parity, "edges.jsonl"), "utf8").trim(), fresh, "run: node docs/design/parity/edges-fixture.mjs > docs/design/parity/edges.jsonl");
});
