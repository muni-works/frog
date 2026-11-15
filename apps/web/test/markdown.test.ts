import { test } from "node:test";
import assert from "node:assert/strict";
import { isValidElement, type ReactElement } from "react";
import { inline, parse } from "../src/ui/Markdown.tsx";

test("blocks: fences (closed or still streaming), headings, lists, quotes, tables", () => {
  const b = parse("# Title\n\nSome *text*.\n\n```py\nprint(1)\n```\n\n- a\n- b\n\n1. one\n2. two\n\n> quoted\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```\nopen");
  assert.deepEqual(b.map((x) => x.k), ["h", "p", "code", "list", "list", "quote", "table", "code"]);
  assert.deepEqual(b[2], { k: "code", lang: "py", text: "print(1)", open: false });
  assert.equal((b[4] as { ordered: boolean }).ordered, true);
  assert.equal((b[7] as { open: boolean }).open, true);
});

test("the haiku's fence is code, not backticks", () => {
  const b = parse("Here's a haiku for you:\n```\nSilent moonlight ripples\n```");
  assert.equal(b[1].k, "code");
});

const tags = (nodes: unknown[]) => nodes.filter(isValidElement).map((n) => (n as ReactElement).type);

test("inline: code, bold, em, links; unsafe links stay text", () => {
  assert.deepEqual(tags(inline("use `npm test` and **then** *ship*")), ["code", "strong", "em"]);
  const safe = inline("[docs](https://frog.toys)").filter(isValidElement) as ReactElement<{ href: string }>[];
  assert.equal(safe[0].type, "a");
  assert.equal(safe[0].props.href, "https://frog.toys");
  const bad = inline("[click](javascript:alert(1))").filter(isValidElement) as ReactElement[];
  assert.ok(bad.every((n) => n.type !== "a"));
});
