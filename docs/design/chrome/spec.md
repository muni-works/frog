# Window chrome: one design for the Mac and the web

What's around the transcript, Settings and the inspector: the controls at the top right, the turn
rail, the header, the sidebar's brand row and the rest of [`audit.md`](audit.md). Written
2026-11-18. The rule is [`../app-shell.md`](../app-shell.md)'s: inside the window Frog draws
everything from one spec; the Mac is native only at the edges.

Sizes are points on the Mac and CSS pixels on the web (the same at 1×). Colours are tokens from
[`design/tokens.json`](../../../design/tokens.json): the CSS name, then the Swift one
(`card` / `Tokens.raised`). Icons are SF Symbols on the Mac; the web draws the same shapes as inline
SVG on a 24 grid, stroke 1.8, round caps (`apps/web/src/ui/icons.tsx`).

Parity is measured, not eyeballed: [`parity/README.md`](parity/README.md).

## States, for every control here

| State | Fill | Icon / text |
| --- | --- | --- |
| Rest | none | `muted` / `Tokens.textSecondary` |
| Hover | `hover` / `Tokens.hover` | `fg` / `Tokens.text` |
| Pressed | `well` / `Tokens.well` | `fg` / `Tokens.text` |
| On (a toggle that's showing its thing) | `well` / `Tokens.well` | `fg` / `Tokens.text` |
| Disabled | none, no hover | rest colour at 35% opacity |

Every icon button has an accessibility label (the Mac's `accessibilityLabel`, the web's
`aria-label`) that is the same word on both apps, and a tooltip `Name (keys)` when it has a
shortcut. Toggles say whether they're on (`aria-pressed` on the web; the Mac's toggle trait).

## 1. The top-right controls

One control, the **window controls**: a capsule at the conversation's top-right holding, left to right,
**Split**, **Commands**, **Inspector**.

| | |
| --- | --- |
| Place | Top 9, right 8 from the conversation area's right edge, in the title row (52 tall): the window's edge, or left of a docked inspector, whose tabs head its own column |
| Surface | A capsule, fill `card` / `Tokens.raised`, no stroke, radius = height / 2 |
| Size | Height 34, padding 3 on every side; buttons side by side with no gap |
| Button | 34 × 28, a capsule (radius 14); the states above |
| Icon | The SF Symbol at 15 pt regular; the web's SVG drawn so its ink matches (split and inspector at 18, command at 17): 17.5 × 13.5 and 14 × 14 |
| Accessibility | The group is labelled **Window controls**; buttons **Split**, **Commands**, **Inspector** |

| Button | Mac symbol | Web SVG | Tooltip | Does | Disabled |
| --- | --- | --- | --- | --- | --- |
| Split | `rectangle.split.2x1` | rounded rect 18 × 16, r 3, a line down its middle | Split pane (⌘\\) | Splits the focused pane right; right-click: Split Right, Split Down | Can't split; Settings or Documentation |
| Commands | `command` | the ⌘ loop | Command palette (⌘K) | Opens or closes the palette. **On** while it shows | never |
| Inspector | `sidebar.right` | rounded rect 18 × 16, r 3, a line at x 15, three short lines in the right panel | Inspector (⌥⌘0) | Shows or hides the inspector. **On** while it shows | No session; Settings or Documentation |

Width: 108 with three buttons. The rightmost button never moves: a button the app hasn't got
leaves from the left.

**Where the two apps differed, and what was picked:**

- *Surface.* The Mac used the system's toolbar glass; the web had none. **Frog's capsule on
  both**: the web can't draw glass, the glass doesn't draw in `-FrogSnapshot` (so it couldn't be
  measured or captured), and the rule puts everything inside the window on one spec. The Mac's
  item is one `ToolbarItem` with `.sharedBackgroundVisibility(.hidden)`, the pattern the title row
  already uses. The title bar itself (traffic lights, window dragging, full screen) stays the
  system's.
- *The inspector toggle while it's open.* The web hid it; the Mac kept it. **Kept, with its on
  state**: the button that opened it is where you close it, and the group doesn't change width
  as you use it. The web inspector's × stays too (it's in the inspector's own row).
- *Shortcuts.* The web had only ⌘K. **⌥⌘0 toggles the inspector on the web too** (read from the key
  code, since ⌥ changes the character). ⌘\\ is the Mac's split; the web uses it for the sidebar
  today and keeps that until the web has split panes (piece 4 moves the sidebar to ⌃⌘S on both).
- *Tooltips.* One wording: `Name (keys)`, sentence case.

**The web has no split panes.** Until it does, its group is **Commands** and **Inspector** (74
wide), the inspector in the same place as the Mac's. A split button that can't split would be a
dead control, so it isn't drawn. What the web should get, as its own piece of work: two sessions
side by side in the main area, the Mac's `PaneLayout` rules (360 minimum, a draggable divider,
the focused pane takes the composer's keys), ⌘\\ to split, and the Split button back in the
group. The parity check lists split as Mac-only (`ONE_APP` in `parity/diff-chrome.mjs`) and
fails if the web grows one without the spec changing.

## 2. The turn rail

One design, the Mac's `TimelineRail`, on both.

| | |
| --- | --- |
| Shows | Once the conversation has a turn |
| Place | Top 60 (8 under the title row), 8 from the conversation area's right edge: left of a docked inspector, never over it |
| Room | The conversation keeps its width plus 8 + 28 clear on the right for it, so the column centres in what's left |
| Surface | A capsule, fill `card` / `Tokens.raised`, 28 wide; height `min(room, 360, chapters × 18 + 28)` |
| Narrow | 14 wide in a narrow split pane (Mac only, while the web has no split) |
| Accessibility | `Timeline, N turns, in chapter c of C`; on the web a slider whose arrow keys move between chapters (the Mac's has the label only, for now) |

Marks, drawn inside a 12 pad top and bottom, centred on the rail:

| Mark | Look |
| --- | --- |
| The conversation | A 1 wide hairline, `fg` at 14% |
| Turns on screen | A 12 wide rounded thumb (r 6) from 7 above the first to 7 below the last, `fg` at 9% |
| A chapter you started | A solid dot, r 2.5 (3.5 the chapter you're in), `fg` at 40% (85%) |
| An autonomous stretch | A hollow dot, r 2.25 (3), 1 stroke, `fg` at 35% (70%) |
| Summarized here | The line steps out: two 8 × 1 bars, `muted` at 50% |
| A turn that needs you | A 4 dot: `warn` failed, `notice` stopped (looping, step or token limit), `frog` / `Tokens.accent` running |
| Hovered turn | A ring r 5, 1 stroke, `fg` at 60% |

Chapters: a chapter starts at the first turn, at each prompt of yours, at a summary, and after six
turns with no prompt. A chapter's name is the engine's title when it wrote one, else the first
clause of your prompt with the lead-in dropped, at most four words. Chapter dots closer than 7
apart drop all but the one you're in. Both apps run the same cases
([`rail-cases.json`](rail-cases.json)).

Hover: the turn under the pointer gets its ring and a label hangs 8 left of the rail, over the
transcript: a capsule, `card` fill, 12 pt, padding 10 × 5, holding the chapter's name (on a
chapter's first turn, `muted`), the turn number (`muted`, tabular) and the prompt (one line, at
most 260 wide). Scrub: press, click or drag anywhere on the rail jumps the transcript to the turn
under the pointer (its top, instantly), and keeps jumping as you drag; the Mac ticks a haptic per
turn crossed.

**Where the two apps differ, on purpose:**

- *The menu* (Fork after this turn, Rewind to before this turn…, Compare with now) is the Mac's
  only. The web's protocol has no fork or rewind op and no preview checkpoints. When the protocol
  gets them, the web adds the same items in a card menu on right-click.
- *Find marks and camera badges* are the Mac's only: the web has no find bar or checkpoints.
- *Chapter names beside the dots* (when there's 90 or more free beside the rail) stay the Mac's
  for now; the web shows them on hover only.

## 3. The header

The session's title at the left of the conversation's title row, and its menu.

| | |
| --- | --- |
| Place | In the 52 title row, vertically centred (top 17.5); its left edge 20 from the conversation area's (the sidebar's edge); with the sidebar collapsed, after its toggle and New session |
| Title | 13 pt semibold, `fg` / `Tokens.text`, one line, truncated at the tail |
| Menu affordance | The whole title is the button; a 9 pt semibold chevron down (8.5 × 4.9 on the web), `muted`, 5 after the text |
| Hit area | The text and chevron, 17 tall, no fill; hover and pressed turn the chevron `fg` |
| Tooltip | Rename, archive or delete this session |
| Accessibility | **Session menu**, its value the title |
| Menu | Rename…, Archive (Unarchive when archived), a divider, Delete… (destructive) |
| Rename | In place: the title becomes a field of the same type, 320 wide; Return or leaving the field saves, Escape cancels; an empty name keeps the old one |
| Delete | Asks first, then deletes |
| Surface | The title row is opaque in every mode (threads, Customize, Settings, Documentation): the canvas, the title bar's full height; pages scroll beneath it, never through the crumbs or controls |
| A mode's own items | Customize's figure and action stand left of the window controls, 12 apart, in the same row; the figure is one line, cut at its end, and gives way before the action |

**Where the two apps differed, and what was picked:**

- *Size and weight.* Mac 13 semibold, web 14 bold. **13 semibold**: the title row's other words
  (the brand, the breadcrumbs) are 13 semibold already.
- *The chevron.* A separate button on the web. **The whole title is the button**, as on the Mac:
  a bigger target, and one thing to press.
- *Rename.* An alert on the Mac, in place on the web. **In place on both**: no window for one
  word, and the title stays where you were looking. The web's double-click on the title goes:
  with the whole title a menu button, the first click opens the menu (Rename… is its first item).
- *Wording.* "Rename…" and "Delete…" (they ask for more), "Archive"/"Unarchive".
- *The web's connection words* ("Reconnecting…", "Disconnected", "Update Frog to continue") stay
  web-only, right-aligned in the row before the window controls: a web session is a socket to a
  sandbox that can drop; a Mac session isn't.

## 4. The sidebar's brand row

Next after the header (not built in this round). The Mac's design on both: `FrogFace` / `Mark`
at 18, "Frog" 13 semibold, view options `line.3.horizontal.decrease` (web: three lines of falling
length), collapse `sidebar.left` 24 × 24 with "Collapse the sidebar (⌃⌘S)". The sidebar is 250
wide on both (the web's is 270 today). Collapsed, the toggle carries the amber waiting dot and the
hover list of live sessions on both. The web keeps ⌘\\ as a second key for the sidebar until it
has split panes. The Mac's row starts right of the traffic lights (84): a platform difference the
web has no reason to copy.

## 5. Later pieces

In order of how visible the difference is ([`audit.md`](audit.md)):

1. Composer's control row: the web gets the context ring, in the Mac's order (+, ─, ring,
   mode, model, send).
2. Sidebar's first rows: New session is `square.and.pencil` on both; Search shows ⌘K on both.
3. Inspector's tab row: the web moves its tabs into the title row when the inspector is open,
   left of the window controls, as the Mac does.
4. Toasts: one transient line at the bottom centre on both (the web's `.toast`), for copied,
   archived, and errors that have no place of their own.
5. Empty states: one new-session hero (frog 56, a title, a line, the composer).

## What stays native on the Mac

| Native | Why |
| --- | --- |
| The title bar: traffic lights, dragging, double-click to zoom, full screen | The window manager owns it; drawing it would break system behaviour |
| The menu bar (`Views/Commands.swift`) | macOS apps have one; the web's palette is its counterpart |
| Menus and context menus (`Menu`, `contextMenu`) | Keyboard navigation, type-select, accessibility and the system's placement for free. The web's cards follow the same item wording and order |
| Sheets and alerts (confirm delete, permissions) | System dialogs, by the rule |
| Tooltips (`.help`) | The system draws them; the words are the spec's |
