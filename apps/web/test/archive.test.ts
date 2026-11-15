// Archiving from the web app: the session on screen clears the view; anything else doesn't, and
// unarchiving never navigates. The rule is `viewAfterArchive` in ui/guards.ts; App's `archive`
// calls it, so the tests here cover both the decision and that it is actually wired in.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { archiveForwards, viewAfterArchive } from "../src/ui/guards.ts";

type View = { kind: "session"; id: string } | { kind: "new"; repo?: string; pick?: boolean };

test("archiving the open session clears the view to a new one", () => {
  const view: View = { kind: "session", id: "s1" };
  assert.deepEqual(viewAfterArchive(view, "s1", true), { kind: "new" });
});

test("archiving another session leaves you where you are", () => {
  const view: View = { kind: "session", id: "s1" };
  assert.deepEqual(viewAfterArchive(view, "s2", true), view);
});

test("unarchiving never navigates, even for the session on screen", () => {
  const view: View = { kind: "session", id: "s1" };
  assert.deepEqual(viewAfterArchive(view, "s1", false), view, "you're in the archive, restoring things");
});

test("a new-session view archives an old row without jumping", () => {
  const view: View = { kind: "new", repo: "muni-works/frog" };
  assert.deepEqual(viewAfterArchive(view, "s1", true), view);
  assert.equal(archiveForwards("s1", null), false, "nothing on screen, nowhere to go");
});

// The decision is pure, so a dropped call site would leave every test above green. Pin the one
// that performs it: App's archive clears the view through viewAfterArchive.
test("App's archive() uses the decision instead of leaving the open session up", () => {
  const src = readFileSync(new URL("../src/App.tsx", import.meta.url), "utf8");
  const start = src.indexOf("const archive = async");
  assert.ok(start > 0, "App still has an archive()");
  const body = src.slice(start, src.indexOf("const clear = async", start));
  assert.match(body, /setView\(\(v\) => viewAfterArchive\(v, s\.id, archived\)\)/);
});

// The bug, written down as intent in a comment that would now be a lie.
test("the session list no longer claims the open session stays either way", () => {
  const src = readFileSync(new URL("../src/ui/SessionList.tsx", import.meta.url), "utf8");
  assert.doesNotMatch(src, /the open session stays either way/);
});
