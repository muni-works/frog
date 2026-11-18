# Mac app feature map

Every feature of the Mac app and every user flow through it, as JSON:

- `shell.json`: windows, sidebar, panes, menus, the palette, Settings.
- `conversation.json`: the transcript, composer, permission cards, inspector, git.
- `platform.json`: Frog Cloud, models, machines, updates, docs.
- `harness.json`: the test target, the fakes that exist, the background rule and the gaps.

Each feature has `flows`; each flow has `steps`, the `expected` result, what it `needs`, and
whether it can be automated (`automatable`: yes, hard, no, with `why_hard`).

The first version was read from the code at v0.7.0 (2026-11-18) by agents, not run. Treat a
flow as a claim to check: when a test shows it's wrong, fix the flow here. The hand-read
`coverage_v070` and `existing_tests_v070` fields are that first reading, kept for reference
and never updated; what a test drives today is `flow_tests` (below), which is computed.

**Flow ids are stable keys.** Tests name them, so don't rename or reuse one; a new flow gets a
new id. Ids are unique across the three files (the shell area's copies of a flow described
twice got a `shell-` prefix: `shell-quit-and-resume`, `shell-quit-and-stop`,
`shell-sign-in-from-footer`, `shell-cancel-sign-in`, `shell-get-suggested-model`,
`shell-map-project`, `shell-undo-last-turn`, `shell-search-docs`).

## Flow tests and computed coverage

An integration test that drives a flow through the user's steps is named for it:

```swift
func test_rename_from_title()   // covers rename-from-title
func test_deny__withNote()      // a variant of deny
```

`test_` plus the flow id with underscores for hyphens, and an optional `__variant`. That's the
only way a test declares a flow; nothing else in FrogTests starts with `test_`.

`coverage.py` reads the tests and fills each flow's `flow_tests`:

```bash
python3 docs/testing/feature-map/coverage.py          # what's driven, what isn't
python3 docs/testing/feature-map/coverage.py --write  # update flow_tests in the map
python3 docs/testing/feature-map/coverage.py --check  # what CI runs (FeatureMapTests)
```

`--check` fails when a test names a flow that isn't in the map, a `test_` name breaks the
rule, two flows share an id, or `flow_tests` is stale. It runs inside the Mac test suite
(`FeatureMapTests`), so it's part of CI's `macos-app` job.
