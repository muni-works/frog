# frog on Apple Watch

The Mac is where you work with frog. The watch is where frog reaches you when you've walked away.
It does three things, in this order:

1. **Answer** a permission request without going back to the Mac.
2. **Know** what's running and when it's done, at a glance.
3. **Nudge**: a short spoken reply, or stop a turn that's gone wrong.

Anything longer (reading diffs line by line, browsing transcripts, starting real work) belongs on
the Mac or the iPhone. Handoff (`eco.frog.conversation`) carries you there.

## Principles (from the watchOS HIG)

- **Glanceable, then done.** Every interaction finishes in a few seconds. Lead with the one thing
  that matters ("git push needs you"), never with chrome.
- **Notifications are the app.** Most answers happen from a notification, wrist raised, app never
  opened. The app is for when you want to look.
- **Ambient first.** The Smart Stack and complications show frog's state before you ask.
- **Native controls.** System type, Dynamic Type, full-bleed dark backgrounds, toolbar buttons,
  the Digital Crown for scrolling, double tap for the primary action, and haptics for state changes.
- **Same product as the Mac.** Same words, same colors, same frog.

## The same product as the Mac

| | Mac | Watch |
|---|---|---|
| Brand in copy | lowercase "frog" | same |
| Unit | Conversation, grouped by project | same; rows show the project or title |
| Running | "Running the tests… 12s", "Thinking…" | the same activity string, shown alongside the frog |
| Permission | orange card: **Allow** (⌘↩), *always* label, **Deny** (⌘.) | orange; **Allow**, **Deny**, *Always allow …* below |
| Accent | `Color.frog` | `Color.frog` (dark variant; the watch is always dark) |
| Mascot | `FrogFace(mood:)` | the same view and moods; still under Reduce Motion and in always-on |
| Sounds | plip / ribbit / drip | haptics (see below) |

`FrogFace`, `Color.frog`, `ToolIcon` and the protocol types come from `FrogKit`. No new art.

## Structure

```
Notifications ─┬─ Permission (long look) ── Allow · Deny · Always allow …
               └─ Finished (long look) ──── Reply · Open on Mac

App ── List ─┬─ Needs you  ──→ Request
             ├─ Working    ──→ Conversation ──→ Reply / Stop
             └─ Earlier    ──→ Conversation
     toolbar: ✎ New (dictate to the most recent project)

Smart Stack widget · complications (circular, corner, rectangular, inline)
```

## Screens

### 1. Permission notification (the main path)

- **Short look.** The system's app icon and title: "frog · ~/frog needs permission". This matches
  the Mac's `"\(project) needs permission"`.
- **Long look.** A custom SwiftUI notification view:
  - Waiting frog (`FrogFace(mood: .waiting)`, 28 pt) with the project name in `.caption`, secondary.
  - The command in `.body.monospaced()`, up to 3 lines, e.g. `git push origin claude/fix-wrap`.
  - `reason` in `.footnote`, secondary: "uses the network · outside the sandbox".
  - With a file diff: the file name and "+12 −3" instead of the command; the full diff stays on
    the Mac and iPhone.
- **Actions.** **Allow**, then *Always allow "git push"* (only when `request.always` isn't empty),
  then **Deny** (destructive).
- Double tap triggers the first action, Allow, matching the Mac's default (⌘↩). See open questions.

### 2. Finished notification

- Title: the project. Body: the first sentence of frog's answer ("1 test failing. tui::wrap
  breaks mid-word at column 40.").
- Actions:
  - **Reply** (`UNTextInputNotificationAction`: dictation, Scribble, or the suggestions below), which
    sends `submit` to that conversation.
  - **Open on Mac** (Handoff).
- Posted only when `notifyWhenDone` is on, as on the Mac.

### 3. List (app root)

`NavigationStack` with a `List`, titled "frog". The sections only appear when they have rows:

- **Needs you.** Orange. Each row: small waiting frog, project in `.caption2`, the command in
  `.headline` (2 lines max). Tapping opens the Request screen. No buttons in the row: answering
  from a scrolling list risks a mis-tap, and the full-screen request has room for context.
- **Working.** Working frog, title, activity ("Running the tests… 12s"), live timer from
  `Text(date, style: .timer)`.
- **Earlier.** Turns that finished today: done frog, title, first line of the answer.
- **Empty state.** As now: idle frog, "All quiet", "frog will tap you when it needs you."
- **Toolbar.** `square.and.pencil` in the top-trailing corner, the Mac's New Conversation symbol.
  It opens dictation and sends to the most recently active project.

### 4. Request

A full-screen sheet from a Needs you row, or opened from the notification:

- Waiting frog on top, project name.
- Command (monospaced, scrolls with the Crown when long), `reason`, diff summary.
- Bottom toolbar:
  - **Allow**: `.borderedProminent`, tinted `.frog`, and the `handGestureShortcut(.primaryAction)`
    target, so double tap answers.
  - **Deny**: `.bordered`.
- Below, a plain text button: *Always allow "git push"* (when offered).
- Answering:
  - `.success` haptic for Allow, `.click` for Deny.
  - The sheet closes and the row moves to Working.
  - While the answer is in flight, the buttons swap for a `ProgressView`, as today.
  - If the phone can't be reached, the answer is queued (`transferUserInfo`) and the row shows
    "Will send when your iPhone is near."

### 5. Conversation

- **Header.** Frog in the current mood (44 pt), activity line, timer.
- **Body.** The latest answer, or the user's last message while working, in `.body`, scrolled with
  the Crown. Then the last few items as compact rows: `ToolIcon` + "Ran cargo test",
  "Edited ui.rs". Only the one-line summaries; no output.
- **Bottom toolbar:**
  - **Reply** (`mic`) on the leading side. It opens text input with suggestions:
    "Yes, go ahead", "Fix it", "Not now", "Stop after this".
  - **Stop** (`stop.fill`, red) on the trailing side, only while working. It sends `interrupt`.
- **Handoff** to Mac or iPhone, so "pick this up on the Mac" just works.

### 6. Smart Stack and complications

The same `StatusWidget` family the iPhone uses, with watch layouts:

| Family | Shows |
|---|---|
| `accessoryCircular` | Frog in the most urgent mood; orange ring and count when something needs you |
| `accessoryCorner` | Frog; the curved label reads "1 needs you" or "Running 12s" |
| `accessoryRectangular` | Most urgent row: "git push needs you" / "Running the tests… 12s" / "All quiet" |
| `accessoryInline` | "frog · 1 needs you" |

- The Smart Stack widget sets relevance (`RelevanceKit` / `TimelineEntryRelevance`) high while
  something waits or runs, so it rises on its own and falls back when all is quiet.
- Tapping a widget or complication deep-links to the most urgent row.

## Motion, haptics, always-on

- **Haptics stand in for the Mac's sounds:**
  - a request arrives: `.notification`
  - a turn finishes: `.success`
  - an error or "can't reach your Mac": `.failure`
  - another conversation needs you while you're in one: `.directionUp`
- **Motion.** `FrogFace` moods carry it: blink, hop on done, droop on error. Rows use the default
  list animations, nothing custom.
- **Always-on** (`isLuminanceReduced`): the frog freezes on its last pose, timers show minutes
  only, orange becomes secondary, and buttons hide until the wrist is raised.
- **Reduce Motion.** `FrogFace` already holds a still pose.

## Accessibility

- Dynamic Type everywhere. The command wraps, with no fixed font sizes.
- VoiceOver: rows read as "~/frog. Needs you. git push origin claude/fix-wrap". Buttons read
  "Allow git push" and "Deny git push", not "checkmark".
- Color is never the only signal: Needs you has its own section header and frog mood, not just
  orange.

## Data and transport

The watch can't open the Mac bridge itself: watchOS reserves sockets and WebSockets for audio and
calling apps. So the path stays Mac → iPhone (`RemoteBridge`) → watch (`WatchConnectivity`).
Notifications mirror from the iPhone automatically when the phone is locked; the watch app
registers the same `permission` and `finished` categories so the actions work on the wrist.

What the current link needs:

| Today | Needed |
|---|---|
| One `question` string per row | `name`, `arg`, `reason`, `always`, diff summary (file, +/−) |
| `allow: Bool` | `decision`: `allow` / `allow_always` / `deny` |
| waiting and running only | finished-today rows with the first line of the answer |
| answers only | `submit` (reply text), `interrupt` |
| `sendMessage` only | `transferUserInfo` fallback, so answers queue when the phone is away |
| `"permission"` category on Mac only | `permission` and `finished` categories on iPhone and watch, with Always allow and Reply actions |

## Open questions

1. **Double tap = Allow?** It matches the Mac's default and HIG's primary action. But a
   `git push` approved by a gesture you can trigger by accident is a real risk. Alternative: double
   tap only works on the Request screen, never on the notification, or only for read-only tools.
2. **Auto mode.** If Settings › Permissions › Auto is on, the watch sees far fewer requests.
   Should the watch show what Auto approved ("Auto-allowed 3 steps")?
3. **New conversation from the wrist.** Is "dictate to the most recent project" enough, or should
   it offer a short project picker?
4. **Brief.** The morning Brief could be a Smart Stack card on the watch. Worth it, or Mac-only?
