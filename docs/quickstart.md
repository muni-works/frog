# Quickstart

## Install

```sh
curl -fsSL https://frog.toys/install.sh | sh
```

Or from a checkout of this repo:

```sh
cargo install --path crates/frog
```

## First session

```sh
cd your-repo
frog
```

Which model frog uses, first match wins:

1. `-m provider/model`
2. `FROG_MODEL`, then `default_model` in `~/.config/frog/config.toml`
3. the last model you used (any session, any directory)
4. the first that works here: `local/qwen3-4b` (mlx-community/Qwen3-4B-4bit) on frog's own Metal engine, a model running in ollama, LM Studio, Apple Intelligence (`apple/on-device`), Frog Cloud's default if you're signed in, a model you turned on with `--enable-model`, or Anthropic when `ANTHROPIC_API_KEY` is set

`--resume` keeps the session's own model unless you pass `-m`. Local models are free; the banner says which model is in use and whether it's billed.

Ask for a task in plain words:

```
> the login test is flaky. find out why and fix it.
```

- `@path` attaches a file, `!cmd` runs a command and attaches its output.
- ctrl+c interrupts a turn, alt+enter inserts a newline.
- New sessions start in `auto`: a local classifier approves the steps that plainly serve your request and asks about the rest. A flagless `--resume` runs in `default` unless the session saved a mode.
- **shift+tab** cycles permissions: `default` asks before edits and commands, `accept-edits` lets edits through, `yolo` never asks, `auto` asks the classifier. `--mode`, `--auto`, `--accept-edits` and `--yolo` pick one at start.

## Switching models

```sh
frog -m ollama/qwen3-coder:30b
frog -m lmstudio/qwen3-coder-30b
frog -m apple/on-device
frog -m anthropic/claude-sonnet-5
frog -m cloud/qwen3-coder-next       # Frog Cloud, hosted, billed per token; `frog login` first
```

Inside a session, `/model` switches. `frog --providers` lists providers and whether each is connected. The [reference](reference.md#providers) has the full table.

## One-shot and headless

```sh
frog -p "why does the build fail?"   # answer on stdout
frog -p --json "..."                 # every engine event as a JSON line
frog --serve                         # engine protocol over stdio
```

## Coming back

```sh
frog -c                              # continue the last session here
frog --sessions                      # list this directory's sessions
frog --fork <id>@3                   # branch a session after turn 3
```

## If macOS blocks frog or tang-llm

Early builds aren't signed by Apple yet. The installer and `frog setup` download with curl, which
macOS doesn't quarantine, so this only comes up if you downloaded a binary in a browser. If macOS
says it "can't be opened", use Open Anyway in System Settings → Privacy & Security, or run:

```sh
xattr -d com.apple.quarantine ~/.local/bin/frog ~/.local/share/frog/bin/tang-llm 2>/dev/null; codesign -s - -f ~/.local/bin/frog ~/.local/share/frog/bin/tang-llm
```
