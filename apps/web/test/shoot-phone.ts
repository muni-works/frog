// Screenshots of each "Frog on a phone" frame's screen from the real App against the mock gateway,
// at 390 × 844 (and 360 × 780 with --narrow): `node --import tsx test/shoot-phone.ts <out dir>`.
// macOS or Linux with Chrome. The same scenes run on main for the "before" shots.
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { pause, until } from "./cdp.ts";
import { rig, shot } from "./phone-rig.ts";

const out = process.argv[2] ?? "phone-shots";
const narrow = process.argv.includes("--narrow");
const [W, H] = narrow ? [360, 780] : [390, 844];
mkdirSync(out, { recursive: true });

const r = await rig();
/** Clicks the first element matching any of these selectors (or a button with this text). */
const click = (sel: string[], text?: string) => `(() => {
  for (const s of ${JSON.stringify(sel)}) { const el = document.querySelector(s); if (el) { el.click(); return s; } }
  ${text ? `const b = [...document.querySelectorAll('button')].find((b) => b.textContent.trim() === ${JSON.stringify(text)}); if (b) { b.click(); return 'text'; }` : ""}
  return null;
})()`;

try {
  // Fresh free accounts: 25¢, nothing paid in.
  const fresh = async (key: string) => { await r.call(key, "/v1/mock/account", { credit_cents: 25, history: [] }); return key; };
  const ada = await fresh("frog_phone_ada");
  const bo = await fresh("frog_phone_bo");
  const task = await r.session(ada, ["Make a tiny pomodoro timer"]);
  await r.session(bo, []);
  // On a plan, 12% of the week used.
  const cy = "frog_phone_cy";
  await r.call(cy, "/v1/mock/account", { credit_cents: 500, history: [{ kind: "topup", at: "2026-11-02T18:00:00Z", amount_micro_usd: 5_000_000, status: "succeeded" }], plan: "pro", weekly: 0.12, fiveHour: 0.3 });
  const planned = await r.session(cy, ["Fix the failing tests"]);
  // Out of credit mid-task: the wall.
  const di = await fresh("frog_phone_di");
  const walled = await r.session(di, ["Add a README"]);
  await r.call(di, "/v1/mock/account", { credit_cents: 2 });
  await r.play(di, walled, ["Now add tests for the timer"]);

  const scenes: { name: string; path: string; key: string | null; act?: string; wait?: string }[] = [
    { name: "1-home-signed-out", path: "/", key: null },
    { name: "2-home-signed-in", path: "/", key: bo },
    { name: "3-conversation", path: `/s/${task}`, key: ada, wait: ".tx" },
    { name: "4-sheet", path: `/s/${task}`, key: ada, wait: ".tx", act: click([".phone-title", ".burger"]) },
    { name: "5-plan-sheet", path: `/s/${task}`, key: ada, wait: ".tx", act: click([".cz-meter", ".ctx-ring"]) },
    { name: "6-first-result", path: `/s/${task}`, key: ada, wait: ".tx", act: "(() => { const s = document.querySelector('.scroll'); if (s) s.scrollTop = s.scrollHeight; return 1 })()" },
    { name: "7-settings", path: "/settings", key: ada, wait: ".settings-main, .set-list" },
    { name: "8-billing", path: "/settings/billing", key: ada, wait: ".settings-main" },
    { name: "9-plan-account-meter", path: `/s/${planned}`, key: cy, wait: ".tx" },
    { name: "10-plan-account-sheet", path: `/s/${planned}`, key: cy, wait: ".tx", act: click([".cz-meter", ".ctx-ring"]) },
    { name: "11-wall", path: `/s/${walled}`, key: di, wait: ".tx", act: "(() => { const s = document.querySelector('.scroll'); if (s) s.scrollTop = s.scrollHeight; return 1 })()" },
  ];
  for (const s of scenes) {
    const page = await r.phone(s.path, W, H, s.key);
    try {
      if (s.wait) await until(() => page.eval<boolean>(`!!document.querySelector(${JSON.stringify(s.wait)})`), 15000);
      await pause(1500);
      if (s.act) { const hit = await page.eval<string | null>(s.act); if (!hit) console.log(`${s.name}: nothing to click`); await pause(900); }
      const file = join(out, `${s.name}${narrow ? "-360" : ""}.png`);
      await shot(page, file);
      console.log(file);
    } finally { await page.close(); }
  }
} finally {
  await r.close();
}
