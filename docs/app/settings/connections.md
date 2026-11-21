# Connections

A connection lets Frog reach something outside your code, like GitHub or a database, through the tools an MCP (Model Context Protocol) server offers.

## Where connections are set up

Frog reads servers from three places:

- **`~/.config/frog/config.toml`** on your Mac, for every project.
- **`.mcp.json`** in a project, for that project. When both name a server, `config.toml` wins.
- **Claude Code's servers**, once you've said to use them (`frog --use-claude-mcp on`).

A Frog Cloud session reads its repo's `.mcp.json` and tries to start the servers it lists. Its sandbox can only read the open web, so a server that signs in or writes to a service won't work there yet.

## Add a connection

A server is either a command Frog runs or a URL it calls. In `config.toml`:

```toml
[mcp_servers.github]
command = "npx"
args = ["-y", "@modelcontextprotocol/server-github"]
env = { GITHUB_TOKEN = "${GITHUB_TOKEN}" }

[mcp_servers.docs]
url = "https://example.com/mcp"
headers = { Authorization = "Bearer ${DOCS_TOKEN}" }
```

Or in a project's `.mcp.json`:

```json
{ "mcpServers": { "github": { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"] } } }
```

A new server connects when the next session opens. One that needs you to sign in shows a Sign in card.

## What Frog asks first

A tool's name is `mcp__<server>__<tool>`. A tool whose name starts with a read word (`list`, `get`, `read`, `search`, `describe`, `stream`) and has no write word in it runs without asking. Other calls ask, as edits do. To let one server's writes through without a card, give it a write tier in `config.toml`:

```toml
[mcp_trust]
planetscale = "write"
```

Frog leaves out a tool whose description reads like an attempt to steer it, or hides Unicode, and says so. `trust = true` on a server skips that check.

## What it costs

Each tool that's on sends its description and inputs with every turn, and a server's own instructions ride along too. A server with many tools can add a few thousand tokens a turn.

With more than 40 tools switched on, Frog stops sending them all. It gets a search tool instead and loads a tool when it needs one, so a tool costs tokens only once it's loaded. A model with a window under 16,384 tokens always works this way, and gets no server instructions.

On your Mac, Settings › Connections shows what each server and each tool adds to a turn.

## Turn one off

On your Mac, Settings › Connections has a switch for each server and for each of its tools. A server that's off isn't started. A tool that's off leaves the list and is refused if called. Frog keeps these switches in its own file (`~/.local/share/frog/customize.json`) and never edits `config.toml`, `.mcp.json` or Claude Code's files.

`enabled = false` on a server in `config.toml` turns it off too.

## Connections and skills

A connection gives Frog new tools. A skill gives it steps to follow with the tools it has. A skill can tell Frog to use a connection's tools. See [Skills](https://frog.toys/docs/skills).

## Limits today

- Servers are added by editing `config.toml` or `.mcp.json`. There's no form for it in the app yet.
- The web can't show the servers your Mac has, and has no switches yet.
