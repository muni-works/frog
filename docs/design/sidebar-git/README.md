# Sidebar git badges — design

Status: **built** on `frog/sidebar-git`. Cam approved the design ("perfect, lets implement"), which
took the recommended answer to every open question. What was built and what wasn't is listed at
the end, under "Implementation". Base: `77b5f8c` (main).
Mockup: [mockup.html](mockup.html) (the org tree with badges, light and dark; the hover cards for a
group row and a session row; the anatomy strip; the Workers scope fed by the same data).

Cam asked for per-row git badges like Claude's sidebar: a purple branch glyph with commits ahead, a
green merged glyph with a count, and group rows that sum their children. This spec fits that into
the attention tree (three row weights, `Live · Today · All`) and the merged worktree-ux spec (the
Workers scope, the manifest, one "ahead"). The two specs split the job. **A session row shows a
summary badge. A tree row in Workers shows the full numbers.** Both read one index.

The rule over all of it: **drawing a row never runs git.** A row reads a dictionary. Git runs once
per repo when refs change, and once per tree when a turn ends. The network is used only when you ask.

---

## 0. What exists (checked in source at 77b5f8c)

| Piece | Where | Today |
|---|---|---|
| Org rows | `TreeRow`, `AttentionRows.swift:18` | The default grouping. Trailing: pane number · age (settled only) · state glyph. **No git info.** |
| Project/Date rows | `CompactSessionRow`, `Sidebar.swift:1109` | PR glyph (`arrow.triangle.merge` green / open purple) + `changedFiles`, then `3↑`, age, glyph. |
| PR lookup | `CompactPRCache`, `Sidebar.swift:1330` | **Per row**: `git branch --show-current`, then `gh pr view <branch>`, in the row's `.task`. 60 s throttle. It runs again every time a row scrolls back in. This is the gh spam this spec removes. |
| Ahead | `SessionMetaCache`, `SessionMeta.swift:21` | `rev-list --count main..HEAD` per worktree, 60 s. "Worktree" is a path-substring test, so okc's `.worktrees/` trees never count. |
| Ahead (tools) | `Git.quick`, `Git.swift:64` | ListSessions/SessionStatus count against the **upstream**, which is nil for unpushed `frog/*` (worktree-ux F12). |
| Lock | `worktree.rs` | `.git/worktrees/<name>/frog-engine.lock` holds `"<session> <pid>"`. No branch, base or counts. |
| Manifest, header `worktree`, `frog --worktrees --json`, Workers | worktree-ux §1, §3 | **Specced, not built.** |
| Merge events, diffstats | — | **None.** The engine logs no merge and no diffstat (the only `--numstat` is `checkpoint.rs:205`, which applies race diffs). Pond's GitHub read (`pond/github.rs`) asks for OPEN PRs only. |
| Merge commits on base | git | In frog's `origin/main`, 58 of 116 merges are `Merge pull request #N from ecto/<branch>`, and the PR title is the first body line. The rest (all recent ones) are local `Merge remote-tracking branch 'origin/frog/<x>'`. The last 200 first-parent merges list in **17 ms**, and one merge's `diff --shortstat M^1...M^2` takes **~40 ms**. |

What that means for the design:
1. **"Merged" has to come from local git.** Most merges in this org are local `git merge
   origin/frog/x` + push, not GitHub PR merges, so local git sees them anyway. GitHub only adds the
   PR number and the squash merges that git can't prove.
2. **Per-repo batches are nearly free.** Measured on the frog repo (103 `frog/*` branches, 115
   worktrees, git 2.54): `for-each-ref --format='%(ahead-behind:origin/main)'` for every branch takes
   **16 ms**, and `for-each-ref --merged origin/main` takes **11 ms**. Per-tree work (status, rev-list,
   cherry) takes 65 ms a tree. So ahead and merged are per repo, and only dirty is per tree.

---

## 1. Badge anatomy

```
 ⎇ 7•   ⇡ 12
 │ │└ dirty: uncommitted changes in the tree (a dot, no count)
 │ └ commits ahead of base (only when > 0)
 └ branch glyph, purple          └ landed glyph, green; the count is on aggregates only
```
(In this doc, `⎇` stands for the branch glyph and `⇡` for the merge glyph. The app uses SF Symbols.)

| Part | Glyph (SF Symbol) | Color | When |
|---|---|---|---|
| **ahead** | `arrow.triangle.branch` 10 pt | purple glyph, secondary digits | The tree's branch has commits the base doesn't (`base..HEAD` > 0). This is work that can be pushed or merged. |
| **dirty** | a 4 pt dot at the top right of the branch glyph | the glyph's purple | `status --porcelain` is non-empty **and the session is settled**. A dot without a count, like the "unsaved" dot on a macOS close button. The count is in the tooltip. With 0 ahead the branch glyph shows alone, with its dot. |
| **landed** | `arrow.triangle.merge` 10 pt | green glyph, secondary digits | The branch is in base: an ancestor of it, or every commit patch-equivalent (`git cherry` shows no `+`), or a PR that gh said is MERGED. A leaf shows only the glyph. An aggregate shows the glyph + N. |
| **trouble** | the branch glyph in amber | amber | A rebase, merge or cherry-pick is in progress, or there are unmerged paths. The counts freeze at their last good value. The tooltip says what's happening ("rebasing onto origin/main, 2 conflicts"). |

Rules:
- **Ahead wins over landed** on a leaf. A branch that merged and then got more commits
  (`subagent-visibility` today: merged in b36d033, 2 ahead again) shows `⎇ 2`, not the green glyph.
- **Dirty is shown only when settled.** A running worker is always dirty, so a dot there says
  nothing. A *finished* worker with a dirty tree has left work uncommitted, and that is worth a dot.
- **Behind is never on a row.** It's in the tooltip, and it's the Workers scope's `↓12` and amber
  chip. Rows answer "is there work here that isn't in main?" and nothing else.
- **No git, no badge.** No dot either (see open question 1). Claude's plain dot would collide with
  our dots, which already mean waiting (orange), unread (accent) and failed (red).
- Digits: 11 pt rounded, monospaced, `.secondary`, like the age. Glyph and digits are 2 pt apart,
  and two badges are 6 pt apart. A badge never truncates the title: it's `fixedSize` and the title
  takes what's left.
- Tooltip (always): `frog/accounts-ux-spec · 17 ahead, 133 behind origin/main · clean`, plus `PR #212
  merged` when gh has been asked.

## 2. Placement per row type

The trailing column of `TreeRow` becomes **[git badge] · [pane] · [age, settled] · [state glyph]**.
The badge sits left of everything that's already there, so the state glyph keeps its column and
nothing else moves.

| Row | Badge | Example |
|---|---|---|
| **Manager** (depth 0, has children, semibold while live) | **Aggregate** over its whole subtree: `⎇ Σahead` over children whose trees aren't landed, `⇡ N landed`. Dirty shows as a dot if any *settled* child is dirty. | `frog manager   ⎇• 37  ⇡ 12` |
| **Manager, collapsed** (`· 4 running · 1 waiting`) | Same aggregate. Collapsing hides rows, not numbers. | |
| **Live worker** (regular weight) | Its own `⎇ N`. No dirty dot while running. | `sidebar git   ⎇ 1  ◌` |
| **Settled row** (12 pt, muted) | Its own badge at 0.7 opacity: `⎇ N` (+ dot) when it carries work, `⇡` when landed. | `freedom analysis v2   ⇡  2h` |
| **Done fold** (`› 12 done · 1 failed`) | Aggregate of the folded rows, on the right: `⎇ 34 ⇡ 9`. This answers "did the finished work land?" without opening the fold. | |
| **Branch fold** (several sessions, one tree) | **One** badge, on the fold's head row. The older sessions under it show none. | `delegation pipeline v5  ⎇ 10` (v4 folded) |
| **Agent rows** (`SessionAgents`, in-process subagents) | None. They share the parent's tree. | |
| **Needs-you lens** | None. The lens is about the ask, so one fact gets one home. The row keeps its badge in its tree place. | |
| **Chief tile** | None. | |
| **Yours** (roots you started) | Their own badge, the same as a worker's. | `mew gha runner setup  ⎇ 4` |
| **Project grouping header** (repo) | Aggregate over the repo's rows. It replaces `CompactSessionRow`'s PR glyph + `changedFiles` and `3↑` with the same badge. | `frog   ⎇ 41  ⇡ 23` |

**Aggregation** (a pure function, done next to `AttentionTree.layout`):
- Dedupe by **tree path** first. Two sessions in one tree count once, and so do a manager and its
  worker if they somehow share a tree.
- `ahead` = the sum over unlanded trees. `landed` = the number of distinct trees (or torn-down trees,
  §4) that landed. `dirty` = any settled tree dirty. `trouble` = any *settled* tree in trouble. A
  rebase in a running worker is normal. One left behind by a finished worker is not.
- **The scope never changes a number.** Live, Today and All show or hide rows, but the manager's
  aggregate is always over all its non-archived children. A count that moved when you flipped the
  scope would read as work happening.
- The manager's own tree counts when it has one (`tang manager v2` runs in `glm5-forward`). A manager
  in a main checkout adds nothing (§5 F2).
- A landed tree's ahead is 0 by definition, so the two numbers never count the same commit twice.

## 3. Data flow

```
 session header worktree.path ─┐                 ┌─ per repo (common dir), one batch:
 (worktree-ux §1), else        │                 │  for-each-ref refs/heads %(ahead-behind:<base>)
 worktree::linked(cwd)         ├─► GitIndex  ◄───┤  for-each-ref --merged <base> refs/heads
 (fs read, no subprocess)      │  (FrogKit,      │  git cherry <base> <tip>   (only unproven tips, cached by sha)
 lock + manifest (owner, base) ┘   @MainActor,   ├─ per tree, on settle:  status --porcelain=v2
                                   observable)   ├─ per tree, stat only:  rebase-merge/ rebase-apply/ MERGE_HEAD …
                                        │        └─ gh, on explicit refresh only: pr view <branch> → {number, state}
                                        │
            ┌───────────────────────────┼──────────────────────────────┐
            ▼                           ▼                              ▼
   GitBadge per session        GitSummary per group          Workers scope rows
   (TreeRow, compact rows)     (manager, done fold, repo)    (worktree-ux §3: ↑3 ↓12 ●2, chip, state)
                                        │
                              frog --worktrees --json / ListWorktrees (same fields, for managers)
```

**The model** (FrogKit, so iOS can share it later):

```swift
struct GitBadge: Equatable, Sendable {
    enum Landed: Equatable, Sendable { case no, ancestor, patchEquivalent, pr(Int) }
    enum Trouble: Equatable, Sendable { case rebasing, merging, cherryPicking, conflicts(Int) }
    var tree: String          // canonical tree top: the dedupe key
    var branch: String?       // nil = detached
    var base: String          // "origin/main"
    var ahead: Int, behind: Int
    var dirty: Int?           // nil = not read yet (running, or never settled)
    var landed: Landed
    var trouble: Trouble?
}
struct GitSummary: Equatable { var ahead = 0, landed = 0, dirty = false, trouble = false }
```

`GitIndex` keeps `repos: [commonDir: RepoRefs]` (per-branch ahead/behind/merged, base sha) and
`trees: [treeTop: TreeState]` (branch, dirty, trouble). It maps each `SessionInfo` to a tree once,
when the listing changes. `badge(for:)` is a lookup. Rows observe only their own entry, so one tree
changing doesn't re-render the sidebar.

**Where it lives.** It's in the app, because the app already owns the listing, the live states and file
watching (`SessionDirectoryWatcher` uses DispatchSource vnode sources). The ref watcher is new: one
FSEvents stream per common dir, because vnode sources don't recurse into `refs/`. `frog --worktrees --json` (worktree-ux §3) is the same
computation in the engine for managers and the CLI. Both call the same git commands. The app doesn't
shell out to the engine for this.

### Refresh story

| Trigger | Work | Cost |
|---|---|---|
| Listing changes (a new session, a cwd change) | map session → tree (fs reads) | no subprocess |
| **Refs change**: FSEvents on the common dir's `refs/heads/`, `refs/remotes/<origin>/`, `packed-refs`, `worktrees/*/HEAD`, debounced 1 s | that repo's batch (2 × `for-each-ref`), then `git cherry` for tips that aren't proven and aren't cached | ~30 ms per repo per change. Commits, merges, pushes and fetches all land here. |
| A session **settles** (`Library.live` running → idle/done/failed) | `status --porcelain=v2` and trouble files for its tree | one subprocess per tree per turn |
| A row becomes visible with `dirty == nil` | the same, at most once a minute per tree (today's `SessionMetaCache` rule) | bounded |
| **Refresh** (row menu "Refresh git", or Workers' refresh button) | `git fetch <origin> <base>` (only the base), then the repo batch, then `gh pr view` for that row's branch | network, only on demand |
| Opening a tree's detail in Workers | `gh pr view` for that branch if it isn't cached | one call, on demand |

There's no timer and no polling of refs. A cold launch with 6 repos and 115 trees costs 6 batches
(~0.2 s total, off the main thread) plus status for visible settled rows. An idle window costs nothing.

**Caches that can't go stale:** `git cherry` and gh results are keyed by `(tip sha, base sha)`.
A new commit or a moved base changes the key, so nothing ever has to be invalidated.

**gh, exactly:** never from a row's `.task`, never per render, never in a batch. It's called only
for (a) an explicit refresh of one row or one repo, and (b) opening a tree's detail. When it says
MERGED for a branch git can't prove (a squash with conflict edits), it pins `landed = .pr(n)` for
that tip. `CompactPRCache` is deleted. Its glyph becomes the shared badge, and `changedFiles` moves to
the tooltip if gh has been asked.

## 3b. The hover card

Resting on a badge opens a floating card that lists the work behind the number. It replaces the
badge's tooltip. The row's own tooltip (title, tree, model) stays on the rest of the row.

```
 ┌ frog manager ─────────────────────────── 12 landed · 37 ahead ┐
 │ LANDED                                                        │
 │ subagent visibility v2          [Merged] ecto/frog@b36d033    │
 │                                              +1751  −378      │
 │ worktree ux                     [Merged] ecto/frog@ef41cd7    │
 │                                               +653    −1      │
 │ engine: never persist native→…  [Merged] ecto/frog#97         │
 │                                               +751   −78      │
 │ … 9 more                                                      │
 │ NOT LANDED                                                    │
 │ accounts ux spec v3   frog/accounts-ux-spec   ↑17  +1241  −0  │
 │ delegation pipeline v5 …                                      │
 │ ───────────────────────────────────────────────────────────── │
 │ Show in Workers                                   Refresh  ⌘R │
 └───────────────────────────────────────────────────────────────┘
```

**Group card** (manager, done fold, repo header). The rows come from all the children, deduped by
tree, in two sections:
- **Landed**, newest merge first, at most 8 rows, then "… N more" (which opens Workers filtered to
  that owner). Each row shows the title, a **Merged** capsule, then `ecto/frog#97` for a PR merge or
  `ecto/frog@b36d033` for a local merge (GitHub's own reference forms), then `+N −M` in green and
  red. The capsule is **green, not GitHub's purple**: in this sidebar purple already means "ahead",
  and one color keeps one meaning. The child's session title
  sits under it in tertiary when it differs from the PR title.
- **Not landed** (only when ahead > 0), most ahead first, at most 5 rows: the session title, the
  branch chip, `↑N`, and `+N −M` against base. A row in trouble shows its amber reason
  ("rebasing · 2 conflicts") in place of the diffstat.
- A header with the group's name and the same numbers as its badge, so the card never disagrees
  with the row.

**Session card** (any session row with a badge). The same two sections, for one tree:
- **Landed**: every merge that brought this branch into base. There can be more than one. A branch
  merged, then worked on and merged again, shows two rows.
- **Not landed**: up to 5 of the branch's own commits (`fa29b9a notes: rebase onto the fixed main`),
  newest first, with "… N more", and a footer `+13 −0 · 1 file vs origin/main`. It adds
  `● 19 uncommitted` when the dot is on.
- An empty section isn't drawn. A landed leaf with nothing new shows only Landed.

**Click-through.** A PR row opens `https://github.com/<owner>/<repo>/pull/<N>`. A local-merge row
opens `…/commit/<sha>`. A not-landed row opens the branch's compare page,
`…/compare/<base>...<branch>`, but only when the branch has an upstream on that remote. Without
one, the row isn't a link and shows the sha (its menu has "Copy sha"). `<owner>/<repo>` is parsed
from `remote.<origin>.url` (`git@github.com:ecto/frog.git` → `ecto/frog`, and https too). A remote
that isn't GitHub gets no links. Opening a link doesn't call gh or any API. ⌥-click on a row opens
its session instead of the browser.

### Where the card's data comes from (no engine merge log exists)

The card has its own item type, `LandedItem { mergeSha, tipSha, title, pr: Int?, slug, added,
removed, at, tree }`, in `GitIndex`. It's built in two tiers.

| Tier | When | What | Cost |
|---|---|---|---|
| **Merge index** (eager, cheap) | the repo batch, when the base ref moved | `git log <base> --first-parent --merges -n 200 --format='%H %P%x09%s%x09%b'`. For each merge: `^2`, the PR number and title parsed from `Merge pull request #N from owner/branch` + the first body line, or the branch from `Merge (remote-tracking )?branch '<x>'`. Map `^2` to the tree whose branch tip it is (or contains, for squash/cherry matches from the batch). | ~17 ms per base move, per repo |
| **Diffstats** (lazy) | **the first hover** of a card that shows an item with no cached stat | `git diff --shortstat M^1...M^2` for a merge, `git show --shortstat <c>` for a squash commit, `git diff --shortstat <base>...<tip>` for not-landed rows. Only for the ≤ 13 rows the card shows, in parallel. | ~40 ms each, cached **forever** by sha (a merge's stat can't change). A not-landed stat is keyed by (tip, base). |
| **Titles** for local merges | from the index | the owning session's title, else the branch name | none |
| gh | **never** for the card | — | — |

So the card opens right away with titles and Merged capsules. Missing `+N −M` cells show a
placeholder dash and fill in within ~100 ms the first time. After that the card is entirely
cached. Nothing is prefetched for rows that are visible but not hovered. Merges older than the
200-merge window list from the `tornDown.landed` record (§4). It gains `{mergeSha, pr, added,
removed}`, so a torn-down tree's row stays exact.

### Lifecycle (macOS conventions)

| Event | Behavior |
|---|---|
| Pointer rests on the badge **500 ms** (the system tooltip delay) | The card opens as a transient popover, anchored below the badge, arrow pointing at it. It's placed to the side away from the row, so the row stays readable. Passing over a badge without resting opens nothing. |
| Pointer moves from the badge to the card | It stays open. A **300 ms grace** covers the gap, and a triangle-shaped safe zone from the pointer to the card's near edge keeps a diagonal move from closing it (the menu-submenu rule). |
| Pointer leaves both | It closes after 250 ms, with a 120 ms fade. Coming back during the fade reopens it with no delay. |
| Another badge is rested on while a card is open | The card **moves** to it with no delay (the warm state, like tooltips), until 1 s passes with no badge under the pointer. |
| **Click** the badge | Pins the card: it becomes a semitransient popover that takes key focus. It closes on Esc, a click outside, or another click on the badge. Hover cards never take focus, so typing in the composer is never interrupted. |
| Keyboard: the sidebar has focus on a row | **Space** opens the row's card pinned (the Quick Look convention). ↑/↓ moves through the card's rows, **Return** opens the focused link, **⌘C** copies its URL or sha, ⌥Return opens the session, **Esc** closes it and returns focus to the row. |
| Sidebar scrolls, window resigns key, the row disappears (scope change, collapse), or the drag starts | It closes at once. |
| Data changes while it's open (a ref event) | The rows update in place. The card doesn't jump, and a moved row keeps the focus ring. |
| VoiceOver | The badge's label is "37 commits ahead, 12 landed", with the action "Show landed work" (= pin). Each card row is a link with the label "subagent visibility v2, merged as b36d033, 1751 added, 378 removed". |
| Reduce Motion | No fade. |

The badge click used to drill into Workers (§4). Pinning wins that click, and **Show in Workers**
moves to the card's footer (and stays in the row menu). Refresh (⌘R while the card is pinned) is the
same Refresh as in §3, and it's the only network action reachable from the card.

## 4. Integration with the Workers scope (worktree-ux §3)

- **One index, two projections.** Workers rows (one per tree) and session rows (one per session)
  both read `GitIndex`. Workers shows the full meta: `↑3 ↓12 ●2`, the branch chip (amber when
  diverged), the owner glyph and the lock-derived state. Session rows show only the summary badge.
- **One "ahead".** It's against `base_ref` from the manifest, or the `worktreeBase` rule until the
  manifest exists. This fixes F12 for the sidebar now. ListSessions/SessionStatus switch to the same
  definition when the manifest lands.
- **One "merged".** The row's `⇡` and Workers' **merged** state dot use the same test (ancestor, or
  cherry, or a pinned PR). The "Clean up N merged" button and a manager's `⇡ N` count the same trees.
- **The card drills in.** **Show in Workers** in the hover card's footer (and in the row menu) switches
  the scope to Workers with that tree scrolled to and expanded (path, base, lock pid, parked refs). A
  group card's "… N more" opens Workers filtered to that owner. Clicking the badge itself pins the card
  (§3b).
- **After teardown** (worktree-ux §4) the session is archived with `tornDown { at, parked, branch }`.
  This spec adds `landed: Bool` to that record, so a manager's `⇡ 12` doesn't drop when its merged
  trees are auto-removed after 24 h. Archived-by-hand sessions don't count. Torn-down ones do.
- **Lock data used:** liveness (the try-lock probe, `worktreeOwner`) and the owner session, to
  attribute a tree to the right row. The lock file adds nothing more, and it doesn't need to, because
  branch, ahead and dirty are cheaper from git than from a file the engine would have to keep current.

## 5. Failure modes

| # | Case | Badge | Why |
|---|---|---|---|
| F1 | Not a git repo, or no `/usr/bin/git` | none | nothing to say |
| F2 | **Main checkout** (managers in `~/Developer/frog`, `chief`, `okc` with 15–40 dirty) | none for dirty. `⎇ N` only if HEAD is a non-base branch (`home` on `adr-006…`). | The main checkout's dirty files are shared by every session there, so they aren't this row's work. Ahead against itself is 0. |
| F3 | Several sessions, one tree (`delegation pipeline v4/v5`) | on the fold head only, deduped in aggregates | it's one body of work |
| F4 | Session cwd is a subfolder of a tree (`…/magical-jennings-f36530/quad00`) | the tree's badge | the tree comes from `worktree::linked`, which walks up |
| F5 | Tree outside `.frog/worktrees` (`okc/.worktrees/muse_*`, `.claude/worktrees`) | normal badge | `linked()` replaces the path-substring test |
| F6 | **Detached HEAD** | the branch glyph in tertiary, `⎇ N` from a per-tree `rev-list base..HEAD`. Tooltip "detached at 9e02a1c". | `for-each-ref` doesn't cover detached heads, so this is the one per-tree count |
| F7 | **Mid-rebase / merge / cherry-pick**, or conflicts | amber branch glyph, counts frozen at the last good value, the reason in the tooltip | HEAD moves during a rebase, and live counts would jitter. The state comes from stat-ing the git dir, with no subprocess. |
| F8 | Base ref missing (no remote, no `main`/`master`) | `⎇` without a number, tooltip "no base to compare" | don't guess |
| F9 | `origin/main` is stale (nobody fetched) | landed shows late | Merges done in this org's main checkout update the local refs already. A remote PR merge needs Refresh. The app never fetches by itself. |
| F10 | Squash merge, patch-equivalent | `⇡` (via `git cherry`) | cached per tip |
| F11 | Squash merge with edits (not patch-equal) | stays `⎇ N` until a Refresh asks gh, then `⇡` pinned | the only case that needs GitHub |
| F12 | Merged, then more commits (`subagent-visibility`) | `⎇ 2` | ahead wins (§1) |
| F13 | Tree removed by hand or torn down | none on the row. Workers shows **missing**, or the session is archived `tornDown`. | worktree-ux F9 |
| F14 | Huge tree, slow `status` | dirty is unknown (no dot). After 2 s the status is killed, and that tree backs off for 10 min. | a badge never blocks |
| F15 | Repo batch fails (corrupt packed-refs, a lock held by git gc) | the last good values, with no flicker to "none" | retry on the next ref event |
| F16 | Old git (< 2.41, no `%(ahead-behind)`) | normal badge | falls back to one `rev-list --left-right --count` per tree, still only on ref events |
| F17 | Card: no GitHub remote, or the branch was never pushed | rows show the sha, not a link | no guessed URLs |
| F18 | Card: a merge older than the 200-merge window, tree still present | the row comes from `tornDown`, or from a one-off `git log --merges --ancestry-path <tip>..<base>` on first hover | rare, lazy |
| F19 | Card: shortstat slow (a huge merge) | the dash stays. The stat is killed at 2 s and retried on the next hover. | the card never waits |
| F20 | Card: the merge was an octopus or `-s ours` | `^2..^N` are each mapped. `-s ours` shows `+0 −0`. | honest numbers |

## Build order (when approved)

1. `GitIndex` + `GitBadge` in FrogKit. The tree comes from `linked()`, the base from the `worktreeBase`
   rule, and the repo batch runs on FSEvents. Tests: aggregation dedupe, ahead-wins, settled-only dirty,
   scope-invariant aggregates.
2. The badge in `TreeRow` (all weights), on the done fold, and on branch folds.
3. Replace `CompactPRCache` and `SessionMetaCache` in the compact rows and the repo headers. gh moves
   to the Refresh menu.
4. Trouble states (F7) and detached heads (F6).
5. The hover card: the merge index in the repo batch, lazy diffstats, the popover lifecycle (hover,
   pin, Space), and GitHub links from the remote URL.
6. When the Workers scope builds: "Show in Workers" drills in, and `tornDown.landed` is added.
7. ListSessions/SessionStatus `ahead` against base (goes with the manifest, worktree-ux build step 1).

## Open questions for Cam

1. A row with no git: **nothing** (recommended; our dots already mean state), or Claude's plain dot?
2. Should the landed count be **all-time** (it grows, like Claude's), or **today only** (it resets daily
   and reads as "landed today")? Recommend all-time on managers, and today in the done fold.
3. Hide the dirty dot while a session runs (recommended), or always show it?
4. Should the manager aggregate include the manager's own tree? (Recommend yes. It only matters for
   managers that run in a worktree.)
5. Clicking a badge: **pin the card** (recommended; macOS popovers open on click), or keep the first
   draft's jump straight into Workers?
6. Should a local-merge row link to the **merge commit** (recommended; it always exists on GitHub once
   pushed), or to the branch's compare page (which breaks once the branch is deleted)?

## Implementation

The questions above took their recommended answers, with one exception. Q2's "today only in the
done fold" was dropped: in the Today scope the fold is "N earlier", which holds nothing from today.
So every landed count is all-time.

| Piece | Where |
|---|---|
| The model: display rules, tree-deduped sums, fold members, parsing, GitHub links | `apps/FrogKit/Core/GitBadge.swift`, tests `GitBadgeTests` |
| The index: tree resolution from `.git`, the per-repo batch on FSEvents, status on settle and on first sight (once a minute), the merge index, lazy diffstats and commits, Refresh (fetch + gh) | `apps/macos/Frog/Model/GitIndex.swift`, test `GitIndexTests` (a real repo: ahead/behind, merged, fresh, dirty, the card, the ref watcher) |
| Hooks | `Library.refresh` → `listingChanged`, `Library.live` → `liveChanged` |
| The badge, the tree's sums, the hover card and its controller (an `NSPanel` that takes key only when pinned) | `apps/macos/Frog/Views/GitBadges.swift` |
| Placement | `TreeRow` (all weights), done folds, compact rows, project headers (compact and regular), the row menu's "Refresh Git" |
| Removed | `CompactPRCache` (gh per row), `SessionMetaCache` |
| Snapshots | `SidebarSnapshotTests.testRenderGitBadges` → `sidebar-git-{today,live}-{light,dark}.png`, `git-card-{group,session}-{light,dark}.png` |

Not built, and why:
- **Space on a focused row** opens nothing, because sidebar rows have no keyboard focus today. The
  keyboard works once the card is pinned by a click: ↑/↓, Return, ⌥Return, ⌘C, ⌘R, Esc.
  VoiceOver's "Show landed work" action also pins the card.
- **The safe triangle.** Only the 300 ms grace is there. The card opens right under the badge, so
  the pointer crosses the gap well within it.
- **"Show in Workers"** and `tornDown.landed`. The Workers scope and teardown (worktree-ux §3–4)
  aren't built yet. The card footer has Refresh.
- **ListSessions/SessionStatus `ahead` against base.** It goes in with the worktree-ux manifest.
- **iOS rows.**
- **Hover-card placement** is below the badge, or above it near the screen's bottom edge. The card
  doesn't move away from the row horizontally.
