# output-cap — notes

Branch frog/output-cap, base c374000c (main). One commit per fix (`git commit -s`), never push to
main; push the branch and open a PR at the end. Edit tool only for Rust. Target dir
/private/tmp/oc-target (delete when the suite passes, ~11G).

## Pieces
0. This checkpoint.
1. CLOUD_MAX_OUTPUT 16_384 → 32_768 (engine/mod.rs). The other 16_384 hits
   (background.rs:694 log tail, project.rs COMPACT_WINDOW, mcp_oauth.rs read buffer) are
   unrelated sizes and stay.
2. Bounded auto-continue on MaxTokens: a reply cut off with no tool call pending is re-called
   with a continuation instruction, up to MAX_CONTINUES (2). The continuation APPENDS to the
   same assistant message (one transcript bubble, one history message via Record::Extend).
   EndReason::MaxTokens carries the count so the banner can say "(auto-continued 2x)".

## Where things are
- crates/frog-engine/src/engine/mod.rs:201 — the cap; :198 — MAX_CONTINUES (now 2).
- crates/frog-engine/src/engine/turn.rs — the step loop, the cut-off branch, message recording.
  `steer` holds the continuation instruction for one call only; `continuing` makes the reply's
  blocks join the message it continues (`extend_last`, i.e. the log's Extend record) instead of
  a second Push. `reply_text` accumulates so the bubble's completion carries the whole answer.
- crates/frog-engine/src/engine/call.rs — `call()` takes the message item id to stream into.
- crates/frog-engine/src/protocol.rs — `EndReason::MaxTokens { auto_continued }` and
  `limit_banner(n)`, one place for the banner copy.
- apps/FrogKit/Core/Protocol.swift, UI/Transcript/{TranscriptView,Activity}.swift — the banner.

## Decisions
- The continuation instruction rides on ONE request (a user message built per call) and never
  enters the history. That keeps the reply a single assistant message, which is what the brief
  asks for, and avoids Anthropic rejecting text-then-thinking block order.
- A continuation's own thinking block is not spliced into the joined message (the old block
  stays exactly as it was); its text is what joins.
- MAX_CONTINUES went 3 → 2 to match "at most 2 auto-continuations per turn".

## Result
Targeted: 6 passed (output_limit, a_cut_off, max_tokens filters).

