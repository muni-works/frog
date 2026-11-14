# sidebar refactor

Mockups: `docs/design/sidebar-mockups.html` (open it in a browser; keys 0–7 switch options, `t` switches theme, `/` searches in option 7). Screenshots: `docs/design/sidebar-shots/`.
Data in the mockups is Cam's real org on Oct 25 (titles from `ListSessions`), with states staged for one moment: chief, 4 managers (frog, okc, frog cloud, tang), rose, 40-odd workers, 2 sessions waiting on Cam, 2 failures, 158 archived.

## 1. the problem

With the org running (1 chief, 4 managers, ~30 workers a day) the sidebar is a wall of about 30 rows, all at one weight: running managers, idle workers, finished-but-unarchived tasks, `+N done` folds, a red failure, and two prompt-as-title rows. To find anything you read every row. Three causes:

1. **no ranking.** A session waiting on Cam gets a 6pt dot. It looks like a spec that finished yesterday.
2. **the wrong grouping.** Groups are project folders (`home()` in `Sidebar.swift:107` files a session under its topmost parent's repo). The org cuts across repos: okc manager files under "chief", frog cloud manager's workers under "frog" or "zest", depending on who started them.
3. **finished work stays.** Settled children fold under `+N done` (`SessionNesting.rows`), but each manager still costs a row plus a fold, and quiet managers (tang, rose) take as much room as busy ones.

Bonus noise: titles that are the whole first prompt ("Continue this branch first: check git status/diff…", "Untitled").

## 2. what exists today (read-only survey)

- `apps/macos/Frog/Views/Sidebar.swift` `SessionList`: a custom `ScrollView` + `LazyVStack`, not a `List`, so there's no arrow-key navigation, type-select or native selection. View options: group by project / date / none, sort by activity / created / name, and a compact mode (`CompactSessionRow`, the one in Cam's screenshot).
- `apps/FrogKit/Core/SessionNesting.swift`: pure started-by tree logic. States `waiting < running < unread < failed < done`. Children sort by urgency. Settled children fold into one `.done` entry per parent. Parents can collapse to counts (`"4 running · 1 waiting"`). **This is most of the recommended design's logic already.**
- `Library` (`apps/macos/Frog/Model/Library.swift`): `parents` (the started-by map), `live` (running / waiting / unread), `pinned`, `archived`, `chief` (+ `makeChief` / `removeChief`).
- Chief tile (`ChiefTile`, #92): a wide tile above everything that shows the chief's question, step or last word.
- Pins: a 4-up grid of monograms. `SessionRail`: the folded 52pt strip (pins + live).
- `SidebarOrder`: ⌘1–9 counts top-level rows.
- `SessionTree`: a diagram popover ("Session Tree…" in the row menu).
- Minimap: `TimelineRail.swift`, a 28pt strip on the transcript's right edge. It isn't part of the sidebar.
- Footer: `Archived (N)` swaps the list for the archive, grouped by day.

## 3. what a good sidebar does here

Scored 1–5 in the mockups' scorecards:
- **find a session**: by name, or by "the okc one that finished this morning".
- **see what needs you**: in one glance, without scrolling.
- **scales past 50**: the org doubles, and the sidebar doesn't.
- **native feel**: keyboard, selection and disclosure behave like Finder or Mail.
- **keeps the org**: chief › manager › worker stays visible, because that's how Cam delegates and checks.
- **cheap to build**: reuses `SessionNesting`, `Library` and the background-work states.

## 4. the options

### 1 · full native tree (`1-native-tree.png`)
**Model:** the org chart is the list. NSOutlineView style: chief at the root, managers, then workers, any depth, one row per session, disclosure triangles.
**With 30+ sessions:** all 49 sessions are rows. Expanded, ~27 fit, and both sessions waiting on Cam fall below the fold (okc's manager sits after frog manager's 20 children). Folded to managers it's 13 rows, and nothing live shows.
**Breaks:** nothing is ranked. Depth eats width: at level 3 a 288pt sidebar leaves ~170pt for the title. "What needs me?" still means scanning. Long-lived managers collect hundreds of children.
**For:** Cam's instinct. Right for structure and keyboard. It's the skeleton, not the whole answer.

### 2 · workspace grouping (`2-workspace.png`)
**Model:** sessions belong to repos. Repo › manager › worker, with branch, worktree and PR chips. Quiet repos fold to one line.
**With 30+:** compact. 8 repos fit, and rows show what they shipped.
**Breaks:** the org. The chief and frog cloud manager work across repos, so a manager's workers scatter. Managers become labels. It doesn't answer "what needs me". `~/Developer` and `home` become junk drawers.
**For:** someone running many workers in a few repos who thinks in PRs. It matches git, not the org.

### 3 · activity-first (`3-activity.png`)
**Model:** sections by state: needs you › running › failed › done today. Each row names its manager. The org chart lives in a popover (⌘⇧O, or hover the manager name).
**With 30+:** only live work takes space. It scales to any size because the hierarchy isn't laid out.
**Breaks:** spatial memory. Rows jump sections as their state changes. Siblings scatter (okc's 5 workers sit in 3 sections). Managers and workers are peers in one flat list. Structure lives somewhere else.
**For:** an operator triaging a queue. Great as a lens, tiring as the only view.

### 4 · sparkline status cards (`4-cards.png`)
**Model:** one live card per manager: its last line or question, an activity sparkline, counts, spend. Expand a card for its workers. Quiet managers drop to one line.
**With 30+:** the best at a glance (frog busy, okc winding down, tang asleep).
**Breaks:** tall (~6 cards fit). Always moving, which pulls the eye from the transcript. Workers are second-class. Live rendering for 50+ sessions is costly.
**For:** a manager of managers watching health and cost. It belongs in Activity (⌘0, background-work spec §2), not the sidebar.

### 5 · command-palette sidebar (`5-palette.png`)
**Model:** the sidebar holds only the chief, needs you and running. Everything else is ⌘K (or just type): fuzzy over titles, managers, archive and commands.
**With 30+:** it never grows. 30 or 300 sessions, it's the same dozen rows.
**Breaks:** browsing. "The thing okc finished this morning" needs its name. Finished work vanishes, so reviewing the day needs another view. The org is invisible.
**For:** a keyboard person who knows what they want. The right answer for *jump*, not for *see*.

### 6 · rail + list (`6-rail.png`)
**Model:** Slack, Mail or Arc. A 58pt rail of managers (plus needs you and yours) with badges, and a list pane for one manager: live, then done.
**With 30+:** calm per manager. The rail holds ~10.
**Breaks:** the cross-org view ("what's running anywhere?" takes 6 clicks). Two clicks to any worker. ⌘1–9 would mean managers. It costs ~320pt of width. `SessionRail` would change meaning.
**For:** someone who lives in one manager at a time. Cam doesn't: he reads across managers through the chief.

### comparison

| | find | needs you | scales | native | org | cheap |
|---|---|---|---|---|---|---|
| 0 today | 2 | 2 | 1 | 3 | 2 | 5 |
| 1 native tree | 3 | 1 | 2 | 5 | 5 | 4 |
| 2 workspace | 3 | 2 | 4 | 4 | 1 | 4 |
| 3 activity | 4 | 5 | 5 | 3 | 1 | 3 |
| 4 cards | 2 | 3 | 3 | 2 | 3 | 2 |
| 5 palette | 5 | 4 | 5 | 3 | 1 | 4 |
| 6 rail + list | 3 | 3 | 4 | 4 | 3 | 3 |
| **7 attention tree** | **5** | **5** | **4** | **5** | **5** | **4** |

## 5. recommendation: the attention tree (`7-recommended-*.png`)

**Cam's native tree as the skeleton, with three things on top:** a needs-you lens above it, a live scope that hides settled work by default, and search that filters the tree in place. Each piece takes the one thing an option above gets right (1's structure, 3's triage, 5's jump, 4's quiet managers) without its cost.

```
[⌕ Search or jump        ⌘K] ≡ ✎
[C chief · relaying 2 merges to frog manager   ⟳]
NEEDS YOU 2                               ⌘⇧0
 ● okc bf16 proj                           4m
   pod past its 2h cap · $3.50/hr · extend?
 ● gateway batching                        1m
   push branch gateway-batching
ORG                         [Live|Today|All]
 ▾ F frog manager                          ⟳
   ▾ graceful restart implementation       ⟳
       restart drill tests                 ⟳
     ▸ 1 done
   ▸ 18 done · 1 failed
 ▾ O okc manager                       12m ○
     okc decode layer                      ⟳
     okc bf16 proj                         ●
     okc prefill layer                     ⟳
   ▸ 2 done
 ▾ F frog cloud manager                    ⟳
     …
 ▸ T tang manager                   6 done
   R rose head mvp setup                3d ○
 ▸ 4 done by chief
YOURS
   B blaze distill                         ⟳
   M Make the frog cloud node boot f…  3d ●
🗄 Archived 158             11 live · $4.20/hr
```

### structure
- **Chief tile** stays pinned on top, unchanged (#92).
- **Needs you**: every session blocked on Cam (an approval, an ask, an elicitation), anywhere in the tree. Two lines per row: the title, and what it wants in muted text (the warning color stays on the glyph). Oldest first. Hidden when empty. It's a *lens*: the session also keeps its place in the tree with an orange dot. Clicking opens the session scrolled to its card. ⌘⇧0 opens the full inbox (background-work spec §2). Child reports and finished jobs never land here.
- **Org**: the started-by tree (`Library.parents`), rooted at the chief. Managers are top-level rows, workers nest at any depth — every level indents (`AttentionMetrics`: 14pt for the first four, then narrowing steps that never reach zero), with a rail per ancestor and an elbow into the row (`SessionNesting.Guide`). Sessions the chief started directly that aren't managers fold into "N done by chief".
- **Yours**: root sessions Cam started himself, newest first. In Live scope only live and failed ones show.
- **Footer**: `Archived (158)` opens the archive as a scope (search by day, as today). On the right, the live count and burn rate from the background-work ledger.

### scope: Live · Today · All
- **Live** (default): a parent shows its live children (running, waiting, unread, dead, orphaned) plus the one on screen. Its settled children fold into one `N done · k failed` row (today's `.done` entry). A manager with nothing live folds to one quiet line with its counts (`tang manager · 6 done`).
- **Today**: settled children from today show as quiet rows; older ones fold into `N earlier`.
- **All**: everything not archived.
- The scope persists per window (`@AppStorage`, like `sidebarGrouping`).

### three row weights
| tier | look | when |
|---|---|---|
| manager | 18pt monogram (folder tint), 13pt semibold | has started sessions and something under it is live |
| live worker | 13pt regular, no monogram (the width goes to the title) | running, waiting, unread |
| settled | 12pt muted, age instead of a glyph, ✓ when nested | done, failed, quiet managers |

State color appears only on the glyph, using the background-work vocabulary: spinner = running, hollow ring = idle, orange dot = waiting on you, accent dot = unread, red dot = failed, red flatline = dead, dashed red ring = orphaned. **Failed folds into done** but keeps its red count (`18 done · 1 failed`): a failure is its manager's to handle, not Cam's. **Dead and orphaned never fold**, because they lose work or cost money.

### search
- Typing in the field (or ⌘K, or type-to-focus from the list) filters the tree in place. Matches stay with their ancestors so context survives, matched text is highlighted, and scope is ignored. An `In archive` group lists archive matches below. Esc clears.
- Matches titles, first input, folder and worktree, as `visible` does today.
- ⌘K stays the command palette, and its session results use the same matcher, so jumping works from anywhere.

### keyboard and mouse (free with a native list)
↑/↓ move · ←/→ fold or unfold (⌥ for all) · ⏎ open · ⌘⏎ open in a new pane · type-select · space peeks the transcript · ⌘1–9 open top-level org rows (`SidebarOrder`, unchanged in meaning) · ⌘⇧0 needs you · drag a row onto a pane, as today.

### why this one
- It answers Cam's two daily questions in order: *what needs me?* (top, no scroll) and *what's my org doing?* (the tree, live-only, one line per quiet manager).
- It's Cam's tree, so the structure he delegates through stays visible, and the keyboard and selection become native.
- It doesn't move rows: state changes a row's glyph and weight, never its place. Only the needs-you lens duplicates a row.
- It's mostly existing code: `SessionNesting.rows` already sorts by urgency, folds settled children and summarizes counts. The new pieces are a scope parameter, the lens, and the move to a `List`.

## 6. migration notes

- **Make Chief / Remove Chief**: unchanged, still in the row menu. The chosen chief becomes the tree's root: its children are the top level, and it's drawn as the tile, not a row. With no chief, each root session with children is a top-level manager and the rest go to Yours.
- **Chief tile (#92)**: unchanged. It still shows the chief's question, step or last word. When the chief itself waits on Cam it also appears in Needs you.
- **Pins**: the 4-up tile grid goes away from the sidebar body. A pinned session gets a pin glyph and floats to the top of its level. The folded `SessionRail` keeps pins + live, as today. (decision 4)
- **Minimap (`TimelineRail`)**: untouched. It's per-transcript navigation on the right edge. The only link: selecting a row in Needs you scrolls the transcript (and the rail's lit window) to the open card.
- **Archived**: the footer button stays and opens archive mode (day groups). New: search reaches the archive inline. Proposed auto-archive: a worker that's done, seen, and whose branch is merged or has no commits, after 24h (chats already auto-archive after 12h). (decision 3)
- **View options menu**: "Group by" becomes Org (default) / Project / Date. Project and Date keep today's code paths for people without an org. Sort stays. "Compact" goes away: the attention tree *is* the compact mode, and its rows match `CompactSessionRow`'s density.
- **`+N done` and collapsed parents**: kept, from `SessionNesting.Entry.done`. "Collapse started sessions" becomes the ← key and the disclosure triangle.
- **Session Tree popover**: kept in the row menu. It's the diagram view, and the outline now covers most of its use.
- **Titles**: out of scope here, but it's the cheapest win. Workers whose title is their first prompt should get a short generated title (or the worktree name) once the first turn ends. Two of the rows in the mockups are only noise because of this.
- **Implementation path**:
  1. Add a `scope` parameter to `SessionNesting.rows` (live / today / all) plus tests next to `SidebarOrderTests`.
  2. Move `SessionList`'s body to `List(selection:)` + `.listStyle(.sidebar)` with recursive `DisclosureGroup`s (or `OutlineGroup` over a node enum: session / done-fold). This gets keyboard nav, type-select and accessibility. If `List` row hover menus or 500+ rows misbehave, fall back to an `NSOutlineView` representable behind the same node model.
  3. The needs-you section reads `library.live == .waiting` now, and the approvals ledger (`ListApprovals`) once background-work item 6 lands.
  4. Dead and orphaned glyphs come with background-work item 5 (heartbeat liveness). Until then those states don't occur.
  5. Footer burn rate comes with background-work items 6–7.

## 7. decisions for Cam

1. **which sidebar**
   1. the attention tree (recommended): native tree + needs-you lens + Live scope + search in place
   2. full native tree only (option 1): every session a row, no scope
   3. activity-first (option 3): state sections, org in a popover
2. **default scope**
   1. Live (recommended): settled work folds; quiet managers are one line
   2. Today: also shows what finished today
   3. All
3. **auto-archive finished workers**
   1. after 24h once done, seen and merged (or no commits) (recommended)
   2. never: Cam archives by hand
   3. at once when done and merged
4. **pins**
   1. pin glyph + float to the top of its level; tiles only in the folded rail (recommended)
   2. keep the 4-up tile grid above the tree
5. **failed workers**
   1. fold into "N done · k failed" under their manager; the manager handles it (recommended)
   2. always show as their own row until opened
   3. also list them in Needs you
