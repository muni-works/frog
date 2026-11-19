// The new-session landing's centre (ui/Home.tsx): the mark, one heading, the composer with a
// suggestion and no idea chips, and the "What is Frog?" card signed out only.
import { after, test } from "node:test";
import assert from "node:assert/strict";
import { closeHarness, find, hasClass, mount, shownText, visible, type Page } from "./app-harness.ts";

after(closeHarness);

const mainCol = (p: Page) => find(p, (n) => n.type === "main")!;
const count = (p: Page, c: string) => visible(mainCol(p)).filter(hasClass(c)).length;
const signedIn = {
  storage: { "frog.key": "frog_test" },
  respond: (url: string) => url.endsWith("/v1/me") ? { body: { account: { plan: "free", name: "Ada", handle: "ada", email: "ada@example.com", credit_cents: 500, resets_at: null } } }
    : url.endsWith("/v1/sessions") ? { body: { sessions: [] } }
    : url.endsWith("/v1/models") ? { body: { data: [] } } : undefined,
};

test("signed out: one heading, a suggestion in the composer, no chips, and the What is Frog? card", async () => {
  const p = await mount("/");
  const m = shownText(mainCol(p));
  assert.ok(m.includes("What should we work on?"));
  assert.ok(m.includes("Hand it the work.") && m.includes("Only the repos you pick. Nothing merges without you."), m);
  assert.ok(!m.includes("Now in beta") && !m.includes("Ship while you sleep"), `the old copy is gone: ${m}`);
  assert.equal(count(p, "cz-chips"), 0, "no idea chips");
  assert.equal(count(p, "cz-sg-text"), 1, "one suggestion");
  p.unmount();
});

test("signed in: the same hero, no card", async () => {
  const p = await mount("/", signedIn);
  const m = shownText(mainCol(p));
  assert.ok(m.includes("What should we work on?"));
  assert.ok(!m.includes("What is Frog?"), m);
  assert.equal(count(p, "home-col"), 1);
  assert.equal(count(p, "cz-sg-text"), 1);
  p.unmount();
});
