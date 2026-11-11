# frog

A free, open-source coding agent that runs on your own machine. [frog.toys](https://frog.toys)

```sh
curl -fsSL https://frog.toys/install.sh | sh
```

frog brings its own inference engine (`local/`, powered by [tang](https://github.com/muni-works/tang)), so it runs models on Apple Metal with nothing else to install. It also works with ollama, LM Studio, Apple's on-device model, Anthropic, OpenAI, and Frog Cloud when you want speed.

## Quickstart

```sh
cd your-repo
frog
```

The default model is `local/qwen3-4b` (Qwen3 4B, 4-bit). It runs on this machine and costs nothing; the banner at the top of every session says which model is in use and whether it's free or billed. (The Mac app starts on Apple Intelligence where the Mac has it.) Ask for something:

```
> why does `cargo test` fail? fix it.
```

frog reads the code, runs commands and edits files. Edits and unsandboxed commands ask first; **shift+tab** cycles the permission mode.

Switch models with `-m` (or `/model` inside a session):

```sh
frog -m ollama/qwen3-coder:30b       # any provider/model
frog -m apple/on-device              # Apple's on-device model (macOS 26)
frog -m anthropic/claude-sonnet-5
frog -m cloud/qwen3-coder-next       # Frog Cloud: hosted, billed per token
```

For Frog Cloud, sign in once. New accounts start with a small free credit, no card needed:

```sh
frog login                           # browser sign-in; the key goes in the Keychain
frog account                         # which model, free or billed, and which key
frog logout
```

One-shot, for scripts: `frog -p "why does the build fail?"` (add `--json` for every engine event as a JSON line). More in [docs/quickstart.md](docs/quickstart.md).

## Features

- **Local first.** Your code and prompts stay on your machine unless you pick a cloud model, and a project can deny cloud models outright.
- **Your machines as one pool.** Pair your other Macs and Linux boxes (`curl -fsSL https://frog.toys/node | sh`) and frog runs models on whichever is free: Window → Devices, or the model chip in the composer.
- **Sessions you can branch.** Every session is an append-only log that survives crashes: `frog -c` continues, `frog --sessions` lists, `frog --fork <id>@3` branches after turn 3.
- **Sandboxed shell.** Commands run under seatbelt (macOS) or bubblewrap (Linux): they can write only inside the project and caches, and can't read `~/.ssh`, `~/.aws` and other credentials.
- **Built for small models.** frog probes each local model once and picks how to call tools (native, text or grammar-constrained JSON), budgets thinking, and guards against loops.
- **Headless and pluggable.** `-p` for one-shots, `--serve` for the engine protocol, `--acp` for editors, MCP servers with [injection quarantine](docs/quarantine.md), Agent Skills, subagents, and `AGENTS.md`/`CLAUDE.md` instructions.

## Docs

- [Quickstart](docs/quickstart.md)
- [Reference](docs/reference.md): providers, Frog Cloud (sign-in, fallback, other agents), tools, permissions, sessions, memory
- [Model policy](docs/design/model-policy.md)
- [config.example.toml](config.example.toml)
- [Contributing](CONTRIBUTING.md) and [Security](SECURITY.md)

Build from source with `cargo install --path crates/frog`. An unsigned `Frog.app` may need `xattr -dr com.apple.quarantine Frog.app`.

## License

Licensed under either of [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option. Contributions are signed off under the [DCO](CONTRIBUTING.md).

frog is free and meant to be used, forked and built on, including commercially. (That's an intent, not a license term.)
