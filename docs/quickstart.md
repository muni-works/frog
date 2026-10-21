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

With no model set, frog uses `tang/mlx-community/Qwen3-4B-4bit` on its own Metal engine. Set `FROG_MODEL` or `default_model` in `~/.config/frog/config.toml` to change the default.

Ask for a task in plain words:

```
> the login test is flaky. find out why and fix it.
```

- `@path` attaches a file, `!cmd` runs a command and attaches its output.
- ctrl+c interrupts a turn, alt+enter inserts a newline.
- **shift+tab** cycles permissions: `default` asks before edits and commands, `accept-edits` lets edits through, `yolo` never asks. `--auto` lets a local classifier approve the steps that plainly serve your request.

## Switching models

```sh
frog -m ollama/qwen3-coder:30b
frog -m lmstudio/qwen3-coder-30b
frog -m apple/on-device
frog -m anthropic/claude-sonnet-5
frog -m frog-api/qwen3-coder-next    # hosted; needs FROG_API_KEY
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
