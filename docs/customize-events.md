# Customize from the conversation: events

The agent changes what Frog knows and can do with one tool, `Customize`: remember, forget or
edit a line; turn a skill or a connection's tool on or off; read or set an app setting. This is
what the apps receive and send so they can draw it. The engine draws nothing; the card's look
is the transcript's (canvas frames N7 Remember, N9 Change).

Code: `crates/frog-engine/src/customize.rs` (tiers, parsing, line edits, undo) and
`src/engine/customize.rs` (asking and applying). Types: `protocol.rs` (`Proposal`).

## Turning it on

The model gets `Customize` only when the app declares it draws these cards:
`{"op":"set_client_caps", ..., "customize": true}`. Without it the tool isn't offered and a call
is refused, so no app is ever sent a card it can't show. Send it once the card, the receipt
with Undo and `setting_change` are drawn.

## Tiers

Every change is either:

- **apply**: changes at once; the app gets `customize_applied` with an undo handle.
- **ask**: one card (`permission_request` with a `proposal`); changes only on approval.

The tier is data, in `design/settings.json`: an `agent` key on a setting's row
(`"apply"` / `"ask"`), and `agentActions` for everything else:

| key | tier |
|---|---|
| `line.notes` (Frog's own notes) | apply |
| `line.home` (`~/.config/frog/FROG.md`) | apply |
| `line.project` (the repo's AGENTS.md, shared) | ask |
| `skill` | apply |
| `tool` (a connection's tool) | ask |

Settings marked apply: notifications, theme, density, detail, playful, sounds, show-energy.
Marked ask: money (monthly-cap, default-model), permissions (default-mode, sandbox,
computer-use, allowed-commands), sharing (share-usage, share-models, lend-battery).
**Anything without a key asks.**

Two rules sit above the tiers:

- An **offer** (the user didn't ask for this change; "Remember this?" after a correction) is
  always a card.
- **Only the user's words start a change.** Each call quotes them (`words`); the engine checks
  the quote is in what the user typed this turn. Words from a tool result, a page or a file
  are refused outright: no card, no change. The card says who asked (`asked_by`).

Ask-tier cards come up in every mode, yolo and auto included: a change to Frog's own reach is
never a classifier's call. A session with nobody to ask (headless) changes nothing.

## The card: `permission_request` with `proposal`

The same event and reply as every other approval; a `Customize` card is the one with
`proposal` set (`name` is `"Customize"`, `arg` the title, `reason` the place).

```json
{
  "type": "permission_request",
  "id": "p_81",
  "item": "call_3",
  "name": "Customize",
  "arg": "Remember this?",
  "always": "",
  "reason": "AGENTS.md in frog, shared with everyone who works in it",
  "proposal": {
    "kind": "line",
    "title": "Remember this?",
    "change": { "new": "Use pnpm, not npm" },
    "where": "AGENTS.md in frog, shared with everyone who works in it",
    "path": "/Users/cam/Developer/frog/AGENTS.md",
    "tokens_per_turn": 6,
    "primary": "Remember",
    "dismiss": "Not now",
    "alternative": {
      "id": "notes",
      "label": "Just for me",
      "where": "Frog's notes for frog, only you",
      "tokens_per_turn": 6
    },
    "asked_by": { "who": "frog", "words": "no, we use pnpm here" }
  }
}
```

Fields of `proposal`:

| field | meaning |
|---|---|
| `kind` | `line`, `skill`, `tool` or `setting` |
| `title` | "Remember this?" (an offer), "Remember this", "Forget this", "Change this line", "Turn off the deploy skill", "Turn off github › merge_pull_request", "Change Density" |
| `change` | the exact change: `old` and `new`. A line to save has only `new`; a line to forget only `old`; a setting or toggle has both (`"Comfortable"` → `"Compact"`, `"On"` → `"Off"`). `old` is absent when the app never told the engine the current value. |
| `where` | one line on where it goes |
| `path` | the file it writes, when it writes one |
| `tokens_per_turn` | estimated tokens it adds to every turn (negative: saves); absent when unknown (settings) |
| `primary` | the primary button's label |
| `dismiss` | always "Not now" |
| `alternative` | at most one other choice; today only "Just for me" on a line for a shared file |
| `asked_by.who` | `user` (they asked for this) or `frog` (Frog offered it) |
| `asked_by.words` | the user's words, quoted as they wrote them |

Reply with `Op::Permission`, as for any card:

- primary: `{"op":"permission","id":"p_81","decision":"allow"}`
- not now: `{"op":"permission","id":"p_81","decision":"deny"}`
- alternative: `{"op":"permission","id":"p_81","decision":"allow","choice":"notes"}`

`permission_resolved` follows as usual. A declined offer is never made again in that session
(the engine refuses it before any card).

## Applied: `customize_applied`

After an apply-tier change, or an approved card. Durable (replays with the transcript). The
`card` is the same shape as `proposal`, describing what was actually done (after the
alternative, `where` is the alternative's).

```json
{
  "type": "customize_applied",
  "item": "call_3",
  "undo": "u_5c1",
  "card": { "kind": "setting", "title": "Change Density",
            "change": { "old": "Comfortable", "new": "Compact" },
            "where": "Settings, on this device", "primary": "Change", "dismiss": "Not now",
            "asked_by": { "who": "user", "words": "make it compact" } }
}
```

Draw it as a one-line receipt with **Undo**. Undo sends `{"op":"undo","undo":"u_5c1"}`; the
engine answers `customize_undone`:

```json
{ "type": "customize_undone", "undo": "u_5c1", "ok": true, "message": "Undone." }
```

`ok: false` says why nothing changed: already undone, the file was edited since (undo never
clobbers; it restores exactly the bytes that were there, or nothing), or a setting whose old
value the app never reported. Undo handles last for the engine process. `Op::Undo` is queued
like other ops, so during a running turn it lands when the turn ends.

## Settings the app owns: `setting_change` and `Op::Settings`

Settings live in the apps. The engine never writes them; it tells the app:

```json
{ "type": "setting_change", "id": "density", "value": "compact" }
```

Sent on apply and on undo. Live only (never replayed), so a reconnect can't re-apply an old
change. Values are the row's option ids (`"compact"`, `"25"`), a bool for toggles, or the raw
string/number for menus without options and fields.

So `get` can answer and a card can quote the old value, the app may send its current values,
at session start and when one changes (lands at once, not queued):

```json
{ "op": "settings", "values": { "density": "comfortable", "sounds": true, "monthly-cap": "10" } }
```

## Toggles and lines

- Skill and tool toggles are kept in `customize.json` beside Frog's notes
  (`{"skills_off": [...], "tools_off": ["mcp__server__tool"]}`). Off skills leave the catalog;
  off tools leave the tool list and are refused if called.
- Lines are minimal edits: append one `- line`, remove one line, or replace one line keeping its
  indent and marker. Nothing else in the file moves (line endings included). A line that's
  already there, missing, or ambiguous is refused before any card.
- A project's rules file is the first of AGENTS.md, FROG.md, CLAUDE.md at its root, else a new
  AGENTS.md.

## Cost

`Customize` is a deferred tool in project sessions: a plain turn carries only its catalog line,
about 75 tokens (299 characters), and only when the app sent `customize: true`; otherwise nothing. The full definition (about 280 tokens: 387-character
description, 725-character schema) is sent only once the model calls or loads it. In chats and
small windows, where tools aren't deferred, the full definition rides each turn. Estimates are
four characters a token.

## Not here yet

Automations ("keep doing this", N8), catalog search, and the card's drawing.
