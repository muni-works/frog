# Composer: the tray

Status: planned 2026-11-12. Design agreed with Cam in mockups (A · Tray, git line on top).

## What we're building

One composer shape everywhere, on Mac and web, in a session and on the new-session screen:

```
┌───────────────────────────────────────────────────────────────┐
│ top line   (git line in a session · "where" line when new)    │
├───────────────────────────────────────────────────────────────┤
│ text                                                          │
│ ＋  Auto ⌄ · ● GLM-5.3 Flash ⌄                          (◉)  │
└───────────────────────────────────────────────────────────────┘
```

- **Top line**:
  - in a session: repo · branch · [worktree] · diff · PR pill(s) · one action;
  - new session: folder or repo · branch · New worktree;
  - absent for chat.
- **Rail**: ＋, mode, model and one action button (mic → send → stop). Context use moves into the model menu as a ring.
- **Removed**: the separate status card, the location chip (web still has it), the folder chip, the standalone context ring, and the separate mic and send buttons.
- **Mode defaults to Auto** (`Mode::Auto`, already in the engine: a local classifier approves steps that plainly serve the request; the rest ask). Existing users keep their saved mode; only new installs and new sessions without a remembered mode get Auto.

## One model, two renderers

The elegant part: the composer's behaviour is a small state machine written once as a spec and implemented twice, as a Swift reducer in `FrogKit` and a TS reducer in `apps/web/src`, with **shared test vectors**. The views just render state and send intents.

- `docs/design/composer/cases.json`: a list of `{ given: State, intent, expect: State (partial), effects: [...] }`. Both test suites load the same file:
  - Swift: `FrogTests/ComposerReducerTests`;
  - web: `vitest`.
  A behaviour change means a new case, and both platforms fail until they agree.
- The reducer is pure. Effects (start a session, run git, call the gateway, load a model) are returned as data, and a thin runner on each platform performs them and feeds results back as intents.
- Parity screenshots (`docs/design/parity/`) cover the look. The cases cover the behaviour.

### State

```ts
Composer {
  draft:   { text, attachments[], caret }          // never cleared except by Send
  mode:    "auto" | "default" | "accept_edits" | "yolo"
  model:   { id, place: "local"|"cloud", node? }    // from the picker (frog#291)
  where:   New | Session
  action:  "dictate" | "send" | "stop" | "queue"    // derived, not stored
  busy:    idle | working | sending | loading_model
  error?:  ComposerError                            // one at a time, inline, dismissible
}
New     = { kind: "folder", folder, branch, worktree: bool }
        | { kind: "cloud",  repo, branch }
        | { kind: "chat" }
Session = { repo?, branch, worktree: bool, diff: {add, del, files}, prs: PR[], dirty: bool }
PR      = { repo, number, title, state: draft|checks|failing|approved|merged|closed, checks: {ok, total} }
```

### Where state lives (so nothing gets wiped)

| What | Kept | Scope |
|---|---|---|
| Draft text, attachments | until Send succeeds | per pane (session) / per window (new session) |
| Mode | last chosen | per folder; new folders get Auto |
| Model | last chosen | per folder; chat and cloud keep their own |
| New worktree switch | last value | per repo (default on for git repos) |
| Branch | — | re-derived when the repo changes (below) |
| PR bindings | engine session state | per session |

Drafts persist across app restarts (Mac: `UserDefaults` keyed by pane and session; web: `localStorage`, guarded with try/catch). A failed send never clears the draft.

## Every click

### Rail

| Control | Click | Default | Notes / errors |
|---|---|---|---|
| ＋ | menu: Add files, Add image, Paste screenshot (Mac), Add a URL | — | Drag-and-drop and paste do the same. Files too large or the wrong type are refused inline, listing which ones; the rest attach. |
| Mode ⌄ | menu: Auto (default) · Ask · Accept edits · Yolo, each with a one-line description | Auto | Changing it mid-turn applies to the next permission (engine `SetMode`). Picking Yolo shows a one-time confirmation; the sandbox still applies. |
| Model ⌄ | the picker from frog#291 (Your machines / Frog Cloud / Manage…), plus a context ring row at the top | last per folder, else a cloud model when signed in, else the best local model | Swapping a node's model (409 while busy) → "swaps after this turn". Cloud while signed out → the row reads "Sign in" and opens login, keeping the draft. Out of credit → inline error with Add credit, plus a fallback to the local model if there is one. |
| Action, empty | Dictate (mic) | — | Mic permission denied → inline "Allow microphone in System Settings" with a button; web uses the browser prompt. |
| Action, text | Send (green). ⌘↩ / ↩ per setting | — | See Send below. |
| Action, working | Stop (Esc) | — | Text typed while working turns ↩ into **Queue** (follow-up); the button shows a small "queued" count. |

### Send

1. Trim. If there's nothing to send, do nothing.
2. `busy = sending` and disable the button. The draft stays visible until the engine acknowledges.
3. On acknowledgement: clear the draft and attachments.
4. On failure: keep everything, show the error inline above the rail with Retry, and focus stays in the text.

| Failure | Shows | Action |
|---|---|---|
| Engine not running / crashed | "Frog's engine stopped" | Restart engine (draft kept) |
| Gateway 401 / signed out | "Signed out of Frog Cloud" | Sign in |
| 402 / no credit | "Out of credit" | Add credit · Use {local model} |
| 429 / 5xx | "Frog Cloud is busy" | Retry, with backoff shown |
| Node down mid-turn | the existing one-line rerun notice in the transcript | — |
| Model loading | the action shows a spinner and "loading on mew" | Send waits, and Stop cancels the load |

### Top line, in a session

| Control | Click | Shown when | Errors |
|---|---|---|---|
| repo | reveal in Finder (Mac) / open on GitHub (web) | a repo | — |
| ⎇ branch | menu: copy name, switch branch… (only when the tree is clean), open on GitHub | always | Dirty tree → "Commit or stash first" in the menu, not a failed switch |
| worktree tag | tooltip: the path; click reveals it | worktree sessions | — |
| +a −d | opens the diff view | uncommitted changes | — |
| **Action** (one, by state) | | | |
| · Commit | drafts a message (engine), editable sheet, commits | dirty, no PR | Hook failure → shows the hook output, and the draft message is kept |
| · Open PR | push and `gh pr create` (title and body drafted), binds the PR | committed, no PR | No `gh` auth → "Connect GitHub" (Mac runs `gh auth login` in a terminal tab) |
| · Push | push the branch | ahead of the PR | Rejected (non-fast-forward) → "Branch moved on GitHub" with Pull & retry. Never force-pushes. |
| · Fix | sends "fix the failing checks on #n" as the next turn | checks failing | — |
| · Merge | confirmation sheet (merge method from the repo default), then merge | approved and mergeable | Conflicts → "Resolve conflicts" (a turn). Branch protection → the reason. |
| · Archive | archive the session (worktree removed if clean) | merged | Dirty worktree → asks before deleting anything |
| · Reopen | `gh pr reopen` | closed | — |
| PR pill | opens the PR on GitHub. ⌥-click copies the URL | one PR bound | — |
| Stack pill ("3 PRs, 1 failing") | popover: each PR (repo#n, title, state, its own action) + "Bind a PR…" | 2+ PRs bound | A PR whose repo you can't access shows "no access" and stays bound |
| Bind a PR… | paste a URL or #n, or pick from the branch's open PRs | in the popover | Not found → inline |

**PR state source.** Mac's `GitIndex` already runs `gh pr view <branch>`. It's extended to `gh pr view <n> --json number,title,state,isDraft,reviewDecision,statusCheckRollup,mergeable` per bound PR, polled every 60 s while the window is focused and immediately after any action. Web gets the same fields from the gateway (`GET /v1/sessions/:id/prs`, backed by the GitHub App). The engine stores bindings (`Op::BindPr` / `UnbindPr`, persisted in the session log), so both apps and replays agree. The auto-binding rule: a PR created from the session's branch binds automatically. Others bind by hand.

**Worst-state order for the stack:** failing > checks > draft > approved > closed > merged. The dot colours are a new token family `pr.*`.

### Top line, new session

| Control | Click | Default | Keeps |
|---|---|---|---|
| ▢ folder ⌄ | menu: recent folders, Choose…, Clone a GitHub repo…, "Just chat" | the last folder used | **Changing the folder keeps the draft, attachments and mode**, takes the model remembered for that folder (else keeps the current one), resets the branch to the new repo's current branch, and takes that repo's worktree switch value. |
| ☁ repo ⌄ (cloud) | the GitHub repos the App can see, plus Install on more repos… | last cloud repo | Same keep rules. Switching between folder and cloud keeps the draft, swaps the model group (local ↔ cloud) and says so in one line: "Switched to GLM-5.3 Flash for Frog Cloud". |
| ⎇ branch ⌄ | branches (local + remote), New branch… | the repo's current branch | The choice is kept if you switch away and back within the window. |
| New worktree switch | toggles | on for git repos, remembered per repo | Off + dirty tree → note: "Frog will work in your checkout". |
| Send (new session) | creates the session (worktree if on), then submits | — | Worktree creation fails (branch checked out elsewhere, disk) → error with "Use checkout instead", draft kept. Clone fails → error, draft kept. |

Suggestion chips (new session only) fill the draft and don't send. They're hidden once there's text.

### Keyboard

- ↩ sends (⌘↩ when "Return adds a line" is set). ⇧↩ adds a newline.
- Esc stops a turn, and otherwise clears errors.
- ⌘. cycles mode (Auto → Ask → Accept edits → Yolo-with-confirm). ⌘M opens the model picker.
- ↑ in an empty composer recalls the last message to edit.
- On web, the same shortcuts use Ctrl where ⌘ conflicts with the browser.

## Error display

- One inline error slot above the rail. It shows a short sentence, one or two buttons, and × to dismiss. It never uses a modal, and never covers the text.
- Errors that belong to a control (mic, worktree, push) also outline that control in red until resolved.
- Every error is a case in `cases.json`, so both apps word and handle it the same way.

## Build order

1. **Spec and cases**: `cases.json` with ~60 vectors (every row above), plus the `pr.*` tokens in `tokens.json`.
2. **Engine**:
   - `Op::BindPr` / `UnbindPr` and PR bindings in the session log and replay;
   - a default mode of Auto for new sessions without a remembered mode;
   - `Event::Prs` carrying bound-PR state, so web and Mac render from one feed.
3. **Mac**:
   - a `ComposerModel` reducer in FrogKit;
   - rebuild `ComposerView.swift` (975 lines today) on it, targeting under 500, with the git-line, rail and new-session parts in `FrogKit/UI/Composer/`;
   - `GitIndex` PR polling.
4. **Web**:
   - a `composer.ts` reducer and `Composer.tsx` on it;
   - remove the location and folder chips;
   - gateway `GET /v1/sessions/:id/prs` (zest).
5. **Parity**: screenshots for idle, typing and working; no repo; worktree; each PR state; stack open; new session (folder, cloud, chat); and each error slot. Mac and web.

The cases and engine go first. Then Mac and web proceed in parallel against the same cases, and zest's PR endpoint can go in alongside them.

## Out of scope

- Editing PR titles or reviewers from the composer.
- Stacked-PR tooling (rebasing a stack).
- Multiple repos in one session's top line beyond bound PRs (the stack covers it).
