# frog for iPhone, iPad and Apple Watch

A remote for frog on your Mac. The work runs on the Mac; the phone watches it, answers frog's
questions and sends it the next thing.

```
xcodegen && open FrogRemote.xcodeproj
```

## How it connects

The Mac app runs `RemoteBridge` (Settings → General → "Let frog on iPhone connect"):

- **On the network (8914):** advertised on Bonjour as `_frog._tcp`, encrypted with TLS-PSK keyed
  by the pairing code (an HMAC of it), carrying JSON lines. Pair by scanning the QR code in the
  Mac's settings (a `frog://pair` link the Camera app opens in frog) or by picking the Mac and
  typing the code. A wrong code fails the handshake. New Code on the Mac signs every phone out.
- **Loopback (8913):** a plain WebSocket, for the Simulator and tools.

A phone says the code, lists conversations (the Mac pushes changes), attaches to one (history
replayed from the session log, then the engine's lines live) and sends ops (`submit`,
`permission`, `interrupt`, `set_mode`). It can also ask the Mac to `open` a conversation or start
a `new` one; a Mac window opens it without replacing what's on screen. On the phone the code
lives in the Keychain.

## Targets

| target | what |
|---|---|
| `Frog` | the app: list, threads, glass composer, questions, Siri/Shortcuts intents |
| `FrogNotify` | long-press a question: the command or diff |
| `FrogWidgets` | Live Activity + Dynamic Island, home/lock widgets, Control Center control |
| `FrogShare` | "Send to frog" in the share sheet |
| `FrogWatch` | what needs you (answer with ✕ / ✓) and what's running |
| `FrogWatchWidgets` | the complication: the iPhone's status widget, built for watchOS |

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

- A paid team: a real device, APNs (and deploying the relay, with rate limits), TestFlight.
- The complication is built and fed, but hasn't been placed on a watch face in the Simulator.

Everything a phone shows of a conversation is FrogKit's (see ../FrogKit/README.md): change a
component there and the Mac, iPhone, iPad and extensions all change with it.
