// The opacity rule is about what a *view* renders, not what a helper returns: `servedByName` can
// be perfect while `TurnFooter` still prints `usage.served_by.name` (Cam, 2026-11-12). So these
// render the real footer and read the HTML, which is the only thing that catches a revert to the
// leak. Written to fail without the fix: see the PR body for the red proof.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { TurnFooter } from "../src/ui/TurnFooter.tsx";
import type { TurnUsage } from "../src/cloud/protocol.ts";

const upstream = { id: "workers-ai", name: "Cloudflare Workers AI", third_party: true };
const model = { id: "qwen3-coder-next", context: 131072, input: 2e-7, output: 8e-7, cached: 2e-8 };

function footer(usage: TurnUsage): string {
  return renderToStaticMarkup(
    createElement(TurnFooter, { usage, models: [model], answer: "Done.", pinned: true }),
  );
}

const turn: TurnUsage = {
  context_tokens: null, input_tokens: 10_000, output_tokens: 1_000, cached_tokens: 0,
  model_calls: 1, tokens_per_sec: 42, model: "cloud/qwen3-coder-next", served_by: upstream,
};

test("the footer renders Frog Cloud and never the upstream's name or id", () => {
  const html = footer(turn);
  // What a user reads.
  assert.match(html, /Frog Cloud/);
  // What they must not: the real upstream, in the text or in a title/aria attribute.
  assert.ok(!html.includes("Cloudflare"), `the footer leaked the upstream's name: ${html}`);
  assert.ok(!html.includes("Workers AI"), `the footer leaked the upstream's name: ${html}`);
  assert.ok(!html.includes("workers-ai"), `the footer leaked the upstream's id: ${html}`);
});

test("an upstream frog has never heard of is opaque too", () => {
  const html = footer({ ...turn, served_by: { id: "acme", name: "Acme Inference Ltd." } });
  assert.match(html, /Frog Cloud/);
  assert.ok(!html.includes("Acme"), `the footer leaked an unknown upstream: ${html}`);
});

test("the cost popover does not name the upstream either", () => {
  // The card is a second surface behind the same button; it renders cost, not who served.
  const html = renderToStaticMarkup(
    createElement(TurnFooter, {
      usage: { ...turn, model_calls: 2 },
      models: [model],
      answer: "",
      pinned: false,
    }),
  );
  assert.ok(!html.includes("Cloudflare") && !html.includes("workers-ai"), html);
});
