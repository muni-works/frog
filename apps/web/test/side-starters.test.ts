// The sidebar's starters (web home canvas, Final page): the generic four signed out or with no
// repos; the account's own repos on a signed-in first visit, saying only what Frog knows.
import { test } from "node:test";
import assert from "node:assert/strict";
import { repoStarters, STARTERS } from "../src/ui/Side.tsx";

test("no repos: the generic starters", () => {
  assert.deepEqual(repoStarters([]), STARTERS);
});

test("repos: two of them by name, the scratch timer, then a picker for the rest", () => {
  const s = repoStarters(["ecto/pond", "ecto/lily", "ecto/a", "ecto/b"]);
  assert.deepEqual(s.map((x) => x.title), ["Find and fix a bug in pond", "Add tests to lily", "Make a tiny pomodoro timer", "Pick another repo"]);
  assert.equal(s[0].repo, "ecto/pond");
  assert.equal(s[1].repo, "ecto/lily");
  assert.equal(s[3].detail, "2 more on GitHub");
  assert.ok(s[3].pick);
});

test("one repo: no second repo row, and the picker still offers more", () => {
  const s = repoStarters(["ecto/pond"]);
  assert.equal(s.filter((x) => x.repo).length, 1);
  assert.equal(s.at(-1)!.detail, "Connect more on GitHub");
});

test("no middle dots in any starter line (style guide)", () => {
  for (const x of [...STARTERS, ...repoStarters(["a/b", "c/d"])]) assert.ok(!x.detail.includes("·") && !x.title.includes("·"), x.detail);
});
