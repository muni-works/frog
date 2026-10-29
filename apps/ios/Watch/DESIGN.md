# frog on Apple Watch

The Mac is where you work with frog. The watch is where frog reaches you when you've walked away.
It does three things, in this order:

1. **Answer.** Allow or Deny a step, or answer an Ask, without going back to the Mac.
2. **Know.** See what's running and what frog said when it finished.
3. **Nudge.** Press a next step, say a few words, or stop a turn that's gone wrong.

Anything longer (diffs line by line, transcripts, starting real work) belongs on the Mac or the
iPhone. A long press, or Handoff (`eco.frog.conversation`), takes you there.

This doc starts from what `WatchApp.swift` does today and proposes what to change.

## What's there today

| | Today |
|---|---|
| **List** | Sections: **Needs you** (orange; the question, then the command in monospace or the file and its +/−, and why it asks; **Deny** / **Allow** as words, Allow in `Color.frog`, plus *Always allow "git push"* when offered; an Ask's options as buttons, plus "Say something else" by voice), **Working** (title, activity, a live timer), **Done** (title, the start of frog's last reply). In always-on the question dims and the buttons hide. Empty: "All quiet" / "frog will tap you when it needs you." |
| **Reply screen** | Opens from running and done rows. Frog's last reply scrolled with the Crown, the turn's stats, and next-step buttons that run a turn on the Mac. Bottom bar: **Stop** while running (`interrupt`), **Reply** by voice when done (`submit`). A long press shows it on the phone; Handoff offers it on the Mac. |
| **Routes** | Answers go straight to the Mac when the watch holds it (`WatchBridge`, a `wss://` URL the phone hands over, the pairing code as token), else through the phone (gives up after 5 s), else the Mac anyway. The list's footer says "Straight to your Mac" or why it's offline: "Your phone is out of reach", "Reaching your Mac…", "Can't reach your Mac", "Pair your phone again". |
| **Haptics** | `.notification` for a new question, `.success` for a finished turn, `.click` / `.failure` for a sent / failed answer, `.directionUp` for show on phone. |
| **Ops** | `permission` (allow / deny / allow_always), `answer` (an Ask's choice, or other words), `act` (a next step), `submit` (a reply), `interrupt` (stop). |
| **Complication** | The iPhone's `StatusWidget`, not yet tried on a watch face. |

These hold up against the HIG: answers in a tap, the Crown for reading, haptics that mean one
thing each, and an honest offline state. Keep all of it. The proposals below fill gaps; they don't
start over.

## Principles (watchOS HIG)

- **Glanceable, then done.** Lead with the one thing that matters ("git push needs you").
- **Notifications are most of the app.** Most answers should happen wrist-raised, without opening
  the app.
- **Ambient first.** The Smart Stack and complications show frog's state before you ask.
- **Native controls.** System type and Dynamic Type, dark full-bleed screens, toolbars, the Crown,
  double tap for the primary action, and meaningful haptics.
- **Same product as the Mac.** Same words, same colors, same frog.

## Proposals

### 1. Permission rows say what they'll do

Today a permission row is the question text with ✕ and ✓ icons. Proposed:

- The command in `.body.monospaced()`, up to 3 lines, with `reason` underneath in `.footnote`
  ("uses the network · outside the sandbox"). For a file edit: the file name and "+12 −3".
- **Deny** and **Allow** as words, not ✕ / ✓. It matches the Mac and iPhone, and VoiceOver reads
  "Allow git push", not "checkmark".
- Allow in `Color.frog`. Today it hardcodes the light-mode green, but the watch is always dark.
- *Always allow "git push"* as a plain text button below, when `request.always` isn't empty. It
  sends `decision: allow_always`. Today the watch can only send allow or deny.
- A tap on the row, outside the buttons, opens a **Request** screen: the full command, reason
  and diff summary, with Allow in the bottom toolbar as the double-tap target
  (`handGestureShortcut(.primaryAction)`). This is the screen for a command too long to trust from
  three lines.

Answering stays inline. The first version of this doc moved it to the Request screen; main's
inline buttons are faster, and the reason/command lines give them the context they lacked.

### 2. Notifications on the wrist

Today the watch app has no notification scene. The iPhone's notifications mirror to the watch
only when the phone is locked, and only with the phone's actions.

- **Permission.** Title "~/frog needs permission", as on the Mac. The expanded view is SwiftUI:
  waiting frog, command (monospaced), reason. Actions: **Allow**, *Always allow "git push"* (when
  offered), **Deny** (destructive).
- **Ask.** The question, with up to three options as actions and a text-input action for the rest
  (dictation).
- **Finished.** The project as title, the first sentence of the answer as body. **Reply** is a
  text-input action that starts a new turn. Next steps become actions too, when the turn
  suggested them.
- The watch registers the same categories, so actions work whether the notification came through
  the phone or the watch posted it locally while holding the Mac directly.

### 3. A free reply and Stop on the Reply screen

- **Reply** (`mic`) in the bottom toolbar of a finished conversation. It opens text input
  (dictation first, then the turn's next steps as suggestions) and sends `submit`. Today you can
  only press a next step.
- **Stop** (`stop.fill`, red) while running. It sends `interrupt`.
- While running, show the activity with a live timer (`Text(start, style: .timer)`) and the last
  couple of one-line steps ("Edited fetch.ts", "Ran npm test") with `ToolIcon`s.

### 4. Sections and an empty-state action

- Section headers: **Needs you** (orange), **Working**, **Done**. Today the groups run together;
  headers are VoiceOver landmarks and keep color from being the only signal.
- A `square.and.pencil` toolbar button, the Mac's New Conversation symbol. It dictates a message
  to the most recently active project.

### 5. Complications and Smart Stack

Build watch layouts for the existing `StatusWidget`:

| Family | Shows |
|---|---|
| `accessoryCircular` | Frog in the most urgent mood; an orange count when something needs you |
| `accessoryCorner` | Frog; the curved label "1 needs you" or "Running 0:12" |
| `accessoryRectangular` | The most urgent row: "git push needs you" / "Running the tests… 0:12" / "All quiet" |
| `accessoryInline` | "frog · 1 needs you" |

- Relevance is high while something waits or runs, so the Smart Stack raises frog by itself and
  drops it when all is quiet.
- Tapping deep-links to that row.

### 6. Always-on

When `isLuminanceReduced`:
- the frog holds its last pose
- timers show minutes only
- orange becomes secondary
- the answer buttons hide until the wrist is raised, so a sleeve can't press Allow

## The same product as the Mac

| | Mac | Watch |
|---|---|---|
| Brand in copy | lowercase "frog" | same |
| Running | "Running the tests… 12s", "Thinking…" | the same activity strings |
| Permission | orange card: Allow (⌘↩), *always* label, Deny (⌘.) | orange; Allow, Deny, *Always allow …* |
| Accent | `Color.frog` | `Color.frog`, dark variant |
| Mascot | `FrogFace(mood:)` | the same moods; still under Reduce Motion and always-on |
| Sounds | plip / ribbit / drip | haptics, as today |

## What the link needs

| Today | Needed for |
|---|---|
| A row has `question`, `arg`, `reason`, `always`, `change` ("fetch.ts +12 −3") and `since` | done (proposals 1, 3, 4, 6 in part) |
| `decision`: allow / deny / allow_always; `submit`; `interrupt` | done |
| `activity` and `since` only | the last few step summaries: proposal 3 |
| No notification categories on the watch | `permission`, `ask` and `finished` categories with the actions above: proposal 2 |
| A tap on a permission row answers inline | the Request screen for a command too long to trust from three lines: proposal 1 |

All of these come from the Mac's `RemoteBridge`, which already has the fields (`PermissionRequest`
carries `reason`, `always` and `preview`) and the ops (`submit`, `interrupt`). Mostly they need
passing through `Snapshot.Row` and `WatchBridge`.

## Risk: the direct route on a real watch

`WatchBridge` uses `URLSessionWebSocketTask`. As I understand Apple's guidance (TN3135),
watchOS allows WebSockets and other low-level networking only for some apps, such as audio
streaming ones. Plain HTTP `URLSession` is fine everywhere. If that's right, the direct route works
in the Simulator but fails on a watch. Check on hardware before building more on it. If it fails,
the fallback is HTTP to the bridge: long-poll `list`, and POST `op`.

## Open questions

1. **Double tap = Allow?** It matches the Mac's default (⌘↩) and the HIG's primary action. But
   approving a `git push` with a gesture you can make by accident is a real risk. Options:
   - double tap only on the Request screen
   - only for steps that don't leave the sandbox
   - never
2. **Auto mode.** With Settings › Permissions › Auto on, few requests reach the watch. Show what
   Auto allowed ("Auto-allowed 3 steps") on the Reply screen?
3. **New conversation from the wrist.** Is "dictate to the most recent project" enough, or should
   it offer a short project picker?
4. **Brief.** Should the morning Brief be a Smart Stack card?
