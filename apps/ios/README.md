# frog for iPhone, iPad and Apple Watch

A remote for frog on your Mac. The work runs on the Mac; the phone watches it, answers frog's
questions and sends it the next thing.

```
xcodegen && open FrogRemote.xcodeproj
```

## How it connects

The Mac app runs `RemoteBridge` (Settings → General → "Let frog on iPhone connect"): a WebSocket
on `127.0.0.1:8913` that speaks the engine protocol. A phone says the code first, then lists
conversations, attaches to one (history replayed from the session log, then the engine's lines
live) and sends ops (`submit`, `permission`, `interrupt`, `set_mode`). Loopback only until LAN
pairing, so today that means the iOS Simulator on the same Mac.

## Targets

| target | what |
|---|---|
| `Frog` | the app: list, threads, glass composer, questions, Siri/Shortcuts intents |
| `FrogNotify` | long-press a question: the command or diff |
| `FrogWidgets` | Live Activity + Dynamic Island, home/lock widgets, Control Center control |
| `FrogShare` | "Send to frog" in the share sheet |
| `FrogWatch` | what needs you (answer with ✕ / ✓) and what's running |

Shared with the Mac app: `Protocol.swift`, `Diagram.swift`, `FrogFace.swift`.

## Working on it without a Mac

Recorded sessions (the Mac's `Fixtures/`) play back as if live: answers stream, tools take their
time, and the first command or edit stops to ask. They drive the Live Activity, widgets and watch
too.

```
xcrun simctl launch booted eco.frog.remote -fixtures YES          # the list of recordings
xcrun simctl launch booted eco.frog.remote -fixture long-answer    # straight into one
```

## Against the Mac, in the Simulator

```
defaults write eco.frog.dev remoteEnabled -bool YES     # the debug Mac app, eco.frog.dev
defaults read eco.frog.dev remoteToken                  # the code
SIMCTL_CHILD_FROG_REMOTE_CODE=<code> xcrun simctl launch booted eco.frog.remote
```

Once connected, the phone registers with the Mac for pushes. In the Simulator the Mac delivers
them with `xcrun simctl push`; real phones go through the relay (`site/api/push.js`), which needs
a paid team's APNs key and isn't deployed yet.

## Not done yet

- LAN pairing (Bonjour, a QR code, SPAKE2 → pinned keys), so a real phone can connect.
- Deploying the relay, and tying its requests to a pairing.
- Starting or resuming a conversation from the phone when it isn't open on the Mac.
- The list refreshes by polling every 4 seconds; the Mac should push changes.
- A watch complication.
