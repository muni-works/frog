# chief-flag — notes

Branch frog/chief-flag, base d13ac864 (main). Commit per piece (`git commit -s`), push the branch,
PR to main when green — the chief merges. Edit tool only for Swift. DerivedData /private/tmp/cf-dd,
DELETE EARLY (disk ~11G). Report ≤25 lines: sha(s), flag home, what's hidden, test counts, PR no.

Task: disable the chief codepaths behind a feature flag — `FeatureFlags.chief = false` default OFF,
one constant in one file. Hide, don't rip out: flipping the constant restores everything. New users
see the pre-chief sidebar (the merged #63-era tree without the chief tile).

## Folded-in refinement (from the frog manager, after the 401 killed turn 1)
The chief-of-staff PATTERN stays usable — talking to the chief as one thread with the org under it
— just not HARDCODED in the UI:
1. Pinning is 90% of the chief-tile UX: verify a plain pinned session renders as a good "home base"
   (pinned-row preview + working indicator read well without any chief logic).
2. The org tree (Group By › Org) must keep working with NO chief set — check AttentionTree for a
   chief-root assumption; if it roots at the chief, make it root at "needs you" + the started-by
   tree without a chief node.
3. Document in the README the pattern instead of the feature: "run a long-lived session in a
   workspace (e.g. ~/Developer/chief), keep it pinned, hang managers under it via StartSession" —
   the UI must not fight that.
Tests for org-tree-without-chief added to the brief's test set.

## Where chief lives (read, none of it deleted)
- apps/macos/Frog/Model/Library.swift — `chief` (defaults "chiefSession"), `chiefSession`,
  `makeChief`/`removeChief`, pin-keep in `togglePin` (chief can't be unpinned), resign on archive.
- apps/macos/Frog/Views/Sidebar.swift — `chiefTile` (the wide tile, shown in every grouping),
  context menu "Make Chief"/"Remove Chief" (`rowMenu`, 1060-1064), pin-menu no-op on the chief
  (1059), org view preempts the tile (359-361), empty-state checks `chiefSession == nil`
  (394, 550, 674), `pins` exclude the chief (101).
- apps/FrogKit/Core/AttentionTree.swift — `layout(... chief: String?)`: the chief's children ARE
  the top level (`up` flattens parent==chief to nil), the chief's own finished leaves fold into
  `chiefFold` ("N done by chief"), chief never listed as a row. NO chief = roots at "needs you" +
  the started-by tree (chief itself becomes a top-level row) — testWithoutAChiefRootsWithChildrenAreManagers
  already covers the pure logic; the VIEW side (Sidebar.attention passes library.chief,
  WorkspaceView.sidebarOrder prepends chiefSession, GitTreeBadges' chiefFold children) must keep
  working with chief nil while the flag is off even when a stale chief is still saved.
- apps/macos/Frog/Views/WorkspaceView.swift:91 — ⌘1…9 order prepends the chief.
- apps/macos/Frog/Views/GitBadges.swift:116,146 — chiefFold's children and "Done by chief" title.
- apps/macos/FrogTests/ChiefTests.swift — 4 tests, all chief-logic (guard whole class flag-on).
- Library.stage chief param (DEBUG only, snapshot fixtures) — persistence-adjacent, keep.

## NOT chief (verified, untouched)
- SessionBroker delegated approvals (ResolveDelegated) — a different "chief": the named target
  session in the delegation request, engine-level, out of scope.
- Chapters.swift:95, GitBadge.swift, Conversation.swift liveActivity — comments only.
- iOS: no chief references at all.

## Plan
1. FeatureFlags (apps/FrogKit/Core/FeatureFlags.swift, `static let chief = false`).
2. Library: pin-keep + tile helpers' callers behind the flag (roster/persistence intact).
3. Sidebar: tile + menu items hidden when off; tree/⌘-order/git badges ignore a saved chief.
4. README: the pattern (long-lived pinned session as home base) instead of the feature.
5. Tests: whole ChiefTests guarded flag-on; new off-state tests (no tile, no menu items, org
   tree ignores a saved chief); AttentionTreeTests already covers chief=nil logic.

## Progress
- (none yet)

## Tests
- (none yet)
