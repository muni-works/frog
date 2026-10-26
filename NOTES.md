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

## Survey

## Decisions

## Progress
- checkpoint 0
