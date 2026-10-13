# Siri and the house

"Hey Siri, ask Frog about the house." Siri asks what you want to know, the iPhone sends it to frog
on the home server (mew), frog works it out with the house's tools, and Siri reads the answer.
Inference and tools stay at home. Apple's servers see the trigger phrase, not the request: the
request text goes from the Frog app straight to your server.

## Architecture

```
Siri / Shortcuts / the Frog app
  │  AskHouseIntent (apps/ios/Frog/HouseIntents.swift)
  │  POST /v1/turn  {"text": …}   Authorization: Bearer …
  ▼
caddy (TLS, frog.pedersen.garden) ─► frog --chat --listen 127.0.0.1:8915   (crates/frog/src/listen.rs)
                                        │ one engine per request, can_ask off
                                        ├─► model (ollama on the 3090)
                                        └─► MCP: homelab-mcp /act (HA, Frigate; allowlisted call_service)
  ◄── NDJSON: the engine's event envelopes, the same stream as --serve, until turn_ended + idle
```

- **`frog --listen ADDR`** answers one turn per HTTP request. It has no HTTP library and no new
  dependencies, and it doesn't change frog-engine.
  - `POST /v1/turn` takes `{"text", "session"?, "model"?}`. `session` continues a conversation.
    `model` is a profile name or `provider/model`.
  - `GET /v1/session/<id>/answer` returns `{"done": false}` while a turn runs, then
    `{"done": true, "text"}`.
  - `GET /v1/health` checks the token.
  - Every request needs `Authorization: Bearer $FROG_LISTEN_TOKEN`, which must be 16 characters
    or more.
- **Nobody can answer a permission prompt** over this transport, so anything that would ask is
  denied. Run it with `--chat`, which has no file or shell tools, and `--yolo`, so the MCP
  tools run. That's safe only because homelab-mcp's one write tool, `call_service`, enforces
  its own allowlist on the server. It never touches locks, alarms or entry doors (ADR 016 in
  `~/Developer/home`). Don't point a `--yolo` listener at an MCP server without such a guard.
- **If the client hangs up**, the turn keeps going. It finishes and is saved in the session log,
  where `/answer` finds it.
- **The intent** waits about 8 seconds, because Siri gives an intent roughly 10.
  - If the turn finishes in time, Siri speaks the answer.
  - If not, Siri says what frog has so far plus "still working". The app keeps polling `/answer`
    while iOS lets it run, and posts the answer as a notification.
  - Either way, the answer shows under Recent in Settings › The House the next time the app
    opens.
- **Offline fallback.** When the server can't be reached at all, Apple's on-device model answers
  through `SystemLanguageModel`. It gets no tools, and the reply starts by saying it couldn't
  reach the house. Private Cloud Compute is never used.

## Set it up

On mew, as a systemd unit. The real deploy lives in `~/Developer/home`; this is the shape.

```ini
# /etc/systemd/system/frog-house.service
[Unit]
Description=frog for Siri (frog --listen)
After=network-online.target docker.service

[Service]
User=frog
WorkingDirectory=/var/lib/frog
EnvironmentFile=/etc/frog/listen.env        # FROG_LISTEN_TOKEN=…, MCP_TOKEN_ACT=…
ExecStart=/usr/local/bin/frog --chat --yolo -m house --listen 127.0.0.1:8915
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

The frog user's `~/.config/frog/config.toml`:

```toml
default_model = "house"

[models.house]
provider = "ollama"
model = "qwen3:30b-a3b"
context_window = 32768

# Opt-in, per frog's MCP policy. trust = true because we run it, so its tool descriptions skip
# the quarantine check. /act is the household tools plus call_service. Use /home/mcp and
# MCP_TOKEN_HOME instead to keep Siri read-only.
[mcp_servers.homelab]
url = "https://mcp.pedersen.garden/act/mcp"
headers = { Authorization = "Bearer ${MCP_TOKEN_ACT}" }
trust = true
```

Caddy terminates TLS. Turn buffering off so answers stream, and keep the site off the public
internet, since it's LAN and Tailscale only like the rest:

```
frog.pedersen.garden {
    reverse_proxy 127.0.0.1:8915 {
        flush_interval -1
    }
}
```

Generate a token with `openssl rand -hex 24`. Check it from the dev box:

```bash
curl -H "Authorization: Bearer $TOKEN" https://frog.pedersen.garden/v1/health
```

On the iPhone, open Frog › Settings › The House, or "Ask the House Instead" on the connect
screen. Enter `https://frog.pedersen.garden`, the token, and optionally a model. The token goes in
the Keychain. Then say "Ask Frog about the house", or add **Ask the house** in Shortcuts.

**Why HTTPS through caddy.** App Transport Security allows plain HTTP only to local addresses.
Tailscale's 100.x addresses and `*.ts.net` names don't count as local, so HTTPS is the way that
works both at home and away.

**Simulator.** An unsigned build can't use the Keychain, so pass the token in the environment:

```bash
SIMCTL_CHILD_FROG_HOUSE_TOKEN=… xcrun simctl launch booted eco.frog.remote
```

## What works where

| device | how | status |
|---|---|---|
| iPhone | Siri phrase, Shortcuts, Action button, the app | built; Shortcuts metadata checked; Siri voice not tried on hardware |
| CarPlay | Siri on the iPhone runs the same intent; answers are spoken | expected to work, not tried |
| Apple Watch | Siri on the watch doesn't run iPhone-only App Shortcuts, and the watch can't reach Tailscale | not done |
| HomePod / Home hub | Siri on HomePod runs App Shortcuts through the paired iPhone ("personal requests") | expected to work, not tried |

## Open questions

- **Freeform speech.** The iOS 27 SDK has no assistant schema for "ask a question" (it has
  `.system.search` and domain schemas). So Siri routes on the phrase, then asks "What do you want
  to ask the house?" as a second step. "Ask Frog why the garage is cold" in one breath needs a
  schema Apple hasn't shipped, or an App Shortcut parameter that's an entity, not free text.
- **Confirming changes.** `call_service` (ecto/home#32) runs without asking, inside its
  allowlist. To confirm each change by voice or on the lock screen, the listener would have to
  forward permission requests instead of denying them, and the phone would answer through the
  existing Allow/Deny Live Activity intents.
- **Watch.** A watch-native intent would need the phone to relay the request, or a
  public-but-authenticated endpoint the watch can reach on LTE. The Watch app already talks to the
  phone through WatchConnectivity.
- **Siri's time budget** is an estimate. The 8 seconds should be tuned on hardware.
- **Deployment target.** The brief asked for iOS 27 minimum. The app stays on iOS 26, which the
  existing targets use, because nothing here needs 27.
