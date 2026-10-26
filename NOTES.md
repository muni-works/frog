# sidebar git badges — notes

Branch frog/sidebar-git, base 77b5f8c (main). Worktree /Users/cam/Developer/frog/.frog/worktrees/sidebar-git.
DESIGN-ONLY: Cam judges before build. Commit per piece (`git commit -s`), never push. Source edits via the
Edit tool only. (Previous branch's notes — subagent visibility — live in git history at 77b5f8c:NOTES.md.)

## Goal (Cam: per-row git badges in the sidebar, Claude's style)
Reference: Claude's sidebar — each row's right side carries small badges: a branch glyph (purple) + commits
ahead, a merged glyph (green) + merged-PR count, a plain dot for sessions with no git activity.
Group rows aggregate (sum of children).

## Deliverables
- docs/design/sidebar-git/README.md: anatomy, per-row-type placement, data flow, workers-scope integration,
  failure modes, cheap-data-source spec + refresh story
- docs/design/sidebar-git/mockup.html: light + dark, realistic tree

## Constraints
- integrate with the merged worktree-ux spec (docs/design/worktree-ux/README.md), don't duplicate
- data sources cheap first: lock/manifest → engine merge events → gh only on explicit open/refresh

## Survey (verified at 77b5f8c)
- Two sidebar row types. Org grouping (default) = `TreeRow` (AttentionRows.swift): manager / live worker /
  settled weights, trailing = pane number · age (settled) · state glyph. **No git info at all today.**
  Project/Date grouping = `CompactSessionRow` (Sidebar.swift:1109): PR glyph (merge green / open purple) +
  `changedFiles`, then `3↑` (SessionMetaCache), age, glyph.
- `CompactPRCache` (Sidebar.swift:1330): **per row** `git branch --show-current` + `gh pr view <branch>` in a
  row `.task`, 60 s throttle, re-runs each time a row reappears. This is the gh-per-render spam to remove.
- `SessionMetaCache` (SessionMeta.swift): `rev-list --count main..HEAD` per worktree, 60 s; `isWorktree` is
  a path-substring test (`/.frog/worktrees/`, `/.claude/worktrees/`) so okc's `.worktrees/` trees miss.
- `Git.quick` (ListSessions/SessionStatus): ahead vs **upstream** → nil for unpushed `frog/*`. (worktree-ux F12.)
- worktree-ux manifest `frog-worktree.json`, header `worktree`, `frog --worktrees --json`, Workers scope:
  **none built yet**. Lock file today holds only `"<session> <pid>"` (worktree.rs). Base = `worktreeBase`
  rule (origin/HEAD → origin/main|master → current).
- Merge events: **the engine logs none.** Pond's GitHub read (pond/github.rs) is OPEN PRs only (review,
  failing, ready). So "merged" must come from local git (branch ⊂ base, or `git cherry` patch-equivalent).
  Merges here are mostly local `git merge origin/frog/x` + push, not GitHub PRs — local git sees them.
- Cost (frog repo, 103 frog/* branches, 115 worktrees, git 2.54): `for-each-ref --format=%(ahead-behind:origin/main)`
  all branches **16 ms**; `for-each-ref --merged origin/main` **11 ms**; `worktree list --porcelain` 25 ms;
  per-tree rev-list+status+cherry 65 ms. → batch per repo, not per tree.
- Real cases in the live list: shared trees (delegation pipeline v4+v5, accounts ux spec v1+v3), managers in
  main checkouts with dirty 15–40 (shared, not theirs), a session in a worktree subfolder (quad00),
  subagent-visibility merged earlier and now 2 ahead again, non-frog branch names (muse_*), a main checkout
  on a feature branch (home: adr-006…).

## Decisions (design, pending Cam)
- badge = branch glyph (purple) + ahead · dirty dot on the glyph (settled only) · merge glyph (green; N on
  aggregates only) · amber on trouble. Ahead wins over landed. No git → nothing (no Claude dot).
- aggregates dedupe by tree, are scope-invariant, trouble/dirty only from settled children.
- data: repo batch (2× for-each-ref) on FSEvents ref changes; status per tree on settle; cherry cached by
  sha; gh only on Refresh / Workers detail. CompactPRCache + SessionMetaCache go away.
- badge click → Workers scope, tree expanded. tornDown gains `landed`.

## Round 2 (relayed by frog manager): hover cards
- Brief assumed "merge events + diffstats the engine already logs". **They don't exist** (checked: no
  merge logging; the only numstat is checkpoint.rs:205 for race diffs). Spec sources them from git instead:
  first-parent merge index (17 ms/200 merges, parse `Merge pull request #N` + body title, or
  `Merge … branch '<x>'`), lazy `diff --shortstat M^1...M^2` (~40 ms) on first hover, cached by sha forever.
- Cards: group (Landed ≤8 newest + Not landed ≤5) and session (its merges + its own commits). Links from
  remote URL: /pull/N, /commit/sha, /compare (only if pushed). No gh for the card.
- Lifecycle: 500 ms rest, 300 ms grace + safe triangle, warm move between badges, click pins (takes focus),
  Space on a focused row = pinned (Quick Look), ↑↓ Return ⌘C Esc; closes on scroll/resign/row gone.
- Changed: badge click now pins the card; "Show in Workers" moves to the card footer + row menu.
- Merged capsule green, not GitHub purple (purple = ahead here).

## Progress
- 6badefc checkpoint 0 · fac2fb0 survey · 048e656 spec · 4edc4de mockup · 47d0463 hover-card spec ·
  hover-card mockup (next commit)
