# subagent visibility — notes

Branch frog/subagent-visibility, base a786571 (main). Commit per piece (`git commit -s`), never push.
Swift/Rust source edits via the Edit tool only. (Previous branch's notes — typography pass — live in git
history at a786571:NOTES.md.)

## Goal (Cam: "better subagent visibility")
1. session-level presence (activity line / sidebar row) for running subagents
2. timeline rail glyphs per subagent start, click-to-jump (chapter-marker machinery)
3. SubagentRunSheet parity with the main transcript
4. failure visibility: failed subagent findable in one click

## Constraints
- perf: streaming benchmark ≤30 materialized rows; rail glyphs no per-row hot-path cost
- app tests: xcodegen -q; xcodebuild test -derivedDataPath /private/tmp/subv-dd (unsandboxed)
- engine (only if touched): CARGO_TARGET_DIR=/private/tmp/subv-target
- delete both dirs at the end

## Survey
(filled in below)

## Decisions

## Progress
