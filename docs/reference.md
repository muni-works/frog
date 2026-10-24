# Reference

The details behind the [README](../README.md).

## Sessions

Each session is an append-only JSONL log in `~/.local/share/frog/sessions/<id>.jsonl`:

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
- **One writer at a time:** `flock` stops two frog processes from writing the same session.

The engine crate has no terminal dependencies, so the compiler enforces this boundary.

## Providers

| spec | backend |
|---|---|
| `local/<model>` | This Mac: the bundled `tang-llm` sidecar (Metal). `local/qwen3-4b` and `local/qwen3-32b` are short for `mlx-community/Qwen3-4B-4bit` and `-32B-4bit`; any HF repo or directory works. frog starts it on `localhost:8911` and reuses it across sessions |
| `apple/on-device` | the `frog-apple` sidecar: Apple's on-device Foundation Model on `localhost:8912`, driven in `json` tool mode (guided generation) |
| `ollama/<model>` | ollama native `/api/chat` (sets `num_ctx` from `context_window`) |
| `lmstudio/<model>` | OpenAI-compatible, `localhost:1234/v1` |
| `llamacpp/<model>`, `mlx/<model>` | OpenAI-compatible, `localhost:8080/v1` |
| `vllm/<model>` | OpenAI-compatible, `localhost:8000/v1` |
| `openai/<model>` | OpenAI, or `OPENAI_BASE_URL` / `--base-url` |
| `anthropic/<model>` | Messages API with prompt caching |
| `cloud/<model>` | frog cloud, hosted (`FROG_API_KEY` or a saved key; `FROG_BASE_URL` overrides `https://api.frog.toys/v1`, and then only `FROG_API_KEY` is sent) |

Old provider ids still work as input: `tang/` means `local/`; `frog-api/`, `frog/`, `tang-cloud/` and `zest/` mean `cloud/`. A bare model id resolves when only one provider has it (`frog -m qwen3-coder-next`). Providers are listed This Mac first, then your servers, then frog cloud, then other clouds (`--providers --json` carries `rank` and `pinned`). `frog account [--json]` shows frog cloud's key source and base URL without touching the network.

`local/` runs safetensors checkpoints (Qwen3 family today) from the Hugging Face cache or a directory, on [tang](https://github.com/muni-works/tang)'s Metal backend. It uses the checkpoint's own chat template, reuses the KV cache for the prefix a turn shares with the previous one, and logs to `~/.local/share/frog/tang-llm.log`. `local/` accepts bf16 checkpoints and `mlx-community` 4-bit ones. The binary is found through `FROG_TANG_BIN`, then next to `frog`, then on `PATH`.

`apple/` needs Apple Intelligence enabled. Build the sidecar with `swift build -c release --package-path sidecars/frog-apple`; it's found through `FROG_APPLE_BIN`, next to `frog`, or on `PATH`. The model has an 8k context and no native tool calling, so frog sends tool calls as a JSON schema that runs as guided generation.

Named profiles live in `~/.config/frog/config.toml`. See [config.example.toml](../config.example.toml).

## Tools

`Bash` · `Read` · `Write` · `Edit` · `Glob` · `Grep` · `TodoWrite` · `Image` · `Screenshot` · `Compare` · `Diagram` · `Present` · `Ask` · `CodeMap` · `Docs` · `WebFetch` · `WebSearch`

The tools behave like Claude Code's: Edit replaces an exact string that must be unique, and a file has to be Read before it can be edited, with a check that it hasn't changed since. Bash keeps its working directory between calls.

**Showing and asking.** Two tools put structure in front of the user instead of prose:
- `Present` shows typed blocks: `table`, `compare` (side by side), `steps`, `callout`, `diagram`, `chart` (bar or line), `stats` (headline numbers) and `actions` (buttons; a press sends `Op::Act`, which runs the next turn). Each block is validated on its own, so a bad one is dropped and the model is told which to fix. Blocks stream: each one is previewed (`Event::PresentPreview`) as soon as its arguments close. The terminal draws them as text; `--serve` clients get the typed blocks. Weak models only get tables, callouts and stats, and small windows don't get the tool.
- `Ask` puts a question with 2-4 options to the user and waits (`question` event, answered with `{"op":"answer","id":…,"choices":[…],"other":…}`). The user can type their own answer or skip. It's only offered when a client says someone can answer (`set_client_caps` with `ask: true`; the TUI does), never in `-p` or to subagents, and an interrupt dismisses it.

**Local-model affordances**
- **Tool-call modes.** `tool_mode` (or `--tool-mode`) can be `native`, `text`, `json` or `auto`, the default.
  - `native` uses the API's own tool calling.
  - `text` describes the tools in the system prompt and parses `<tool_call>` blocks out of the reply.
  - `json` constrains the whole reply with a grammar to `{thought, action}`, where the action is exactly one tool call with schema-checked arguments or a plain answer. It works on ollama (`format`) and OpenAI-compatible servers (`response_format`). There's always an answer branch, because forcing a tool choice hurts a model's ability to decline.
- **Profiling for `auto`.** The first time a local model is used, frog sends four small probe requests. They check native tools, text tools, JSON mode, and whether the model answers directly when no tool is needed. The results are cached in `~/.local/share/frog/models.json`. Together with the parameter count, they set a tier (strong, medium or weak) and pick the mode: weak models whose server supports grammars get `json`. Weaker tiers also get planning guidance in the system prompt. To profile a model on demand, run `frog --probe -m <model>`.
- **Fallback during a session.** Under `auto`, if the model botches the format twice (writing tool calls as text in native mode, invalid argument JSON, or JSON mode not honored), frog switches to text mode for the rest of the session and updates the cache.
- **Thinking budget.** Reasoning is most of what a small local model generates. With `thinking = "auto"` (the default; set it globally or per model), frog lets the model think on the first call of a turn, after reading, and after an error or a failed command, and switches thinking off for routine follow-ups: after an edit, a write, a successful command or a todo update, for at most 3 calls in a row. Compaction summaries and auto mode's classifier don't think either. It only applies to models that pass a probe for answering without thinking (hybrid Qwen3 does; reasoning-only models such as Qwen3-2507-Thinking don't), and it's sent as `think` to ollama and `chat_template_kwargs.enable_thinking` to OpenAI-compatible servers. `always` leaves the model alone; `never` switches thinking off on every call. Where the model does think, `thinking_budget` (default 1024 tokens, doubled on a turn's first call; 0 is unlimited; global or per model) caps the reasoning: servers that take it (tang-llm, which lists the `thinking_budget` capability) close the thinking block after that many tokens and make the model answer. Session logs mark the calls that ran without thinking (`no_think`) and the budget each call was sent (`think_budget`), and `scripts/time_split.py` compares them.
- **Loop guard.** The 3rd identical tool call in a turn is refused with a nudge to change approach. The 5th ends the turn (`looping`). A turn also stops after 60 model calls (`step_limit`).
- **Forgiving argument parsing.** Numbers sent as strings and arguments sent as a JSON string are accepted. Invalid JSON is sent back to the model so it can retry.

**MCP servers.** frog connects to Model Context Protocol servers over stdio or streamable HTTP. It reads them from `config.toml` and from the project's `.mcp.json` (Claude Code's format), and `config.toml` wins when both name the same server:

```toml
[mcp_servers.github]
command = "npx"
args = ["-y", "@modelcontextprotocol/server-github"]
env = { GITHUB_TOKEN = "${GITHUB_TOKEN}" }

[mcp_servers.docs]
url = "https://example.com/mcp"
headers = { Authorization = "Bearer ${DOCS_TOKEN}" }
```

- Their tools appear as `mcp__<server>__<tool>`, and every call asks permission.
- If a tool's description looks like prompt injection or hides Unicode, frog quarantines it and the model never sees it. Set `trust = true` on a server to skip this check. See [quarantine.md](quarantine.md).
- `frog --mcp` lists each server's status, its tools and anything quarantined.
- **Big servers:** past 40 tools, frog loads tools on demand instead of sending every schema. It starts with the tools the server's own instructions mention. The model finds the rest with `McpTools` (keywords, or `select:name,name`).
- **Richer servers:** frog follows tool-list changes mid-session and shows progress on running calls. It also answers roots requests.
- MCP is opt-in. Bash alone is often cheaper.

**Agent Skills.** frog loads [Agent Skills](https://agentskills.io) (a folder with a `SKILL.md`) from these places:
- **In the project:** `.frog/skills`, `.agents/skills` and `.claude/skills`.
- **In your home folder:** `~/.config/frog/skills`, `~/.agents/skills` and `~/.claude/skills`.

A project skill wins over a user skill with the same name.

The skills load in stages:
- **Catalog:** the model sees a short list of skills, cut to fit a small token budget. With many skills it's names only, and the model searches their descriptions.
- **Loading one:** when a task matches, the model loads the skill's instructions with `Skill`. These are kept when old tool output is trimmed to save context.
- **Extra files:** the skill's other files (scripts, references) are listed but only read if the instructions call for them.

Starting a message with `/skill-name` loads that skill directly. `frog --skills` lists what a folder sees.

**Subagents.** `Task` hands a self-contained investigation to a subagent: a child engine with its own context and read-only tools (Read, Grep, Glob, CodeMap).
- Only its final report comes back, so a search through many files costs the parent a few hundred tokens.
- Its steps stream live into the parent's tool card.
- Interrupting the parent stops the child.

**IRC bus.** `Irc` reads and posts on the agent bus (see docs/design/agent-bus-irc.md), one IRC channel per team, one nick per session. Off by default — a client only declares it (`set_client_caps` with `irc: true`) when `[irc] enabled = true` in `config.toml`, which stays off until the frog cloud bus deploys.
- `read` returns lines newer than the session's read marker, capped, each wrapped untrusted: peer data, no user authority, no approvals. `post` sends to the team channel or a DM, up to 4 KB (`draft/multiline`); longer content is a link.
- The engine bridges the bus: it posts only minimal notices (waiting on cam, errored, idle), and a mention of a session's nick or a DM routes to that session's inbox — `Op::Deliver`, the SendMessage contract, delivered at the next turn boundary, never an interrupt.
- Approvals never happen over IRC: a permission card becomes one notice line with a `frog://` link to the app. No secrets ever post: key-shaped text is refused (notices are redacted), and the SASL token is looked up by account name in the Keychain or `FROG_IRC_TOKEN`, never written down or logged.

**Docs.** `Docs` answers "how does this API work" from the dependencies the project actually has installed, at their exact versions, offline. The model is told to try it before the web.
- **Rust:** the version in `Cargo.lock`, read from `~/.cargo/registry/src` (README, `//!` module docs, `///` item docs with signatures).
- **JS/TS:** `node_modules/<pkg>` (README and `.d.ts` files, or `@types/<pkg>`).
- **Python:** the project's `.venv`/`venv` site-packages, else the system `python3`'s (run isolated, so no project code runs): docstrings and the package description.
- `package` alone gives the overview; add `query` for matching items with `file:line`; `query` alone searches the direct dependencies. Ranking is grep-like, with no model calls. Only offered with a project folder.

**Web.** `WebFetch` reads an http(s) page as markdown. It keeps the page's `<main>`/`<article>` and drops navigation, scripts and media. With a `query` it returns only the matching sections, so an 8k-context model isn't flooded. Pages are cached for 15 minutes per session. `WebSearch` returns title, URL and snippet lines from the backend you configure:

```toml
web_search = "searxng"                  # or "brave", "exa", "tavily"
searxng_url = "http://localhost:8888"   # SearXNG's JSON API (/search?format=json)
```

- **Keys:** `echo $KEY | frog --set-key brave` (or `exa`, `tavily`) stores one in the Keychain. `BRAVE_SEARCH_API_KEY`, `EXA_API_KEY` and `TAVILY_API_KEY` work too. With no `web_search` set, frog uses `searxng_url` or a key found in the environment. With nothing configured, `WebSearch` isn't offered.
- **Untrusted content:** results come back wrapped as untrusted data, and the model is told not to follow instructions in them.
- **Private addresses:** `WebFetch` only reaches public addresses. Loopback, RFC 1918, CGNAT (100.64/10), link-local, ULA and other special ranges are refused. Every address a name resolves to is checked when connecting, which covers redirects and DNS rebinding. Set `web_allow_private = true` to reach your LAN or localhost.
- **Permissions:** the web tools work in plain chats too. They don't ask in `default`/`accept-edits` mode, just as reads and sandboxed commands (which can already reach the network) don't, and each fetch shows its URL on the tool card. In auto mode the classifier sees the URL or query first, and "always allow" is per host.

**Computer use.** Turn it on with `computer_use = true` in `config.toml`, `--computer-use`. frog then starts the bundled `frog-desktop` MCP server.
- **How it sees:** it reads an app's window through Accessibility as a list of indexed elements, and shows you a screenshot.
- **How it acts:** it presses and types into elements by index, which usually works without taking over your screen. Coordinates and keystrokes are the fallback.
- **Checking its work:** every action returns the refreshed list and how much changed, so the model can tell whether it worked.
- **Guardrails:** every action asks permission, and it never types into password fields.

## Permissions

`default` asks before edits and shell commands. `accept-edits` lets edits through without asking. `yolo` never asks. **shift+tab** cycles the mode. Read-only commands such as `ls`, `git status`, and `rg` run without asking, as long as they don't include pipes or redirects.


**Auto mode.** `--auto`, or `/mode auto` in the terminal. Every step that would otherwise ask goes to a local classifier first.
- **Edits:** in-project edits run without asking, since they're checkpointed and can be undone. Sandboxed commands already run without asking.
- **Always asks:** hard rules, no model involved: `sudo`, pushes, `reset --hard`/`clean -f`/history rewrites, `curl | sh`, `rm -rf` outside the project, publishing, system settings, killing processes, and writes outside the project.
- **The classifier:** a small local model (Apple's on-device model when available, otherwise the session's model; set `auto_classifier` to choose) judges the rest against your recent messages. It answers allow or ask, with a reason, in grammar-constrained JSON. The call's arguments are marked untrusted, so text in them aimed at the classifier doesn't count.
- **Fails closed:** a timeout, error or unreadable answer means ask.
- **Visible:** approved calls show "Auto: <reason>" on the tool card. When it asks, the permission card says why.

**Sandbox.** Shell commands run in a sandbox by default: seatbelt on macOS, bubblewrap (`bwrap`) on Linux. Without a working `bwrap` (not installed, or unprivileged user namespaces are off), Linux commands ask instead.
- **What it limits:** a command can write only inside the project, temp folders and toolchain caches (`~/.cargo`, `~/.npm`, …). It can't read credentials (`~/.ssh`, `~/.aws`, `~/.gnupg`, keychains, …), so a prompt-injected command can't send them anywhere. Network access works.
- **No prompts:** because of those limits, sandboxed commands run without asking, even in Ask mode.
- **Leaving it:** when a command genuinely needs more (say, `git push` over ssh), the model runs it again with `unsandboxed: true`. That always asks, and the prompt says why.
- **Turning it off:** set `sandbox_shell = false` in `config.toml` or pass `--no-shell-sandbox`. Every command then asks.
- **Environment:** the sandbox limits files, not variables. Commands inherit frog's environment, so a token you export before launching frog (`GH_TOKEN`, `GITHUB_TOKEN`, …) is visible to them.
- **Opening it a little:** a `[sandbox]` section in `config.toml` lets commands read specific credentials. Nothing is opened by default, and it never adds write access:
  ```toml
  [sandbox]
  allow_read = ["~/.config/gh"]  # paths commands may read even though they're credentials
  allow_keychain = false         # macOS: let commands read the login Keychain
  ```
  Inside a linked git worktree, the worktree's git dir and the common git dir (from `git rev-parse --git-dir --git-common-dir`) are writable, so `git commit` works; the rest of the main checkout stays closed. `git push` still asks.

  To restrict the network to dev hosts, set `network = "dev"`:
  ```toml
  [sandbox]
  network = "dev"  # default (unset): open. "dev": github.com, objects.githubusercontent.com, codeload.github.com, crates.io, static.crates.io, index.crates.io, registry.npmjs.org, swiftpackageindex.com, swift.org, download.swift.org
  ```
  macOS only (Linux stays open). Seatbelt can't match remote hosts, so it blocks all outbound except localhost, and frog runs a small local CONNECT proxy that only tunnels https (port 443) to those hosts; `HTTPS_PROXY`/`ALL_PROXY` point at it for sandboxed commands. Tools that ignore proxy variables, plain http and ssh get no network.

  The trade-off: anything you open is readable by every sandboxed command, including one a prompt injection wrote, and the network is open. `allow_keychain` is the broad one: it exposes every Keychain item that doesn't prompt, not just gh's.
- **ssh to user hosts:** ssh can't verify host keys sandboxed (it can't read `~/.ssh/known_hosts`), so connections fail with `hostkeys_find_by_key_hostfile`. Agent sessions that need ssh to your hosts add just that file:
  ```toml
  [sandbox]
  allow_read = ["~/.ssh/known_hosts"]  # read-only; private keys stay unreadable
  ```
  `~` is expanded when the sandbox is built, not when the config is parsed. The no-sudo and no-writes-outside-scratch rules still bind. (For git over GitHub, `git_https = true` avoids `~/.ssh` entirely.)
- **gh, minimal setup:** hand gh its token through the environment and let it read its config directory (gh refuses to start if it can't read `config.yml`):
  ```toml
  [sandbox]
  allow_read = ["~/.config/gh"]
  ```
  and launch frog with `export GH_TOKEN=$(gh auth token)` (in your shell profile or just before `frog`). gh uses `GH_TOKEN` over its stored login, so `gh auth status`, `gh pr list` and friends work sandboxed and only that one token is exposed. Prefer this to `allow_keychain = true`, which also works (on macOS gh keeps its token in the Keychain) but opens the whole Keychain. On Linux gh often keeps the token in `hosts.yml`, so `allow_read` alone is enough there.

## REPL

- `/model` `/mode` `/compact` `/clear` `/context` `/todos` `/exit`
- `/remember <note>` keeps a note for this project (`--global` for every project), `/forget <id or text>` deletes one, `/memory` lists them
- `!cmd` runs a shell command and attaches its output to your next message
- `@path` attaches a file to your message
- alt+enter inserts a newline
- ctrl+c interrupts a turn

## Instructions

Loaded from `~/.config/frog/FROG.md`, `~/.claude/CLAUDE.md`, and any `AGENTS.md`, `FROG.md`, or `CLAUDE.md` in the working directory and its parent directories.

## Memory

`/remember` saves a note as a markdown file under `~/.local/share/frog/memory/` (`global/`, or `projects/<path>/` for one project, shared by its worktrees), readable only by you and easy to edit by hand. Obvious secrets (API keys, tokens, private keys, `password=` values) are redacted before anything is written. Each session starts with a short index of your notes in the system prompt, framed as possibly out-of-date data rather than instructions and sized to the model: about 400 tokens for small models, 1k for mid-size and 2.5k for large ones. Notes that mention files that have since disappeared are marked possibly stale.

