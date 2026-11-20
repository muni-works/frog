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
| `line.notes` (Frog's own notes) | ask |
| `line.home` (`~/.config/frog/FROG.md`, every project) | ask |
| `line.project` (the repo's AGENTS.md, shared) | ask |
| `skill` (turning one on loads its instructions everywhere) | ask |
| `tool` (a connection's tool) | ask |

Nothing that writes text applies without a card: Frog's notes ask too, so an edit always shows
its old and new text. Only the six cosmetic settings can apply: theme, density, detail,
playful, sounds, show-energy (`customize::COSMETIC`; the engine clamps everything else to ask,
whatever the data says, and a test keeps the two equal). Marked ask: notifications (off silences "a
session needs you"), money (monthly-cap, default-model), permissions (default-mode, sandbox,
computer-use, allowed-commands), sharing (share-usage, share-models, lend-battery), auto-note.
**Anything without a key asks.**

Rules above the tiers:

- **The engine decides who asked, not the model.** `asked_by.who` is `user` only when a
  sentence the person typed this turn names the change: the setting (and for a choice, its
  value), the skill or tool by name, or every content word of the line, polarity included
  ("never push to main" doesn't name "always push to main"). Anything short of that is an
  **offer**: always a card, made at most once, with `asked_by.who` `frog`. The model's `offer`
  flag can only make a change an offer, never the reverse.
- **Applying at once needs more.** A cosmetic setting applies without a card only when one
  typed sentence names the setting itself (a value alone isn't enough: "make it compact" is a
  card, "make the density compact" applies), for a choice its value too, for on/off the
  direction and only that one ("sounds are great" never turns sounds off; "sounds off and on"
  says neither), and no negation ("don't turn off the sounds"). The sentence must be about the
  setting and nothing else: every word is the setting's own, one of its values, a direction or
  filler ("please switch the theme to light"), and a choice names only the target value. So
  "switch from the dark theme to light" and "fix the sounds player on macOS" are cards. Never
  one the person said not now to this session: asked again, it's a card.
- **Only the user's words start a change.** The model quotes them (`words`); a quote that
  isn't, word for word, in what the person typed this turn is refused outright: no card, no
  change. A whole short reply ("y", "k", an emoji) counts when the quote is all of it. On a
  card the user asked for, `asked_by.words` is the sentence the engine found that names the
  change, never the model's quote.
- **The user's words are only what the person typed**: `Op::Submit` text (and `more` parts)
  the app marked `"typed": true`, which an app sets only for text the person typed or dictated
  in its composer (on the phone, its chat composer; the Mac's bridge forwards `typed` only from
  a paired phone that says so). Absent means false: an app's own prompts (git actions,
  onboarding, canned starts, deep links, replays of queued text, Siri and notification replies
  on the phone), a message from another
  session (`<session-message>`), a wake or what's delivered with it, a parent's message to its
  child, and the continue note are never the person's words.
- **Words that only justify a card.** A Present button's visible label (the model wrote it)
  and, on `Op::Continue`, the typed words of the turn it picks back up can make an offer a
  card, never apply a change or make `asked_by.who` `user`. A button's hidden `send` never
  counts.
- **Never in a child.** `Customize` (spec and call), noting on its own, Make it a rule and
  "remember …" are refused in a subagent and in a session another session started:
  `parent_session` (the engine's own children) or `--worker` (how the Mac starts every child;
  kept across a resume). Its "user" is an agent.

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
| `choice` | the primary action's id, always `primary`: an allow sends it back as `choice` |
| `dismiss` | always "Not now" |
| `alternative` | at most one other choice; today only "Just for me" on a line for a shared file |
| `asked_by.who` | `user` (they asked for this) or `frog` (Frog offered it) |
| `asked_by.words` | the user's words, quoted as they wrote them |

Reply with `Op::Permission`, as for any card, always naming the choice on an allow:

- primary: `{"op":"permission","id":"p_81","decision":"allow","choice":"primary"}`
- not now: `{"op":"permission","id":"p_81","decision":"deny"}`
- alternative: `{"op":"permission","id":"p_81","decision":"allow","choice":"notes"}`

An allow with no `choice`, or one that isn't on the card, changes nothing (the tool call
fails). That keeps a proposal the user's own: a delegated answer (`ResolveDelegated`, the
chief or a parent session answering through the session broker) sends a bare allow, so it
can't apply one. Brokers should still leave cards with `proposal` out of `ListApprovals`.

The apps hold the same line: a proposal is answered only with a choice the card offered, named
by the control that showed it (its primary button and that button's ⌘↩, its alternative). A
bare allow never becomes the primary, so the app sends nothing and the card stays open. Places
that don't show the change offer no Allow for a proposal: the Mac's notification (tapping it
opens that session at the card), the sidebar's card (Open only), the phone's push (no buttons, no
permission id) and the phone's list, watch and widgets (the Mac leaves the proposal out of the
rows it sends). The Mac's bridge forwards the phone's `choice` exactly.

`permission_resolved` follows once the answer is known for what it did: `allow` only when a
choice on the card was taken. An allow naming no choice is recorded `deny` with
`"outcome":"no_choice"`; a card nobody answered in time is `deny` with `"outcome":"timed_out"`
and is not the person declining (it may be offered again; the model is told nothing changed).
A declined offer is never made again in that session (the engine refuses it before any card;
declines are kept beside the session log, `<id>.declined`, so a resume keeps them),
and a declined change asked for again is a card, never applied at once. The file a line is written to must be the one the
card showed (`path`): if another rules file appears or a link changes while the card is open,
the approval is void and nothing is written.

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
clobbers; it restores exactly the bytes that were there, or nothing), a setting the user has
changed since (the app's `Op::Settings` reported a value other than the one the change set),
or a setting whose old value the app never reported. Each file is moved aside before it's
checked, so a write landing between the check and the undo is put back, never lost. A restored
file keeps the permission bits it had; if writing one file fails part-way, the files not reached
go back from aside and the ones already undone get the change's text again (all or nothing). At
start-up a top-level engine puts back any `.<name>.<id>.undo` file a crash left in the project
root, the home rules folder, Frog's notes folders or beside customize.json, never over a file
written since. Toggles, their undo and `noted-undos` are changed under an exclusive lock on
their folder, and a note's id is claimed atomically, so two sessions at once lose nothing. Undo handles last for the engine process. `Op::Undo` is queued
like other ops, so during a running turn it lands when the turn ends.

## Settings the app owns: `setting_change` and `Op::Settings`

Settings live in the apps. The engine never writes them; it tells the app:

```json
{ "type": "setting_change", "id": "density", "value": "compact" }
```

Sent on apply and on undo. Live only (never replayed), so a reconnect can't re-apply an old
change. Values are the row's option ids (`"compact"`, `"25"`), a bool for toggles, or the raw
string/number for menus without options and fields.

The app sends its values whenever a link opens (a local engine's start, a Frog Cloud link's
open) and when one changes (lands at once, not queued). **The ids it sends are the settings it
applies, and the engine plans a change only for those**: anything else is answered "can't be
changed from here: change it in Settings › <section>", with no card and no receipt, so a
receipt always means the change took effect. A `null` value declares an id applied with its
value unknown. The Mac sends its seven appearance and notification rows plus `auto-note`; the
web sends `theme`, `density` and `auto-note`.

```json
{ "op": "settings", "values": { "density": "comfortable", "sounds": true, "monthly-cap": "10" } }
```

## Toggles and lines

- Skill and tool toggles are kept in `customize.json` beside Frog's notes
  (`{"skills_off": [...], "tools_off": ["mcp__server__tool"]}`). Off skills leave the catalog;
  off tools leave the tool list and are refused if called.
- Lines are minimal edits: append one `- line`, remove one line, or replace one line keeping its
  indent and marker (`- `, `* `, or a number: `1. `, `2) `). Nothing else in the file moves (line endings included). A line that's
  already there, missing, or ambiguous is refused before any card. A rule stays a rule: no
  heading, quote, table, rule line, fence or comment, and forget/edit never match frontmatter
  or headings.
- A project's rules file is the first of AGENTS.md, FROG.md, CLAUDE.md at its root (a link
  counts, even a dangling one), else a new AGENTS.md.
- A rules file that can't be read or isn't UTF-8 is an error shown to the user, never treated
  as empty; a `customize.json` that doesn't parse is an error on write, never rewritten.
- Writes never go through a link that leaves the project (or, for home rules, the home rules
  folder), except to an existing Markdown file in the user's own home (a stow-style dotfiles
  `FROG.md`, a monorepo's `AGENTS.md -> ../AGENTS.md`), and never create a dangling link's
  target; a link inside (`CLAUDE.md` → `AGENTS.md`) is followed, and the card's `path` and
  `where` name the real file. A link anywhere else (`AGENTS.md -> ~/.ssh/authorized_keys`), a
  read-only file, or a hard-linked pair (AGENTS.md and CLAUDE.md as one file) is refused before
  any card; asked to remember a line there, the card offers it just for the person, in Frog's
  notes. Every write is a fresh temp file beside the target, renamed over it, keeping the
  file's permissions. Undo moves the file aside to check it and puts it back with a hard link,
  or where links don't work (exFAT, SMB, NFS, some FUSE drives) a copy created new: a refused
  undo never leaves the file renamed aside, and never replaces one written since.

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
  since, is already gone (so a handle works once), or isn't one Frog wrote on its own. The handle carries what was written, so it works from a replayed
  receipt in a new engine.
- **Make it a rule** sends `{"op":"note_to_rule","id":"<id>","scope":"project"}` (optionally
  `"where":"home"` for the user's own rules everywhere; the default is the project's rules
  file, shared). The engine shows the usual card (`permission_request` with `proposal`,
  title "Make this a rule?", primary "Add rule"); approving adds the line, removes the note,
  and emits `customize_applied`, whose Undo puts both back. All or nothing: the file must be
  the one the card showed, the note is removed only if it's still what the card showed, and if
  it can't be, the rule is taken back. Frog never writes a rule on its own. Refused in a child.
- Turning it off (with `notes: true` sent): the app setting `auto-note` (`design/settings.json`, tier `ask`, on in
  the apps by default), sent with `Op::Settings` on every link (the Mac's local and Frog Cloud
  links, the web's, which has the switch in Settings › Memory). Off, the tool isn't offered and
  a call writes nothing. **Not told is off**: an engine whose app never sent `auto-note` doesn't
  note on its own (config.toml's `[memory] auto_note` decides when it's set). Never on in subagents, sessions another
  session started, or small (Weak-tier) models, which can't do it reliably.
- "remember that …" (or "from now on …", "note to self: …") saves a note as before (with its
  notice) and counts as the turn's one note: only when the phrase opens a typed message
  (`"typed": true`; each `more` part is its own message), never a later sentence or a line of
  something pasted below it, and never in a child (typed there, it keeps nothing and says so
  with the notice `/remember` gets in a child). A paste is part of the typed message: the
  apps don't mark pasted spans, so this opening-only rule is what keeps a pasted document's
  "From now on …" line from becoming a note.
- **Where the slash commands work** (the one rule; each command only when the message starts
  with it and is sent alone, and never as a model turn: anything refused is a notice):
  - `/memory` and `/recall` only read: they answer in any session a person types in, a
    `--worker` child included. Never in the engine's own subagent (its messages are the model's).
  - `/remember` and `/forget` change the person's notes: only in a top-level session, and only
    from someone addressing it directly. That is text the person typed in an app's composer
    (`"typed": true`: the Mac, the web, the phone's chat composer through the Mac's bridge), or
    any message from a client they drive themselves, which never marks typed text: the terminal,
    `frog -p`, an editor over ACP (the engine's `Config::direct`). Not from `--listen` (a chat
    bridge or Siri: the sender may not be the owner), and not from an app's untyped sends to a
    session it hosts (`--serve`, `--serve-ws`): notification replies, Siri, bridged messages
    the phone didn't mark, an app's own prompts, another session's message.
- Text in a composer's field that the person didn't type stays untyped until they edit it:
  the model's next-step suggestion taken with Tab, a chip that fills the field, a
  `frog://new` link's message on the Mac (the web's local-model rows hand the draft over; the
  link never sends it, and it was typed in another app's composer, not this one), a queued
  message taken back with its "x" (keeping the flag it was queued with; the Mac and the
  phone), on the web an earlier turn taken back with Edit (the transcript doesn't record
  whether it was typed, so always untyped until edited), and on the web the last send recalled
  with the up arrow (typed or untyped as it was sent). If any untyped piece is in the field, the whole field is
  untyped until edited. Sent exactly as filled (whitespace aside), it goes without `typed`.
- A note's Undo handle works only if Frog issued it: issued handles are kept beside the notes
  (`noted-undos`, the newest 500), so Undo still works after a restart, and a handle made up
  from a note's id and hash is refused.

What can become a note, checked in Rust after the model proposes it (anything doubtful notes
nothing):

- One short sentence, three words or more, one a turn, not a duplicate of a note already kept.
- Never a secret or personal data: keys, tokens, passwords, email addresses, phone numbers
  are refused outright, not redacted.
- Provenance: `said`/`correction` need the user's exact words from this turn (`quote`, only
  what the person typed: see the user's words above) *and* the note must say what the quote
  says: nearly every content word of the note in the quote itself (one miss, or one in four
  for a long note; the free word never a day, month or number), with the quote's polarity
  kept, and every quantifier ("only", "always", "every") and number in the note also in the
  quote. A correction may end by naming what it
  replaces (", not npm"). So a real quote with text from a tool result, page, MCP response or
  another part of the message attached is refused. `read` needs a file inside the project that
  a `Read` call succeeded on this session, that Frog's Edit or Write didn't change and that
  nothing changed since the engine started (so never text the model wrote itself), and every content word, quantifier and number of the note
  must be in that file. `read` notes
  are always project notes. A turn nobody typed (a wake, a session started by another) notes
  nothing.
- Nothing that reads like an instruction (imperative, or addressed to an agent) is kept, of
  any kind: a note is a fact ("This project uses pnpm"), never an order.
- A note is always data to the model, never an instruction, framed in the prompt exactly as
  `/remember` notes are. Notes are written to the list, not the prompt, mid-session: the
  conversation already has the fact, and rebuilding the system prompt would re-prefill.

Cost: the `Note` tool rides every turn while noting is on (it can't be deferred: the model
uses it unprompted), about 179 tokens (719 characters), in the cached prefix. A turn that
answers and then only notes (or notes and suggests a next step) ends there, so noting costs no
extra model round, only the call's own output, about 40 tokens.

## Used notes: only what fits comes back

A small store rides whole, as before: while the notes fit a modest budget (about 250 / 450 / 600
tokens for small / mid / large models, so a typical 5 to 15 notes), every note is in the system
prompt and applies on every turn whatever the message's words. Nothing is chosen per turn then,
and no `used_notes` is sent.

Past that budget:

- **Standing guidance stays in the prompt**, within the same budget: corrections, and notes
  that say always, never, don't, must, avoid, prefer, instead, "without asking"… ("Never
  force-push without asking" must apply to "clean up this branch", which shares no words with
  it).
- **The rest come back per turn**: at most five that bear on the user's message and the files
  in play (named, `@`-pointed, or read this session), within about 120 / 250 / 400 tokens,
  appended to that turn's user message in a `<memory>` block framed exactly as the index is
  (background data, not instructions). A note already brought into this conversation isn't
  sent again (until compaction rewrites the history). The system prompt adds one fixed line
  saying so.

```json
{ "type": "used_notes", "turn": 13, "tokens": 94,
  "notes": [ { "id": "tests-live-in-spec-one-file-per-module", "scope": "project",
               "text": "Tests live in spec/, one file per module." },
             { "id": "the-staging-database-is-wiped-every-monday", "scope": "project",
               "text": "The staging database is wiped every Monday." } ] }
```

Durable, once per turn, only when a note came back. Draw "Used 2 notes" under that turn's reply,
with the lines (canvas frame M2). `tokens` is what the block added (0 when every note was
already in the conversation).

**How it picks: word and trigram similarity, not meaning.** Each note gets a lexical vector,
computed in the engine with no model and no download (word stems, plurals folded, plus their
character trigrams, hashed into 256 dimensions; `crates/frog-engine/src/memvec.rs`), so it
works the same on a Mac and in a Frog Cloud sandbox. A note scores by cosine against the
message plus how much of the message's words it covers; under 0.2 it doesn't come back; citing
a file in play lifts it. Notes are close when they share words or word pieces, not when they
mean the same thing, so don't describe the selection or the map as understanding meaning.
Vectors carry a `model` tag (`lexical-1`) so a neural embedder can replace them later.

Vectors live beside the notes (`.vectors.json` in each notes folder, with each note's
`last_used`), and a forgotten note is pruned from them at once. If the vectors can't be kept,
the engine falls back to the whole index within the model's budget, as before. Subagents get
the whole index.

Measured on a store of 50 notes (mid-size model):

- Before: the whole index, about 996 tokens on every call (1,464 on a large model).
- After: the 5 standing notes stay in the prompt, about 231 tokens a call, and a turn about one
  subject adds about 94 tokens, once.
- The miss rate, honestly: 20 questions written the way people ask, each of which should bring
  back one of 20 notes in a 50-note store (`memvec::miss_rate`). **8 of 20 miss (40%)**, and
  every miss shares no words with its note: "why did my seed rows vanish over the weekend" doesn't
  recall "The staging database is wiped every Monday", nor "ship the documentation update" the
  docs note, nor "the pipeline takes forever" the CI note. A miss brings nothing back: the note
  just isn't there that turn (no wrong note in its place, and standing guidance isn't subject
  to this). The fix for those is meaning, a neural embedder in the `model` slot.

## Not here yet

Automations ("keep doing this", N8), catalog search, and the card's drawing.
