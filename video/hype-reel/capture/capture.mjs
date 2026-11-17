#!/usr/bin/env node
// Drives the web app (vite dev against gateway.mjs) in headless Chrome and writes PNG frame
// sequences into video/hype-reel/footage/<shot>/NNNN.png. Run through run.sh.
// Every shot is a list of steps; a step that captures writes the next frame. Steps are counted
// (characters typed, gateway steps sent), never timed, so a recapture shows the same frames.
import { launch } from "./cdp.mjs";
import { rmSync } from "node:fs";

const WEB = process.env.REEL_WEB, GW = process.env.REEL_GW;
const OUT = new URL("../footage/", import.meta.url).pathname;
const W = 1280, H = 720; // points; frames come out at 2x (2560x1440) so the compositor can zoom
const step = (n) => fetch(`${GW}/ctl/step?n=${n}`, { method: "POST" }).then((r) => r.json());
const reset = () => fetch(`${GW}/ctl/reset`, { method: "POST" });

async function shotDir(page, name) {
  rmSync(OUT + name, { recursive: true, force: true });
  let i = 0;
  return async () => { await page.shot(`${OUT}${name}/${String(i++).padStart(4, "0")}.png`); };
}

const PROMPT = "upload_retries_on_503 is flaky. Find out why and fix it.";
const byText = (sel, text) => `[...document.querySelectorAll(${JSON.stringify(sel)})].find((e) => e.textContent.includes(${JSON.stringify(text)}))`;
async function clickText(page, sel, text) {
  const ok = await page.eval(`(() => { const e = ${byText(sel, text)}; if (!e) return false; e.setAttribute('data-reel', '1'); return true; })()`);
  if (!ok) throw new Error(`no ${sel} with "${text}"`);
  await page.click('[data-reel="1"]');
  await page.eval(`document.querySelector('[data-reel="1"]')?.removeAttribute('data-reel')`);
}

const shots = {
  // Stills to look at while writing selectors.
  async probe(page) {
    await page.go(`${WEB}/`, 5000);
    await page.shot(`${OUT}probe/new.png`);
    await page.go(`${WEB}/s/s_live`, 5000);
    await step(999);
    await page.sleep(1500);
    await page.shot(`${OUT}probe/live.png`);
  },
  // The new-session screen: the prompt typed a character a frame, then the where menu picks a repo.
  async type(page, cap) {
    await page.go(`${WEB}/`, 5000);
    await page.focus(".cz textarea");
    await cap();
    for (let i = 0; i < PROMPT.length; i++) { await page.type(PROMPT[i]); await page.sleep(30); await cap(); }
    await page.click(".cz-where");
    await page.sleep(600);
    await cap(); // the menu, open
    await clickText(page, ".cz-menu button", "lilypad");
    await page.sleep(600);
    await cap(); // lilypad picked
  },
  // The live session: one frame per gateway step, from the prompt to the ask card.
  async stream(page, cap) {
    await page.go(`${WEB}/s/s_live`, 5000);
    await cap();
    for (;;) {
      const { sent, total } = await step(1);
      await page.sleep(140);
      await cap();
      if (sent >= total) break;
    }
  },
  // The same session with the right sidebar open on Changes: the diff, Commit and Open PR.
  async inspector(page, cap) {
    await page.go(`${WEB}/s/s_live`, 2000);
    await page.eval(`localStorage.setItem('frog.inspector', '1'); localStorage.setItem('frog.inspectorTab', 'changes')`);
    await step(999);
    await page.go(`${WEB}/s/s_live`, 5000);
    await cap();
    await page.eval(`localStorage.removeItem('frog.inspector'); localStorage.removeItem('frog.inspectorTab')`);
  },
  // The model menu on the new-session screen: Frog Cloud's models with their prices.
  async models(page, cap) {
    await page.go(`${WEB}/`, 5000);
    await cap();
    await clickText(page, ".cz button", "DeepSeek");
    await page.sleep(700);
    await cap();
  },
  // Documentation, in the same window.
  async docs(page, cap) {
    await page.go(`${WEB}/`, 4000);
    await clickText(page, "button", "Documentation");
    await page.sleep(1500);
    await cap();
  },
};

const which = process.argv[2] ?? "all";
const page = await launch({ width: W, height: H, scale: 2, look: "dark", storage: { "frog.key": "frog_reel", "frog.device": "frog.toys web · reel" } });
try {
  for (const [name, fn] of Object.entries(shots)) {
    if (which !== "all" ? name !== which : name === "probe") continue;
    await reset();
    console.log(`shot ${name}`);
    await fn(page, await shotDir(page, name));
  }
} finally {
  await page.close();
}
