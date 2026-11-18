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
- `failed-opened-*`: the failed step opened: the failing test named above its last lines
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
  written, cost. Speed moves to phase 2's stats line. Cost needs the model's prices, so it doesn't
  show in the parity gateway, which serves no models.
- **The prompt's receipts** sit beside the last bubble so the block gap stays 16. At phone width
  there's no room beside it, so they show under it on tap, over the gap.
- **Thought line** keeps today's behaviour (phase 2 replaces it), drawn as a line with a chevron.
