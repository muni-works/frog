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

## Noted: Frog keeps a note on its own

Frog notes durable things without being asked: a correction ("no, we use pnpm"), a stated
preference, a lasting fact it read in the project. Each turn it may keep one, and the app draws
a quiet line under that turn's reply (canvas frame M2 Noted): *Noted for pond*, the sentence,
**Undo**, **Make it a rule**.

Code: `crates/frog-engine/src/noting.rs` (the tool and every check) and
`src/engine/noting.rs` (the setting, the receipt, undo, the rule).

**Turning it on.** Noting on its own runs only for a client that draws the receipt:
`{"op":"set_client_caps", ..., "notes": true}`. Without it (the CLI and TUI, and any app that
hasn't built the line yet) the `Note` tool isn't offered and a call writes nothing, so Frog never
keeps a note nobody can see or undo. Send it once the line with Undo and "Make it a rule" is
drawn. The user's `auto-note` setting is the second switch.

```json
{
  "type": "noted",
  "item": "call_7",
  "turn": 12,
  "id": "the-staging-database-is-wiped-every-monday",
  "text": "The staging database is wiped every Monday.",
  "scope": "project",
  "place": "pond",
  "source": "said",
  "undo": "note:project:9f2c4a1be03d7765:the-staging-database-is-wiped-every-monday"
}
```

| field | meaning |
| --- | --- |
| `item` | the `Note` tool call that kept it (in the turn's items; draw the line after the reply, not at the call) |
| `turn` | the turn it belongs to: draw it under that turn's reply |
| `id`, `scope` | the note, as the Customize report names it (`scope`: `project` or `everywhere`) |
| `text` | the note, one sentence, at most 160 characters |
| `place` | "Noted for **pond**": the project's folder name, or `everywhere` for a note about the user |
| `source` | `said` (the user stated it), `correction` (the user corrected Frog), `read` (Frog read it in a project file) |
| `from` | only with `read`: the file, relative to the project |
| `undo` | the handle for Undo |

Durable: it replays with the transcript, and its Undo still works after a restart.

- **Undo** sends `{"op":"undo","undo":"<handle>"}`, answered by `customize_undone` as for any
  change. It removes exactly that note, and refuses (`ok: false`) when the note was edited
  since or is already gone. The handle carries what was written, so it works from a replayed
  receipt in a new engine.
- **Make it a rule** sends `{"op":"note_to_rule","id":"<id>","scope":"project"}` (optionally
  `"where":"home"` for the user's own rules everywhere; the default is the project's rules
  file, shared). The engine shows the usual card (`permission_request` with `proposal`,
  title "Make this a rule?", primary "Add rule"); approving adds the line, removes the note,
  and emits `customize_applied`, whose Undo puts both back. Frog never writes a rule on its own.
- Turning it off (with `notes: true` sent): the app setting `auto-note` (`design/settings.json`, tier `ask`, default
  on), sent with `Op::Settings`. Off, the tool isn't offered and a call writes nothing. Without
  an app, `[memory] auto_note = false` in config.toml. Never on in subagents, sessions another
  session started, or small (Weak-tier) models, which can't do it reliably.
- "remember that …" in a message still saves a note as before (with its notice) and counts as
  the turn's one note.

What can become a note, checked in Rust after the model proposes it (anything doubtful notes
nothing):

- One short sentence, three words or more, one a turn, not a duplicate of a note already kept.
- Never a secret or personal data: keys, tokens, passwords, email addresses, phone numbers
  are refused outright, not redacted.
- Provenance: `said`/`correction` need the user's exact words from this turn (`quote`) *and*
  the note's own words must mostly be the user's, so a real quote with text from a tool result,
  page or MCP response attached is refused. `read` needs a file inside the project that Frog's
  `Read` opened this session, the note's words must be in that file, and nothing that reads
  like an instruction (imperative, or addressed to an agent) is kept. `read` notes are always
  project notes. A turn nobody typed (a wake, a session started by another) notes nothing.
- A note is always data to the model, never an instruction, framed in the prompt exactly as
  `/remember` notes are. Notes are written to the list, not the prompt, mid-session: the
  conversation already has the fact, and rebuilding the system prompt would re-prefill.

Cost: the `Note` tool rides every turn while noting is on (it can't be deferred: the model
uses it unprompted), about 176 tokens (705 characters), in the cached prefix. A turn that
answers and then only notes (or notes and suggests a next step) ends there, so noting costs no
extra model round, only the call's own output, about 40 tokens.

## Not here yet

Automations ("keep doing this", N8), catalog search, and the card's drawing.
