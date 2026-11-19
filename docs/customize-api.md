# Customize: the engine API

What the Customize pages (Skills, Connections, Rules, Memory) read from the engine and how they
change it. One snapshot, one change call, the same JSON from two ways in:

| Who | Read | Change |
| --- | --- | --- |
| Mac (like Settings → MCP today) | `frog --customize --json` in the project folder | `frog --customize-change '<change>' --json` |
| Web (over the session's socket) | op `{"op":"customize"}` | op `{"op":"customize_change","change":{…}}` |

Both answer with a **report** (below): the CLI prints it, the socket sends it as the event
`{"event":"customize","report":{…}}`. A change answers with the report as it is after the
change, so a page redraws from the answer. A change that fails answers `{"error":"…"}` on the CLI
(exit status 1), and on the socket the same `customize` event with `"error":"…"` beside the
report as things still are; nothing is half-applied.

On the socket the op is answered between steps, like any op the session's work loop takes: if
a turn is running, the answer comes when it ends. A page that must draw at once uses the CLI.

The `customize` event is a reply, not session history: it is not journaled and is never replayed.
A client that doesn't know it ignores it (`unknown` in FrogKit).

The CLI connects the MCP servers to list their tools (as `--mcp` does), so it takes as long as
the slowest server, capped at 30 s. Pass `--no-connect` for a fast first draw: connections then
come back with `state: "unknown"` and no tools, and everything else is complete.

Nothing here leaves the machine. Use counts live in `~/.local/share/frog/usage.jsonl`.

The agent can make some of the same changes from a conversation (the `Customize` tool, behind
approval); those arrive as `customize_applied` events (docs/customize-events.md). A page that is
open should re-read the snapshot when it sees one.

## Tokens

Every `tokens` is what the item adds to **every turn**, measured on the text the engine actually
puts in the prompt (the skills catalog line, the tool's schema, the memory index line, the rules
section), counted with the engine's estimator (`context::Estimator`): characters divided by
`estimate.chars_per_token`. A live session calibrates that ratio against what the provider
counted; the CLI has no session, so it uses the default 3.5 and says `calibrated: false`. Show
them as estimates ("about 820 tokens"); they are close, not exact.

Budgets that depend on the model (how much of the rules and memory fit) are the session's
model's on the socket; the CLI measures against a large model (200k window). A small-window
model (under 16k) carries no skills catalog and no connection instructions, so those weigh 0
there.

An item that is off weighs `0`. Its would-be weight is in `tokens_if_on`.

## The report

```jsonc
{
  "project": "/Users/cam/Developer/pond",        // null for a chat (no folder)
  "estimate": { "chars_per_token": 3.5, "calibrated": false },
  "tokens": 4060,                                 // all four sections, per turn
  "skills": {
    "tokens": 820,
    "budget_tokens": 1715,                        // the catalog budget (skills.rs), in tokens
    "names_only": false,                          // over budget: listed by name, no summaries
    "items": [Skill]
  },
  "connections": {
    "tokens": 2860,
    "deferred": false,                            // > 40 tools: loaded on demand, see below
    "items": [Connection]
  },
  "rules": { "tokens": 310, "files": [RulesFile] },
  "memory": { "tokens": 70, "omitted": 0, "notes": [Note] }
}
```

### Shared pieces

```jsonc
// Scope: where it applies.
"scope": "project" | "everywhere"

// Source: whose file it is. Frog reads other tools' files in place and never copies them.
"source": "frog"          // Frog's own files (~/.config/frog, .frog/)
        | "claude_code"   // ~/.claude, .claude/, ~/.claude.json
        | "agents"        // the shared .agents/ convention, AGENTS.md
        | "builtin"       // shipped inside Frog (no file)
        | "project"       // a project's own .mcp.json (connections only)

// Use: from the local use log. `days` is always 30 numbers, oldest first, the last is today
// (local time). `count` is their sum.
"use": {
  "count": 14,
  "days": [0,0,0,1,0, …, 1,1],
  "last": { "at": "2026-11-16T10:04:00-08:00", "session": "c1f…", "title": "0.7.1 notes" } | null
}
// `title` is the session's first message (up to 80 characters) when it was used; look the
// session up by `session` for its current title.
```

### Skill

```jsonc
{
  "id": "/Users/cam/Developer/pond/.frog/skills/release-notes/SKILL.md", // stable key; builtin: "frog-builtin:gh"
  "name": "release-notes",
  "description": "Write release notes in pond's house style from merged pull requests.",
  "scope": "project",
  "source": "frog",
  "path": "/Users/cam/…/SKILL.md",      // null for builtin
  "on": true,
  "tokens": 40,                          // its catalog line, per turn (0 when off)
  "tokens_if_on": 40,
  "full_tokens": 310,                    // the whole skill, paid only on the turn it's loaded
  "shadowed_by": null,                   // a project skill of the same name hides this one
  "use": Use
}
```

Every skill found is listed, including ones that are off or shadowed (a project skill shadows a
home one of the same name; the shadowed one weighs nothing and can't be switched on).

### Connection

```jsonc
{
  "name": "figma",
  "scope": "everywhere",
  "source": "frog",                      // config.toml; "project" for .mcp.json; "claude_code"
  "on": true,                            // the whole connection
  "state": "connected" | "connecting" | "needs_sign_in" | "declined" | "failed" | "off" | "unknown",
  // "declined": the person already said no to its sign-in; still offer the button.
  // "unknown": the CLI ran with --no-connect.
  "error": null,                         // one line when failed
  "waiting": null | "sign_in",           // "allow" is reserved, see Gaps
  "tokens": 2160,                        // tools that are on, plus the server's instructions
  "tokens_if_all_on": 3900,              // every tool that isn't withheld
  "instructions_tokens": 120,
  "tools": [Tool],
  "use": Use                             // all its tools together
}
```

### Tool

```jsonc
{
  "name": "get_file",
  "exposed": "mcp__figma__get_file",     // stable key
  "description": "…",
  "state": "on" | "off" | "withheld",
  "why": null,                           // withheld: what in its description read like instructions
  "read_only": true,                     // the server's readOnlyHint; null when it doesn't say
  "tokens": 180,                         // its schema, per turn (0 when off or withheld)
  "tokens_if_on": 180,
  "use": Use
}
```

When `connections.deferred` is true there are too many tools to send them all; the model gets a
search tool and loads tools as it needs them. Each tool's `tokens` is then `0` (it is not sent
until loaded), `tokens_if_on` is its size when loaded, and the search tool's own weight is in
`connections.tokens`.

### RulesFile

The project and home instruction files (FROG.md, AGENTS.md, CLAUDE.md) and the rule files in
`.frog/rules`, `.claude/rules`, `.agents/rules`.

```jsonc
{
  "path": "/Users/cam/Developer/pond/CLAUDE.md",
  "scope": "project",
  "source": "claude_code",
  "kind": "instructions" | "rule",
  "applies": "always" | "paths",         // "paths": a rule shown only when matching files come up
  "paths": [],                           // its globs, for "paths"
  "tokens": 210,                         // per turn; 0 for "paths" rules
  "full_tokens": 210,
  "lines": [ { "n": 41, "text": "Use pnpm in this project, never npm." } ]
}
```

`lines` are the file's non-blank lines as they are (frontmatter left out), numbered from 1 as in
an editor. Edit and remove name a line by `n` **and** its current `text`; if the file changed
since the page read it, the change fails rather than touching the wrong line.

`home_file` in the change below is where a new "everywhere" line goes when there is no home file
yet: `~/.config/frog/FROG.md`. A new project line goes in the first project instruction file, or
a new `FROG.md` at the project root.

### Note

```jsonc
{
  "id": "staging-db-reset-mondays",
  "scope": "project",                    // "everywhere" for a global note
  "created": "2026-11-12T09:30:00-08:00",
  "session": "c1f…" | null,              // the session it was remembered in; null for older notes
  "title": "why did my seed data vanish" | null,
  "text": "The staging database is reset every Monday; don't rely on data there.",
  "path": "/Users/cam/.local/share/frog/memory/projects/…/staging-db-reset-mondays.md",
  "cites": ["db/seed.sql"],
  "missing": [],                         // cited files that are gone
  "tokens": 18,                          // its line in the memory index (0 if omitted for space)
  "omitted": false
}
```

## Changes

```jsonc
{ "change": "skill",        "name": "release-notes", "on": false }
{ "change": "connection",   "name": "figma",     "on": false }
{ "change": "tool",         "exposed": "mcp__figma__get_file", "on": false }
{ "change": "rule_add",     "path": "<file>" | null, "scope": "project" | "everywhere", "text": "…" }
{ "change": "rule_edit",    "path": "<file>", "n": 28, "old": "<current text>", "text": "<new text>" }
{ "change": "rule_remove",  "path": "<file>", "n": 28, "old": "<current text>" }
{ "change": "memory_edit",  "id": "<note id>", "scope": "project" | "everywhere", "text": "…" }
{ "change": "memory_remove","id": "<note id>", "scope": "project" | "everywhere" }
```

On/off is Frog's own choice, kept in `~/.local/share/frog/customize.json` (the same file the
agent's `Customize` tool writes, docs/customize-events.md), never written into a Claude Code file
or a project's `.mcp.json`. A skill is switched by name: off hides every skill of that name. The snapshot reflects a change at once; a session
that receives `customize_change` applies it from its next turn, and other sessions when they
next start.

`rule_add` with `path: null` picks the file as above. Rule edits only touch files the report
listed. Memory edits redact secrets the same way `/remember` does.

## Gaps: what the mocks show that the engine can't answer yet

See the PR description for the current list.
