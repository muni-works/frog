# Onboarding

Spec, written 2026-09-28. Status: steps 1 and 2 built (what frog found, recent projects); the rest proposed.

frog has no onboarding screens. No welcome window, no tour, no account. The product is the onboarding: the first message gets an answer in about a second, frog notices what's already on the Mac, and it asks a question only at the moment the answer matters.

## Principles

1. **Instant first answer.** The first message works with nothing downloaded, no key and no account (Apple Intelligence, see docs/models.md).
2. **Use what's already here.** The Mac knows your projects, your Claude Code setup, your keys. frog shows what it found and uses it, instead of asking you to repeat it.
3. **Ask at the moment of need.** Notifications, the microphone, cloud, a bigger model: each is asked once, in context, when it would help, never up front.
4. **One line, not a card.** Everything onboarding says fits in a line under the question on the empty page, and goes away once it's done or dismissed.
5. **Everything is reversible.** Anything frog turns on can be turned off where it was turned on.

## The first 60 seconds

**0s: the window.** The frog blinks awake on its lily pad, "What should we work on?", and the composer, focused. Nothing else.

**2s: the first answer.** New conversations start on Apple Intelligence where the Mac has it, so the first reply takes a second or two.

**10s: what frog found.** Under the question, at most one line at a time (this one first, then the model suggestion from docs/models.md):

> Using your Claude Code setup: CLAUDE.md, 14 skills. Also found 2 MCP servers. **Use them**

- What frog already uses (your CLAUDE.md, skills, rules, a project's `.mcp.json`, provider keys in your environment) is named, so you know it's there.
- What it would add (Claude Code's own MCP servers, in `~/.claude.json`) has one button. frog records the choice (`~/.config/frog/imports.json`) and reads those servers from then on, alongside `config.toml`; it doesn't copy them, so edits in Claude Code carry over.
- The line is closed with ×, or goes away once there's nothing left to add.

**Recent projects,** as up to three chips under the question in a new chat: "kiln", "ipse", "vcad". One click starts the conversation in that folder. They come from where you've actually been working: folders of your recent frog conversations first, then frog's recent folders, then git repositories under `~/Developer` (and `~/Projects`, `~/code`, `~/src`, `~/dev`) by latest commit.

**30s: the project greeting.** A new conversation in a project opens with what frog read, from its repo map and a quick look at the project's state:

> kiln · a Rust engine and a SwiftUI app · 41k lines · 2 failing tests in frog-engine

and three starting points you can click, made from what it found (failing tests, TODOs near recent changes, "explain how it fits together").

**60s: a bigger model, when it's needed.** When a task outgrows Apple's model (a project, a long answer, a full context), frog says so once, inline:

> This needs a bigger model. **Get Qwen3 8B** (4.6 GB) or **use Claude**

It keeps going on Apple Intelligence until you pick, then switches without losing the conversation.

**Permissions, in context:**
- Notifications: the first time a task takes more than 30 seconds, "Ping you when it's done?".
- Dictation: the first time you hold the mic.
- Cloud: the per-project sheet (docs/models.md).

## After that

- **Features show up when they're relevant,** once each, next to the thing: ⌘\ the first time two conversations run at once; the changes card the first time a turn edits several files; "Make this a skill?" the first time you send a prompt close to an earlier one.
- **Trust is earned.** frog keeps each project's record ("40 edits approved as they were"), and offers the next permission mode when it's earned, reversible from the same place.
- **It gets faster the more you use it.** Warm projects (saved context, prefill while typing: roadmap bet 1) get a small mark in the sidebar.
- **Your devices join in.** A GPU box or another Mac on the network is found (Bonjour, bet 3): "mew is on your network with a 3090. Use it?". Approvals come to your iPhone as notification actions; conversations continue on another Mac through Handoff.
- **frog everywhere.** App Intents for Spotlight ("frog: fix the build in kiln"), a menu bar frog with running agents, a Dock badge when one needs you.
- **Memory you can see.** A weekly "what frog learned about kiln", editable.
- **Delight, with restraint.** The ribbit when a long task finishes, the frog looking toward the pane that's working, the seasons. All under `playfulFrog`.

## Build order

1. **What frog found.** `frog --setup --json` reports what's in use (CLAUDE.md, skills, rules, env keys) and what could be added (Claude Code's MCP servers); `frog --use-claude-mcp on|off` records the choice; the engine reads those servers when it's on. The app shows the setup line.
2. **Recent projects** as chips in a new chat.
3. **A bigger model, when it's needed.**
4. **The project greeting.**
5. Permissions in context; then the "after that" list, roughly in its order.
