# One transcript: Mac and web

Decided with Cam on 2026-11-17 on a nine-board canvas (copied to `canvas/`). The Mac and the web
draw the same transcript: the same type, the same gaps, the same rows saying the same words. This
spec is the source of truth. Not built.

## Which board to trust

The boards were drawn over one evening and later ones overrule earlier ones.

- **Look** (type, sizes, gaps, alignment): `canvas/Type.dc.html` (board 9), then
  `canvas/Transcripts.dc.html` (board 8). Boards 1 to 7 are drawn in the system font at 13 and are
  wrong about every size. Never copy a size, font or gap from them.
- **Behaviour** (what a row says, when it changes, what opens): boards 1 to 7, as amended here.
- **Overruled, wherever a board still shows it:**
  - a "failed" pill or tag: it is a red verb (see Failure);
  - a per-test grid of squares: it is a count and the failing names (see Test runs);
  - a waterfall opened inline in the transcript: it opens in a panel (see The turn panel);
  - stats set in mono: they are in the text face;
  - the turn line coloured at rest: it is grey until hovered.
- Where this file and a board disagree, this file wins. Say so in your PR if you find one.

## Phases

Unifying the two apps is the point, so it lands first. Each phase is shippable on its own.

1. **Type, spacing and rows.** Tokens, the scale, the gaps, the left edge, tool lines, folds, the
   red verb, the footer. No engine change.
2. **The thinking row and the stats line.** The engine's thought line, the live row, the stats
   under it, hover and opening.
3. **The turn line and the turn panel.** A timeline record per turn, the line in the stats and
   footer, the panel.

## 1. Type, spacing and rows

### Tokens

Everything below goes into `design/tokens.json` and is generated into `apps/web/src/tokens.css`
and `apps/FrogKit/UI/Basics/Tokens.swift`. The apps read the tokens; neither hard-codes a size
or a gap. The Mac's `Tokens.Size` and `TurnSpace.Scale` already hold most of these values and
become generated from the JSON (or are checked against it by `TokensTests`).

| Role | Size / line | Where |
| --- | --- | --- |
| body | 14 / 22 | prose, the prompt, a card's title |
| status | 12.5 / 20 | live rows, tool lines, thoughts, the opened outline |
| meta | 11.5 / 16 | stats, the footer, counts, durations |
| label | 10.5 / 14, weight 600 | small labels (Queued, Beta) |

- Faces: IBM Plex Sans; IBM Plex Mono one step down inside the text it sits in (13 in body, 12 in
  status). Mono is only for code, paths and commands.
- Weights: 400 and 600. Nothing in a line or the stats is bold.
- Tones: `fg` for prose and the thing a line acts on, `muted` for verbs and thoughts, `faint` for
  numbers. Figures are tabular wherever they tick or stack.
- The web's transcript moves from 13/1.45 to these values. This changes the transcript only, not
  the app's base size (sidebar, menus and settings keep theirs).

### Gaps

Comfortable / compact. Compact is the Mac's existing density setting; the web gains the same
setting in phase 1 only if it is a small change, otherwise it ships comfortable and says so.

| Gap | pt | Between |
| --- | --- | --- |
| turn | 32 / 16 | turns |
| footer | 20 / 12 | the last row and the footer (block + 4 / + 2) |
| paragraph | 18 / 16 | paragraphs of prose |
| block | 16 / 10 | the prompt and the first row; prose and a card or code box |
| activity | 12 / 8 | prose and a run of lines, either way round |
| row | 24 / 22 | one line's height: its text line plus 4 / 2; lines in a run touch |
| stats | 2 | a live row and its stats line |

These are `TurnSpace.Scale`'s values. `rowGroup` (8 / 5) goes away: lines in a run touch.

### Measure and the left edge

- The column is 720 wide with a 32 gutter each side (`TurnSpace.measure`, `gutter`).
- **Prose stops at 640.** Paragraphs, lists and headings cap at 640; code, tables, diffs, cards,
  the prompt bubble (still at most 540, right-aligned) and the composer use the full 720.
- **One left edge.** A line's mark (its icon, the live dot, a fold's chevron) sits in an 18-point
  box hung 26 points into the gutter. A line's first word, a thought, the stats and prose all
  start at the column's edge. This replaces `TurnSpace.Inset.iconColumn`.
- **When the gutter is under 26** (a narrow split pane, the phone layout): marks come back
  inside the column, all text indents by 26 together, and prose still shares one edge with the
  lines. Never hang a mark off-screen or under a neighbouring pane. Measure the gutter at the
  minimum pane width on the Mac and at 375 on the web, and write the numbers in the PR.
- A line's hover plate is 24 tall with a 7 corner and bleeds 6 past the text on each side, so
  words don't move when it appears.
- **Two lines.** Every row's text starts on the left line and everything that reaches the right
  ends on the right line; marks hang in the gutter and never push text. Boxes (code, tables, cards,
  the inline visual, the error banner on the web) put their outer edge on the lines and their words
  inside their padding. **The composer is part of the column: its card's outer edge sits on the two
  lines, like a card's, and its words sit inside its padding.** Inline code that starts a line keeps
  its letters on the edge and its plate overhangs into the gutter by its own padding. A top-level
  list's marker hangs in the gutter like a line's mark, so an item's words start on the edge; a
  nested list steps in by the 22-point marker column. The turn line's drawing ends on the right
  line: its time axis ends where its last segment does.

### Lines

A finished step is one line: mark, verb, object, then its result at the right in `meta`.

- Verbs are past tense, sentence case, in `muted`: Read, Edited, Ran, Searched, Fetched,
  Delegated, Didn't run. The object is in `fg`; paths and commands in mono. One verb list for
  both apps: move the Mac's map in `Activity.swift` and the web's equivalent into one shared
  table (a JSON file under `docs/design/transcript/` that both read or are tested against), and
  update `OneLookTests` to it.
- Results: `lines 1 to 124`, `+3 −2` (a true minus, green and the existing diff red), `8
  results`, `10 of 11 · 9s`, `you said no`.
- **Folds.** Four or more finished steps in a row, with no prose between, fold into one line:
  a chevron, "12 steps", and the time. A failed step never folds. Opened, a fold lists its steps.
- **Hover** shows the plate and at most two actions for that kind (commands: Copy command, Run
  in Terminal; edits: Show in Changes; reads: opens the file; searches: opens a result).
- **Opened** (one click, or Return): a command shows its last 12 lines, exit code and where it
  ran, with Show all and Copy; an edit shows the changed lines with a little context; a search
  shows titles and sites. A read has nothing to open.
- An edit's line may carry the minimap from board 6 (a 96 by 6 strip with marks where lines
  changed) on hover and when opened. It is optional in phase 1.

### Failure

A step that failed keeps its line, changes its verb to **Failed**, and sets that one word in
`warn` (the app's existing red). The word and the colour both say it; there is no pill. A failed
command starts opened, once. This is the only red text in the transcript and the only thing that
opens itself. Update the voice rule that says error text is never red to name this exception.

### Test runs

When a command's output ends in a summary line the engine recognises, the step's result is
"10 of 11" and, opened, the failing tests are named above the output. Recognise the summary
lines of cargo test, pytest, go test, vitest and jest, each with recorded outputs as fixtures.
Anything else is a plain command. Never guess a count; no per-test picture.

### The footer

One line in `meta`, 20 below the last row: the model in `muted`, then time, tokens and cost,
each part 10 apart with no separator character (Cam, 5b76372f: metadata gets space; this was
middle dots). Phase 3 adds the turn line at
its right end. The web's `.turn-foot` and the Mac's footer become this; the web's `.turn-card`
popover is replaced by the turn panel in phase 3 and stays until then.

### Parity is measured, not eyeballed

Reuse `docs/design/parity/` (one fixture session rendered by both apps). Add a metrics dump:
each app renders the fixture at the same size and writes, for every row, its kind, its text,
the x of its first word, its top and height, and its font size. A script diffs the two dumps
and fails on any text difference or any position off by more than 1 point. The fixture gains a
fold, a failed step, a two-paragraph reply, a card that needs you and a finished footer. The
side-by-side screenshots stay, for people.

The two lines are measured too: `docs/design/parity/edges-fixture.mjs` has every kind of row,
each app dumps every element's left and right edge (`edges.mjs`, the Mac's `-FrogEdges`), and an
edge test on each app (`apps/web/test/transcript-edges.test.ts`,
`FrogTests/TranscriptEdgesTests`) fails on anything more than 0.5 pt off its line.

## 2. The thinking row and the stats line

### The thought line (engine)

The engine, not each app, turns reasoning into the line both apps show. It emits, with the
reasoning item, a `thought` string that changes at most once every 1.2 s. Rules:

1. Wait for a paragraph to finish. Never show a partial one.
2. Take its first sentence; cut at the first full stop, or at a colon that ends the line.
3. Drop lead-ins ("Let me", "I should", "Actually,", "Hmm,", "OK so") and use the sentence
   that follows if the lead-in was the whole sentence.
4. Skip the paragraph (hold the previous line) if what's left is a list item, code, mostly
   digits or symbols, or under three words.
5. Strip markdown and trailing punctuation.

The rules are illustrations. The definition is `docs/design/transcript/thoughts.json`: cases of
`{reasoning so far, expected line}` that the engine's tests run and both apps' tests load to
check they display it verbatim. Before any UI depends on it, run the filter over real reasoning
from at least DeepSeek, GLM, Qwen and one local model, and report how often the line is empty,
stale for over 10 s, or reads badly. Commit only synthetic or rewritten cases: session logs hold
private prompts.

This replaces the Mac's `ThoughtSubtitle.current` (which shows the sentence being written, and
whose tests in `VerbosityTests` expect lead-ins to show) and the web's equivalent. Delete both
and their tests' old expectations.

### The row

- A dot, the label "Thinking" in `fg`, and the thought in `muted` on one line, truncated with
  an ellipsis. Empty for the first 600 ms and until there is a line.
- The thought cross-fades: out over 180 ms, in over 240 ms, overlapping, no movement. With
  reduced motion it swaps.
- The dot breathes while tokens arrive and holds still when they don't.
- Other live work uses the same row, held still, cutting between steps: a present-tense verb
  and its object (Running, Reading, Editing, Searching, Starting, Loading, Retrying, Tidying
  context, Delegating, Waiting for you). Board 3 lists them. Parallel steps fold into a count.
- Slow (under a quarter of the model's usual rate for 5 s) is said in the stats. No tokens for
  10 s: the dot stops and greys and the row says "No output for 12s". At 30 s it offers Stop,
  through the same question a quiet child raises (#411).
- The dot is amber only when Frog is waiting on a person.
- When the answer starts the row settles to "Thought for 31s" in `muted` with a chevron.

### The stats line

Under the live row, 2 below it, in `meta`: time, tokens, tokens per second, 10 apart with no
separator character, as the footer. Time shows after
the first second. The token figure while a call is streaming is counted from what has arrived
and is replaced by the provider's number when the call ends; it must never be shown as exact
while it is a count of chunks (no decimals, and the hover says "so far"). While the answer
writes there is no row and the same stats sit under the text.

### Hover and opening

- The row is a button, live or settled. Hover: the plate and a chevron.
- One click opens the thinking as an outline: one line per shown thought, newest in `fg` while
  live. A click on a line opens that paragraph in full. At most twelve lines, then "24 more";
  the full text is one more click and scrolls in its own box.
- The outline may be drawn as the rail on board 5 (marks spaced by time, skipped paragraphs as
  small marks). Optional in phase 2.
- It never opens itself. Opening never moves what you're reading. Return opens, arrows move,
  Esc closes one level.
- Tooltips: a cut-off thought shows its full sentence; the stats spell themselves out with
  first-token time and tokens read from cache.

## 3. The turn line and the turn panel

### What the log has, and what it needs

- **Step bars exist.** Every `item_started` and `item_completed` event carries `created`, and
  `turn_ended` carries `usage.timing` (`TurnTiming`: wall, prefill, decode, think, tool, early).
  Bars for steps, thinking and writing can be drawn for any session, old ones included.
- **Waiting on a person** needs the ask and the answer to be timed items. Check; if a
  permission prompt is not an item with both times, add that.
- **The pace curve does not exist for finished turns.** Deltas are not persisted. Add one small
  record to `turn_ended`: output tokens per second in fixed buckets, at most 120 per turn
  (longer turns widen the bucket). It must fit the web's per-thread cache budget. A turn
  without it (every turn before this ships) draws the strip and no curve.

### The turn line

- At the right end of the stats line while live and of the footer at rest: 200 by 16. A strip
  along the bottom coloured by phase (thinking `frog`, tools `faint`, waiting amber, writing
  `fg`), and above it the pace curve.
- Grey at rest (`faint` and darker), so it reads as part of the numbers. On hover it takes its
  colours over 150 ms and scrubs: a hairline at the pointer and a readout of time, speed then,
  and the step under it; that step's line in the transcript gets the hover plate.
- Click a segment to scroll to its step. Click anywhere else on it to open the turn panel.
- Under 420 wide the curve goes and the strip stays. A sidebar row and a fold may carry the
  strip alone, 6 tall.

### The turn panel

- Opens over the transcript, which dims and does not reflow. Esc or a click outside closes it.
  It replaces the web's `.turn-card` popover and whatever the Mac shows on its footer today.
- Header: "This turn", the model and where it ran, the totals.
- Where the time went: thinking, tools, waiting on you, writing; tokens read and from cache.
- The waterfall: one row per step under a shared time axis with ticks, the pace curve above.
  Steps that ran together overlap in time on their own rows. A wait over 30 s is drawn as a
  short broken segment with its real length written on it.
- Select a row to see its detail beside the waterfall: output for a command, the change for an
  edit, the outline for a think. "Show in transcript" closes the panel and scrolls there.
- A live turn opens the same panel with its last bar still growing.

## What goes away

- The Mac's `ThoughtSubtitle` and its sentence-being-written behaviour; the web's thought tail.
- `TurnSpace.Inset.iconColumn` and `rowGroup`.
- Any "failed" pill; any mono stats; the web's `.turn-card` (in phase 3).
- Per-app verb maps.

## Rules for building

- Frog's own look: existing tokens only, plus the transcript tokens above. No new colours.
- Speeds are tokens per second; costs are dollars; the cloud is Frog Cloud. Sentence case.
- A test written to catch a bug is shown to fail without the fix.
- Mac tests run in the background and never take the screen.
- Draft PRs. No auto-merge and no admin merge: this is the largest change to the transcript
  yet, and each phase gets its CI and a hands-on look before it lands.
