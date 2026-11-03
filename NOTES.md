# perf-audit — notes

Branch `frog/perf-audit`, worktree `/Users/cam/Developer/frog/.frog/worktrees/perf-audit`, tracks
origin/main. Measurement only — **no fixes** in this branch. One commit per unit (`git commit -s`),
never push. Edit tool only for source.

Scope: everything that burns CPU in a typical session **except** `SessionDirectoryWatcher` /
`Library.refresh` (39% idle CPU, already owned by another worker). Covered here: transcript
rendering during streaming, sidebar list rebuild, `GitIndex` FSEvents, `DiagramView` /
`TimelineView` ticks, changes strip / `TurnFlow` footer, composer, and whatever else the samples
show.

## Plan
1. This checkpoint.
2. Build the app from this worktree (`FROG_PREBUILT_DIR=/private/tmp/be-prebuilt2`,
   `-derivedDataPath /private/tmp/pa-dd`, `CODE_SIGN_IDENTITY="-"`), launch with a scratch HOME.
3. `sample <pid> 10` idle; 10–15 s during a streaming turn; during sidebar interactions and in a
   git-heavy folder.
4. Group the heaviest stacks by component, rank, write the top 10 below.
5. `cargo build -p frog -p frog-engine` no-op check, commit the notes.

## Raw samples
(filled in below as they are taken)

## Ranked CPU costs
(filled in below)

## Result
(filled in below)
