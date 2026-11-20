# Memory

Memory is the notes Frog keeps about you and your projects: short facts you asked it to remember.

## Keep a note

- `/remember` followed by the note keeps it for this project. `/remember --global` keeps it for every project.
- A message that opens with "remember that", "remember:", "note to self" or "from now on" keeps the rest of that line as a note, and the turn still runs. The phrase has to start the message, so a line in something you pasted doesn't count.

Frog says when it kept a note. Obvious secrets, such as API keys, tokens and passwords, are taken out before a note is saved.

`/memory` lists your notes. `/forget` deletes one, by its id or its text.

## Where notes live

On your Mac, each note is a markdown file under `~/.local/share/frog/memory/`: `projects/` has a folder for each project, shared by its worktrees, and `global/` holds notes for every project. You can edit the files by hand. Nothing goes into your repo, and nothing leaves the machine.

A Frog Cloud session starts in a fresh sandbox each time, so a note kept there doesn't carry over to the next session.

## What comes back on a turn

While your notes fit a small budget (about 250, 450 or 600 tokens for small, mid-size and large models, typically 5 to 15 notes), every note rides on every turn.

Past that:

- Notes that guide how Frog works, ones that say always, never, don't, prefer or instead, stay on every turn, within the same budget.
- The rest come back only on turns they fit: at most five, within about 120, 250 or 400 tokens, added to your message once a conversation.

Frog picks those by shared words, not meaning. "Why did my seed rows vanish" doesn't bring back "The staging database is wiped every Monday", because they share no words. A note your whole team should follow fits better as a rule.

## What it costs

Up to the budget above on every turn, plus a few notes on turns they fit. On your Mac, Settings › Memory shows what each note adds and which notes the last turn used.

## Turn it off

Memory has no off switch. Forget the notes you don't want, with `/forget` or from Settings › Memory on your Mac, or delete their files.

## Memory and rules

- A **note** is a fact Frog keeps for you, outside the repo, on one machine. It's background data, not an instruction, and may be out of date.
- A **rule** is an instruction you wrote in a file, usually in the repo, so your team shares it. When a note and a rule disagree, the rule wins. See [Rules](https://frog.toys/docs/rules).

## Limits today

- Frog keeps a note only when you ask. Noting things on its own is built but switched off for now, so Settings › Memory's switch for it does nothing yet.
- Picking notes by shared words misses notes worded differently from your message.
- Notes don't sync between your Mac and Frog Cloud.
