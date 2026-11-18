# One transcript: build notes

[`spec.md`](spec.md) is the source of truth. This file records what was built against it, what was
measured, and what was decided where the spec left room. Phase 1 (type, spacing and rows) is built
on the web; the Mac builds it next from the same spec, tokens and verb table.

## What the apps share

| Shared piece | File | Who reads it |
| --- | --- | --- |
| Type roles, gaps, layout | [`design/tokens.json`](../../../design/tokens.json) → `transcript` | `apps/web/src/tokens.css` (`--tx-*`, `--gap-*`), `Tokens.Transcript` in `apps/FrogKit/UI/Basics/Tokens.swift` |
| Verb table | [`verbs.json`](verbs.json) | `apps/web/src/ui/rows.ts`; the Mac's `OneLookTests` should load it next |
| Parity metrics | [`../parity/metrics.mjs`](../parity/metrics.mjs), [`../parity/diff-metrics.mjs`](../parity/diff-metrics.mjs) | Format: [`../parity/README.md`](../parity/README.md#metrics) |

### Tokens

`node design/generate.mjs` writes both files. The generator now takes a `transcript` section:

- `type`: one entry per role (`body`, `status`, `meta`, `label`), with `size`, `line`, `mono`
  (the mono size inside it) and `weight`. CSS: `--tx-<role>-size`, `-line`, `-mono`, `-weight`.
  Swift: `Tokens.Transcript.body` etc., a `Role(size:line:mono:weight:)`.
- `gap`: one entry per gap with a `comfortable` and a `compact` value. CSS: `--gap-<name>` holds
  comfortable on `:root`, and `[data-density="compact"]` swaps in compact for anything under it.
  Swift: `Tokens.Transcript.Gaps.comfortable` / `.compact`, the same shape as `TurnSpace.Scale`.
- `layout`: fixed values (column 720, prose 640, gutter 32, narrow gutter 16, hang 26, mark 18,
  plate 24, plate bleed 6, plate corner 7, prompt 540, bubble padding 8 × 14). CSS: `--tx-<name>`.
  Swift: `Tokens.Transcript.Layout.<camelName>`.

The values equal the Mac's `Tokens.Size` and `TurnSpace.Scale` today, so nothing on the Mac moves
until it reads them. `apps/web/test/transcript-tokens.test.ts` reads the Swift source and fails if
they part. The spec's footer gap is the whole distance (20 / 12). `TurnSpace.Scale.footer` (4 / 2) is the
extra on top of `block`; the test checks `footer == block + Scale.footer`. Also added, because
prose needs them and the Mac has them: `list` 7 / 6, `section` 30 / 26, `heading` 7 / 6.

The web has no density setting, so it ships comfortable. Compact is one attribute away
(`data-density="compact"` on the column) once a setting exists.

## Verb table

[`verbs.json`](verbs.json), keyed by the engine's tool name (aliases: `!` for Bash, `MultiEdit`,
`ToolSearch`). Each tool has a `live` verb, a `past` verb and an `object` format (`command`, `path`,
`pattern`, `host`, `text`, `tool`, `none`). Mono is for `command`, `path`, `pattern` and `tool` only.
The `states` entry holds the rules for failed, denied and gists. `unknown` covers tools the table
doesn't list.

### Where the two apps disagreed, and what was kept

| Case | Mac said | Web said | Kept |
| --- | --- | --- | --- |
| Grep, finished | Searched for | Searched | **Searched** (spec's list) |
| Glob | Finding / Searched for | Finding / Found | **Searching / Searched** |
| Task | Delegating / Ran an agent | Running an agent / Ran an agent | **Delegating / Delegated** (spec) |
| TodoWrite, finished | Updated the plan | Planned | **Updated the plan** (live: Planning) |
| WebSearch, live | Searching the web | Searching the web for | **Searching the web for** (the object follows) |
| WebFetch object | the host | the whole URL | **the host**; the URL is the hover and the opened body |
| Bash, finished | no verb (the command was the line) | no verb | **Ran** + the command (spec: every line has its verb) |
| A failure | "Ran …", "failed" detail | the verb + a "failed" pill | **Failed** in `warn`, no pill |
| Denied | a denied flag | a "denied" pill | **Didn't run** + object, result "you said no" |
| Unknown or MCP tool | the raw argument, no verb | "Used X" | **Called** + the tool's name ("github › list_issues"); the argument opens |
| Skill | Loading skill / Used the skill | Used Skill | **Loading skill / Loaded skill** (no row reads "Used") |
| UseFolder | Moved to | Used UseFolder | **Moving to / Moved to** |
| SetTitle | (none) | Naming / Named | **Naming / Named** |
| CodeMap, Docs, Models, McpTools | live only (Mapping, Reading docs, Listing models, Finding tools) | Used … | past added: **Mapped, Read docs, Listed models, Found tools** |
| SendMessage, Recall | (none) | Used … | **Messaged, Recalled** |
| Diagram, Present, Ask | Drew, Showed results, Asked you | Used … | **the Mac's** |
| Grep's result | counted output lines ("3 matches") | nothing | **the engine's own display** ("3 matches in 2 files"); neither app parses output |
| A gist | the gist is the line | the gist is the line | **kept**: a finished, successful step with a gist shows only the gist, in muted. A failed or denied step never shows it |

## Measurements (web, phase 1)

From [`metrics/`](metrics/) (the parity fixture, dark) and in-page checks:

| Layout | Transcript pane | Column | Gutter | Mode | Mark x | Mark on screen |
| --- | --- | --- | --- | --- | --- | --- |
| 1280 × 800, sidebar | 1010 | 720 | 32 | hang | −26 | yes |
| 1600 × 900, sidebar | 1330 | 720 | 32 | hang | −26 | yes |
| 1024 × 800, sidebar + inspector | 360 | 328 | 16 | inset | 0 (text at 26) | yes |
| 761 × 800 (narrowest desktop), sidebar + inspector | 121 | 89 | 16 | inset | 0 (text at 26) | yes |
| 375 × 812 (phone) | 375 | 343 | 16 | inset | 0 (text at 26) | yes |

At 761 with both columns open the transcript pane is squeezed to 121 points. That is the shell's
column minimums (sidebar 220, inspector), not this change. The fallback still holds there.

At 1280, every gap equals its token. Values below are measured tops in the dump; text is never cut:

- prompt (38 tall, one line: 8 + 22 + 8) → first row: **16** (`block`)
- line → line: **0**, each **24** tall (`row`)
- line → prose and prose → line: **12** (`activity`)
- paragraph → paragraph: **18** (`paragraph`)
- last row → footer: **20** (`footer`); footer **16** tall (`meta` line)
- turn → turn: **32** (`turn`)
- prose width: **640** at most (`prose`); code, cards and the ask card use 720
- first word x: **0** for every line, thought, fold, paragraph and the footer. Marks at **−26**.
  One exception: a paragraph that opens with inline code starts **4** in, inside the code's
  plate (its padding). The plate itself is on the edge.

## Captures

[`captures/`](captures/), from [`captures/capture.sh`](captures/capture.sh) against the parity gateway
(`fixture.jsonl`) and a long-prose session ([`captures/long-prose.mjs`](captures/long-prose.mjs)),
light and dark, at 1280 and 375:

- `coding-turn-*`: a finished coding turn (thought, a fold, a failed run opened, prose, an edit, a
  passing run, a two-paragraph reply, the footer)
- `failed-opened-*`: the failed step opened, the failing test named above its last lines
- `fold-opened-*`: a fold opened, the pointer on one of its steps (hover plate)
- `long-prose-*`: a long reply: 640 measure, heading, list and code gaps

## Decided beyond the spec, or not verified

See the PR for the full list. In short:

- **Gists stay the line** (see the table). A verb beside a gist would say "ran" twice.
- **Folds** count only finished steps that draw as lines. A thought line, prose, a card or a
  running step breaks a run, and so does a failed step. Boards 8 and 9 show "2 reads" folding; the
  spec says four or more, and the spec wins.
- **"Opens once"**: a failed command starts open the first time it is drawn. After that it stays as
  the person last left it, across remounts (the web replays a cached session and remounts the
  transcript right after load).
- **Results**: Read and Grep results are the engine's display without the verb it repeats ("Read 54
  lines" → "54 lines"). The spec's "lines 1 to 124" needs a line range the engine doesn't send.
- **Opened command**: the last 12 lines, "Ran in your Frog Cloud sandbox", Show all and Copy. There
  is no exit code: the protocol has none.
- **Hover actions**: commands get Copy command, edits get Show in Changes (opens the inspector on
  Changes). Run in Terminal, opening a read's file and opening a search result have no web
  equivalent yet. Actions overlay the result's end on hover, so the result reaches the edge at rest.
- **Footer**: model, Frog Cloud when it served the turn (kept from 2026-11-12), time, tokens
  written, cost. Speed moves to phase 2's stats line. Cost is written the Mac's way
  (FrogKit `Dollars.format`: "<$0.01", "$0.11", "$15"). It needs the model's prices; the parity
  gateway serves the fixture's model with list prices (`/v1/models`), and the parity web points its
  API at the gateway (`VITE_API=`).
- **The prompt's receipts** sit beside the last bubble so the block gap stays 16. At phone width
  there's no room beside it, so they show under it on tap, over the gap.
- **Thought line** reads "Thought for 1s" (the spec's settled row): the engine's `think_ms` when it
  sends one, otherwise the item's own times, as the engine's timeline and the Mac read an older
  log. Phase 2 replaces the rest of it.
- **Parity with the Mac**: on #424's fixture the web's and the Mac's 1280 dumps match, 12 rows within
  1 pt (#424 commits `diff-web-mac-1280.txt` with the Mac dump).
- **A failed read opens** to its error. A successful read has nothing to open (spec).
- **Scrolling** (a fix found while building, in `App.tsx`): the scroller's inline ref ran on every
  App render and threw the reader to the end whenever any state changed. Opening a fold or a line
  and Show in Changes all did it. The ref is now stable per session. Following is "you were at the
  end of the last render's content", and a remount of the same session keeps its place.
  Checked in the browser (fold, line, Show in Changes stay at 0; at the end, it still follows).
  No unit test: it lives in App.
- **The composer's dock** follows the column's gutter (32, or 16 in a pane under 480), so the
  composer and the transcript share edges. The phone layout keeps its 8.
- **Test runs** use the engine's shape (`tests: { runner, passed, failed, total, failed_names? }`,
  transcript-engine commit 420a7ae2). The web never computes a count.

## Phase 2 (web): the thinking row and the stats line

Built against the engine's wire shapes from #420 and #426, as the transcript manager's wire contract
gives them (`thought` on reasoning deltas, `thoughts` and `think_ms` on the finished item, the live
`output_tokens` event with `so_far`, `slow` and `cached`, and the quiet call as an ordinary
`question`). Its cases,
[`thoughts.json`](thoughts.json), are loaded by `apps/web/test/transcript-thinking.test.ts`: every
`streams` case is replayed through the reducer and the row must show each delta's `thought`
verbatim and keep it until the next.

| Piece | Where |
| --- | --- |
| Folding the wire: `thought`, `shown`, `thoughts`, `thinkMs`; `live` tokens, `pulse`, `firstOutputAt`, `askedAt` | `apps/web/src/engine/thread.ts` |
| What the row says (`liveRow`), "Thought for 31s" (`thoughtLabel`), rate and slow | `apps/web/src/ui/rows.ts` |
| The row, its stats, the outline, the settled line | `apps/web/src/ui/LiveRow.tsx` |
| The words | [`verbs.json`](verbs.json) → `live` |
| A turn streamed in real time (full, stall, think) | [`../parity/live.mjs`](../parity/live.mjs) |

### What it does

- **One row** at the end of the running turn, a line's height, its dot hung where a line's mark
  is. A card waiting on a person wins ("Waiting for you", amber, still). Then what the engine says
  it's doing (`progress`, a retry notice). Then the running steps: one shows its live verb and
  object ("Editing src/retry.rs"), several fold into a count ("Reading 3 files", or "Running 3
  steps" when they differ). Then a think. An answer writing has no row; its stats sit under the
  text. Anything else (between steps, before the first token) is "Thinking" with no thought yet.
- **A running step is the row, not a line.** It becomes a line when it finishes (board 8B).
- **The thought** is the engine's, verbatim, empty for the first 600 ms. It cross-fades (out 180 ms,
  in 240 ms, overlapping, no movement); reduced motion swaps it.
- **The dot** breathes while output arrives (the last piece within 1.5 s), holds still otherwise,
  greys when stalled, and is amber only for a card.
- **Stats**, 2 under the row in meta: time after the first second, tokens, tokens per second.
  Tokens are the engine's `output_tokens`; the hover says "so far" while `so_far` is set. The rate
  is the change in that figure over the last 4 s of the viewer's clock, never with a decimal.
  Waiting: time and "waited 6s".
- **Slow**: the stats say "Slow" while the engine's latest count carries `slow`. The web never
  works it out itself. Nothing turns orange.
- **Stalled**: no output (no streamed piece and no token count) for 10 s while thinking, and the
  row says "No output for 12s" with the dot grey and still. At 30 s the engine asks (its quiet
  call: "Keep waiting" / "Stop the turn"), drawn as a question card after the streaming think or
  answer, or after the turn when nothing has streamed (`item: ""`); the row then waits on you. A
  token withdraws it. A step or a card is never called stalled: a command can be quiet for minutes.
- **Settled**: "Thought for 31s" from `think_ms`, opening to the outline: one line per shown
  thought (twelve, then "3 more"), a line opening its paragraph, "Show all N characters" for the
  whole text in its own scrolling box with Copy. Stopped mid-think: "Stopped after 46s" (to when
  the turn ended), and the turn's own "Stopped" note isn't repeated under it.
- **Opened while live**: the outline is every line shown so far, newest twelve, newest in fg; the
  row's own thought hides.
- **It never opens itself**, and what you opened stays open across redraws (kept by item id, per
  page load). Return opens, arrows move between outline lines, Esc closes one level.

### Decided beyond the spec, or left out

- **Old logs** (no `think_ms`, no `thoughts`) read "Thought" and open straight to the full text.
  The length is never derived from the item's own times: `item_completed` comes after the whole
  reply. A short scratch thought alone between replies still folds away there, as before.
- **Hover**: time, tokens (with "so far"), first-token time (the first reasoning or text delta
  minus the turn's start), and "Read 11,900 tokens from cache" once a call has ended (`cached`). The
  total read isn't on the wire while it runs, so only the cached part shows.
- **The rail** (board 5's marks spaced by time) and **pace in the opened header** are left out of
  phase 2; the spec marks the rail optional, and the pace curve is phase 3's.
- **Parallel steps** count only the steps still running; the nouns are in `verbs.json` (`counts`).
- **Activity** (`progress`, retry notices) takes the row while it lasts, held still, in the
  engine's words.

### Measured

[`../parity/metrics/`](../parity/metrics/): on the parity fixture every phase 1 row is unchanged,
and phase 2 adds two under the ask card, the live row "Waiting for you" 16 below the card and its
stats 2 below that (`diff-p1-p2-1280.txt`). 1280 and 1600 match (`diff-p2-1280-1600.txt`).
Captures: `captures/p2-*` (`capture-p2.sh`): thinking, thinking opened, two reads at once, an
answer writing with its stats, waiting on a card, stalled ("No output for 12s"), and the engine's quiet call at 30 s.
