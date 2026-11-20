# Rules

Rules are standing instructions Frog reads on every turn: how to build and test, what to leave alone, the house style.

## Where rules live

**Instruction files.** Frog reads `AGENTS.md`, `FROG.md` and `CLAUDE.md` in the project's folder and in each folder above it. These live in your repo, so your team shares them.

**Your own rules.** `~/.config/frog/FROG.md` on your Mac applies to every project, and so does `~/.claude/CLAUDE.md`. `load_claude_md = false` in `config.toml` skips every `CLAUDE.md`.

**Rule files.** Markdown files in a project's `.frog/rules`, `.claude/rules` or `.agents/rules` folder are rules too. A rule file can apply to some files only:

```markdown
---
paths: ["migrations/**", "*.sql"]
---
Never edit a migration that has shipped. Add a new one.
```

A rule file with `paths` is shown the first time Frog reads, edits or is pointed at a matching file, once a session. One without `paths` applies on every turn, like an instruction file.

A Frog Cloud session reads the project's files: the instruction files at the repo's root and its rule folders. It has none of your own rules.

## Add a rule

Open the file and add a line. A short line works better than a paragraph:

```markdown
- Use npm in this project, never yarn or pnpm.
- Run `cargo test -p engine` before saying a change is done.
```

On your Mac, Settings › Rules lists each file's lines, and you can edit or remove a line there.

## What it costs

Instruction files ride in full on every turn. Keep them short: a 200-line file is paid for on every turn of every session in the project.

Rule files without `paths` share a budget, about 2,000, 6,000 or 16,000 characters for small, mid-size and large models. A file that doesn't fit is left out, and Frog is told how many were. A rule file with `paths` costs nothing until a matching file comes up.

On your Mac, Settings › Rules shows what each file adds to a turn.

## Turn one off

Rules have no switch. To stop one, remove its line or the file. To stop reading `CLAUDE.md` files, set `load_claude_md = false` in `config.toml`.

## Rules and memory

Both are things Frog knows on every turn, but they're kept differently.

- A **rule** is an instruction you wrote, in a file you own. It's in the repo, so the team gets it, and it wins when a note disagrees.
- A **note** in memory is a fact Frog kept for you, outside the repo, on one machine. It's background, not an order. See [Memory](https://frog.toys/docs/memory).

If the team should follow it, make it a rule. If it's about you or a passing fact, leave it as a note.

## Limits today

- Frog doesn't write a rule on its own. Changing rules from a conversation is built but switched off for now.
- The web shows which files a Frog Cloud session reads, but not what's in them.
