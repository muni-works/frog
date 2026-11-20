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

// The where-chip beside the meter keeps its start (live at 375 px, signed in on a plan, "Scratch
// sandbox" read as "dbox"): it truncates at the end, and the meter's words are whole. With the
// longest meter label and a long repo name, at 360 and 375.
const chip = `(() => {
  const name = document.querySelector('.cz-where-name');
  if (!name) return { missing: true };
  const box = name.getBoundingClientRect();
  const walker = document.createTreeWalker(name, NodeFilter.SHOW_TEXT);
  let first = walker.nextNode();
  while (first && !first.textContent.trim()) first = walker.nextNode();
  const r = document.createRange(); r.setStart(first, 0); r.setEnd(first, 1);
  const c = r.getBoundingClientRect();
  const label = document.querySelector('.cz-meter-label');
  // Cut short, the cut is at the end: the name's last letters are what's hidden, never its middle.
  const cut = name.scrollWidth > name.clientWidth + 0.5;
  const tail = name.querySelector('.cz-where-tail');
  const atEnd = !cut || !tail || tail.getBoundingClientRect().right > box.right + 0.5;
  return { text: name.textContent, start: c.left >= box.left - 0.5 && c.right <= box.right + 0.5, atEnd, cut, width: Math.round(box.width), meter: label?.textContent, meterWhole: !!label && label.scrollWidth <= label.clientWidth + 0.5 };
})()`;
const LONG = "ada/teleoperation-web-app-for-so101-arms";
for (const w of [360, 375]) {
  for (const s of [
    { name: "on a plan, home", acct: { credit_cents: 500, plan: "pro", weekly: 0.12, history: [] }, meter: "12% of week", repo: null },
    { name: "out of credit, home", acct: { credit_cents: 0, plan: null, history: [] }, meter: "Out of credit", repo: null },
    { name: "on a plan, a long repo", acct: { credit_cents: 500, plan: "pro", weekly: 0.12, history: [], repos: [LONG] }, meter: "12% of week", repo: LONG },
    { name: "out of credit, a long repo", acct: { credit_cents: 0, plan: null, history: [], repos: [LONG] }, meter: "Out of credit", repo: LONG },
  ]) {
    test(`phone ${w}: the where-chip keeps its start beside the meter, ${s.name}`, { skip }, async () => {
      const key = `frog_chip_${w}_${s.name.replace(/\W+/g, "_")}`;
      await r.call(key, "/v1/mock/account", s.acct);
      const p = await r.phone("/", w, w === 360 ? 780 : 812, key);
      try {
        assert.ok(await has(p, ".cz-where-name"));
        // A repo picked from the chip's menu: the new session's composer names it.
        if (s.repo) {
          await tap(p, ".cz-where");
          await until(() => p.eval<boolean>(`[...document.querySelectorAll('[role=menuitemradio]')].some((b) => b.textContent.includes(${JSON.stringify(s.repo.split("/")[1])}))`));
          await p.eval(`[...document.querySelectorAll('[role=menuitemradio]')].find((b) => b.textContent.includes(${JSON.stringify(s.repo.split("/")[1])})).click()`);
          assert.ok(await until(async () => ((await text(p, ".cz-where-name")) ?? "").includes("teleoperation")), "the chip names the repo");
        }
        await until(async () => (await text(p, ".cz-meter-label")) === s.meter);
        await pause(300);
        const c = await p.eval<{ text: string; start: boolean; atEnd: boolean; cut: boolean; width: number; meter: string; meterWhole: boolean }>(chip);
        assert.equal(c.meter, s.meter);
        assert.ok(c.meterWhole, `the meter's words are whole: ${JSON.stringify(c)}`);
        assert.ok(c.start, `the chip's first letter shows: ${JSON.stringify(c)}`);
        assert.ok(c.atEnd, `the chip is cut at its end: ${JSON.stringify(c)}`);
        holds(await audit(p), `where-chip, ${s.name}`);
      } finally { await p.close(); }
    });
  }
}

// ---------- plan accounts: Billing fits, every plan's buttons, stale, 80%, the wall ----------
// Prices as long as the live ones ("$0.0066"), which clipped Billing's table on a phone.
const LONG_PRICES = [
  { id: "deepseek-v4.1-flash", context_length: 131072, pricing: { prompt: "0.00000033", completion: "0.00000132", input_cache_read: "0.0000000066" } },
  { id: "glm-5.3-flash", context_length: 131072, pricing: { prompt: "0.0000000439", completion: "0.0000000862", input_cache_read: "0.000000033" } },
  { id: "qwen3-coder-next", context_length: 262144, pricing: { prompt: "0.0002", completion: "0.002" } },
];
const planAcct = (plan: string, weekly: number, extra: Record<string, unknown> = {}) => ({ credit_cents: 500, history: [{ kind: "topup", at: "2026-11-02T18:00:00Z", amount_micro_usd: 5_000_000, status: "succeeded" }], plan, weekly, stale: false, ...extra });
const rows = (p: Page) => p.eval<string[]>("[...document.querySelectorAll('.ps-row-plan')].map((r) => r.querySelector('b').textContent + ': ' + (r.querySelector('button, .ps-yours')?.textContent ?? ''))");

for (const w of [360, 390]) {
  test(`phone ${w}: Billing on a plan fits, long prices and all, with the three plans and a quiet Cancel plan`, { skip }, async () => {
    await r.call("frog_models", "/v1/mock/models", { data: LONG_PRICES });
    const key = `frog_bill_plan_${w}`;
    await r.call(key, "/v1/mock/account", planAcct("pro", 0.12));
    const p = await r.phone("/settings/billing", w, w === 360 ? 780 : 844, key);
    try {
      assert.ok(await has(p, ".ps-row-plan"));
      await until(() => p.eval<boolean>("!!document.querySelector('.price-row')"));
      await pause(400);
      assert.deepEqual(await rows(p), ["Pro: Your plan", "Max: Upgrade to Max", "Ultra: Upgrade to Ultra"]);
      assert.ok(await p.eval<boolean>("[...document.querySelectorAll('.bill-cancel')].some((b) => b.textContent === 'Cancel plan')"));
      assert.equal(await p.eval<boolean>("document.body.textContent.includes('at once')"), false, "no concurrency in Billing");
      holds(await audit(p), "Billing on a plan");
    } finally { await p.close(); await r.call("frog_models", "/v1/mock/models", { data: null }); }
  });
}

test("phone 390: each plan's sheet marks its own and offers the others", { skip }, async () => {
  const want: Record<string, string[]> = {
    pro: ["Pro: Your plan", "Max: Upgrade to Max", "Ultra: Upgrade to Ultra"],
    max5: ["Pro: Switch to Pro", "Max: Your plan", "Ultra: Upgrade to Ultra"],
    max: ["Pro: Switch to Pro", "Max: Switch to Max", "Ultra: Your plan"],
  };
  for (const plan of Object.keys(want)) {
    const key = `frog_sheet_${plan}`;
    await r.call(key, "/v1/mock/account", planAcct(plan, 0.12));
    const p = await r.phone("/", 390, 844, key);
    try {
      await until(async () => (await text(p, ".cz-meter-label")) === "12% of week");
      await tap(p, ".cz-meter");
      assert.ok(await has(p, ".plan-sheet .ps-row-plan"));
      assert.deepEqual(await rows(p), want[plan], plan);
      assert.equal(await p.eval<boolean>("!!document.querySelector('.ps-up')"), false, "at 12% nothing leads");
      holds(await audit(p), `plan sheet, ${plan}`);
    } finally { await p.close(); }
  }
});

test("phone 390: a stale plan says so in plain muted words, with every plan below to set one up", { skip }, async () => {
  const key = "frog_stale";
  await r.call(key, "/v1/mock/account", planAcct("pro", 0.12, { stale: true }));
  const p = await r.phone("/settings/billing", 390, 844, key);
  try {
    assert.ok(await has(p, ".bill-cancel"));
    await pause(400);
    await tap(p, ".bill-cancel");
    assert.ok(await has(p, ".bill-note"));
    assert.equal(await text(p, ".bill-note"), "This plan can't be managed from here. Choose a plan below to set it up again.");
    assert.equal(await p.eval<string>("getComputedStyle(document.querySelector('.bill-note')).color"), await p.eval<string>("getComputedStyle(document.querySelector('.det')).color"), "muted, not orange");
    assert.deepEqual(await rows(p), ["Pro: Set up Pro again", "Max: Upgrade to Max", "Ultra: Upgrade to Ultra"]);
    holds(await audit(p), "stale plan");
  } finally { await p.close(); }
});

test("phone 390: at 80% of the week, a quiet line and the sheet lead with the next plan up", { skip }, async () => {
  const key = "frog_near";
  await r.call(key, "/v1/mock/account", planAcct("pro", 0.1));
  const id = await r.session(key, ["Add a README"]);
  await r.call(key, "/v1/mock/account", { plan: "pro", weekly: 0.84 });
  const p = await r.phone(`/s/${id}`, 390, 844, key);
  try {
    assert.ok(await has(p, ".credit-warn"));
    assert.equal(await text(p, ".credit-warn-text"), "84% of this week used");
    assert.equal(await text(p, ".credit-warn-add"), "Upgrade to Max");
    await tap(p, ".credit-warn-add");
    assert.ok(await has(p, ".ps-up"));
    assert.match((await text(p, ".ps-up")) ?? "", /^Max gives you 5 times the weekly work\.Upgrade to Max$/);
    holds(await audit(p), "80% of the week");
  } finally { await p.close(); }
});

test("phone 390: past the plan at the wall, Upgrade to Max through the portal, and the turn resumes", { skip }, async () => {
  const key = "frog_wall_plan";
  await r.call(key, "/v1/mock/account", planAcct("pro", 0.3));
  const id = await r.session(key, ["Add a README"]);
  await r.call(key, "/v1/mock/account", { credit_cents: 2, over: true, portal_plan: "max5" });
  await r.play(key, id, ["Now add tests"]);
  const p = await r.phone(`/s/${id}`, 390, 844, key);
  try {
    assert.ok(await has(p, ".wall"));
    await pause(500);
    assert.match((await p.eval<string>("document.querySelector('.wall').textContent")) ?? "", /Max gives you 5 times the weekly work\./);
    await p.eval("[...document.querySelectorAll('.wall button')].find((b) => b.textContent === 'See plans').click()");
    assert.ok(await has(p, ".ps-up"), "the sheet leads with the next plan");
    await pause(300);
    await tap(p, ".ps-up .ps-go");
    assert.ok(await until(async () => (await p.eval<string>("location.pathname")) === `/s/${id}`, 20000), "back from the portal on the session");
    assert.ok(await until(() => p.eval<boolean>("[...document.querySelectorAll('.wall .det')].some((d) => d.textContent.includes('Your plan is on'))"), 20000), "the wall sees the new plan");
    await p.eval("[...document.querySelectorAll('.wall button')].find((b) => b.textContent === 'Resume').click()");
    assert.ok(await until(async () => !(await p.eval<boolean>("!!document.querySelector('.wall')")), 20000), "resumed");
    await until(async () => (await text(p, ".cz-meter-label")) !== null);
    const me = (await r.call(key, "/v1/me")) as { account: { subscription: { name: string } } };
    assert.equal(me.account.subscription.name, "Max");
  } finally { await p.close(); }
});
