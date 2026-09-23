# kiln

A terminal coding agent in the style of Claude Code, built for local models.

```
cargo install --path crates/kiln
kiln                                 # interactive, default model
kiln -m ollama/qwen3-coder:30b       # any provider/model
kiln -m lmstudio/qwen3-coder-30b
kiln -m tang/mlx-community/Qwen3-4B-4bit   # kiln's own inference sidecar, no ollama needed
kiln -m apple/on-device              # Apple's on-device Foundation Model (macOS 26)
kiln -m anthropic/claude-sonnet-5
kiln -p "why does the build fail?"   # one-shot, prints to stdout
kiln -c                              # continue the last session in this dir
kiln --sessions                      # list sessions started in this dir
kiln --fork <id>@3                   # branch a session right after turn 3
kiln --sandbox                       # confine writes to this directory (bash too, on macOS)
kiln -p --json "..."                 # one-shot, every engine event as a JSON line
kiln --serve                         # speak the engine protocol over stdio
```

## Architecture

```
crates/kiln-engine   headless agent: providers, tools, sessions, the agent loop
crates/kiln          clients: TUI (tui.rs/render.rs), -p and --serve (headless.rs)
crates/kiln-bench    another client: runs task suites across models and harness settings
apps/macos           the native Mac app, another client (SwiftUI, speaks --serve)
```

The engine runs as a background task. Clients talk to it only through `kiln_engine::protocol`, which has two types:
- `Op` goes from client to engine. `Interrupt` and `Permission` take effect immediately. Every other op is queued and ends with `Event::Idle`.
- `Event` goes from engine to client.

Both types are serde-tagged, so the in-process TUI and a remote client over `--serve` see exactly the same stream:

```
→ {"op":"submit","text":"fix the failing test"}
← {"seq":3,"session":"…","created":…,"event":"turn_started","turn":1,"input":"fix the failing test"}
← {"seq":5,…,"event":"item_started","id":"t1","kind":{"type":"tool_call","name":"Bash","arg":"cargo test"}}
← {"seq":6,…,"event":"permission_request","id":"p1","item":"t1","name":"Bash","arg":"cargo test","always":"…"}
→ {"op":"permission","id":"p1","decision":"allow"}
← {"seq":8,…,"event":"item_completed","id":"t1","item":{"type":"tool_call","outcome":"ok","output":"…",…}}
← … {"event":"turn_ended","turn":1,"reason":{"type":"complete"},"usage":{…}} {"event":"status",…} {"event":"idle"}
```

The protocol follows a few rules:
- Every event is wrapped in an envelope with a `seq` that increases within a session.
- Each turn contains items, and every item goes started → delta* → completed.
- Every turn ends with `turn_ended`, whose reason is `complete`, `max_tokens`, `denied`, `cancelled` or `error`. Errors come from a closed set of types.
- `Event::is_durable()` marks which events are durable facts and which are live-only hints. Deltas, progress and status are never persisted.
- `{"op":"subscribe","after":N}` replays the session's durable events with `seq > N`, then sends `synced`. After that the stream is live.

## Sessions

Each session is an append-only JSONL log in `~/.local/share/kiln/sessions/<id>.jsonl`:

```
{"type":"header","version":1,"id":"…","cwd":"…","model":"…","created":…}
{"type":"event","env":{"seq":3,…,"event":"turn_started",…}}   ← durable protocol events
{"type":"push","message":{…}}                                    ← model history ops
{"type":"extend","blocks":[…]}
{"type":"reset","messages":[…]}                                  ← compaction
```

- **Resuming** folds the `push`, `extend` and `reset` records back into the message history and continues the `seq` numbering where it left off.
- **Durability:** records are appended as they happen, the file is fsynced at the end of each turn, and a half-written last line from a crash is ignored.
- **Crash recovery:** if a session died in the middle of a turn, resuming it gives any tool calls that never finished an "interrupted" result.
- **One writer at a time:** `flock` stops two kiln processes from writing the same session.

The engine crate has no terminal dependencies, so the compiler enforces this boundary.

## Providers

| spec | backend |
|---|---|
| `tang/<hf-repo-or-dir>` | the bundled `tang-llm` sidecar (Metal): kiln starts it on `localhost:8911` and reuses it across sessions |
| `apple/on-device` | the `kiln-apple` sidecar: Apple's on-device Foundation Model on `localhost:8912`, driven in `json` tool mode (guided generation) |
| `ollama/<model>` | ollama native `/api/chat` (sets `num_ctx` from `context_window`) |
| `lmstudio/<model>` | OpenAI-compatible, `localhost:1234/v1` |
| `llamacpp/<model>`, `mlx/<model>` | OpenAI-compatible, `localhost:8080/v1` |
| `vllm/<model>` | OpenAI-compatible, `localhost:8000/v1` |
| `openai/<model>` | OpenAI, or `OPENAI_BASE_URL` / `--base-url` |
| `anthropic/<model>` | Messages API with prompt caching |

`tang/` runs safetensors checkpoints (Qwen3 family today) from the Hugging Face cache or a directory, on [tang](https://github.com/ecto/tang)'s Metal backend. It uses the checkpoint's own chat template, reuses the KV cache for the prefix a turn shares with the previous one, and logs to `~/.local/share/kiln/tang-llm.log`. `tang/` accepts bf16 checkpoints and `mlx-community` 4-bit ones. The binary is found through `KILN_TANG_BIN`, then next to `kiln`, then on `PATH`.

`apple/` needs Apple Intelligence enabled. Build the sidecar with `swift build -c release --package-path sidecars/kiln-apple`; it's found through `KILN_APPLE_BIN`, next to `kiln`, or on `PATH`. The model has an 8k context and no native tool calling, so kiln sends tool calls as a JSON schema that runs as guided generation.

Named profiles live in `~/.config/kiln/config.toml`. See [config.example.toml](config.example.toml).

## Tools

`Bash` · `Read` · `Write` · `Edit` · `Glob` · `Grep` · `TodoWrite`

The tools behave like Claude Code's: Edit replaces an exact string that must be unique, and a file has to be Read before it can be edited, with a check that it hasn't changed since. Bash keeps its working directory between calls.

**Local-model affordances**
- **Tool-call modes.** `tool_mode` (or `--tool-mode`) can be `native`, `text`, `json` or `auto`, the default.
  - `native` uses the API's own tool calling.
  - `text` describes the tools in the system prompt and parses `<tool_call>` blocks out of the reply.
  - `json` constrains the whole reply with a grammar to `{thought, action}`, where the action is exactly one tool call with schema-checked arguments or a plain answer. It works on ollama (`format`) and OpenAI-compatible servers (`response_format`). There's always an answer branch, because forcing a tool choice hurts a model's ability to decline.
- **Profiling for `auto`.** The first time a local model is used, kiln sends four small probe requests. They check native tools, text tools, JSON mode, and whether the model answers directly when no tool is needed. The results are cached in `~/.local/share/kiln/models.json`. Together with the parameter count, they set a tier (strong, medium or weak) and pick the mode: weak models whose server supports grammars get `json`. Weaker tiers also get planning guidance in the system prompt. To profile a model on demand, run `kiln --probe -m <model>`.
- **Fallback during a session.** Under `auto`, if the model botches the format twice (writing tool calls as text in native mode, invalid argument JSON, or JSON mode not honored), kiln switches to text mode for the rest of the session and updates the cache.
- **Loop guard.** The 3rd identical tool call in a turn is refused with a nudge to change approach. The 5th ends the turn (`looping`). A turn also stops after 60 model calls (`step_limit`).
- **Forgiving argument parsing.** Numbers sent as strings and arguments sent as a JSON string are accepted. Invalid JSON is sent back to the model so it can retry.

## Context budget

Local models often run with a 32k window, and ollama silently cuts off anything that doesn't fit. So kiln checks the budget before every model call rather than reacting after an overflow:

1. **Probe the real window.** It asks the server: ollama `/api/show`, llama.cpp `/props`, LM Studio `/api/v0/models`, vLLM `max_model_len`. A configured `context_window` is lowered to fit what the server reports. If you don't configure one, ollama's window is capped at 32k, since ollama allocates memory for the whole window.
2. **Estimate the prompt.** Characters are converted to tokens using a ratio calibrated against the token counts the provider reports.
3. **Prune without an LLM call** (`context_pruned`). Past 60% of the window, it first replaces stale file reads, where the same file was read, written or edited again later. Then it trims old tool output, oldest first, down to 45%. The last 4 tool results are never touched. Pruning happens in one large step because it invalidates the provider's prompt cache.
4. **Summarize only when pruning isn't enough** (`compacted`), which is past 80% of the window and at most once per turn. The user's own messages survive verbatim, so instructions like "never touch main.rs" can't get paraphrased away. Rules in the system prompt and AGENTS.md live outside the history entirely.

Every pruning step is written to the session log, so a resumed session sees exactly the history the model saw.

## Mac app

```bash
brew install xcodegen
cd apps/macos && xcodegen generate && open Kiln.xcodeproj
```

**How it works:**
- The app is a SwiftUI client that launches the bundled `kiln --serve` and speaks the same JSON-lines protocol as every other client. [Protocol.swift](apps/macos/Kiln/Engine/Protocol.swift) mirrors `protocol.rs`.
- The protocol tests decode events captured from a real engine run, so the two sides can't drift apart.
- A build phase compiles the Rust engine and copies it into the app bundle.

**What's in the window:**
- **Outcome-first turns.** The work collapses to one line, like "Worked 42s · read 3 files · edited 1 file". While a turn runs you see a live tail of its steps and the plan checklist. Below that come the answer and a strip of the files it changed.
- **Changes inspector (⌥⌘0):** every file the session touched, with syntax-highlighted diffs.
- **Rewind** on any finished turn, and continue on a new branch; the old session is kept. **Fork** and **Copy** are there too, on hover.
  - In a git repo, every turn starts with a checkpoint of the whole working tree, pinned under `refs/kiln/`. Rewind restores it, so it also undoes what shell commands did. Your index, stash and HEAD are never touched.
  - Outside git, rewind restores the files kiln edited with Edit and Write.
- **Race.** One prompt runs as 2–4 parallel attempts, each with its own engine in its own git worktree. Every worktree starts from your current files, uncommitted changes included, and runs unattended but sandboxed to that worktree. An optional check command, like your tests, scores each attempt. You apply the one you want; the others are thrown away. The same steps are available from the CLI: `kiln --attempts N`, `--apply-attempt DIR --base COMMIT`, and `--discard-attempt DIR`.
- **Session titles** come from Apple's on-device model after the first turn.
- **Permission cards** show exactly what an edit will change before you allow it (⌘↩ to allow, ⌘. to deny).
- **Live, ANSI-colored output** from running commands.
- **Composer:** `@` file picker with fuzzy search, follow-ups queued while kiln is working, Esc to interrupt, and pickers for mode and model.
- **⌘K command palette:** sessions, models, modes, fork, compact.
- **Notifications** when a turn finishes or needs permission while you're in another app. You can Allow or Deny straight from the notification.

**Designing without a model.** `open Kiln.app --args -KilnFolder <dir> -KilnReplay <session.jsonl> -KilnReplaySpeed 4 [-KilnReplayAsk YES]` plays back a recorded session. Some fixtures live in [apps/macos/Fixtures](apps/macos/Fixtures). The snapshot tests render them through the real views into `$TMPDIR/kiln-snapshots/*.png`.

**Opening a folder from the command line:** `open Kiln.app --args -KilnFolder <path>`. Engine stderr is logged to `~/Library/Logs/Kiln/engine.log`.

## Bench

```bash
cargo run -p kiln-bench -- run -m ollama/qwen3:4b,lmstudio/qwen3-coder-30b --modes auto,native,json -r 3
cargo run -p kiln-bench -- report ~/.local/share/kiln/bench/<timestamp>/results.jsonl
```

**Tasks.** Each task lives in [bench/tasks](bench/tasks) and has two parts:
- a `task.toml` with a prompt and a shell `check` that must exit 0 to pass
- a `repo/` directory that gets copied into a fresh workspace for every run

**How runs work:**
- Runs are headless, with no permission prompts, and they're `--sandbox`ed to the workspace.
- `auto` models are profiled up front, so the one-time probe isn't counted in a timed run.

**What gets reported for each model × mode:**
- pass rate, time, model calls and tokens per solved task
- tool calls and tool errors
- how each turn ended (`complete`, `looping`, `timeout`, …)
- a per-task pass grid

**What gets saved:** every run's session log, so any failure can be replayed with `kiln -r`. Every task's check is verified to fail on the untouched repo and to pass with a reference fix.

## Permissions

`default` asks before edits and shell commands. `accept-edits` lets edits through without asking. `yolo` never asks. **shift+tab** cycles the mode. Read-only commands such as `ls`, `git status`, and `rg` run without asking, as long as they don't include pipes or redirects.

## REPL

- `/model` `/mode` `/compact` `/clear` `/context` `/todos` `/exit`
- `!cmd` runs a shell command and attaches its output to your next message
- `@path` attaches a file to your message
- alt+enter inserts a newline
- ctrl+c interrupts a turn

## Instructions

Loaded from `~/.config/kiln/KILN.md`, `~/.claude/CLAUDE.md`, and any `AGENTS.md`, `KILN.md`, or `CLAUDE.md` in the working directory and its parent directories.
