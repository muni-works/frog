# Open a PR when the work is done: the setting, and `ask` only

Status: `ask` built 2026-11-13; `auto` built 2026-11-15 (see "`auto`, as decided" below).

## The gap

The machinery already existed and was manual:

- `ComposerView+Tray.swift` `case "open_pr"` submits "Push this branch and open a pull request
  with `gh pr create`: draft a clear title and body from our changes."
- `apps/web/src/composer.ts` `derive` sets `gitAction = 'open_pr'` when `ahead > 0` and no PR is
  bound — the state machine already derives "this needs a PR" from the branch alone.

So the only question was **who triggers it**. This adds a setting for that, and the predicate
that decides when the answer may be "yes".

## The setting

```toml
[git]
open_pr_when_done = "off" | "ask" | "auto"   # default: "ask"
```

- **`off`** — today's silent behaviour. Nothing is offered; the branch is yours to push.
- **`ask`** — the git line's existing **Open PR** action, when the work is done. It is the same
  control in the same place; it is drawn as the line's one emphatic chip (accent fill, semibold,
  a tooltip) instead of a plain one. No new affordance.
- **`auto`** — the engine opens a **draft** PR itself when the work is done (below). The composer
  treats it as `ask` (`Status.open_pr_when_done` says `"ask"`), so the Open PR chip is the
  fallback when the engine declined or failed.

Parsing is strict: an unknown word is an error, never a guess.

**Nothing is turned on in anyone's config.** `ask` is the default in code; `~/.config/frog/config.toml`
is untouched.

## The predicate

`OpenPR.shouldOpenPR` (`apps/FrogKit/Core/OpenPR.swift`) is pure — no git, no session store, no
filesystem — and takes an `Input` of facts the composer already knows:

```swift
static func shouldOpenPR(_ s: Input) -> Bool {
    s.worktree      // started with worktree: true: its own branch
        && s.ahead > 0  // commits its base doesn't have
        && !s.hasPR     // no PR bound yet
        && !s.isManager // not depth 0 with children
        && !s.readOnly  // not a read-only child
        && !s.optedOut  // no `open-pr: off` in the first prompt
}
```

The manager exclusion is the load-bearing one. Managers and their workers produce a branch per
session; opening a PR for each would be dozens a day into one repo — ~15 in a single night.

The per-session opt-out is a line in the first prompt, `open-pr: off` (or `never`), so it lives
in the session's log: visible, greppable, and still true after a resume.

The web reducer (`apps/web/src/composer.ts`) carries the same predicate as `shouldOpenPr` over
the same `OpenPrInput`; the two are kept in step by hand, as the rest of the reducer is.

## What `ask` changes, exactly

- `ComposerModel.derive` drops `gitAction = .open_pr` entirely when the setting is `off`.
- It reports `Derived.openPR = true` when the action is `open_pr` **and** the predicate holds.
  The action is never hidden by the predicate: a manager can still open a PR by hand, it just
  isn't urged to.
- The Mac's `TrayChip` and the web's `.cz-act--go` render that as the accent chip.

## Verification

`apps/macos/FrogTests/OpenPRTests.swift` tests the predicate as a pure function. No test shells
out to git.

- `testAFinishedWorktreeSessionWithCommitsOpensAPR`
- `testEveryReasonToSayNoIsEnoughOnItsOwn` — worktree, ahead, hasPR, readOnly, optedOut
- `testAManagerNeverOpensAPR` — **fails if the manager exclusion is removed**
- `testTheOptOutRemovesTheOffer` — **fails if the opt-out is removed**
- `testTheMarkerIsReadOffTheFirstPrompt`
- `testTheSettingGatesTheOfferAndAutoIsAsk`

## `auto`, as decided (Cam, 2026-11-15)

- **A standing grant** for exactly two commands, run by the engine (not the model) when a turn
  completes with nothing queued behind it: `git push --set-upstream origin
  refs/heads/<branch>:refs/heads/<branch>` (no force, its own branch only, never the base) and
  `gh pr create --draft --fill --base <default> --head <branch>`. The PR binds to the session.
- **Draft** PRs.
- **Workers are skipped**: `--worker`, or any session with a parent session. Managers (a
  session that started sessions, or has engine-owned children), read-only sessions and
  `open-pr: off` stay excluded, as for `ask`.

Defaults this build picked where nothing was decided; each is one place in `open_pr.rs` or
`Agent::auto_open_pr` to change:

- **Base**: the remote's default branch (`origin/HEAD`, else `origin/main` / `origin/master`).
  On the default branch itself, detached, or with no `origin`: nothing happens.
- **Failure**: one warning notice with the reason and "Open PR is offered instead"; no retry
  for the same head commit. A new commit gets one new attempt.
- **Network policy**: a restricted `[sandbox] network` or an enforced egress list rules the
  push out; one notice, and the chip stays.
- **Rate**: no ceiling beyond one PR per session and the exclusions above.

## What autofix (and anything left of `auto`) still needs decided

The list as it stood before `auto` was built; 1 and 3 are answered above, 2 and 5 have defaults:

1. **Who is excluded.** `--worker` sessions (started by an agent) are currently *not* excluded by
   the predicate, only managers are. A manager's worker with its own worktree and no children
   would open a PR. Is "started by an agent" its own exclusion, or is the manager rule enough?
2. **The base.** `ahead > 0` is measured against whatever upstream the tree has. Should `auto`
   require the branch to be ahead of the *remote default branch* specifically, and refuse when
   the base moved?
3. **Draft or ready.** `auto` should almost certainly open a **draft** PR, since nobody has read
   the diff. That is a product call, not a technical one.
4. **Rate.** A per-repo ceiling (say N open frog PRs, or N per day) is the real protection once
   `auto` is on, independent of the predicate. What N?
5. **Failure.** `gh` not authed, push rejected, branch protected: does `auto` retry, card, or
   drop the offer silently? `ask` already has answers here (the error slot's actions).
6. **Autofix** additionally needs: which failures it may act on, a round cap, a spend cap, and
   what it does when it can't fix (escalate to whom). `docs/design/pr-lifecycle.md` §5 sketches
   this; none of it is decided.

