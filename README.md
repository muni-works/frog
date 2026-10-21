# frog

A free, open-source terminal coding agent for local models. [frog.toys](https://frog.toys)

```sh
curl -fsSL https://frog.toys/install.sh | sh
```

frog runs on your machine by default. Its own inference engine, `tang/`, runs models on Apple Metal with nothing else to install. It also works with ollama, LM Studio, Apple's on-device model, Anthropic and OpenAI.

## Quickstart

```sh
cd your-repo
frog
```

The default model is `tang/mlx-community/Qwen3-4B-4bit` on frog's own engine. Ask for something:

```
> why does `cargo test` fail? fix it.
```

frog reads the code, runs commands and edits files. Edits and unsandboxed commands ask first; **shift+tab** cycles the permission mode.

Switch models with `-m` (or `/model` inside a session):

```sh
frog -m ollama/qwen3-coder:30b       # any provider/model
frog -m lmstudio/qwen3-coder-30b
frog -m tang/mlx-community/Qwen3-4B-4bit   # frog's own inference sidecar, no ollama needed
frog -m apple/on-device              # Apple's on-device Foundation Model (macOS 26)
frog -m anthropic/claude-sonnet-5
```

One-shot, for scripts:

```sh
frog -p "why does the build fail?"   # prints to stdout
frog -p --json "..."                 # every engine event as a JSON line
```

More in [docs/quickstart.md](docs/quickstart.md).

## Run on frog api

Local models are private and free, but slow on small machines. frog api hosts Qwen3-Coder-Next, powered by tang, for when you want speed. It is part of frog pro.

```sh
export FROG_API_KEY=...              # during the beta, get one at https://api.frog.toys/beta
frog -m frog-api/qwen3-coder-next
```

If frog api is offline or out of credit or capacity, frog says so and carries on with a local model: `FROG_FALLBACK_MODEL` if set, otherwise the default `tang/` model. `FROG_BASE_URL` points it at a different endpoint.

### Other agents

frog api is OpenAI-compatible, so other agents can use it too. Base URL
`https://api.frog.toys/v1`, model `qwen3-coder-next`, key `FROG_API_KEY` (get one at
[api.frog.toys/beta](https://api.frog.toys/beta)). Beta limits are low, and you'll get a 503 when
it's at capacity.

**opencode** (`opencode.json`)
```json
{"provider":{"frog":{"npm":"@ai-sdk/openai-compatible","name":"frog api","options":{"baseURL":"https://api.frog.toys/v1","apiKey":"{env:FROG_API_KEY}"},"models":{"qwen3-coder-next":{"name":"Qwen3-Coder-Next (frog)"}}}},"model":"frog/qwen3-coder-next"}
```

**Cline, Roo Code, Kilo Code**: Settings → API Provider: **OpenAI Compatible** → Base URL
`https://api.frog.toys/v1` → API Key: your `frog_` key → Model ID `qwen3-coder-next`. Turn on
native tool calling. Context window 32768.

**Continue** (`config.yaml`)
```yaml
models:
  - name: Qwen3-Coder-Next (frog)
    provider: openai
    model: qwen3-coder-next
    apiBase: https://api.frog.toys/v1
    apiKey: ${{ secrets.FROG_API_KEY }}
    roles: [chat, edit, apply]
```

## Features

- **Sessions you can branch.** Every session is an append-only log that survives crashes.
  ```sh
  frog -c                              # continue the last session in this dir
  frog --sessions                      # list sessions started in this dir
  frog --fork <id>@3                   # branch a session right after turn 3
  ```
- **Sandboxed shell.** Commands run under seatbelt (macOS) or bubblewrap (Linux): they can write only inside the project and caches, and can't read `~/.ssh`, `~/.aws` and other credentials. Sandboxed commands don't need to ask. `frog --sandbox` confines writes to this directory.
- **Headless.** `-p` for one-shots, `frog --serve` to speak the engine protocol over stdio, and `--acp` for editors.
- **MCP.** Connect Model Context Protocol servers from `config.toml` or the project's `.mcp.json`. `frog --mcp` lists them.
- **Injection quarantine.** MCP tools whose descriptions try to steer the model are withheld before the model sees them. See [docs/quarantine.md](docs/quarantine.md).
- **Built for small models.** frog probes each local model once and picks how to call tools (native, text or grammar-constrained JSON), budgets thinking, and guards against loops.
- Agent Skills, subagents, offline dependency docs, web fetch and search, project memory, and `AGENTS.md`/`CLAUDE.md` instructions.

## Docs

- [Quickstart](docs/quickstart.md)
- [Reference](docs/reference.md): providers, tools, permissions, sessions, memory
- [Prompt-injection quarantine](docs/quarantine.md)
- [config.example.toml](config.example.toml)
- [Contributing](CONTRIBUTING.md) and [Security](SECURITY.md)

Build from source:

```sh
cargo install --path crates/frog
```

## License

Licensed under either of [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.
Contributions are signed off under the [DCO](CONTRIBUTING.md).

frog is free and meant to be used, forked and built on, including commercially. (That's an
intent, not a license term.)
