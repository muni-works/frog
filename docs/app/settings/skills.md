# Skills

A skill teaches Frog how to do one task your way. It is a folder with a `SKILL.md` file: a short description, then the steps.

## Where skills live

Frog looks for skills in these folders, project first:

- **In the project:** `.frog/skills`, `.agents/skills` and `.claude/skills`
- **In your home folder:** `~/.config/frog/skills`, `~/.agents/skills` and `~/.claude/skills`

Each skill is a folder of its own, such as `.frog/skills/release-notes/SKILL.md`. A project skill hides a home skill with the same name. Frog also ships two skills of its own, `gh` and `visual-loop`; a skill of yours with the same name replaces one.

A Frog Cloud session runs in a fresh copy of your repo, so it sees the project's skill folders and none from your home folder.

## Add a skill

Make a folder in one of the places above and put a `SKILL.md` in it:

```markdown
---
name: release-notes
description: Write release notes in our house style from merged pull requests.
---
1. List the pull requests merged since the last tag.
2. Group them by area. Leave out dependency bumps.
3. One line each, in the past tense.
```

`name` defaults to the folder's name. The `description` is what Frog chooses by, so say when the skill applies. A skill without a description is skipped. `disable-model-invocation: true` hides a skill from Frog entirely.

The skill can keep other files beside `SKILL.md`, such as scripts or templates. Frog reads them only when the steps call for them.

## Use one

Frog loads a skill when a task matches its description. To load one yourself, start a message with `/` and the skill's name, such as `/release-notes`.

## What it costs

Every turn carries a short list of your skills: each one's name and the start of its description, about 300 characters at most. The whole list is held to about 6,000 characters, roughly 1,700 tokens. With too many skills to describe in that space, Frog lists them by name only and searches their descriptions when it needs to.

A skill's full steps cost tokens only on the turn it's loaded. A model with a window under 16,384 tokens gets no skills at all.

On your Mac, Settings › Skills shows what each skill adds to a turn and when it was last used.

## Turn one off

On your Mac, Settings › Skills has a switch for each skill. Off, it leaves the list and can't be loaded. The switch goes by name, so it turns off every skill with that name, in every project. Frog keeps the switch in its own file (`~/.local/share/frog/customize.json`) and never edits the skill's folder.

Deleting the folder removes the skill for good.

## Skills, rules and memory

- A **skill** is steps for one kind of task, read in full only when that task comes up.
- A **rule** is a standing instruction read on every turn. See [Rules](https://frog.toys/docs/rules).
- A **note** in memory is a fact Frog keeps about you or the project. See [Memory](https://frog.toys/docs/memory).

If it should apply to everything, it's a rule. If it's a recipe for one job, it's a skill.

## Limits today

- The web shows which folders a Frog Cloud session reads, but not the skills in them, and has no switches yet.
