# sidebar-git — notes

Branch frog/sidebar-git, base 77b5f8c-era main. Commit per piece (`git commit -s`), never push.
Edit tool only for Swift/Rust source.

## Design (committed, Cam approved in-session)
docs/design/sidebar-git/README.md (anatomy, placement, data flow, refresh, failure modes,
hover cards, popover lifecycle) + docs/design/sidebar-git/mockup.html (org tree light+dark,
hover cards).

## Design decisions (Cam approved all 6 recommended, except Q2 all-time note)
- Badge click pins the hover card (macOS popovers open on click); "Show in Workers" moved to
  the card footer + row menu.
- Local-merge rows link to the merge commit (compare pages 404 when the branch is deleted).
- Merged capsule green (purple already means "commits ahead").
- Q2: done-fold landed counts are ALL-TIME (the Today scope's fold is "N earlier", so
  every landed count is all-time — the today-only variant doesn't fit).

## Data honesty (the brief's assumption was false, corrected in design)
The engine logs NO merge events and NO diffstats (only checkpoint.rs numstat = race diffs;
the pond fetches open PRs only). The cards read git locally:
- Merge index: `git log <base> --first-parent --merges -n 200` (17ms), rebuilt when base moves.
  Parses "Merge pull request #N" + body title (58/116 frog merges); "Merge branch '<x>'" for
  local merges (session title as the title).
- +N −M: `diff --shortstat M^1...M^2` (~40ms each), lazy on first hover, ≤13 visible rows only,
  cached by sha forever. No prefetch, no gh.
- Links from remote.origin.url (/pull/N, /commit/sha, /compare only if pushed); non-GitHub
  remotes get no links.

## Build (6 commits past the design)
- 6c01996 GitBadge model — row display, tree-deduped group sums, fold members, git output parsing
- 00a2b4c GitIndex — per-repo ref batch on FSEvents, per-tree status on settle, merge index,
  lazy card stats
- fe45786 badges on the attention tree (leaf, manager sum, done fold) + the hover card
  (lifecycle, links, keyboard when pinned)
- dfaaf4d compact rows + project headers use the shared badge; CompactPRCache (gh per row) and
  SessionMetaCache REMOVED
- 0e70af1 GitIndex tested against a real temp repo (ahead/behind, merged, fresh, dirty, card,
  ref watcher); card closes on scroll, refits as stats arrive
- 964b251 hover-card lifecycle tests; listing-driven status reads at most every 10s; README
  implementation notes

Not built (README "Implementation"): Space-to-open (rows have no keyboard focus), safe triangle,
Show in Workers + tornDown.landed (no Workers/teardown yet), ListSessions ahead vs base, iOS.
Suites green: GitBadge, GitIndex, GitCard, SidebarSnapshot, AttentionTree, SessionNesting,
SidebarOrder, SessionFolds, SessionState, AgentRow (78 tests). The full suite was started but
interrupted at TranscriptSwitchBenchmark (unrelated, slow); not re-run.

## Progress
- 6badefc checkpoint 0 · fac2fb0 survey · 048e656 spec · 4edc4de mockup · 47d0463 hover-card spec ·
  afef4c0 hover-card mockup · build commits above
- origin/main history that touched the same files (merge context, from the switch-tab-kill
  branch's notes, merged here): SwitchAwayTests repro (f41d393) — new thread switched away
  mid-first-answer killed the engine (red on base at 0.5/2/5s + same-folder 2s); fix ad05e31 —
  `SessionBroker.keep` keeps any session with work (not just agents'), an idle startup still
  goes, a kept session waits in `unnamed` until its first `observe`; window/pane close goes
  through the same keep. Suspects 1 (watchdog/reconcile) and 2 (engine-start race) ruled out:
  the engine was stopped by the app, by name, at the switch. App 325 tests, 4 failures all
  TranscriptSwitchBenchmarkTests (wall-clock perf). Engine cargo 467/0 (unsandboxed).
