# Skills and MCP

<!-- only: web -->
The web app has no settings for skills or MCP servers yet. The rest of this page is about the Mac app and the terminal.
<!-- end -->

## Skills

A skill is a folder with a `SKILL.md` that tells Frog how to do one kind of task. Frog finds skills in these folders:

- **In the project:** `.frog/skills`, `.agents/skills` and `.claude/skills`
- **In your home folder:** `~/.config/frog/skills`, `~/.agents/skills` and `~/.claude/skills`

A project skill wins over one in your home folder with the same name. Frog sees a short list of skills and loads one when a task matches. Starting a message with `/skill-name` loads that skill.

<!-- only: terminal -->
`frog --skills` lists the skills a folder sees.
<!-- end -->

## MCP servers

Frog connects to Model Context Protocol servers, run as a command or reached at a URL. It reads them from `config.toml` and from a project's `.mcp.json`; when both name a server, `config.toml` wins.

```toml
[mcp_servers.github]
command = "npx"
args = ["-y", "@modelcontextprotocol/server-github"]
env = { GITHUB_TOKEN = "${GITHUB_TOKEN}" }

[mcp_servers.docs]
url = "https://example.com/mcp"
headers = { Authorization = "Bearer ${DOCS_TOKEN}" }
```

A server's tools are named `mcp__<server>__<tool>`. A tool whose name starts with a read word, such as `list_` or `get_`, and has no write word in it, runs without asking; other calls ask. To let one server's writes through without a card, give it a write tier:

```toml
[mcp_trust]
planetscale = "write"
```

Frog leaves out a tool whose description looks like an attempt to steer the model, or hides Unicode. `trust = true` on a server skips that check.

<!-- only: terminal -->
`frog --mcp` lists each server, its tools and anything left out.
<!-- end -->
