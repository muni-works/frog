# checkout-both-fixes — notes

Branch frog/checkout-both-fixes, base b23479fd (current main). Cam's brief: two people fixed the
same beachball bug in `SessionBroker.checkout(of:)` and only one covered the launch path —
reconcile both fixes into one, commit `-s`, never push. Edit tool only for source. One commit
checkpoint, then the fix, then local suites as the gate (Actions billing is rejecting every run).

## The near-miss, verified

`SessionBroker.checkout(of:)` (apps/macos/Frog/Model/SessionBroker.swift) walks up looking for
`.git`. A RELATIVE folder URL — what a restored window passes at launch — never reaches "/":
`deletingLastPathComponent` walks "." → ".." → "../.." forever, beachballing the app after a
reboot. Two fixes existed, each incomplete alone:

- main from #242: `folder.resolvingSymlinksInPath().standardizedFileURL` + the non-shortening
  guard (`var last` / `guard up.path != last`). Resolution terminates the MISSING-folder case
  (standardized keeps ".." segments for a missing path). But for a relative URL, resolution
  STAYS relative (experiment: `URL(fileURLWithPath:"rel/nested").resolvingSymlinksInPath()` is
  still relative — unlike `URL(string:)`, the fileURLWithPath initializer is already absolute,
  so the relative case must arrive as a scheme-less `URL(string:)`) — the walk still never
  terminates.
- 61683fd2 (Claude's, on claude/frog-beachball-reboot-1209da, not on main):
  `URL(fileURLWithPath: folder.path).standardizedFileURL` — absolute first — plus a third
  belt `if up.path == at.path || !up.path.hasPrefix("/") { return .plain }`. But without
  resolution, a missing folder's kept ".." segments make `deletingLastPathComponent` grow the
  path forever again: belt two (main's guard) is what catches that.

## The combined fix (all three belts kept)

1. `var at = URL(fileURLWithPath: folder.path).resolvingSymlinksInPath().standardizedFileURL`
   — absolute FIRST, then resolve, then standardize.
2. Belt two from main kept: `var last = at.path` before the loop; `guard up.path != last else
   { return .plain }` then `last = up.path`.
3. Belt three from 61683fd2 kept: the exit condition is
   `if up.path == at.path || !up.path.hasPrefix("/") { return .plain }`.

A comment at the setup names the near-miss and why each belt is there.

## Tests (apps/macos/FrogTests/WorktreeHoldTests.swift)

a) `testARelativeFolderURLIsPlainAndReturnsBeforeTheTimeout` — a scheme-less relative URL on a
   background queue, guarded by a 5 s timeout expectation so a regression fails fast instead of
   hanging the suite (this is the beachball case: launch passes a relative URL).
b) the existing missing-nested-ABSOLUTE test from #242 stays;
c) the existing real-worktree coverage stays;
d) new `testDotDotSegmentsResolveToTheRightAbsolutePlace` — a dotted path must reach the real
   repo above it (`.main(top:)` at the right absolute top), not merely terminate.

## Result

Commits: c62edc6d (checkpoint: NOTES + the fix, swept in), 0265f620 (the regression tests).
`git add -A` at the checkpoint caught the already-edited SessionBroker.swift, so the checkpoint
holds the whole source change; the second commit is the tests.

Verification: WorktreeHoldTests 9/9 passed (2 new), SessionBrokerTests 53/53 passed; full app
suite 382 executed, 4 skipped, 4 failures — all four are one distinct test,
`TranscriptSwitchBenchmarkTests.testScrollUpFillsOlderRowsInOrder` ("never reached the first
row"), which fails identically with BASE b23479fd `checkout()` in this same worktree (37 s full
run, 22 s alone): pre-existing flaky scroll benchmark, not this change. `cargo build -p frog -p
frog-engine` finished clean (19.6 s, dev profile).

The sandbox blocked SwiftPM's sidecar compile and Xcode's macro plugin server
(swift-plugin-server "malformed response") — both run unsandboxed, with FROG_PREBUILT_DIR
supplying the prebuilt engine binaries so build-engine.sh skips cargo/SwiftPM. The xcodeproj is
xcodegen-generated (gitignored); regenerated with `xcodegen generate`. Scheme is `Frog` (no
FrogTests scheme exists); `-only-testing:FrogTests/…` filters within it.

Test-construction finding worth keeping: `URL(fileURLWithPath: "rel/nested")` is ALREADY
absolute (resolved against the CWD), so the relative case under test must be built as
`URL(string: "rel/nested")` — scheme-less, `isFileURL == false`, path without a leading "/".

## Lesson

Two fixes for the same function — reconcile before merging, and test the RELATIVE-URL case,
which is what launch passes.
