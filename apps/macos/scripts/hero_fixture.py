#!/usr/bin/env python3
"""The session frog.eco's hero screenshot shows, and a believable sidebar around it.

    hero_fixture.py <home>

Writes <home>/code/lilypad (the project, a few real files), the replayed session to
<home>/hero.jsonl, and a handful of earlier sessions to <home>/.local/share/frog/sessions so
the sidebar isn't empty. Everything is invented: no real sessions or paths leak into the shot.
"""
import json
import os
import pwd
import sys
import time
from pathlib import Path

HOME = Path(sys.argv[1])
PROJECT = HOME / "code" / "lilypad"
MODEL = "ollama/qwen3-coder:30b"
NOW = int(time.time() * 1000)
MIN = 60_000


def envelope(session, seq, created, event):
    return {"type": "event", "env": {"seq": seq, "session": session, "created": created, **event}}


def write(path, session, cwd, created, events):
    path.parent.mkdir(parents=True, exist_ok=True)
    header = {"type": "header", "version": 1, "id": session, "cwd": str(cwd), "model": MODEL, "created": created}
    with open(path, "w") as f:
        f.write(json.dumps(header) + "\n")
        t = created
        for seq, (dt, event) in enumerate(events, 1):
            t += dt
            f.write(json.dumps(envelope(session, seq, t, event)) + "\n")


def tool(id, name, arg, outcome="ok", output="", display=None, diff=None):
    item = {"type": "tool_call", "name": name, "arg": arg, "input": {}, "outcome": outcome, "output": output, "display": display}
    if diff:
        item["diff"] = diff
    return [
        (200, {"event": "item_started", "id": id, "kind": {"type": "tool_call", "name": name, "arg": arg}}),
        (400, {"event": "item_completed", "id": id, "item": item}),
    ]


def said(id, kind, text, ms):
    return [
        (250, {"event": "item_started", "id": id, "kind": {"type": kind}}),
        (ms, {"event": "item_completed", "id": id, "item": {"type": kind, "text": text}}),
    ]


def diff(path, start, lines):
    """lines: (' ' | '-' | '+', text). Numbers follow the old and new files from `start`."""
    old = new = start
    out, added, removed = [], 0, 0
    for mark, text in lines:
        if mark == " ":
            out.append({"kind": "context", "old": old, "new": new, "text": text})
            old += 1
            new += 1
        elif mark == "-":
            out.append({"kind": "remove", "old": old, "text": text})
            old += 1
            removed += 1
        else:
            out.append({"kind": "add", "new": new, "text": text})
            new += 1
            added += 1
    return {"path": path, "created": False, "added": added, "removed": removed, "hunks": [{"lines": out}]}


# The project: enough real files that the folder looks lived in.
(PROJECT / "src").mkdir(parents=True, exist_ok=True)
(PROJECT / "tests").mkdir(exist_ok=True)
(PROJECT / "Cargo.toml").write_text('[package]\nname = "lilypad"\nversion = "0.4.2"\nedition = "2024"\n')
(PROJECT / "src" / "lib.rs").write_text("pub mod retry;\npub mod upload;\n")
(PROJECT / "src" / "retry.rs").write_text("// Exponential backoff with jitter.\n")
(PROJECT / "src" / "upload.rs").write_text("// Multipart uploads to the store.\n")
(PROJECT / "tests" / "upload.rs").write_text("// Upload against a mock store.\n")

# The hero: a flaky test, found and fixed, on a local model.
hero = "20260929-090000-hero"
events = [
    (0, {"event": "turn_started", "turn": 1,
         "input": "upload_retries_on_503 fails about one run in five. Find out why and make it reliable."}),
    *said("r1", "reasoning", "Flaky and probably timing. Read the test and the retry code, then run it a few times.", 1800),
    *tool("t1", "Read", "tests/upload.rs", display="Read 86 lines"),
    *tool("t2", "Read", "src/retry.rs", display="Read 54 lines"),
    *tool("t3", "Bash", "cargo test upload_retries_on_503", outcome="error",
          output="test upload_retries_on_503 ... FAILED\n\nthread 'upload_retries_on_503' panicked at tests/upload.rs:41:\nmock store: no request within 500ms\n\ntest result: FAILED. 0 passed; 1 failed"),
    *said("m1", "message",
          "The backoff adds up to 100% jitter from `thread_rng()`, so the third retry can wait as long as 800ms. "
          "The mock store gives up after 500ms, so whenever the jitter runs high, the test times out.", 1200),
    *said("r2", "reasoning",
          "Make the jitter injectable. Production keeps thread_rng; the test passes a seeded StdRng so its delays "
          "are the same every run and stay under the mock's timeout.", 3800),
    *tool("t5", "Edit", "src/retry.rs", diff=diff("src/retry.rs", 18, [
        (" ", "impl Backoff {"),
        ("-", "    pub fn delay(&self, attempt: u32) -> Duration {"),
        ("+", "    pub fn delay(&self, attempt: u32, rng: &mut impl Rng) -> Duration {"),
        (" ", "        let base = self.base * 2u32.pow(attempt);"),
        ("-", "        let jitter = thread_rng().gen_range(0..=base.as_millis() as u64);"),
        ("+", "        let jitter = rng.gen_range(0..=base.as_millis() as u64 / 2);"),
        (" ", "        base + Duration::from_millis(jitter)"),
        (" ", "    }"),
    ])),
    *tool("t6", "Edit", "tests/upload.rs", diff=diff("tests/upload.rs", 30, [
        (" ", "    let store = MockStore::failing(2, StatusCode::SERVICE_UNAVAILABLE);"),
        ("-", "    let client = Client::new(store.url());"),
        ("+", "    let rng = StdRng::seed_from_u64(7);"),
        ("+", "    let client = Client::new(store.url()).with_rng(rng);"),
    ])),
    *tool("t7", "Bash", "for i in $(seq 50); do cargo test -q upload_retries_on_503 || exit 1; done",
          output="test result: ok. 1 passed; 0 failed (×50)"),
    *said("m2", "message",
          "Fixed. `Backoff::delay` now takes its jitter from an `Rng` you pass in. The client still uses "
          "`thread_rng()`, and the test gives it a seeded `StdRng`, so the delays are the same on every run "
          "and stay well under the mock's 500ms. It passed 50 runs in a row.\n\n"
          "I also halved the jitter to at most 50% of the base delay, which is the usual choice and keeps "
          "the worst case retry at 600ms.", 1500),
    (400, {"event": "turn_ended", "turn": 1, "reason": {"type": "complete"},
           "usage": {"context_tokens": 9400, "input_tokens": 31000, "output_tokens": 1400,
                     "model_calls": 7, "tokens_per_sec": 58.0, "model": MODEL}}),
    (100, {"event": "titled", "title": "Flaky upload retry test"}),
]
write(HOME / "hero.jsonl", hero, PROJECT, NOW - 2 * MIN, events)

# The sidebar: earlier conversations, across a few projects.
sessions = HOME / ".local" / "share" / "frog" / "sessions"
earlier = [
    ("Multipart uploads over 5 GB", PROJECT, 40 * MIN),
    ("Why is cold start slow?", HOME / "code" / "tidepool", 3 * 60 * MIN),
    ("Explain how the store fits together", PROJECT, 5 * 60 * MIN),
    ("Rename Bucket to Store everywhere", PROJECT, 26 * 60 * MIN),
    ("Add a --json flag to the CLI", HOME / "code" / "tidepool", 28 * 60 * MIN),
    ("Is 0.0.0.0 safe for the dev server?", None, 50 * MIN),
]
for i, (title, folder, ago) in enumerate(earlier):
    sid = f"20260928-1{i}0000-side"
    # A plain chat lives in the app's chat folder, which it finds from the real home, not $HOME.
    cwd = folder or Path(pwd.getpwuid(os.getuid()).pw_dir) / ".local" / "share" / "frog" / "chat"
    if folder:
        folder.mkdir(parents=True, exist_ok=True)
    write(sessions / f"{sid}.jsonl", sid, cwd, NOW - ago, [
        (0, {"event": "turn_started", "turn": 1, "input": title}),
        (20_000, {"event": "turn_ended", "turn": 1, "reason": {"type": "complete"},
                  "usage": {"input_tokens": 1, "output_tokens": 1, "model_calls": 1, "model": MODEL}}),
        (100, {"event": "titled", "title": title}),
    ])
print(HOME / "hero.jsonl")
