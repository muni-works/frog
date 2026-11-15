import { test } from "node:test";
import assert from "node:assert/strict";
import { AuthError, billingPortal, portalErrorMessage } from "../src/auth.ts";

test("maps each edge code to a sentence to act on", () => {
  assert.equal(
    portalErrorMessage(new AuthError(409, "stale_subscription")),
    "your plan isn't linked to Stripe — subscribe again below to manage it",
  );
  assert.equal(portalErrorMessage(new AuthError(400, "no_subscription")), "no plan to manage");
  assert.equal(portalErrorMessage(new AuthError(400, "no_customer")), "cancel and resubscribe to manage this plan");
  assert.equal(portalErrorMessage(new AuthError(401, "invalid_key")), "your session expired — sign in again");
});

test("an unknown code shows as itself", () => {
  assert.equal(portalErrorMessage(new AuthError(400, "invalid_return")), "invalid_return");
  assert.equal(portalErrorMessage(new AuthError(500, "unavailable")), "unavailable");
});

test("anything that isn't an AuthError has no message", () => {
  assert.equal(portalErrorMessage(new TypeError("Failed to fetch")), null);
  assert.equal(portalErrorMessage(new Error("stale_subscription")), null);
  assert.equal(portalErrorMessage(null), null);
  assert.equal(portalErrorMessage("stale_subscription"), null);
});

test("billingPortal propagates the AuthError instead of navigating", async () => {
  const realFetch = globalThis.fetch;
  const realLocation = globalThis.location;
  const navigated: string[] = [];
  globalThis.fetch = (async () =>
    new Response(JSON.stringify({ error: { code: "stale_subscription" } }), { status: 409 })) as typeof fetch;
  // auth.ts reads location.origin and calls location.assign; node has neither.
  globalThis.location = {
    origin: "https://frog.toys",
    assign: (url: string) => navigated.push(url),
  } as unknown as Location;
  try {
    await assert.rejects(
      billingPortal("frog_test"),
      (e: unknown) => {
        assert.ok(e instanceof AuthError);
        assert.equal(e.status, 409);
        assert.equal(e.code, "stale_subscription");
        assert.equal(portalErrorMessage(e), "your plan isn't linked to Stripe — subscribe again below to manage it");
        return true;
      },
    );
    assert.deepEqual(navigated, []);
  } finally {
    globalThis.fetch = realFetch;
    globalThis.location = realLocation;
  }
});
