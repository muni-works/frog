// The model menu's local rows in a real browser: search narrows them, and arrows reach them from
// the search field like any other row (parity/models.html, headless Chrome). Skips without Chrome.
import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { chrome, serve } from "./chrome.ts";
import { open, until, type Page } from "./cdp.ts";

const skip = chrome ? false : "no Chrome on this machine";
let s: Awaited<ReturnType<typeof serve>> | null = null;
let page: Page | null = null;

before(async () => {
  if (!chrome) return;
  s = await serve();
  page = await open(`${s.origin}/parity/models.html?view=picker&machines=none`, 760, 760);
  assert.ok(await until(() => page!.eval<boolean>("!!document.querySelector('.cz-models input')")), "the menu never drew");
});
after(async () => { await page?.close(); await s?.close(); });

const key = (k: string, code = k) => page!.call("Input.dispatchKeyEvent", { type: "keyDown", key: k, code, windowsVirtualKeyCode: k === "ArrowDown" ? 40 : 0 })
  .then(() => page!.call("Input.dispatchKeyEvent", { type: "keyUp", key: k, code }));

test("search finds a local model, header and all", { skip }, async () => {
  await page!.eval("document.querySelector('.cz-models input').focus()");
  await page!.call("Input.insertText", { text: "gemma" });
  assert.ok(await until(() => page!.eval<boolean>("document.querySelectorAll('.cz-local').length === 1")), "search didn't narrow the local rows");
  const seen = await page!.eval<{ name: string; header: boolean }>(`({ name: document.querySelector('.cz-local .cz-mname').textContent,
    header: [...document.querySelectorAll('.cz-menu-h')].some((h) => h.textContent === 'Run it on your Mac') })`);
  assert.deepEqual(seen, { name: "Gemma 3 4B", header: true });
});

test("ArrowDown from the search field lands on a local row that links out", { skip }, async () => {
  await page!.eval("document.querySelector('.cz-models input').focus()");
  await key("ArrowDown");
  const focused = await page!.eval<{ cls: string; href: string | null; label: string | null }>(`(() => { const a = document.activeElement;
    return { cls: a.className, href: a.getAttribute('href'), label: a.getAttribute('aria-label') } })()`);
  assert.match(focused.cls, /cz-local/);
  // A local row hands off to the Mac app (frog://new, #505); without the app it falls back to /download or /mac.
  assert.ok(/^frog(-dev)?:\/\/new\?/.test(focused.href ?? "") || focused.href === "/download" || focused.href === "/mac", focused.href ?? "no href");
  assert.match(focused.label ?? "", /^Gemma 3 4B, runs on your Mac, /);
});
