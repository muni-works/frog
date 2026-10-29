# premium-shell-1-5 — notes

Branch frog/premium-shell-1-5, base 31bf237 (main). Commit per numbered step (`git commit -s`),
never push (chief merges on green CI). Edit tool only for Swift. Pure SwiftUI polish: no engine,
protocol or new data deps. DerivedData /private/tmp/prem-dd, delete when suites pass.

Spec (read-only, chief repo):
/Users/cam/Developer/chief/.frog/worktrees/app-premium-redesign/design/app-premium/README.md

## Scope: spec §d rows 1, 2, 3, 4, 5, 11
1. Tokens.swift (c.0 constants as static lets); FrogCanvas dark 0.118 → 0.098.
2. Neutral prompt bubble (TurnView.swift:76-79): raised #232323, c.0 text; place indicator moves.
3. One clock: toolbar capsule (ActivityLabel elapsed) static, step rows lose clocks; LiveStatus
   in the transcript keeps the only 1Hz tick.
4. Composer: persistent hint "⏎ to send · ⌘⏎ to queue for later · esc interrupts"; QUEUED strip
   (ComposerParts.swift:65-86).
5. Per-turn footers hover-only (TurnFlow.swift:393-409), no pin on the last turn.
11. Mascot leaves the live flow (TranscriptView.swift:701-783); empty page only.

Cam's calls: (1) bubble NEUTRAL gray, place tint → subtle indicator (model picker keeps place
colors); (2) sidebar stays org-first, no sidebar work here; (3) docked inspector is future (step 10).

## Spec copy: (a) the gaps (short)
1 env provenance in title bar · 2 queue-for-later first-class · 3 nested sessions folded ·
4 one accent (place colors retire to model picker) · 5 activity as status rows, ONE clock ·
6 calm negative space (flat opaque, canvas 0.098) · 7 type ramp, few sizes · 8 model+effort one
control, per-turn footers hover-only · (9 account pill).

## Spec copy: c.0 tokens
```
canvas      #191919   (FrogCanvas dark 0.118 → 0.098)
sidebar     #141414   (opaque, one step darker)
raised      #232323   (bubbles, cards, composer field, menus)
hairline    white .065 (dividers)   .11 (field strokes, controls)
text        #ececec / .58 / .34 / .2  (primary / secondary / tertiary / quaternary)
accent      #58cc6f   running, selected, verified, send — THE accent
signal      #e5a54b   needs-you only
fail        #ff6961   failed only
type ramp   14 body · 13 secondary UI · 12.5 status rows · 11.5 meta · 10.5 small-caps labels
radii       16 field · 14 window chrome · 12 card · 16 bubble · 7 control
motion      keep Motion.swift; add ONE status pulse (2.4s breathe)
```
Rules: state color on glyphs only; numbers tabular; one shadow family (composer field).

## Spec copy: d build order (this batch)
| 1 | tokens file; FrogCanvas dark 0.098 | Motion, Palette, new Tokens | S |
| 2 | neutral prompt bubble | TurnView:76-79 | S |
| 3 | one clock: drop capsule elapsed, keep LiveStatus | ActivityViewer, ActivityLine | S |
| 4 | composer hint + QUEUED strip | ComposerView, ComposerParts:65-86 | S |
| 5 | turn footer hover-only | TurnFlow:393-409 | S |
| 11 | mascot out of live flow | TranscriptView:701-783 | S |

## Progress
- e254588 checkpoint 0
- f8b3703 step 1 — Tokens.swift: c.0 as static lets (canvas/sidebar/raised/bubble, hairline .065/.11,
  text #ececec/.58/.34/.2, accent=frog, signal #e5a54b, fail #ff6961, ramp 14/13/12.5/11.5/10.5,
  radii 16/14/12/16/7, one pulse anim); 4-component Color(light:dark:) init; FrogCanvas dark 0.118→0.098.
  Only FrogCanvas swapped (the one §d row); sidebar/field chrome stays for steps 6–8.
- 737216a step 2 — UserPrompt: neutral bubble (Tokens.bubble, radius 16, Tokens.text); dropped
  `tint` param + TurnView.promptTint + the dead `models` env read. Place colors stay in ModelLabel.
- 21479c1 step 3 — one clock: pill's ActivityLabel running branch lost TimelineView+elapsed;
  ActivityPanel header clock → finished-only; ActivityStepRow.runningClock → `streaming` dot;
  SubagentView per-agent clock dropped; ActivityLabel.elapsed() deleted. LiveStatus keeps the
  only 1Hz tick. PillProbe.clockTicks kept (reads 0; benchmark line notes it).
- 281bb93 step 4 — composer: always-on hint under the controls ("⏎ to send · ⏎ while frog works
  queues for later · ⇧⏎ new line"; busy: "⏎ to queue for later · esc interrupts"). Honest wording:
  queueing is plain Return while busy, NOT ⌘Return (ComposerTextView checks shift/option only), so
  the spec's "⌘⏎ to queue" would have lied; flag for the PM. QueuedMessages → QUEUED strip
  (small-caps tag, Tokens type, hairline, ✕ per row). Busy placeholder trimmed (hint covers it).
- 7dd1d26 step 5 — footers hover-only on macOS: `footers` = empty Set on the Mac;
  TurnFooter.pinned kept for iOS (no hover there). TurnView.pinsFooter mechanics untouched.
- ff633a9 step 11 — mascot out of the live flow: pill icons → plain symbols (ActivityLabel.icon
  simplified; playful now words-only; ActivityViewer's waiting frog + dead icon() removed);
  TypingBubble's frog column removed; Settings help text updated. FrogFace stays: EmptyTranscript,
  DropZone, Dock tile, iOS/watch/widgets, snapshot frog-faces sheet, permission card, iOS chat header.
## Tests
- App suite (local, after step 11): 349 executed, 1 failure —
  TranscriptSwitchBenchmarkTests/testSwitchTo400RowSession "ready over budget" (0.567 vs 0.25s).
  Timing flake: the same suite ran all-green 20 min earlier in this worktree; ready is a
  wall-clock poll under concurrent load; the diff touches no mount/scroll/decode path. Not blocking.
- Streaming 500-row benchmark passed on rerun; snapshot fixtures all pass; prem-snaps PNGs
  verified visually (neutral bubble, 0.098 canvas). /private/tmp/prem-dd + prem-target deleted.
## Deferrals (honest)
- iOS untouched and green: ChatView:229's `tint:` is SendButton's own param (still exists) —
  UserPrompt's iOS callers pass no tint. No iOS rebuild run in this worktree (Mac scope).
- Spec's "⌘⏎ to queue" wording dropped (real binding is Return-while-busy); PM's copy may differ.
- c.0 applied only where this batch touches; sidebar/field/window chrome keep old surfaces (6–8).
- WorkingLine/ModelLoadingStatus keep their 0.08s sweeps (progress-idiom unification is later).
- ThinkingTrace shimmer clock, sidebar/AgentRows clocks: other panes' status rows, out of scope.

