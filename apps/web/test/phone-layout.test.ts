// The phone layout ("Frog on a phone") in headless Chrome against the mock gateway, at 390 and
// 360 px wide: home signed out and in, a conversation, the sessions sheet, the plan sheet,
// Settings' list and Billing. Each screen holds: no horizontal scroll and nothing past the edges
// (wide rows scroll inside their own box), every visible control at least 44 px tall, and the
// meter's words where the meter is. Skips without Chrome.
//
// Chrome is a real browser here: under a loaded machine a test can flake. One that fails in a full
// run and passes alone is that.
import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { chrome } from "./chrome.ts";
import { pause, until, type Page } from "./cdp.ts";
import { AUDIT, rig, type Rig } from "./phone-rig.ts";

const skip = chrome ? false : "no Chrome on this machine";
let r: Rig;
let task = "";
const KEY = "frog_layout_ada";
const NEW = "frog_layout_bo";

before(async () => {
  if (skip) return;
  // Every turn plays a recording with a long diff, a wide table and a long code line.
  r = await rig({ fixture: fileURLToPath(new URL("./mock/wide.jsonl", import.meta.url)) });
  for (const k of [KEY, NEW]) await r.call(k, "/v1/mock/account", { credit_cents: 25, history: [] });
  task = await r.session(KEY, ["Make a tiny pomodoro timer"]);
});
after(async () => { await r?.close(); });

type Audit = { over: number; sideways: string[]; wide: string[]; small: string[] };
const audit = (p: Page) => p.eval<Audit>(AUDIT);
const holds = (a: Audit, where: string) => {
  assert.equal(a.over, 0, `${where}: the page scrolls sideways by ${a.over}px`);
  assert.deepEqual(a.sideways, [], `${where}: a box that scrolls sideways`);
  assert.deepEqual(a.wide, [], `${where}: past the screen's edge`);
  assert.deepEqual(a.small, [], `${where}: controls under 44 px`);
};
const has = (p: Page, sel: string) => until(() => p.eval<boolean>(`!!document.querySelector(${JSON.stringify(sel)})`), 15000);
const text = (p: Page, sel: string) => p.eval<string | null>(`document.querySelector(${JSON.stringify(sel)})?.textContent ?? null`);
const attr = (p: Page, sel: string, a: string) => p.eval<string | null>(`document.querySelector(${JSON.stringify(sel)})?.getAttribute(${JSON.stringify(a)}) ?? null`);
const tap = (p: Page, sel: string) => p.eval<boolean>(`(() => { const el = document.querySelector(${JSON.stringify(sel)}); if (!el) return false; el.click(); return true })()`);

for (const [w, h] of [[390, 844], [360, 780]] as const) {
  test(`phone ${w}: home signed out, the question, the starters, the meter's words`, { skip }, async () => {
    const p = await r.phone("/", w, h, null);
    try {
      assert.ok(await has(p, ".ph-body"));
      await pause(600);
      assert.equal(await text(p, ".cz-meter-label"), "25¢ free");
      assert.equal(await attr(p, ".cz-meter", "aria-label"), "25¢ free, open plans");
      assert.match((await text(p, ".ph-price")) ?? "", /Plans from \$20 a month/);
      holds(await audit(p), "home signed out");
    } finally { await p.close(); }
  });

  test(`phone ${w}: home signed in`, { skip }, async () => {
    const p = await r.phone("/", w, h, NEW);
    try {
      assert.ok(await has(p, ".cz-meter"));
      await until(async () => (await text(p, ".cz-meter-label")) === "25¢ left");
      assert.equal(await text(p, ".cz-meter-label"), "25¢ left");
      holds(await audit(p), "home signed in");
    } finally { await p.close(); }
  });

  test(`phone ${w}: a conversation, the title is the header, no desktop chrome`, { skip }, async () => {
    const p = await r.phone(`/s/${task}`, w, h, KEY);
    try {
      assert.ok(await has(p, ".tx"));
      await until(async () => ((await text(p, ".cz-meter-label")) ?? "").endsWith("left"));
      assert.match((await text(p, ".cz-meter-label")) ?? "", /^\d+¢ left$/);
      assert.ok(await has(p, ".phone-title"));
      assert.equal(await p.eval<boolean>("!!document.querySelector('.window-controls, .burger')"), false, "no window controls or hamburger on a phone");
      assert.equal(await p.eval<number>("[...document.querySelectorAll('.turn-rail')].filter((e) => e.getBoundingClientRect().width > 0).length"), 0);
      assert.equal(await p.eval<string>("getComputedStyle(document.querySelector('.cz-card textarea')).fontSize"), "16px");
      holds(await audit(p), "conversation");
    } finally { await p.close(); }
  });

  test(`phone ${w}: the sessions sheet opens from the title and closes with Back`, { skip }, async () => {
    const p = await r.phone(`/s/${task}`, w, h, KEY);
    try {
      assert.ok(await has(p, ".phone-title"));
      await pause(500);
      await tap(p, ".phone-title");
      assert.ok(await has(p, ".ss"));
      await pause(400);
      assert.match((await text(p, ".ss-who")) ?? "", /Free, \d+¢ left/);
      assert.ok(await p.eval<boolean>("[...document.querySelectorAll('.ss button')].some((b) => b.textContent === 'Get a plan')"));
      holds(await audit(p), "sessions sheet");
      await p.eval("history.back()");
      assert.ok(await until(async () => !(await p.eval<boolean>("!!document.querySelector('.ss')")), 5000), "Back closes the sheet");
      assert.equal(await p.eval<string>("location.pathname"), `/s/${task}`, "and stays on the conversation");
    } finally { await p.close(); }
  });

  test(`phone ${w}: the meter opens the plan sheet`, { skip }, async () => {
    const p = await r.phone(`/s/${task}`, w, h, KEY);
    try {
      assert.ok(await has(p, ".cz-meter"));
      await pause(800);
      await tap(p, ".cz-meter");
      assert.ok(await has(p, ".plan-sheet"));
      await pause(400);
      assert.match((await text(p, ".ps-title")) ?? "", /^You have \d+¢ left$/);
      assert.equal(await p.eval<number>("document.querySelectorAll('.ps-plan').length"), 3);
      assert.equal(await text(p, ".ps-go"), "Get Pro, $20 a month");
      holds(await audit(p), "plan sheet");
      // A swipe down from the handle closes it.
      const g = await p.eval<{ x: number; y: number }>("(() => { const r = document.querySelector('.sheet-grab').getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 } })()");
      const touch = (type: string, y: number) => p.call("Input.dispatchTouchEvent", { type, touchPoints: type === "touchEnd" ? [] : [{ x: g.x, y }] });
      await touch("touchStart", g.y);
      for (let d = 20; d <= 220; d += 40) { await touch("touchMove", g.y + d); await pause(16); }
      await touch("touchEnd", g.y + 220);
      assert.ok(await until(async () => !(await p.eval<boolean>("!!document.querySelector('.plan-sheet')")), 5000), "a swipe down closes it");
      await tap(p, ".cz-meter");
      assert.ok(await has(p, ".plan-sheet"));
      await pause(400);
      await tap(p, ".sheet-scrim");
      assert.ok(await until(async () => !(await p.eval<boolean>("!!document.querySelector('.plan-sheet')")), 5000), "a tap outside closes it");
    } finally { await p.close(); }
  });

  test(`phone ${w}: /pay is the plan sheet, signed out too`, { skip }, async () => {
    const p = await r.phone("/pay", w, h, null);
    try {
      assert.ok(await has(p, ".plan-sheet"));
      assert.equal(await p.eval<string>("location.pathname"), "/");
      assert.match((await text(p, ".ps-go")) ?? "", /^Sign in with GitHub to get Pro$/);
      holds(await audit(p), "/pay signed out");
      await p.eval("history.back()");
      assert.ok(await until(async () => !(await p.eval<boolean>("!!document.querySelector('.plan-sheet')")), 5000), "Back closes the sheet");
      assert.equal(await p.eval<string>("location.pathname"), "/", "and leaves the landing, not /pay");
    } finally { await p.close(); }
  });

  test(`phone ${w}: Settings is a list; Billing opens as its own page`, { skip }, async () => {
    const p = await r.phone("/settings", w, h, KEY);
    try {
      assert.ok(await has(p, ".set-list"));
      await pause(500);
      holds(await audit(p), "Settings list");
      await p.eval("[...document.querySelectorAll('.set-li')].find((b) => b.textContent.includes('Billing')).click()");
      assert.ok(await has(p, ".bill-phone"));
      assert.equal(await p.eval<string>("location.pathname"), "/settings/billing");
      await pause(600);
      assert.match((await text(p, ".bill-phone .bill-h")) ?? "", /Free\d+¢ of 25¢ left/);
      holds(await audit(p), "Billing");
      await tap(p, ".phone-back");
      assert.ok(await has(p, ".set-list"), "back to the list");
    } finally { await p.close(); }
  });
}

// A plan bought from the credit wall (item 6): See plans, Get Pro through the existing subscribe
// path (the mock's Checkout comes straight back with ?session_id), the session reopens, the wall
// says the plan is on, and Resume picks the turn up; the plan pays for it.
test("phone 390: a plan bought from the wall resumes the stopped turn", { skip }, async () => {
  const key = "frog_layout_wall";
  await r.call(key, "/v1/mock/account", { credit_cents: 25, history: [], plan: null });
  const id = await r.session(key, ["Add a README"]);
  await r.call(key, "/v1/mock/account", { credit_cents: 2 });
  await r.play(key, id, ["Now add tests"]);
  const p = await r.phone(`/s/${id}`, 390, 844, key);
  try {
    assert.ok(await has(p, ".wall"), "the wall");
    await pause(600);
    await p.eval("[...document.querySelectorAll('.wall button')].find((b) => b.textContent === 'See plans').click()");
    assert.ok(await has(p, ".plan-sheet"));
    await pause(400);
    await tap(p, ".ps-go");
    // Off to Checkout and back: the bare origin, then the session again.
    assert.ok(await until(async () => (await p.eval<string>("location.pathname")) === `/s/${id}`, 20000), "back on the session");
    assert.ok(await until(() => p.eval<boolean>("[...document.querySelectorAll('.wall .det')].some((d) => d.textContent.includes('Your plan is on'))"), 20000), "the wall says the plan is on");
    await p.eval("[...document.querySelectorAll('.wall button')].find((b) => b.textContent === 'Resume').click()");
    assert.ok(await until(async () => !(await p.eval<boolean>("!!document.querySelector('.wall')")), 20000), "the turn resumed and the wall went");
    assert.ok(await has(p, ".cz-card"), "the composer is back");
    const me = (await r.call(key, "/v1/me")) as { account: { subscription: { name: string } | null } };
    assert.equal(me.account.subscription?.name, "Pro");
  } finally { await p.close(); }
});
