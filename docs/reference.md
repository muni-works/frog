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
- **Degraded, visibly:** the engine's `status` carries `degraded`, a list of what runs degraded and why: text tool calls the profile didn't ask for, a model other than the one the session was started or set to (a resume without `-m` takes the default), auto mode's classifier down. The app shows it as a small badge in the session header, and `SessionStatus` reports it.

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
| `cloud/<model>` | Frog Cloud, hosted (`FROG_API_KEY` or a saved key; `FROG_BASE_URL` overrides `https://api.frog.toys/v1`, and then only `FROG_API_KEY` is sent) |

Old provider ids still work as input: `tang/` means `local/`; `frog-api/`, `frog/`, `tang-cloud/` and `zest/` mean `cloud/`. A bare model id resolves when only one provider has it (`frog -m qwen3-coder-next`). Providers are listed This Mac first, then your servers, then Frog Cloud, then other clouds (`--providers --json` carries `rank` and `pinned`). `frog account [--json]` shows the model a new session starts on (and whether it runs locally for free or on Frog Cloud, billed per token), plus Frog Cloud's key source and base URL, without touching the network.

`local/` runs safetensors checkpoints (Qwen3 family today) from the Hugging Face cache or a directory, on [tang](https://github.com/muni-works/tang)'s Metal backend. It uses the checkpoint's own chat template, reuses the KV cache for the prefix a turn shares with the previous one, and logs to `~/.local/share/frog/tang-llm.log`. `local/` accepts bf16 checkpoints and `mlx-community` 4-bit ones. The binary is found through `FROG_TANG_BIN`, then next to `frog`, then on `PATH`.

`apple/` needs Apple Intelligence enabled. Build the sidecar with `swift build -c release --package-path sidecars/frog-apple`; it's found through `FROG_APPLE_BIN`, next to `frog`, or on `PATH`. The model has an 8k context and no native tool calling, so frog sends tool calls as a JSON schema that runs as guided generation.

Named profiles live in `~/.config/frog/config.toml`. See [config.example.toml](../config.example.toml).

## Frog Cloud

**Signing in.** `frog login` opens the browser to sign in with GitHub (`--google` for Google), then saves this machine's own `frog_…` key in the Keychain (service `frog`, account `cloud`) — the same place and the same flow as the Mac app's sign-in (PKCE at `https://api.frog.toys/auth/web`, back to a one-shot listener on `127.0.0.1`, then `POST /v1/auth/exchange`). On Linux, with no Keychain, it prints an `export FROG_API_KEY=…` line instead. `frog logout` deletes the saved key; an environment key is left alone and keeps winning. There's no device-code flow yet, so signing in needs a browser on the same machine.

**No fallback.** If Frog Cloud is offline or out of capacity, the turn stops with the error and the thread stays as it was; send again once it's back. frog never switches the thread to a local model on its own: a cloud-sized history doesn't fit a small local window, and squeezing it in would wreck the thread. A credit error (402) stops the same way, with the one line saying where to add credits. `FROG_BASE_URL` points it at a different endpoint (a saved key only goes to `https://api.frog.toys`; elsewhere, only `FROG_API_KEY` is sent).

**Two kinds of model** ([design/model-policy.md](design/model-policy.md)). **Frog Cloud** (`cloud/*`) is the platform's: the default for worker sessions, subagents and the auto-mode classifier. **BYOK** is your own account or machine — `vercel/`, `anthropic/`, `openai/`, `openrouter/`, `cloudflare/`, `ollama/`, `lmstudio/` and servers you add — for the interactive session you're sitting in. A fresh install starts on neither: it's on this machine (`local/qwen3-4b`, or Apple Intelligence in the Mac app). Nothing hops between the tiers: a worker on your own provider fails fast with one line naming it and the fix, an interactive session may carry on without it because you're there to see the notice, and auto mode's classifier is always `apple/on-device` then `cloud/deepseek-v4.1-flash`, never the model the session runs on.

**Errors and retries.** A busy provider (429 or a 5xx) is retried three times at 1 s, 2 s and 4 s with a single notice; a wrong key, an empty wallet or a model your gateway doesn't list (401/402/404) fails at once with the provider's fix in the transcript. A session only starts on a model its gateway's `/v1/models` lists right now (checked once at spawn, from a list cached for a minute); `cloud/*` always starts.

### Other agents on Frog Cloud

Frog Cloud's endpoint is OpenAI-compatible, so other agents can use it too. Base URL `https://api.frog.toys/v1`, model `qwen3-coder-next`, key `FROG_API_KEY` (sign in at [api.frog.toys](https://api.frog.toys)). At capacity it answers 503.

**opencode** (`opencode.json`)
```json
{"provider":{"frog":{"npm":"@ai-sdk/openai-compatible","name":"Frog Cloud","options":{"baseURL":"https://api.frog.toys/v1","apiKey":"{env:FROG_API_KEY}"},"models":{"qwen3-coder-next":{"name":"Qwen3-Coder-Next (Frog Cloud)","limit":{"context":131072,"output":16384}}}}},"model":"frog/qwen3-coder-next"}
```

**Cline, Roo Code, Kilo Code**: Settings → API Provider: **OpenAI Compatible** → Base URL `https://api.frog.toys/v1` → API Key: your `frog_` key → Model ID `qwen3-coder-next`. Turn on native tool calling. Context window 131072.

**Continue** (`config.yaml`)
```yaml
models:
  - name: Qwen3-Coder-Next (Frog Cloud)
    provider: openai
    model: qwen3-coder-next
    apiBase: https://api.frog.toys/v1
    apiKey: ${{ secrets.FROG_API_KEY }}
    roles: [chat, edit, apply]
```

## The chief pattern

For running an org of sessions in the Mac app, the pattern is the nesting and the pins — no feature, no special tile. Run a long-lived session in a workspace (`~/Developer/chief`, say), keep it **pinned** in the sidebar, and have it start the others (`StartSession`): a session's row nests the sessions it started under it, so the whole org reads as one tree with the long-lived session at the top. Pins float above the list, and a pinned row shows what it's doing and what it's waiting on like any other. Open two windows on the same session when you want to watch it work.

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

**IRC bus.** `Irc` reads and posts on the agent bus (see docs/design/agent-bus-irc.md), one IRC channel per team, one nick per session. Off by default — a client only declares it (`set_client_caps` with `irc: true`) when `[irc] enabled = true` in `config.toml`, which stays off until the Frog Cloud bus deploys.
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
web_search = "searxng"                  # or "brave", "exa", "tavily", "frog"
searxng_url = "http://localhost:8888"   # SearXNG's JSON API (/search?format=json)
```

- **Keys:** `echo $KEY | frog --set-key brave` (or `exa`, `tavily`) stores one in the Keychain. `BRAVE_SEARCH_API_KEY`, `EXA_API_KEY` and `TAVILY_API_KEY` work too. `frog` is Frog Cloud's own search, with your Frog Cloud key. With no `web_search` set, frog uses `searxng_url`, then a key found in the environment, then Frog Cloud's search if Frog Cloud is connected. With nothing configured, `WebSearch` isn't offered.
- **Untrusted content:** results come back wrapped as untrusted data, and the model is told not to follow instructions in them.
- **Private addresses:** `WebFetch` only reaches public addresses. Loopback, RFC 1918, CGNAT (100.64/10), link-local, ULA and other special ranges are refused. Every address a name resolves to is checked when connecting, which covers redirects and DNS rebinding. Set `web_allow_private = true` to reach your LAN or localhost.
- **Permissions:** the web tools work in plain chats too. They don't ask in `default`/`accept-edits` mode, just as reads and sandboxed commands (which can already reach the network) don't, and each fetch shows its URL on the tool card. In auto mode the classifier sees the URL or query first, and "always allow" is per host.

**Computer use.** Turn it on with `computer_use = true` in `config.toml`, `--computer-use`. frog then starts the bundled `frog-desktop` MCP server.
- **How it sees:** it reads an app's window through Accessibility as a list of indexed elements, and shows you a screenshot.
- **How it acts:** it presses and types into elements by index, which usually works without taking over your screen. Coordinates and keystrokes are the fallback.
- **Checking its work:** every action returns the refreshed list and how much changed, so the model can tell whether it worked.
- **Guardrails:** every action asks permission, and it never types into password fields.

## Permissions

New sessions start in `auto` (below). A `--resume` with no mode flag keeps the mode the session saved, or `default` if it saved none. `default` asks before edits and shell commands. `accept-edits` lets edits through without asking. `yolo` never asks. **shift+tab** cycles the mode; `--mode default|auto|accept-edits|yolo` (or `--auto`, `--accept-edits`, `--yolo`) picks one at start. Read-only commands such as `ls`, `git status`, and `rg` run without asking, as long as they don't include pipes or redirects.


**Auto mode.** `--auto`, or `/mode auto` in the terminal. Every step that would otherwise ask goes to a local classifier first.
- **Edits:** in-project edits run without asking, since they're checkpointed and can be undone. Sandboxed commands already run without asking.
- **Always asks:** hard rules, no model involved: `sudo`, pushes, `reset --hard`/`clean -f`/history rewrites, `curl | sh`, `rm -rf` outside the project, publishing, system settings, killing processes, and writes outside the project.
- **The classifier:** a small model judges the rest against your recent messages — Apple's on-device model where it exists (the Mac), else Frog Cloud's small model (`cloud/deepseek-v4.1-flash`, or `cloud/qwen3-coder-next` when the gateway lists it); set `auto_classifier` to choose. It answers allow or ask, with a reason, in grammar-constrained JSON. The call's arguments are marked untrusted, so text in them aimed at the classifier doesn't count.
- **When the classifier is down:** a timeout, an HTTP error, an unreachable server or an unreadable answer tries the next judge — `auto_classifier_fallback` (another model) if you set one, else the session's own model — then frog's built-in rules alone: reads (read-only commands, MCP read verbs, captures of public pages) and the session's own work still run; anything no rule covers asks. A down classifier is skipped for a minute rather than retried per call, shows one notice per session, and the session status says what's judging instead.
- **Visible:** approved calls show "Auto: <reason>" on the tool card. When it asks, the permission card says why.
- **Own scratch:** a Write or Edit of a fresh file under the shared temp dir (`/private/tmp/…`), or of a file this session created, runs without asking. Overwriting someone else's temp file still asks.

**MCP tools.** In every mode, an MCP tool whose own name opens with a read verb (`list_`, `get-`, `read_`, `search-`, `describe_`, `stream-`; a repeated server name like `planetscale_list_databases` is skipped) runs without asking, as do vcad's `see`/`inspect`/`measure`/`describe`/`render` tools. A name with a write, run, start/stop or secret word in it (`get_or_create`, `get_branch_password`) still asks, and so does anything not clearly a read. To let one server's writes through, grant it a write tier in `config.toml`:
```toml
[mcp_trust]
planetscale = "write"   # execute_write_query and its create/delete/drop/alter/apply/insert/update tools
# runpod = "write"      # create-pod, delete-pod, pod-action
```
No server is trusted by default. Each granted write runs without a card and is logged: a notice with the server, tool and arguments, a `trust` permission decision in the session log, and a line in the engine log.

**Never asks twice.** A call (same tool, same arguments) that was denied on a card isn't asked about again in that turn: the turn ends `blocked_on_approval` with the denial, so the agent (or whoever wakes it) routes around it. Denied twice in a session, it's denied at once for the rest of the session, with a notice, and the agent carries on.

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

**One engine per worktree.** An engine that starts in a linked git worktree holds a lock on it (`flock` on `frog-engine.lock` in the worktree's git dir) for as long as it runs, so two sessions never mix uncommitted work in one tree. A second engine there refuses with the session that owns it. The lock dies with its engine, so a crash never leaves a worktree stuck; the main checkout is never locked, and subagents share their parent's tree.

  To restrict the network to dev hosts, set `network = "dev"`:
  ```toml
  [sandbox]
  network = "dev"  # default (unset): open. "dev": github.com, objects.githubusercontent.com, codeload.github.com, crates.io, static.crates.io, index.crates.io, registry.npmjs.org, swiftpackageindex.com, swift.org, download.swift.org
  ```
  macOS only (Linux stays open). Seatbelt can't match remote hosts, so it blocks all outbound except localhost, and frog runs a small local CONNECT proxy that only tunnels https (port 443) to those hosts; `HTTPS_PROXY`/`ALL_PROXY` point at it for sandboxed commands. Tools that ignore proxy variables, plain http and ssh get no network.

  The trade-off: anything you open is readable by every sandboxed command, including one a prompt injection wrote, and the network is open. `allow_keychain` is the broad one: it exposes every Keychain item that doesn't prompt, not just gh's.
- **Egress allow-list:** sessions an agent starts (`StartSession`, marked `--worker`; their subagents too) reach only an allow-list of hosts from sandboxed commands; your own sessions stay open unless you ask:
  ```toml
  [egress]
  allow = ["pkg.go.dev"]          # beyond the defaults; a domain covers its subdomains
  defaults = true                 # github.com, githubusercontent.com, crates.io, pypi.org, pythonhosted.org, registry.npmjs.org, api.frog.toys, huggingface.co, hf.co
  workers_deny_by_default = true  # agents' sessions enforce the list
  interactive = "off"             # yours: "off", "flag" (record, don't block) or "enforce"
  ```
  Per project, in `~/.config/frog/egress.toml` (frog's config dir, which the sandbox can't write, so an agent can't widen its own list; the nearest folder decides):
  ```toml
  [projects."/Users/me/Developer/web"]
  allow = ["registry.yarnpkg.com"]
  mode = "enforce"                # optional: overrides worker/interactive here
  ```
  macOS only for now. Enforced, the seatbelt profile denies every outbound connection but localhost (DNS included) and `HTTPS_PROXY`/`HTTP_PROXY`/`ALL_PROXY` point at frog's allow-list proxy, so the check happens at connect time whatever the command looks like (compound commands, `python -c`). An attempt to any other host gets a 403, is logged to `~/.local/share/frog/egress.jsonl`, shows in the transcript as a warning row (`egress_blocked`), and is counted in `egress.jsonl`. To get past it a command names the hosts (`allow_hosts: ["…"]`) or asks for `unsandboxed`; `default`, `accept-edits` and `auto` ask you, allow covers that run and "always allow …" the rest of the session. `yolo` never asks: it runs the call and shows one quiet line (`egress_widened`) saying it left the sandbox or which hosts it now allows for the session, and the proxy still refuses every host nobody declared. Tools that ignore proxy variables (ssh, raw sockets, URLSession-based downloads such as SwiftPM registries) get no network at all.
- **ssh to user hosts:** ssh can't verify host keys sandboxed (it can't read `~/.ssh/known_hosts`), so connections fail with `hostkeys_find_by_key_hostfile`. Agent sessions that need ssh to your hosts add just that file:
  ```toml
  [sandbox]
  allow_read = ["~/.ssh/known_hosts"]  # read-only; private keys stay unreadable
  ```
  `~` is expanded when the sandbox is built, not when the config is parsed. The no-sudo and no-writes-outside-scratch rules still bind. (For git over GitHub, `git_https = true` avoids `~/.ssh` entirely.)

  **Manager briefs:** the default brief for a manager (or any long-running agent session) should say to run with `allow_read = ["~/.ssh/known_hosts"]` under `[sandbox]`, so its ssh runs sandboxed instead of escaping with `unsandboxed: true` and carding.
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


### Compiled memory

With a model server that keeps memory in the model itself (tang-llm serve `--memory-layer N`; design in `docs/design/compiled-memory.md`), frog also offers the model a `Memory` tool: named text files that persist across sessions in this project and cost no context, because the server reads and writes them inside the model's recurrent state instead of the prompt.

- **Tool.** `Memory` takes `action` = `list`, `get` (`name`), `put` (`name`, `text`; replaces the file) or `delete` (`name`). `list` and `get` run without asking, like Read; `put` and `delete` ask like an edit (allowed in accept-edits mode, and in auto mode).
- **Where it lives.** Between sessions the store is a 768 KiB blob at `~/.local/share/frog/memory/projects/<path>/compiled-memory.blob` (the global memory folder for a chat), mode 0600, replaced atomically after every write and at session end. If the server says the store failed its audit (409), frog keeps the last good blob and tells you.
- **Text memory.** `/remember` notes work as before and keep their index in the system prompt. The compiled store is never put in the prompt; while it's active the prompt gains one line pointing the model at `Memory`. Servers without the feature (every server but tang with `--memory-layer`) see one probe per session and nothing else changes.
- **Config.** `[memory] compiled = "auto"` (default: use it when the server offers it), `"on"` (use it, and warn when the server doesn't), `"off"` (no probe, no tool).
- **Commands.** `frog memory dump` prints every file in this project's blob as text (it loads the blob into a throwaway session on the model's server, since only that model can read it; `--model M` picks the profile). `frog memory forget <name>` deletes one file the same way. `frog memory clear` deletes the blob; no server needed.

## Command line

`frog --help` has the full list. The ones not covered above:

**Subcommands** (the first argument):
- `frog setup [MODEL]` installs frog's local engine and downloads a local model's weights (default `qwen3-4b`). Not the same as `frog --setup`, which only reports what frog found on this Mac for this folder (instruction files, skills, rules, keys in the environment, Claude Code's MCP servers) and exits.
- `frog account [--json]`: which model a new session starts on, free or billed, and the Frog Cloud key. Local only.
- `frog login [--google]` / `frog logout`: Frog Cloud's key in the Keychain.
- `frog memory dump|forget <name>|clear [--model M]`: compiled memory (above).
- `frog approvals [--since 24h] [--json]`: who approved what (the classifier, the second pass, the chief, or you) across every session's log in that span (`90m`, `7d`, `3600s`). Local only.
- `frog git-credential get`: git's credential helper when frog runs with `--git-credential-gateway <URL>` (Frog Cloud's sandbox); credentials come from `GET <URL>/internal/git-credential`, never from disk.

**Sessions**
- `-c`/`--continue`, `-r`/`--resume <ID>`, `--fork <ID>[@TURN]`.
- `--rewind <ID@TURN>` undoes that turn and everything after it: restores the files frog edited and branches the conversation from just before it. With `--json`, prints the result and exits.
- `--wait-lock <SECS>` (with `--resume`): if another frog process holds the session, wait up to that long for it to exit, then fail instead of starting a new session.
- `--chat`: a plain chat, not tied to a project; no file or shell tools.
- `--sessions [--all] [--ids a,b] [--digest] [--json]`, `--rename <ID> <TITLE>`.
- `--session-tree [--json]` draws this directory's sessions and their forks and exits.

**Parallel attempts**
- `--attempts N` creates N worktrees from the current working tree (uncommitted changes included) and prints `{"base", "dirs"}`.
- `--apply-attempt <DIR> --base <COMMIT>` applies one attempt's changes to this tree and prints the files.
- `--discard-attempt <DIR>` (repeatable) removes attempt worktrees.

**Models and providers**
- `-m`/`--model`, `--base-url`, `--config <FILE>`.
- `--models`, `--providers`, `--catalog [--refresh]` list what's available (`--json` for JSON).
- `--enable-model <SPEC>…` / `--disable-model <SPEC>…` show or hide models in the list.
- `--set-key <PROVIDER>` stores a key read from stdin (empty removes it).
- `--add-provider <ID> <URL> [--provider-kind openai|ollama] [--provider-name NAME]`, `--remove-provider <ID>`.
- `--tool-mode auto|native|text|json`, `--text-tools`, `--probe`.
- `--cloud-policy [allow|deny|ask]`: whether this folder's code may go to cloud models. `deny` keeps it on your devices, `ask` forgets the answer, no value prints it.

**Permissions and sandbox**: `--mode`, `--auto`, `--accept-edits`, `--yolo`, `--sandbox` (confine writes to the working directory), `--no-shell-sandbox`, `--worker`, `--computer-use`.

**Servers and protocols**
- `--serve`: the engine protocol over stdio. `--serve-ws <ADDR>` speaks it over a websocket instead (one peer at a time, `GET /health` on the same port), with `--store <DIR>` as the session store and `--ask [ID]` to ask the peer for permission instead of denying.
- `--listen <ADDR>`: one turn per HTTP request (needs `FROG_LISTEN_TOKEN`).
- `--acp`: Agent Client Protocol on stdio, for editors. frog doesn't implement ACP's `loadSession`, so an editor can't reopen an old session.
- `--replay <SESSION> [--speed X] [--replay-ask]`: play a recorded session over the serve protocol, for UI work.

**Tools that print and exit**
- `--mcp`: connect the configured MCP servers and list their tools.
- `--skills`: the Agent Skills this folder sees.
- `--mermaid`: read Mermaid from stdin, lay it out, print the diagram.
- `--map [DIR]`: map the project's (or a subdirectory's) structure from its code.
- `--use-claude-mcp on|off`: read Claude Code's MCP servers from `~/.claude.json`.

**Measuring**: `--energy` reads each turn's energy from the Mac's power sensor and reports it with the turn.
