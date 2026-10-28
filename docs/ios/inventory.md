# iOS, iPadOS and watchOS: what exists today

Snapshot of `main` at 4f246b3 (2026-10-26). Read from the code, not the README. Related:
[surfaces.md](surfaces.md), [market.md](market.md), [recommendation.md](recommendation.md).

## Headline

The brief called `apps/ios` "structurally thin and rarely built" with "no watch target". The
first half is wrong and the second half is right, and both matter:

- **It's not thin.** `apps/ios` holds **6 targets and ~4,400 lines of Swift**: an iPhone/iPad
  app, a watch app, a watch complication, widgets with a Live Activity, a notification extension
  and a share extension. It also compiles in most of FrogKit (~16,900 lines), so the phone
  renders the same transcript as the Mac. The Mac side has a real bridge (`RemoteBridge`,
  694 lines) and a push sender (`RemotePush`). There are 45 commits since 2026-09-30, the last on
  2026-10-26.
- **It's rarely built, and today it doesn't build.** Nothing in CI builds it (`.github/workflows/ci.yml`
  builds only `Frog.xcodeproj`, the Mac app). On `main` today, `xcodebuild` fails for the
  `Frog` (iOS) and `FrogWatch` schemes:
  `apps/FrogKit/UI/Basics/FrogFace.swift:34: cannot find 'PillProbe' in scope`.
  Commit 94fd341 (2026-10-25, a Mac benchmark) put a reference to `UI/Transcript/PillProbe.swift`
  into `UI/Basics`. Five targets (watch, watch widgets, widgets, notify, share) compile `UI/Basics` without
  `UI/Transcript`. Nobody noticed, because no build checks those targets. This is the
  feature-drift risk, already happening.
- **Nothing has run on a real device.** `DEVELOPMENT_TEAM 54SNZV8YN8` is a free personal team.
  Free teams get no APNs, no TestFlight and no increased-memory entitlement (see the ios-spike
  commit message). The APNs push relay exists in code but isn't deployed. Everything so far has
  been tested in the Simulator against `-fixtures` recordings or a loopback Mac.

## Targets (`apps/ios/project.yml`, XcodeGen, iOS/watchOS 26.0, Swift 6)

| target | platform | what's real | key files |
|---|---|---|---|
| `Frog` (`toys.frog.remote`) | iPhone + iPad (`TARGETED_DEVICE_FAMILY 1,2`) | Pair by QR or code. Session list with "Needs you / Pinned / Open on your Mac / by day" sections. Full FrogKit transcript, glass composer, Ask and permission cards. Model picker (the Mac decides). Changes inspector, row menu (archive/pin/rename), photo attach and lightbox, fork/rewind/Mermaid, spend and energy settings. Handoff (`eco.frog.conversation`). Siri/Shortcuts intents. "The house" (talks to `frog --listen` with no Mac). Fixture playback. | `Frog/FrogApp.swift` (iPad `NavigationSplitView`), `Remote.swift` (501), `ChatView.swift`, `SessionListView.swift`, `Notifications.swift`, `LiveActivities.swift`, `Intents.swift`, `HouseIntents.swift`, `WatchLink.swift` |
| `FrogNotify` | iOS content extension | Long-press a `PERMISSION` notification to see the command or diff in FrogKit's `QuestionBody` | `NotificationContent/NotificationViewController.swift` |
| `FrogWidgets` | iOS WidgetKit | A Live Activity and Dynamic Island per running turn. Home and lock status widgets, a Control Center control. | `Widgets/FrogWidgets.swift`, `StatusWidgets.swift`, `Shared/TurnActivity.swift` |
| `FrogShare` | iOS share extension | "Send to frog": text, a URL or an image into an open conversation | `ShareExtension/ShareViewController.swift` |
| `FrogWatch` | watchOS app (`WKRunsIndependentlyOfCompanionApp`) | Waiting rows first, with ✕/✓ for a permission and option buttons or dictation for an Ask. Then running (activity line) and unread (start of the reply). A reply screen with stats and next-step buttons. Answers go Mac-direct over `wss://`, else through the phone (5 s timeout). Honest offline footer, haptics. | `Watch/WatchApp.swift` (358), `WatchBridge.swift`, `DESIGN.md` (a proposed v2: no watch notification scene yet, no "always allow") |
| `FrogWatchWidgets` | watchOS WidgetKit | The complication: the iPhone's status widget built for watchOS. Never placed on a face. | `WatchWidgets/WatchWidgets.swift` |

Elsewhere:

- `apps/ios-spike/` (TangSpike) runs tang-llm inside an iPhone app through an xcframework. It
  benches prefill and decode at 512/2k/4k tokens. It's capped at the default memory limit
  because free teams can't get the increased-memory entitlement. No results are committed.
- `crates/puck` is an ESP32 round-AMOLED "puck" that talks to `frog --serve`. It's another
  remote surface, out of scope here.

## What FrogKit shares, and what stays Mac-only

FrogKit is compiled in as source, with no module, so nothing needs `public`
(`apps/FrogKit/README.md`). Platform differences live inside components (`#if os(...)`, 24 files).

| FrogKit folder | iOS app | iOS extensions | watch |
|---|---|---|---|
| `Core` (Protocol.swift 1,338 lines, Pairing, AttentionTree, SessionNesting, Present, Diagram, GitBadge) | ✓ | ✓ | ✓ |
| `Model` (Conversation 1,246, Turns, TurnFlow, Agents, ModelIdentity, stats) | ✓ | — | — |
| `UI/Basics` (FrogFace, palette, motion, haptics) | ✓ | ✓ | ✓ |
| `UI/Cards` (diffs, question body) | ✓ | ✓ | — |
| `UI/Transcript`, `Sessions`, `Composer`, `Models`, `Settings` | ✓ | — | — |

The seams are `ConversationLink` (where the engine is: an `EngineProcess` on the Mac, the bridge
on a phone, or a recording) and `ConversationEffects` (what a platform does around a
conversation: the Mac's sidebar, the phone's Live Activity).

**Mac-only today** (from `apps/ios/README.md`, checked against the code): races, the morning brief
(`Pond.swift`), terminal and preview panes, the timeline rail, moving a conversation to another
folder, `@file` and `/skill` in the composer, and most of Settings (models, keys, permissions,
MCP). One gap matters for the org: **the sidebar's attention tree.** `AttentionTree.swift` and
`SessionNesting.swift` compile into every iOS target, but no iOS view uses them. The phone's list
is flat, because the bridge's `sessionList()` (`RemoteBridge.swift:398`) never sends the parent
link that `Library.parents` holds on the Mac (`Library.swift:149`). The phone can say a session
"needs you", but not "the vcad manager's worker needs you".

## The remote protocol (Mac ⇄ phone)

`RemoteBridge.swift` is a second protocol layered on the engine's. It's JSON objects, and every
client must say `hello{token}` first.

- **Transports.**
  - LAN on 8914: Bonjour `_frog._tcp`, TLS-PSK keyed by an HMAC of the pairing code, JSON lines.
  - Loopback on 8913: a plain WebSocket, for the Simulator.
  - Watch-direct: a `wss://` URL the phone hands over, e.g. `tailscale serve` in front of 8913,
    because watchOS has no raw sockets.
- **Client → Mac:** `hello`, `list`, `attach{session, after}`, `detach`, `register` (push
  device), `activity` (a Live Activity token), `open`, `new`, `turn`, `manage`
  (archive/pin/rename), `model`, `mermaid`, and `op`, which carries an engine Op: `submit`,
  `permission`, `answer`, `act`, `interrupt`, `shell`, `set_title`, `stop_subagent`,
  `compact`, `elicit`, `set_mode`.
- **Mac → client:** `welcome`, `sessions` (pushed on change, debounced 300 ms), `event` (engine
  envelopes, verbatim), `synced`, `stats`, `error`. History replays from the session log, so
  attaching never disturbs an engine.
- **Coverage.** Every engine the Mac app hosts goes through `EngineLink.onLine` →
  `RemoteBridge.forward` (`EngineLink.swift:37`). That includes sessions started by other
  sessions through `SessionBroker`, so the whole org is visible. Sub-agent permission requests
  arrive in the parent's stream.
- **Gaps.**
  - No protocol version in `hello`/`welcome`, so App Store review lag will skew Mac and phone
    versions.
  - No tests for the bridge or push (`apps/macos/FrogTests` has none).
  - Nothing runs if the Mac app isn't running or the Mac sleeps. No power assertion was found in
    `apps/` or `crates/`.
  - **No first-party way off the LAN.** You can type a `host:port` (e.g. a Tailscale IP), but
    nothing more. The ROADMAP lists "reaching your GPU from anywhere through a relay" and
    "approving from your phone" under frog Pro (`docs/ROADMAP.md:225`).

## Push and Live Activities

`apps/macos/Frog/Model/RemotePush.swift` watches every engine line and sends:

- **`permission_request`**: a time-sensitive alert in category `PERMISSION` (Allow needs Face ID,
  Deny doesn't), with the command or the trimmed diff under 3.8 KB. It also sends a Live
  Activity update with `waiting: true`.
- **`question` (Ask)**: category `ASK`, with the options in the body.
- **`turn_ended`**: category `DONE`, with the first line of the answer and a text-input Reply.
- **Item and turn events**: Live Activity updates through per-session push tokens
  (`Device.activities[session]`), so the lock screen moves while the app sleeps.

Delivery goes through `xcrun simctl push` for simulators, or POSTs to a relay for real phones.
The relay holds the APNs key (`site/api/_apns.js`). It validates the token format, the topic
(`toys.frog.remote`), the size limits and `push_type`. On a 410 it tells the Mac to forget the
device.

Problems in the push path:

1. **Wrong host.** `RemotePush.relay` defaults to `https://frog.eco/api/push`. The site moved to
   **frog.toys on Cloudflare Pages** on 2026-10-22 (9e524b9).
2. **The Cloudflare function is broken as written.** `site/functions/api/push.js` uses `require`
   inside an ES-module `onRequest`. It also reads `context.env.request` instead of
   `context.request`, and that destructure shadows the `request()` helper it imports. The
   Vercel version (`site/api/push.js`) looks right but is no longer the deploy target.
3. **No caller auth and no rate limits.** Anyone who holds a device token can push to it. The
   README already lists rate limits as missing.
4. **Payloads are plaintext.** The command text and diff hunks pass through the frog relay and
   APNs. There's no Notification Service Extension to decrypt an encrypted payload (`FrogNotify`
   is a content extension). For a privacy-first product, that's a shipping blocker.
5. **One Live Activity at a time.** `LiveActivities.current` holds a single activity for the
   conversation you last followed, and iOS only lets a foreground app start one. A per-turn
   activity fits one agent, not an org of 20.

## Build status, measured 2026-10-26

| scheme | destination | result |
|---|---|---|
| `Frog` (iOS, builds its embedded extensions and the watch app) | generic iOS Simulator | **fails**: `PillProbe` not in scope (FrogFace.swift:34) |
| `FrogWatch` | generic watchOS Simulator | **fails**: same error |
| Mac `Frog` | — | built and tested in CI |

The fix is one line: move the probe hook behind `#if FROG_APP`, or move `PillProbe.swift` into
`UI/Basics`. It's out of scope for this docs-only pass. The real fix is an iOS and watch build in CI.

## Demand data: Cam's approvals, Oct 22–26

From `~/.local/share/frog/sessions/*.jsonl`, pairing each human-layer `permission_decision`
(`layer: ask`) with the next `permission_resolved` in the same session:

| | |
|---|---|
| human approvals | **1,106** in 5 days (482 / 471 / 62 / 67 / 24 per day) |
| median wait | **16.5 s**. When Cam is at the desk, he answers fast. |
| waited > 5 min | 93 (8%) |
| waited > 30 min | 12 (1%) |
| total agent time blocked on Cam | **58 agent-hours** |
| share of that from waits > 5 min | **83%** (59% from waits > 30 min) |

In short, 8% of approvals cause 83% of the blocked agent-time. That tail is when Cam is away from
the desk. Approval volume fell about 7× after Oct 23, when the classifier and delegation work
cut needless asks. The tail kept going: on Oct 25, 14 waits over 5 minutes cost 5.6 agent-hours.
There were also 175 Ask (`question_resolved`) answers. The FIFO pairing is approximate. Read the
numbers as orders of magnitude, not to the second.
