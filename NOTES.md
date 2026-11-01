# model-sections-red-fix — notes

Branch frog/model-sections-red-fix (worktree model-sections-red-fix), base = origin/main
(76631850). Fixing frog's red macos-app CI test step on main (run 41318468435, 2026-11-01):
ModelSectionsTests.{testOrderWithoutServersSignedIn, testOrderWithServersSignedIn,
testSignedOutFrogCloudStaysWithSignInAction} fail. One commit per step (`git commit -s`),
NEVER push (branch tracks origin/main). Edit tool only for source. xcodebuild derived data in
/private/tmp/ms-dd only.

## What I know (verified from the commits)
- #224 (f1eb8776, Oct 30, "Launch with Frog Cloud's models only") added
  `ModelSections.frogCloudOnly = true`: `make()` filters the section list to Frog Cloud models
  only, and hides the picker's "Cloud setup" row, "Manage Models…", and Settings' Models tab.
  Cam's explicit launch decision, quoted in the commit message.
- #225 (dc26cff2, Oct 30, later the same day) removed the `alwaysFrogCloud` fallback (nothing
  built in fills the Frog Cloud section; the section exists only when the engine listed it) and
  already updated ONE test for the new world (renamed testFrogCloudAlwaysPresent →
  testNoFrogCloudSectionWhenNothingListedIt). It also switched the test fixture's cloud entry
  to `cloud/tree`.
- The three failing tests still assert the PRE-#224 section order: This Mac / On mew / frog
  cloud / Cloud · Anthropic / Cloud · OpenAI. Under frogCloudOnly every non-Frog-Cloud model is
  filtered out, so `make()` returns just ["frog cloud"].

## Decision (before changing anything)
INTENDED behavior change; update the tests, do not touch the code.
Evidence: the filter is `if frogCloudOnly { all = all.filter(\.place.isFrogCloud) }`
(ModelList.swift:44), added by #224 whose message says Cam asked for exactly this ("keep it
simple for launch … every picker lists Frog Cloud's models and nothing else"), with a documented
off-switch. #225 doubled down (no fallback section) and already migrated one test. Nothing in
either commit suggests the pickers were meant to keep the full list. The test file's header
comment still cites the old plan doc's order, which #224 superseded for launch.

## New expectations (launch behavior)
- Signed in, servers or not: sections = ["frog cloud"] only.
- Signed out: "frog cloud" section remains IF the engine listed a cloud model (fixture does:
  cloud/tree), with the sign-in state/line unchanged ("Sign in or add a key to use it").
- testSignedOutFrogCloudStaysWithSignInAction's positional index assert is meaningless with one
  section; keep the state/line asserts, drop the index (or keep a ["frog cloud"] order check).

## Plan
1. This checkpoint, commit.
2. Run the 3 failing tests locally (xcodegen generate --quiet first; -only-testing:
   ModelSectionsTests; dd /private/tmp/ms-dd) and confirm the actual assertion diffs.
3. Update the three tests to the launch expectations above. Only assertions change; no source
   edits expected.
4. Full suite, same xcodebuild without -only-testing. TranscriptSwitchBenchmarkTests
   s400/s5000 = known-noisy. Report exact pass/fail counts.
5. Commit the fix.

## Result
- Local failing run reproduced the CI diffs: actual ["frog cloud"] vs the 4/5-section
  expectations; testOrderWithServersSignedIn also crashed the runner at `s[2]` (index out of
  range). testSignedOutFrogCloudStaysWithSignInAction's state + stateLine asserts PASSED.
- Fix: tests only. Order asserts → ["frog cloud"]; server/positional index asserts dropped;
  sign-in state/line asserts kept. Header comment now cites #224 and the off-switch.
- Targeted run: ModelSectionsTests 7/7 passed.
- Full suite: Executed 363 tests, 0 failures, 4 skipped (359 passed, ~244 s). Zero test
  failures; TranscriptSwitchBenchmarkTests included and quiet.
- Commits: a5174ddd (notes checkpoint), 2c88732d (the fix). Not pushed.
