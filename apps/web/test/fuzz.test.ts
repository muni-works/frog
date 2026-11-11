// Pins the 2026-11-05 fuzz findings for the web app (docs/plans/fuzz-findings-2026-11-05.md).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { composing, sessionMissing } from "../src/ui/guards.ts";
import { friendly, GatewayError } from "../src/cloud/client.ts";
import { emptyThread, reduce } from "../src/engine/thread.ts";
import type { Envelope, Event } from "../src/cloud/protocol.ts";

test("#1 long unbroken text wraps inside the user bubble and replies", () => {
  const css = readFileSync(new URL("../src/app.css", import.meta.url), "utf8");
  for (const sel of [".me", ".say"]) {
    const rule = css.match(new RegExp(`^\\${sel} \\{([^}]*)\\}`, "m"))?.[1] ?? "";
    assert.match(rule, /overflow-wrap:\s*anywhere/, sel);
  }
});

test("#2 Enter confirming an IME candidate doesn't count as a send", () => {
  assert.equal(composing({ nativeEvent: { isComposing: true }, keyCode: 13 }), true);
  assert.equal(composing({ nativeEvent: { isComposing: false }, keyCode: 229 }), true); // Safari
  assert.equal(composing({ nativeEvent: { isComposing: false }, keyCode: 13 }), false);
});

test("#3 a streamed delta leaves finished turns the same object, so memoized turns skip", () => {
  let seq = 0;
  const env = (e: Event) => ({ ...e, seq: ++seq, session: "s1", created: 0 }) as Envelope;
  let t = emptyThread;
  for (let n = 1; n <= 3; n++) {
    t = reduce(t, env({ event: "turn_started", turn: n, input: `q${n}` }));
    t = reduce(t, env({ event: "item_started", id: `m${n}`, kind: { type: "message" } }));
  }
  const before = t.turns;
  t = reduce(t, env({ event: "item_delta", id: "m3", delta: { type: "text", text: "hi" } }));
  assert.equal(t.turns[0], before[0]);
  assert.equal(t.turns[1], before[1]);
  assert.notEqual(t.turns[2], before[2]);
  assert.equal(t.turns[2].entries[0].text, "hi");
});

test("#5 a stale /s/<id> is missing only once the list has loaded", () => {
  const view = { kind: "session", id: "s_gone" };
  assert.equal(sessionMissing(view, [], false), false); // still loading: no flash of "not found"
  assert.equal(sessionMissing(view, [{ id: "s_other" }], true), true);
  assert.equal(sessionMissing(view, [{ id: "s_gone" }], true), false);
  assert.equal(sessionMissing({ kind: "new" }, [], true), false);
});

test("#6 raw server and network text never reaches the copy", () => {
  assert.doesNotMatch(friendly(new GatewayError(500, "Internal Server Error")), /Internal Server Error/);
  assert.doesNotMatch(friendly(new TypeError("Failed to fetch")), /Failed to fetch/);
  assert.doesNotMatch(friendly(new GatewayError(400, "repo must be owner/name")), /must be/);
});
