# Composer: two rows and a status line

The composer is redrawn so that it is the same on the Mac and the web, matches the rest of
the app, and has less on screen. Decided with Cam on 2026-11-16. This doc is the source of
truth for the build; it supersedes the layout in `docs/plans/2026-11-12-composer-tray.md`
(the behaviour and the shared reducer described there stay).

The drawn design is a canvas of six boards. Their sources are checked in beside this file
under `canvas/` (`Main`, `Where`, `Action`, `ModeModel`, `Errors`, `Git`, each a
self-contained HTML file). Every colour, size and spacing below can be read exactly from
their `<style>` blocks; when this doc and a board disagree, the board wins and this doc
gets fixed.

## Principles

1. **Three rows at most.** Status line (only when there is something to say), field,
   controls. Two rows at rest. Nothing ever adds a fourth.
2. **One loud thing.** Only the action is filled, and only Send is green. Every other
   control is plain text until hovered or open.
3. **What on the left, how on the right.** Attach and where describe the task. Mode and
   model describe how Frog does it, so they sit beside the action.
4. **One line of status, in priority order.** Error, then question, then notice, then git
   state. An error replaces the git state while it shows.
5. **Short words.** Hints live in menus, not in the placeholder.
6. **The same on both apps.** One reducer, one set of words, one layout. A difference
   between the apps is a bug unless this doc names it.

## Anatomy and metrics

Names map to the old doc as: status line = the old "top line" and "tray" together;
controls = the old "rail".

| Part | Spec |
| --- | --- |
| Card | fill `card`, 1px stroke `edge` at rest (the quiet border the sidebars use), radius 16 (`radius-field`). No shadow, no glass, no blur. |
| Width | the transcript column: `min(720, available)`, centred, 32 gutter on a narrow window. It does not grow when a sidebar closes. |
| Status line | 32 tall, padding 0 8 0 14, 1px `line` hairline below. Text 12/15 (`callout`); content in `fg`, detail in `muted`. Gap 8. |
| Field | padding 12 top, 14 sides, 4 bottom. Text `body` 13/16 in `fg`. One line at rest, grows to 10 lines (160), then scrolls inside. Placeholder in `muted`-ish (`#8a8a8a` dark). |
| Controls | 28 tall; padding 6 top, 8 sides, 8 bottom. Text 12/15 in `muted`. Gap 2 between chips. |
| Chip | 24 tall, padding 0 8, radius pill, gap 4 between icon and label, icons 14 with 1.4 stroke. No fill at rest. Hover and open: `hover` plate (primary at 8%) and text in `fg`. |
| Action | 28 circle, 4 from the last chip, 8 from the right and bottom edges. Fill: primary at 8% (quiet) or `frog` (Send). |
| Resting height | 78 with no status line, 110 with one. |
| Focus | the card's stroke goes to `muted`; the caret is `frog`. No ring, no glow. |
| Light theme | same structure with the light token values. |

Controls order, left to right: **attach**, **where** (only before a session starts), a
flexible gap, **mode**, **model**, **action**.

Narrow (under 420 wide): the model chip keeps its icon and drops its name (the name stays
as the accessibility label); the where chip truncates in the middle. Nothing wraps to a
second row. On touch layouts each control keeps its look inside a 44 tap area.

Type size: the metrics above are the Mac's. The web app keeps its current base size
(15/21 field) with the same structure and paddings. *Open: Cam may want the web on 13/16.*

## Where it runs

One chip names where the work will happen, with its branch: place icon, name in `fg`,
branch in `muted`, a chevron.

- Icons: folder for a local folder, cloud for a Frog Cloud repo or "No repo", a speech
  bubble for "Just chat". A folder outside git shows no branch.
- It opens **one menu, upward**, with a filter field at the top that takes focus:
  - **This Mac** (Mac only): recent folders with their parent path right-aligned, then
    "Choose a folder…".
  - **Frog Cloud**: the account's repos, "No repo", and on the web "Give Frog access to
    more repos". Signed out, the group is one row: "Sign in to use Frog Cloud".
  - "Just chat" (Mac only), under a hairline.
  - Under a hairline, for the current choice: **Branch** (opens a second level with its
    own filter) and **New worktree** (a switch; Mac only).
  - Web filter placeholder: "Search repos, or paste a GitHub URL". Mac: "Search folders
    and repos". Pasting a GitHub URL picks that repo on both.
- Menu rows are 28 tall with the 7-radius hover plate; the current choice has a check at
  the right.
- Picking keeps the draft, attachments and mode (already the reducer's behaviour).
- A tree with uncommitted changes can't switch branch: the Branch row is muted with
  "Commit your changes to switch branches" under it.
- Once the session starts the chip is gone. Place and branch then show in the status line
  with the git state, and only when there is git state to show.

What this removes: the where line as its own row; the separate branch chip and worktree
chip; the Mac's Frog Cloud tray (`ComposerView+Tray.swift`'s cloud target picker) and its
folder-only chip. The web's "No repo" chip becomes this chip.

## The action

One button. Its position and size never change; the glyph cross-fades in place (0.12s).

| Face | When | Look |
| --- | --- | --- |
| Dictate | idle, nothing in the field | quiet disc, microphone |
| Listening | dictation in progress | quiet disc, waveform, 2px `frog` ring |
| Send | idle, with text or an attachment | `frog` fill, up arrow in `on-frog` |
| Sending | the send is in flight | the disc becomes a progress ring; the draft dims to `muted` and stays until acknowledged |
| Stop | working (or loading a model), field empty | quiet disc, filled square |
| Queue | working, with text | quiet disc, up arrow (not green: it sends later) |
| Marked | an error concerns this button | 1.5px `notice` ring |

Signed out on the web, the action is a `frog` pill reading "Sign in"; it grows leftward
from the action's position. Loading a local model shows in the model chip ("Loading Qwen3
8B" with a small ring) while the action is Stop.

Queued follow-ups are visible: each sits above the field as a chip, in the same place and
style as attachments, with a remove control. There is no bare count.

Placeholders: "What should we work on?" (new session), "Reply to Frog" (in a session),
"Add a follow-up" (while Frog works).

Keys: Return sends or queues; Shift-Return adds a line; Esc stops a turn, or clears the
status line when nothing runs; Up in an empty field recalls the last message.

## Mode, model, attach

- **Mode** chip: the mode's name. Yolo adds a small bolt icon in `notice`; the word stays
  in the normal colour. Menu ("When Frog asks"): Ask, Accept edits, Auto, Yolo, each with
  one line of description, a check on the current one. Yolo confirms once, in the status
  line ("Yolo runs every step without asking", Cancel, Use Yolo).
- **Model** chip: a place icon then the name. Laptop in `place-local` for this Mac, a
  server in `place-local` for your own nodes, cloud in `place-cloud` for Frog Cloud. No
  dots. Menu: a filter, then groups by place, price right-aligned ("free", "from $0.04/M").
- **Attach** (the plus): "Attach a file…", "Paste a screenshot", "Mention a file" with `@`
  at the right, "Run a command" with `!` at the right. This is where the shortcuts are
  taught. Attachments sit above the field: name, size in `muted`, remove.

## The status line

One line. It shows the first of these that applies:

1. **An error.** A small triangle in `notice`, the message in `fg`, then up to two buttons.
2. **A question.** Yolo the first time, Merge, Archive. No triangle. Cancel then the
   confirming button.
3. **A notice.** Something Frog did for you ("Switched to GLM-5.3 Flash in Frog Cloud",
   "Frog will work in your checkout, alongside your changes"). A dismiss control. It
   clears on the next send.
4. **Git state**, in a session with a repo and something to report (below).

Rules: one at a time (a new error replaces the old one). Buttons are quiet: text in `fg`
on the 8% plate, 22 tall; a secondary or Cancel is plain `muted` text with no plate.
Nothing in the status line is filled or green except an urged Open PR. Text is never red (the one red word anywhere is a failed step's verb in the transcript; see ../transcript/spec.md, "Failure").
It opens and closes by sliding (0.22s; 0.12s fade under reduced motion). Esc clears an
error or a question.

Errors keep the reducer's list (`ERRORS` in `apps/web/src/composer.ts` and its twin in
`ComposerModel.swift`) with one wording change: `mic_denied` reads "Needs mic access to
take dictation", button "Open Settings".

### Git state

`[folder icon] repo  branch  +a −d` at the left (the counts in mono, green and the warn
colour), then at the right the PR and one action.

- PR: a 7px state dot and "#412 checking". Grey for draft and closed, `notice` for
  checking, the warn colour for failing, green for approved, violet (`#a78bfa`) for merged.
  The word is always there; colour is never the only signal. Several PRs: "3 PRs, 1
  failing" with a chevron, opening the list upward (each row: dot, number, title, state and
  checks right-aligned; last row "Bind a PR by URL or number…").
- The action is the reducer's `gitAction`, unchanged: Commit, Open PR, Push, Fix, Merge,
  Archive, Reopen, or none. Merge and Archive ask first, in this same line.
- Open PR is green only when the reducer's `openPr` is true (the work is done in its own
  worktree and a PR is wanted). The web never has that fact, so it is never green there.
- With nothing to report (no repo, or clean with nothing ahead and no PR) there is no line.
- The same action also exists at the bottom of the right sidebar's Changes tab. Both run
  the same step.

## Changes to the shared logic

Both reducers change together, with `cases.json` regenerated from `generate.py`:

- `queued: number` becomes `queued: [{text, attachments}]`, with a `remove_queued` intent
  (by index) and a matching effect so the engine drops it. `turn_done` clears the list.
- A `dictating: boolean` (intents `dictation_started`, `dictation_ended`); `derive` gives
  the action face `listening` while it is true.
- `derive` gains `status`: which of `error | confirm | notice | git | none` the status
  line shows, by the priority above.
- `mic_denied`'s message, as above.
- Nothing else about behaviour changes. Every existing case that doesn't touch `queued`
  keeps passing.

## Who builds what

- **Web session** owns `docs/design/composer/generate.py` and `cases.json`, the web
  reducer (`apps/web/src/composer.ts`) and the web view (`apps/web/src/ui/Composer.tsx`,
  `app.css`).
- **Mac session** owns `apps/FrogKit/Core/ComposerModel.swift` and the Mac views
  (`apps/macos/Frog/Views/ComposerView*.swift`, `apps/FrogKit/UI/Composer/`). It implements
  the logic changes exactly as listed here, then makes its reducer pass the web session's
  regenerated `cases.json` once that lands. It does not edit `generate.py` or `cases.json`.

## Done looks like

- Light and dark screenshots of the same states from both apps, side by side, checked
  into `docs/design/composer/`: new session (folder on Mac, cloud on both), typing,
  working, a queued follow-up, an error, git state with a PR, the where menu open, narrow.
- Both reducers pass the regenerated `cases.json`.
- No where-line row, no cloud tray on the Mac, no shadow or glass on the composer.
- The composer is never taller than three rows in any state.

## Not in this work

- Flush sidebars and making the Mac's right sidebar match the web's on a narrow window.
- Full hover, pressed and motion polish beyond what is stated here.
- Changing what any git action does.
