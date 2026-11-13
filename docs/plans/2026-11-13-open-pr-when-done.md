# Open a PR when the work is done: the setting, and `ask` only

Status: built 2026-11-13, **first half only**. `auto` is parsed and deliberately inert.

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
- **`auto`** — **parsed, documented, not wired.** It reads as `ask` in `config::OpenPr::effective`,
  the engine reports `"ask"` in `Status.open_pr_when_done`, and it says so once at startup:
  `[git] open_pr_when_done = "auto" is not implemented yet: it behaves as "ask"`. The single line
  to change when the unattended path is built is `OpenPr::effective`.

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

## What `auto` and autofix still need decided

Not built, on purpose. Before either can be written:

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

Until then `auto` is one enum case, one doc comment, and one line in `effective`.
