// The composer reducer against the shared vectors (docs/design/composer/cases.json). The Mac's
// FrogTests/ComposerReducerTests runs the same file against ComposerModel.swift.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { derive, reduce, type Intent, type State } from "../src/composer.ts";

type Json = unknown;
const doc = JSON.parse(readFileSync(new URL("../../../docs/design/composer/cases.json", import.meta.url), "utf8")) as {
  base: State;
  cases: { name: string; given: Json; intent: Intent; expect: Json; effects: Json[] }[];
};

const isObj = (v: Json): v is Record<string, Json> => typeof v === "object" && v !== null && !Array.isArray(v);

/** Objects merge, arrays and scalars replace. */
export function merge(a: Json, b: Json): Json {
  if (!isObj(a) || !isObj(b)) return structuredClone(b);
  const out: Record<string, Json> = { ...structuredClone(a) };
  for (const [k, v] of Object.entries(b)) out[k] = k in out ? merge(out[k], v) : structuredClone(v);
  return out;
}

/** Partial match: objects match the listed keys, arrays match length and each element. */
function match(actual: Json, want: Json, path: string): string | null {
  if (isObj(want)) {
    if (!isObj(actual)) return `${path}: wanted an object, got ${JSON.stringify(actual)}`;
    for (const [k, v] of Object.entries(want)) {
      const m = match(actual[k] ?? null, v, `${path}.${k}`);
      if (m) return m;
    }
    return null;
  }
  if (Array.isArray(want)) {
    if (!Array.isArray(actual) || actual.length !== want.length) return `${path}: wanted ${JSON.stringify(want)}, got ${JSON.stringify(actual)}`;
    for (let i = 0; i < want.length; i++) {
      const m = match(actual[i], want[i], `${path}[${i}]`);
      if (m) return m;
    }
    return null;
  }
  return actual === want ? null : `${path}: wanted ${JSON.stringify(want)}, got ${JSON.stringify(actual)}`;
}

test("there are enough cases to cover the plan", () => {
  assert.ok(doc.cases.length >= 60, `${doc.cases.length} cases`);
  assert.equal(new Set(doc.cases.map((c) => c.name)).size, doc.cases.length, "names are unique");
});

for (const c of doc.cases) {
  test(c.name, () => {
    const given = merge(doc.base, c.given) as State;
    const [next, effects] = reduce(given, c.intent);
    const got = { ...next, derived: derive(next) };
    const m = match(got, c.expect, "state") ?? match(effects, c.effects, "effects");
    assert.equal(m, null);
  });
}
