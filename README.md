# frog

**No caps. Your machines. One agent.** [frog.toys](https://frog.toys)

A free, open-source coding agent. Frog owns the whole path: the agent, the inference engine
([tang](https://github.com/muni-works/tang)) and the route to your hardware. Run as many agents as
your machines can hold, with no rate limits. When you want more, Frog Cloud is billed by the token.

```sh
curl -fsSL https://frog.toys/install.sh | sh
```

- **Every frog is a node.** Pair another Mac or a Linux GPU box with a 6-digit code and it joins
  one pool. The composer chip and the map show where the model runs; if a machine drops out
  mid-turn, the turn finishes on another one.
- **No caps, measured.** Qwen3-8B on this Mac + a Linux box with an RTX 3090: 41 passed runs in
  15 minutes vs 21 on the box alone, zero rate-limit errors. Not every task got faster; the
  numbers and the caveats are in [docs/no-caps-bench.md](docs/no-caps-bench.md).
- **Bring any model.** Besides its own engine, frog works with ollama, LM Studio, Apple's
  on-device model, Anthropic, OpenAI and Frog Cloud.

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
- **Your machines as one pool.** On a Linux box, `curl -fsSL https://frog.toys/node | sh`; on a Mac, Settings › Lend. Type the node's 6-digit code once. A scheduler sends each call to the machine that will finish it first, and the picker can load a model onto a paired node.
- **Sessions you can branch.** Every session is an append-only log that survives crashes: `frog -c` continues, `frog --sessions` lists, `frog --fork <id>@3` branches after turn 3. Parallel work runs as child sessions, which `frog --sessions` draws as a tree.
- **Sandboxed shell.** Commands run under seatbelt (macOS) or bubblewrap (Linux): they can write only inside the project and caches, and can't read `~/.ssh`, `~/.aws` and other credentials.
- **Built for small models.** frog probes each local model once and picks how to call tools (native, text or grammar-constrained JSON), budgets thinking, and guards against loops.
- **Headless and pluggable.** `-p` for one-shots, `--serve` for the engine protocol, `--acp` for editors, MCP servers with [injection quarantine](docs/quarantine.md), Agent Skills, subagents, and `AGENTS.md`/`CLAUDE.md` instructions.

## Docs

- [Quickstart](docs/quickstart.md)
- [Reference](docs/reference.md): providers, Frog Cloud (sign-in, fallback, other agents), tools, permissions, sessions, memory
- [Model policy](docs/design/model-policy.md)
- [config.example.toml](config.example.toml)
- [Contributing](CONTRIBUTING.md) and [Security](SECURITY.md)

Build from source with `cargo install --path crates/frog`.

## License

Licensed under either of [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option. Contributions are signed off under the [DCO](CONTRIBUTING.md).

frog is free and meant to be used, forked and built on, including commercially. (That's an intent, not a license term.)
