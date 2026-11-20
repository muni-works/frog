# Memory and FROG.md

## Instructions

Frog reads instruction files at the start of a session: `AGENTS.md`, `FROG.md` and `CLAUDE.md` in the project's folder and the folders above it. Put what Frog should always know about the project there: how to build and test, what to leave alone, the house style.

<!-- only: mac, terminal -->
Frog also reads `~/.config/frog/FROG.md` and `~/.claude/CLAUDE.md` for instructions that apply everywhere. `load_claude_md = false` in `config.toml` skips the `CLAUDE.md` files.
<!-- end -->

## Notes

`/remember` followed by a note keeps it. A message that starts with "remember that" or "from now on" keeps a note too, and Frog says it did. The phrase has to open the message. `/memory` lists the notes and `/forget` deletes one, by its id or its text.

Each session starts with a short index of your notes, marked as possibly out of date. Obvious secrets, such as API keys, tokens and passwords, are taken out before a note is saved.

<!-- only: web -->
Each web session runs in its own sandbox, so don't count on a note carrying over to another session.
<!-- end -->

<!-- only: mac, terminal -->
Notes are kept for the project. They are markdown files under `~/.local/share/frog/memory/`, one folder for each project and one for notes that apply everywhere. `/remember --global` keeps a note for every project. You can edit the files by hand.
<!-- end -->
