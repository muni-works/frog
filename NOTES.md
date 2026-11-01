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
- crates/frog-engine/src/engine/mod.rs:201 — the cap; :198 — MAX_CONTINUES.
- crates/frog-engine/src/engine/turn.rs — the step loop, the cut-off branch, message recording.
- crates/frog-engine/src/engine/call.rs — `call()`, which seeds the message item id to extend.
- apps/FrogKit/Core/Protocol.swift, UI/Transcript/{TranscriptView,Activity}.swift — the banner.
