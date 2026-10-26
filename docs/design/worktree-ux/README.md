# Worktree UX — design

Status: **design for review** (Cam). No code yet. Base: `115b40d` (main).
Mockup: [mockup.html](mockup.html) (the workers scope in the sidebar, and the teardown prompt).

Frog runs many sessions at once, each in its own git worktree. That works today when nothing goes
wrong. This spec covers the cases where something does: a session restarts, a name gets reused,
an engine comes back up in the wrong folder, a finished worktree is left behind. Five areas. Each
one gives what exists (checked in source), what's new, and the design.

The rule over all of it: **frog never quietly works in a tree it can't name.** If frog can't say
"this session, this tree, this branch", it refuses and says which names it's missing.

---

## 0. Current state (survey, verified at 115b40d)

| Piece | Where | What it does today |
|---|---|---|
| StartSession | `SessionBroker.swift:360` → `start` `:1474` | `worktree` defaults to **false**. With `worktree:true`, `makeWorktree` runs. Without it, `checkWorkerFolder` runs. Result: `{id, name, cwd, branch, base}`. The parent is recorded with `Library.setParent`. |
| makeWorktree | `SessionBroker.swift:1187` | `slug(title)` (≤40 chars). Creates `<repo>/.frog/worktrees/<slug>` on branch `frog/<slug>`, from `worktreeBase`. On a collision it **renumbers without saying so** (`<slug>-2`, `-3`, …). Adds `/.frog/worktrees/` to `info/exclude`. |
| worktreeBase | `SessionBroker.swift:1096` | Tries `origin/HEAD`, then `origin/main\|master`, then the current branch (only when there's no remote). |
| checkWorkerFolder | `SessionBroker.swift:1166` | Refuses the main checkout (and names up to 3 trees to reuse) unless `allow_main_checkout`. Refuses a worktree whose engine lock is held. **Reuses any free worktree as-is**, without checking whose it was. |
| Engine worktree lock | `worktree.rs`, taken at `engine.rs:521` | `flock(LOCK_EX\|LOCK_NB)` on `.git/worktrees/<name>/frog-engine.lock`. The file holds `"<session> <pid>"`. It's taken on the **process cwd** (`opts.cwd`). The same session waits up to 5 s; any other session is refused by name. The lock is released on drop (`engine.rs:941`) or when the process dies. Subagents and the main checkout never lock. |
| Session log lock | `session.rs:181` | A separate flock on the session's JSONL: one writer per session. `in_use` / `wait_free` probe it. |
| App lock probe | `SessionBroker.worktreeOwner` `:1151` | Try-lock and release. A held lock means its holder is alive (flock dies with the process). |
| Resume | `SessionBroker.conversation(for:)` `:990` | `Conversation(folder: info.folder)`. `info.cwd` is the **header** cwd (`main.rs:964`), not the last `cd` / `UseFolder` that `SessionStatus` reports (`:1416`). |
| Listing | `Library.swift:66` | Sessions whose cwd no longer exists are **dropped from the sidebar**. The log stays on disk. |
| Branch info | `Git.quick` (`Git.swift:64`); `SessionMeta` | ListSessions/SessionStatus `ahead` counts against the **upstream**, so it's nil for unpushed `frog/*` branches. The sidebar's `3↑` counts `rev-list base..HEAD`. These are two different "ahead" numbers. |
| Folding | `SessionFolds.swift` | Sessions in the same worktree folder (or forks) fold into one row. |
| Sidebar scope | `Sidebar.swift:43`, `AttentionTree.Scope` | `live · today · all`, stored in `@AppStorage("sidebarScope")`. |
| Teardown | — | **None.** `ArchiveSession` only hides the session. The only worktree removal anywhere is race attempts (`checkpoint.rs:213`: `worktree remove --force` + `prune`). |
| Sandbox | `bash.rs:277`, `git_dirs` `:608`, `seatbelt` `:715` | See §5. |
| Write/Edit guard | `engine.rs:4965` | A write outside the session root (e.g. into the main checkout) asks for approval, and is denied headless. |

Two facts set the design:
1. **The silent renumber is the collision bug.** A restarted task that calls StartSession with the same
   title gets a fresh, empty `<slug>-2`. Its real tree, holding the dirty work, sits unused. Nothing
   in the result says so.
2. **The lock is taken on the process cwd.** An engine resumed in the main checkout (because the
   header cwd is the main checkout and the session later `cd`'d into its worktree) finds no linked
   worktree, takes no lock, and refuses nothing. This is most likely how #107's second incident
   happened.

---

## 1. Auto worktree + branch for spawned sessions

**Exists.** `worktree:true` makes `.frog/worktrees/<slug>` on `frog/<slug>` from the remote default branch.
Without it, the main checkout is refused, so a worker can't land there by accident. In practice every
worker ends up in a worktree. It isn't fully automatic, though: the caller has to pick.

**New: one record of the tree, written at birth.**
- **Manifest** `.git/worktrees/<name>/frog-worktree.json`, next to the lock (in the tree's private git
  dir, so it goes away when the tree does):
  `{ session, owner, title, branch, base_ref, base_sha, created, repo }`. `owner` is the spawning
  session (the parent).
- **Session header** gets `worktree: { path, branch }`. This is the session's recorded tree, and #107
  checks against it (§2b).
- **Resume uses the recorded tree**, not the header cwd. `conversation(for:)` and `Workspace.open` start
  the engine in `header.worktree.path` when it's set.
- **`worktree` defaults to `"auto"`.** When the cwd resolves to a main checkout that owns
  `.frog/worktrees`, auto means a new worktree. When it's a free worktree, it goes through the collision
  rules (§2). Otherwise it uses the folder as-is. Explicit `true` / `false` keep today's meaning.
- **One "ahead".** Count against `base_ref` from the manifest, as SessionMeta does, everywhere
  (ListSessions, SessionStatus, the sidebar). Add `behind` (base moved on) so "diverged" can be shown.

---

## 2. Named refusal on collision

### 2a. Creation (app side)

**Exists.** A silent renumber in `makeWorktree`, and silent reuse in `checkWorkerFolder`.

**New.** StartSession takes `on_collision: "refuse" | "reuse" | "new" | "replace"`, default **refuse**.
A collision is any of these: the dir `.frog/worktrees/<slug>` exists, the branch `frog/<slug>` exists,
or a free worktree passed as `cwd` whose manifest names a different session.

The refusal names everything, and gives each way out as an exact parameter:

```
worktree "feat-x" already exists:
  path    /Users/cam/Developer/frog/.frog/worktrees/feat-x
  branch  frog/feat-x  (3 ahead of origin/main, 12 behind, 2 dirty)
  owner   session local_8f7b… "feat x" (started by frog), engine: not running, last active 2h ago
Pick one:
  on_collision: "reuse"    continue in this tree (the work above stays; this session becomes its owner)
  on_collision: "new"      a fresh tree "feat-x-2" from origin/main (the old one is left as it is)
  on_collision: "replace"  park the 2 dirty files (refs/frog/parked/feat-x/1), remove the tree, recreate it
                           from origin/main; the branch's 3 commits stay on frog/feat-x-old-1
Or resume the owner instead: SendMessage to local_8f7b….
```

- `reuse` with a **live** owner (lock held) is still refused, as it is today. The error names the
  session and pid.
- `replace` is destructive, so it runs through teardown (§4) and gets the same app prompt whenever
  the tree is dirty or holds unmerged commits. It can only be approved in the app. A relay doesn't
  count.
- `new` is the old behavior, now opt-in, and the result says so: `"renamed": "feat-x-2"`.

### 2b. Serving (engine side): #107 is the guard

The creation checks only run when StartSession runs. Both #107 incidents were **restarts**, where
nothing goes back through StartSession. So the engine has to hold the guarantee itself:

- At start and at `-r` resume, the engine compares the top of its process cwd (`worktree::linked`)
  with `header.worktree.path`:
  - **Match:** take the lock (as today) and serve.
  - **Header has a tree, cwd is somewhere else** (the main checkout, a different tree): **refuse to serve**,
    naming both paths, the session and the branch. Read-only is the fallback only if Cam prefers it
    (open question). The app's resume (§1) fixes the cause. #107 catches whatever cause comes next.
  - **The recorded tree is gone:** refuse, and point to the parked ref if one exists ("torn down at …,
    parked as refs/frog/parked/feat-x/1"). Don't fall back to the session root. Today
    `engine.rs:3788` falls back for a cwd deleted mid-session. That's fine for a live session, but
    wrong at resume.
- The lock moves from `opts.cwd` to the **recorded** tree. A mis-rooted engine can then never hold a
  lock it doesn't own, or skip a lock it should hold.

---

## 3. Tree-level visibility: the Workers scope

**Exists.** Branch suffix on rows, `3↑` meta, same-tree folding, ListSessions `fields: branch/ahead/dirty`.
There's no view of the *trees* themselves, so orphans and dead trees can't be seen.

**New: a fourth sidebar scope, `Live · Today · All · Workers`** (same picker, same `sidebarScope`
storage, new case `.workers`). The Workers scope is a list of **trees, not sessions**, grouped by repo:

| Column | Source |
|---|---|
| owner glyph | the manifest's `owner` (the parent session's initial and tint). `you` when you started it. |
| title | the owning session's title (falls back to the dir name) |
| branch chip | `frog/<name>`, mono. Amber when the base has moved more than 20 commits ahead (diverged). |
| ahead / dirty | `↑3 ↓12 ●2` against `base_ref` (§1). `↑` only shows when > 0. |
| state dot | **running** (lock held, turn active) · **waiting** (lock held, needs you) · **idle** (lock held, no turn) · **parked** (no engine, has work) · **merged** (no engine, branch in base, clean) · **orphan** (no frog session or manifest) · **missing** (git has the entry, the dir is gone) |

Hovering or expanding a row shows the path, base ref and sha, the lock holder's pid, the parked refs,
and the sessions folded into the tree. Row actions are Open, Resume, Reveal in Finder, and Tear down…
(§4). The group header has one bulk button, **"Clean up N merged"**.

Data comes from a new `frog --worktrees --json`. It runs `git worktree list --porcelain` per repo
seen in the listing, plus the manifest, a lock probe, `rev-list --left-right --count base...HEAD`, and
`status --porcelain`. It runs off the main thread, at most once a minute per tree (as SessionMeta
does), and right away after a teardown. ListSessions gains a `worktree` field. A `ListWorktrees`
session tool gives managers the same rows.

### Self-cleaning

The flock already tells whether a holder is alive, with no daemon: a lock that can be taken has
no holder. On each refresh, every tree is put in exactly one class:

| Class | Test | Action |
|---|---|---|
| live | lock held | none |
| crashed | lock free, the session's last turn has no `turn_ended` | dot shows "parked", with a **Resume** action. Never auto. |
| parked | lock free, dirty or unmerged commits | none. After 7 days idle the dot gets an amber "stale" badge. |
| merged | lock free, clean, branch reachable from base (or every commit patch-equivalent: `git cherry` shows none `+`, which catches squash merges) | **auto teardown** after 24 h idle: remove the tree and delete the branch. The parked refs stay. The manager gets an informational message. |
| missing | entry in `git worktree list`, dir gone | `git worktree prune` (safe: there's nothing in it). Auto. |
| orphan | tree under `.frog/worktrees/` with no manifest and no session cwd | flagged only. |

Auto actions are limited to trees whose work is already somewhere else: merged into base, or an
empty dir. A tree that holds the only copy of any work is never deleted. It's flagged, and a human
or its owner decides.

---

## 4. Lifecycle teardown: one command

**Exists.** Nothing, apart from race attempts.

**New: an engine op `teardown` and a session tool `TeardownSession`.** The app's "Tear down…" uses the
same op.

```
TeardownSession { id, park: true, remove: true, branch: "keep" | "delete_if_merged" (default) | "delete" }
```

Steps. Each one is idempotent, and the tool result reports each:
1. **Resolve** the tree from the session header and the manifest. Refuse the main checkout, any folder
   that isn't a worktree, and a tree whose manifest names another session (it names that owner).
2. **Stop** the engine (StopSession, drain), then wait up to 10 s for `frog-engine.lock` to come free.
   If it's still held: refuse, naming the pid.
3. **Inspect**: dirty and untracked counts, ahead and behind against base, merged?, pushed?
4. **Park** if dirty. This reuses the checkpoint machinery (`checkpoint.rs`): a private index,
   `add -A`, `write-tree`, and a commit whose parent is HEAD. The commit is pinned at
   **`refs/frog/parked/<name>/<n>`** with the message `parked <branch> from <session> "<title>"`.
   - It's a ref, not `git stash`, because `refs/stash` is **shared by every worktree**. A `stash pop`
     in another tree takes it, which is exactly the #107 stash incident. A named ref can only be
     applied on purpose.
   - Apply it in a fresh tree with `StartSession { …, from_parked: "feat-x/1" }`, which runs
     `git diff <ref>^ <ref> | git apply --3way` (so it works on a newer base). By hand, the same
     command does it. This is the continuity-ux pattern (stash, fresh worktree,
     PR) as one parameter.
5. **Archive** the session *before* removal (the listing drops sessions whose cwd is gone). The archive
   entry gets `tornDown: { at, parked, branch }`, so the row can still be found in All.
6. **Remove**: `git worktree remove` (no `--force`, since it's clean after parking), then `prune`.
7. **Branch**: `delete_if_merged` deletes only when §3's merged test passes. Otherwise it's kept, and
   the result says "kept frog/feat-x (3 unmerged)".

**The app prompt.** This is the only time a person is asked. It comes up for any teardown that would
park, or that would delete a branch holding unmerged commits. It can only be approved in the app
(see the mockup). Choices: **Park & remove** (default) · **Keep tree** (archive only) · **Remove,
discard changes** (red; needs a second click) · **Cancel**. It lists the dirty files, the commits
ahead, and where the parked ref will go. A clean, merged teardown runs without asking.

Triggers: archiving a session that owns a tree offers teardown (a checkbox on the archive, default on
when the tree is merged), a PR merge noticed on refresh (§3 merged → auto), and managers calling
`TeardownSession` when their worker reports done.

---

## 5. Sandbox rules: the enforcement layer (spec of what exists)

`git_dirs(ctx.root)` (`bash.rs:608`) runs `git rev-parse --git-dir --git-common-dir` in the **session
root**, then canonicalizes and dedupes the result. `bash.rs:277` passes it on every sandboxed Bash
call. It's computed from the root, **not** the shell's current dir, so a `cd` into another checkout
can't widen the write set. The seatbelt profile (`bash.rs:759`) is `allow default`, then
`deny file-write*`, then re-allows: the session root, tmp (`/private/tmp`, `/private/var/folders`),
dev nodes, tool caches, **the git dirs**, and config `allow_write`. The secrets list is denied for
both read and write. On Linux, bubblewrap gets the same list.

**Guaranteed** for a session rooted in a linked worktree:
- It can write its own tree's files, and git can work there (`index.lock`, its HEAD, objects, refs).
- **The main checkout's working files can't be written.** Neither can any other worktree's files.
  Write/Edit outside the root asks, and is denied headless (`engine.rs:4965`).
- Widening it takes an approved `unsandboxed: true`.

**Not guaranteed** (the common dir is the whole main `.git`, and it's writable):
- Shared refs: `git branch -f main`, `update-ref`, `push` refspecs, tags.
- **`refs/stash`**, shared across every worktree. This is why §4 parks to `refs/frog/parked/*` instead.
- The main checkout's `.git/index` and `.git/HEAD` (e.g. `git -C <main> reset --soft`, `checkout <branch>`).
  The working files stay safe, but the main checkout's staged state does not.
- Other trees' admin dirs, `.git/worktrees/<other>/`: their index, HEAD, and **`frog-engine.lock` and
  manifest** (`git worktree remove/prune` of a sibling).
- Reads are open (`allow default`), except secrets.

**Proposed tightening (small, optional):** in seatbelt, the last matching rule wins. After the
current allow, add three rules: `(deny file-write* (subpath "<common>/worktrees"))`,
`(deny file-write* (literal "<common>/index"))`, and then `(allow file-write* (subpath "<own git dir>"))`.
Together they keep sibling trees' admin dirs and the main checkout's index out of reach, and
leave this tree's own git dir writable. Shared refs stay writable on purpose, because committing
and fetching need them. Approval policy, not the sandbox, should catch `branch -f` / `update-ref`
on `main`.

---

## Failure modes

| # | Failure | Today | With this design | Guard |
|---|---|---|---|---|
| F1 | Restart calls StartSession with the same title | silent `<slug>-2`; the old tree's work is stranded | refused, naming the tree, branch, owner and counts, plus three exact escapes | §2a `on_collision` |
| F2 | Resumed engine starts in the main checkout (header cwd ≠ tree) | serves the main checkout with no lock (#107 incident 2) | resume uses `header.worktree`, and the engine refuses on a mismatch | §1 resume + **#107** |
| F3 | Worker launched with cwd = repo root | refused unless `allow_main_checkout` (already fixed for spawn) | same, plus `worktree:"auto"` picks a tree | §1 |
| F4 | Two engines in one tree | refused by name (flock) | same, but the lock is on the recorded tree, not the process cwd | `worktree.rs` + §2b |
| F5 | `stash pop` takes another branch's stash | possible (`refs/stash` is shared) | teardown parks to `refs/frog/parked/*`, never `refs/stash` | §4 |
| F6 | Free worktree reused by an unrelated session | silent | refused when the manifest names another owner; `reuse` is explicit | §2a |
| F7 | Engine crashed, tree left behind | invisible | the Workers dot shows "parked" with Resume | §3 flock classes |
| F8 | Merged tree lingers for weeks | invisible, using disk | auto teardown after 24 h idle when clean and merged | §3 |
| F9 | Tree removed by hand; session row vanishes | silent (listing drops it) | archived with `tornDown`; resume refuses and names the parked ref | §2b, §4 |
| F10 | `git worktree remove` of a sibling from a sandboxed shell | allowed (common dir writable) | optional deny on sibling admin dirs | §5 |
| F11 | Teardown of a dirty tree | n/a | parked first; delete is a second, red click in the app only | §4 prompt |
| F12 | "ahead" disagrees between ListSessions and the sidebar | upstream vs base | one definition: against the manifest's `base_ref` | §1 |

## Build order (when approved)

1. Manifest and header `worktree`; resume from the recorded tree. Small, and it fixes F2's cause.
2. #107 serving-cwd check; lock on the recorded tree.
3. `on_collision` and the named refusal.
4. `teardown` op, `TeardownSession`, parked refs, `from_parked`.
5. `frog --worktrees --json`, the Workers scope, self-cleaning classes.
6. Optional sandbox tightening (§5).

## Open questions for Cam

1. On a #107 mismatch: **refuse** to serve, or serve **read-only** with a loud notice? (Recommend refuse.)
2. Auto teardown of merged, clean trees after 24 h: OK? Or always ask?
3. Parked work: a private `refs/frog/parked/*` (recommended), or also mirror it into `git stash list` so
   it shows up in normal git tools (that brings back the shared-stash risk)?
4. `worktree` default flips to `"auto"`: OK? Or keep it explicit?
5. §5 tightening (deny writes to sibling trees' admin dirs): now, or later?
