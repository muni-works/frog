// The row's ask reads as one plain question, the same words as the Mac's.
import { test } from "node:test";
import assert from "node:assert/strict";
import { askLine } from "../src/ui/ask.ts";

test("asks read as plain questions", () => {
  assert.equal(askLine("Bash", "cargo test -q\nmore"), "Run cargo test -q?");
  assert.equal(askLine("Edit", "src/fetch.ts"), "Edit fetch.ts?");
  assert.equal(askLine("WebFetch", "https://docs.rs/x"), "Open docs.rs?");
  assert.equal(askLine("Mcp", ""), "Allow Mcp?");
});
