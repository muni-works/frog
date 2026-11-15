// The Ask card as it renders and answers: the model's `multi` is a starting guess at the
// arity, and the person's click decides it. Not the reducer — this drives the DOM the person
// actually presses.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { QuestionCard } from "../src/ui/AskCards.tsx";
import type { Question } from "../src/engine/thread.ts";

const q = (multi: boolean): Question => ({
  id: "q1",
  item: "t1",
  question: "Which fix?",
  options: [{ label: "Truncate" }, { label: "Checksum" }],
  multi,
  allowOther: true,
});

const draw = (multi: boolean) =>
  renderToStaticMarkup(createElement(QuestionCard, { q: q(multi), onAnswer: () => {} }));

test("a single-choice card at rest has nothing to confirm, so one click is the answer", () => {
  const html = draw(false);
  assert.match(html, /ask-option/);
  // Skip is there; Answer is drawn only because typing is allowed, and it's disabled until
  // there's something to send. Nothing is picked, so a click on an option is the whole answer.
  assert.match(html, />Skip</);
  assert.match(html, /disabled=""[^>]*>Answer</);
  assert.doesNotMatch(html, /aria-pressed/);
});

test("a multi card draws checkboxes and an Answer button", () => {
  const html = draw(true);
  assert.match(html, />Answer</);
});

test("either card can be made wide by the person, without typing first", () => {
  assert.match(draw(false), /Pick several/);
  // A card the model already called multi needs no switch.
  assert.doesNotMatch(draw(true), /Pick several/);
});
