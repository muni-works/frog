# Turning on the merge queue

Why: main is protected by the ruleset **"main: CI green on an up-to-date branch"**, which
requires `check (ubuntu-latest)`, `check (macos-26)`, `macos-app` and `check-dco`. But its
"require branches to be up to date" setting (`strict_required_status_checks_policy`) is
**off**. So each PR is tested only against the main it branched from. On 2026-11-14 three PRs
that were each green broke two engine tests once all three had merged. A merge queue tests
each PR on top of current main plus the PRs queued ahead of it, and merges exactly the commit
it tested.

The workflows are ready: `ci.yml` and `dco.yml` run on `merge_group`, `macos-app` runs for
it (a skipped required job would count as passing), and pushes to the queue's
`gh-readonly-queue/**` branches don't start a second run.

## Settings to change (a repo admin, in the GitHub UI)

**Settings → Rules → Rulesets → "main: CI green on an up-to-date branch" → Edit**

1. Under *Branch rules*, tick **Require merge queue** and set:

   | setting | value | why |
   |---|---|---|
   | Merge method | **Merge commit** | What main uses today ("Merge pull request #…"). It also keeps every commit's `Signed-off-by`. A squash commit written by GitHub can lose it and fail `check-dco` |
   | Build concurrency | 5 | How many queued groups CI runs at once. Each runs the `macos-26` jobs |
   | Minimum group size | 1 | Don't wait for company |
   | Maximum group size | 5 | A failing group is split to find the PR that broke it |
   | Wait time to meet minimum group size | 5 minutes | Ignored when the minimum is 1 |
   | Require all queue entries to pass required checks | **on** | The point of the queue |
   | Status check timeout | 60 minutes | `macos-app` takes about 25 minutes, and its job timeout is 60 |

2. Leave **Require status checks to pass** on, with the same four checks. Leave **Require
   branches to be up to date before merging** off: the queue does that job without making
   every author merge main by hand.

3. Save.

Nothing else changes.

## What changes day to day

- The PR's merge button becomes **Merge when ready**, or `gh pr merge <n> --merge --auto` from
  the CLI. Org admins can still bypass the ruleset (it lists them as bypass actors), and that
  includes skipping the queue.
- A PR that breaks main only in combination with the ones ahead of it is removed from the
  queue with the failing run linked. The others merge.
- CI minutes: every merged PR runs the required jobs twice (on the PR, then in the queue).

## To turn it off

Untick **Require merge queue** in the same ruleset. The `merge_group` triggers do nothing
without a queue.
