// Engine failures read as plain lines; OS error strings never show (the Mac's twin: PlainEngineErrorTests).
import { test } from "node:test";
import assert from "node:assert/strict";
import { plainError } from "../src/errors.ts";

test("a missing session says what to do", () => {
  assert.match(plainError("no session 20261111-101400-834f: No such file or directory (os error 2)"), /Start a new session\./);
});

test("no OS error string is shown", () => {
  for (const raw of ["reading config: Permission denied (os error 13)", "write: No space left on device (os error 28)",
    "open x: No such file or directory (os error 2)", "bind: Address in use (os error 48)"]) {
    const line = plainError(raw);
    assert.doesNotMatch(line, /os error|No such file/);
  }
});

test("a plain line is kept", () => {
  assert.equal(plainError("the model isn't on this gateway"), "the model isn't on this gateway");
});
