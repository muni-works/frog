# frog

A free, open-source terminal coding agent for local models. [frog.toys](https://frog.toys)

```sh
curl -fsSL https://frog.toys/install.sh | sh
```

frog runs on your machine by default. Its own inference engine (`local/`, powered by tang) runs models on Apple Metal with nothing else to install. It also works with ollama, LM Studio, Apple's on-device model, Anthropic and OpenAI.

## Quickstart

```sh
cd your-repo
frog
```

The default model is `local/qwen3-4b` (Qwen3 4B, 4-bit) on frog's own engine. Ask for something:

```
> why does `cargo test` fail? fix it.
```

frog reads the code, runs commands and edits files. Edits and unsandboxed commands ask first; **shift+tab** cycles the permission mode.

Switch models with `-m` (or `/model` inside a session):

```sh
frog -m ollama/qwen3-coder:30b       # any provider/model
frog -m lmstudio/qwen3-coder-30b
frog -m local/qwen3-4b                # frog's own engine on this Mac, no ollama needed
frog -m apple/on-device              # Apple's on-device Foundation Model (macOS 26)
frog -m anthropic/claude-sonnet-5
```

One-shot, for scripts:

```sh
frog -p "why does the build fail?"   # prints to stdout
frog -p --json "..."                 # every engine event as a JSON line
```

More in [docs/quickstart.md](docs/quickstart.md).

## Run on frog cloud

Local models are private and free, but slow on small machines. frog cloud hosts Qwen3-Coder-Next, powered by tang, for when you want speed. Sign in at [api.frog.toys](https://api.frog.toys) with GitHub or an email link — new accounts start with a small free credit, no card needed.

```sh
export FROG_API_KEY=...              # sign in at https://api.frog.toys to get one; the app's Settings → frog cloud sign-in mints it automatically
frog -m cloud/qwen3-coder-next
```

If frog cloud is offline or out of credit or capacity, frog says so and carries on with a local model: `FROG_FALLBACK_MODEL` if set, otherwise the default `local/qwen3-4b`. `FROG_BASE_URL` points it at a different endpoint (a key saved in the app or Keychain only goes to `https://api.frog.toys`; elsewhere, only `FROG_API_KEY` is sent). `frog account` shows which key is in use. Old names (`frog-api/`, `tang/`) still work.

### Other agents

frog cloud's endpoint, frog api, is OpenAI-compatible, so other agents can use it too. Base URL
`https://api.frog.toys/v1`, model `qwen3-coder-next`, key `FROG_API_KEY` (sign in at
[api.frog.toys](https://api.frog.toys)). If it's at capacity, you'll get a 503 and frog falls
back to a local model.

**opencode** (`opencode.json`)
```json
{"provider":{"frog":{"npm":"@ai-sdk/openai-compatible","name":"frog cloud","options":{"baseURL":"https://api.frog.toys/v1","apiKey":"{env:FROG_API_KEY}"},"models":{"qwen3-coder-next":{"name":"Qwen3-Coder-Next (frog cloud)","limit":{"context":131072,"output":16384}}}}},"model":"frog/qwen3-coder-next"}
```

**Cline, Roo Code, Kilo Code**: Settings → API Provider: **OpenAI Compatible** → Base URL
`https://api.frog.toys/v1` → API Key: your `frog_` key → Model ID `qwen3-coder-next`. Turn on
native tool calling. Context window 131072.

**Continue** (`config.yaml`)
```yaml
models:
  - name: Qwen3-Coder-Next (frog cloud)
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

### The chief pattern

For running an org of sessions, the pattern is the nesting and the pins — no feature, no special
tile. Run a long-lived session in a workspace (`~/Developer/chief`, say), keep it **pinned** in
the sidebar, and have it start the others (`StartSession`): a session's row nests the sessions it
started under it, so the whole org reads as one tree with the long-lived session at the top.
Pins float above the list, and a pinned row shows what it's doing and what it's waiting on like
any other. Open two windows on the same session when you want to watch it work.

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

## macOS unsigned builds

If you download an unsigned build, you may need to remove the quarantine attribute:

```sh
xattr -dr com.apple.quarantine Frog.app
```

## License
