# kiln

A terminal coding agent in the style of Claude Code, built for local models.

```
cargo install --path crates/kiln
kiln                                 # interactive, default model
kiln -m ollama/qwen3-coder:30b       # any provider/model
kiln -m lmstudio/qwen3-coder-30b
kiln -m anthropic/claude-sonnet-5
kiln -p "why does the build fail?"   # one-shot, prints to stdout
kiln -c                              # continue the last session in this dir
kiln --sessions                      # list sessions started in this dir
kiln --fork <id>@3                   # branch a session right after turn 3
kiln -p --json "..."                 # one-shot, every engine event as a JSON line
kiln --serve                         # speak the engine protocol over stdio
```

## Architecture

```
crates/kiln-engine   headless agent: providers, tools, sessions, the agent loop
crates/kiln          clients: TUI (tui.rs/render.rs), -p and --serve (headless.rs)
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
| `ollama/<model>` | ollama native `/api/chat` (sets `num_ctx` from `context_window`) |
| `lmstudio/<model>` | OpenAI-compatible, `localhost:1234/v1` |
| `llamacpp/<model>`, `mlx/<model>` | OpenAI-compatible, `localhost:8080/v1` |
| `vllm/<model>` | OpenAI-compatible, `localhost:8000/v1` |
| `openai/<model>` | OpenAI, or `OPENAI_BASE_URL` / `--base-url` |
| `anthropic/<model>` | Messages API with prompt caching |

Named profiles live in `~/.config/kiln/config.toml`. See [config.example.toml](config.example.toml).

## Tools

`Bash` · `Read` · `Write` · `Edit` · `Glob` · `Grep` · `TodoWrite`

The tools behave like Claude Code's: Edit replaces an exact string that must be unique, and a file has to be Read before it can be edited, with a check that it hasn't changed since. Bash keeps its working directory between calls.

**Local-model affordances**
- `tool_mode = "text"` (or `--text-tools`) describes the tools in the system prompt and parses `<tool_call>` blocks from the text. Use it with servers whose tool calling is broken.
- Even in native mode, `<tool_call>` blocks a model writes as plain text are picked up as tool calls.
- Tool arguments are accepted loosely: numbers sent as strings, arguments sent as a JSON string, and invalid JSON reported back so the model can retry.
- The footer shows context usage and tok/s. Once context passes 80% of the window, the conversation is compacted automatically.

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
