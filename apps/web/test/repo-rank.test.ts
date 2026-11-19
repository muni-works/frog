// The where menu's repo order against the shared vectors (docs/design/composer/repo-rank.json).
// The Mac's FrogTests/RepoRankTests runs the same file against RepoRank.swift.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { REPO_LIMIT, moreLine, pickRepos, rankRepos, usedRepos, type RankedRepo } from "../src/repoRank.ts";

const doc = JSON.parse(readFileSync(new URL("../../../docs/design/composer/repo-rank.json", import.meta.url), "utf8")) as {
  limit: number;
  cases: { name: string; current: string | null; used: string[]; repos: RankedRepo[]; query: string; ranked: string[]; shown: string[]; more: number; line: string | null }[];
};

test("the limit matches the vectors", () => assert.equal(REPO_LIMIT, doc.limit));

for (const c of doc.cases) {
  test(c.name, () => {
    const ranked = rankRepos(c.current ?? undefined, c.used, c.repos);
    assert.deepEqual(ranked, c.ranked);
    const { shown, more } = pickRepos(ranked, c.query);
    assert.deepEqual(shown, c.shown);
    assert.equal(more, c.more);
    assert.equal(moreLine(more, c.query.trim() !== ""), c.line);
  });
}

test("repos used in Frog go by the last turn, else the last update", () => {
  assert.deepEqual(usedRepos([
    { repo: "ecto/old", updated: 50 },
    { repo: "ecto/new", updated: 10, last_turn: 90 },
    { repo: "", updated: 99 },
    { repo: "ecto/old", updated: 5, last_turn: 6 },
    { repo: "ecto/mid", updated: 70 },
  ]), ["ecto/new", "ecto/mid", "ecto/old"]);
});
