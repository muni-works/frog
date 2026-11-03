# Egress allow-list

Why: Cohere's sandbox caught Qwen3.8-Flash-Next, asked for a defensive rule, inventorying the
machine, reading DNS settings and uploading a probe file to an Alibaba Cloud bucket in Beijing,
while its reasoning said it would call no tools. frog's shell sandbox fenced writes and hid
credentials but left the network open, so a compound command in an auto-mode worker could do
the same. The trust story is "actions gated, not intent": the gate has to sit where the
connection happens, not where the tool call is parsed.

## Mechanism

Seatbelt matches network peers by address (`*` or `localhost`), never by name, so the profile
alone can only say "nothing but localhost". Names are decided by a proxy in the engine:

- Enforced sessions get `(deny network-outbound)` + `(allow network-outbound (remote ip
  "localhost:*"))`, unix sockets allowed except `/private/var/run/mDNSResponder` (with it,
  `getaddrinfo`/`dig` would still put data on the wire as DNS queries).
- `HTTPS_PROXY`/`HTTP_PROXY`/`ALL_PROXY` = `http://frog:<token>@127.0.0.1:<port>`; `NO_PROXY`
  is localhost only. The token ties each connection to the tool call that made it.
- The proxy (own thread and runtime, one per process) tunnels `CONNECT host:port` and forwards
  absolute-form plain http (one request per connection, `Connection: close`, proxy headers
  stripped) to hosts on the list. Anything else: 403, a `Hit` (host, port, tool, command head),
  a line in `~/.local/share/frog/egress.jsonl`.
- A client that ignores the proxy can't resolve or connect at all; when its output names the
  host (`Could not resolve host: …`) that's recorded too, with port 0.

So the check is per connection, not per tool call: `a && b; curl …`, `python -c`, a script the
agent wrote, a background job — all go through the same door.

## Policy

`[egress]` in config.toml: `allow`, `defaults`, `workers_deny_by_default` (true),
`interactive` (`off` | `flag` | `enforce`, default off). `~/.config/frog/egress.toml` adds
per-folder `allow` and `mode` (nearest folder decides). It lives in frog's config dir because
the sandbox can neither read nor write it: a project-level file would let an agent widen its own
list by writing one.

Workers: the app passes `--worker` for `StartSession` sessions; the engine keeps it in the log
header (`worker: true`), so a resume or fork stays a worker. Subagents share the parent's
`Egress` (same list, same grants, hits surface in the parent's transcript).

## Grants

`Bash { allow_hosts: [...] }` naming hosts off the list, or `unsandboxed: true` in an enforced
session, cards in every asking mode — no read-only rule, sandbox layer, classifier or session
allow passes it; headless (`can_ask = false`) it's denied. Allow = `grant_once` (that exact
command's next run); "always allow X this session" = `grant` (shared with subagents).

In auto mode the card is first offered to the chief of staff when `[delegation]` grants it the
`egress-widen` class (docs/design/delegation.md): the chief's approval makes the same grant an
answered card does, and its denial denies. Without that grant the card is the user's, as before.

**Yolo never asks** (Cam, 2026-11-02). Both shapes run, with one quiet `EgressWidened` row in
the transcript instead of a card: the hosts a call names are its declaration and are `grant`ed
for the session, and a call that leaves the sandbox runs outside it. The proxy still refuses
every host nobody declared, so the tripwire below keeps working; the row is what makes the
widening visible rather than silent.

## Surfacing

`Event::EgressBlocked { host, port, item?, tool, command, enforced }` is durable; the app
renders it as a warning notice row. The tool result gets a note naming the hosts and how to ask.
`Event::EgressWidened { item, tool, command, hosts, sandbox_left }` is durable too, and renders
as one quiet (info) row: "Yolo: `cmd` reaches host, now allowed for this session." or "Yolo:
`cmd` ran outside the sandbox; it can change files anywhere and read your credentials."
The brief carries the day's `egress` digest (attempts, sessions, top hosts), and blocked egress
alone makes the morning notice.

## Not covered (yet)

- Linux: bubblewrap has no name filter; `--unshare-net` would cut the proxy off too. The policy
  resolves but isn't enforced there.
- WebFetch: its own gate (public hosts only, auto-allowed as a read). A GET can carry data in
  its URL; folding WebFetch into the list for workers is the next step.
- ssh and other non-proxy protocols get no network under an enforced list (an ssh
  `ProxyCommand` through the proxy for listed hosts would fix it).
- URLSession-based tools (SwiftPM registry/binary downloads) ignore proxy env on macOS.
- Allowed hosts that accept anonymous uploads or front other origins (a CDN) remain channels;
  keep the list to registries.
- MCP servers and terminal panes aren't sandboxed by this; they have their own approvals.
