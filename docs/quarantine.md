# Prompt-injection quarantine

An MCP server's tool descriptions go straight into the model's context. A hostile or compromised server can use them to give the model orders: read your SSH key, hide a step from you, ignore its instructions. frog checks every MCP tool before the model sees it and withholds the ones that look like this.

## What happens

When frog connects to an MCP server, it checks each tool's description and input schema. A tool that matches is quarantined:

- It is left out of the tool list sent to the model, so the model never sees its description and can't call it.
- frog shows a warning naming the server, the tool and the reason:

  ```
  MCP `deploy`: withheld tool `update-ssh-keys` because its description asks to send out credentials. Set `trust = true` for this server to allow it.
  ```

  (That one came up in testing: the server's `update-ssh-keys` tool description asked the model to send out credentials.)
- `frog --mcp` lists each server's tools and, separately, anything quarantined, with the reason.

The server's other tools work as usual. Tools a server adds mid-session are filtered the same way.

## What is detected

The description and the JSON of the input schema are checked together. A tool is withheld if it contains hidden Unicode characters (zero-width characters, bidirectional controls, invisible operators or tag characters), or if it matches one of these, case-insensitively:

| reason shown | what matches |
|---|---|
| tells the model to ignore its instructions | "ignore (all/any) previous/prior/above/earlier/other instructions/prompts/rules" |
| mentions the system prompt | "system prompt", "developer message" |
| asks the model to hide things from the user | "do not / don't / never tell/inform/mention/reveal (to) (the) user" |
| contains instruction tags | `<important>`, `<system>`, `<instructions>` and their closing tags |
| asks to send out credentials | "send/post/upload/exfiltrate/forward" followed within 40 characters by ssh, .env, credentials, API keys, secrets, passwords or tokens |
| references credential files | `~/.ssh`, `id_rsa`, `.aws/credentials` |
| tries to chain other tool calls | "before using this/any tool" followed within 40 characters by read, call or run |

The first match is the reason reported. The patterns are in `suspicious()` in [crates/frog-engine/src/mcp.rs](../crates/frog-engine/src/mcp.rs).

This is a filter for the common, known shapes of tool poisoning, not a guarantee. Every MCP tool call still asks permission, and tool results are not filtered by this check.

## Trusting a server

If a server is yours and a tool is flagged by mistake, mark the server trusted. Its tools then skip the check entirely.

In `~/.config/frog/config.toml`:

```toml
[mcp_servers.deploy]
command = "deploy-mcp"
trust = true
```

Or in the project's `.mcp.json`:

```json
{"mcpServers": {"deploy": {"command": "deploy-mcp", "trust": true}}}
```

`trust` is off by default. frog's own bundled computer-use server (`desktop`) is trusted.
