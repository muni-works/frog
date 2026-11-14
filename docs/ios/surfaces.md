# Candidate surfaces

Three candidates, each judged on five things: the user story, what FrogKit gives for free, the
new work, the maintenance cost, and how it fits the org model. Facts come from
[inventory.md](inventory.md). Effort is in relative sizes (S ≈ a few agent-days, M ≈ a couple of
agent-weeks, L ≈ more than a month), not dates.

The org model in one line: a chief of staff runs managers, and managers run workers. At peak
that's hundreds of sessions a day. **The org's throughput is capped by how fast Cam unblocks it**,
and 83% of the blocked agent-time comes from the waits that happen when he's away from the desk
(inventory, "Demand data").

---

## (a) iPhone remote: the org's pager

**User story.** "I'm away from my desk. The org keeps working. When something needs me, my phone
(or my wrist) tells me *what* needs me and *who asked*. I approve or deny from the lock screen
in one tap, with Face ID on Allow. I can glance at what's running and send a one-line nudge.
When I'm back, the Mac is exactly where the phone left it."

**Already built.**

- Pairing: QR, Keychain, TLS-PSK.
- The session list, with "Needs you" first.
- The full transcript (FrogKit's own `TranscriptView`, `AskViews`, permission card in its thumb
  layout), the composer, `interrupt`, `set_mode`.
- Actionable notifications (Allow/Deny/Reply), the long-press diff (`FrogNotify`), a Live
  Activity per turn, and widgets.
- Mac-side `RemotePush`, which already decides what deserves a push.
- The watch app (answer, know, nudge) as a bonus. Actionable iPhone notifications also mirror to
  the watch with no watch-app work.

Roughly 80% of the UI exists. What's missing is the plumbing that lets it leave the house.

**New work.**

| # | work | size | why |
|---|---|---|---|
| 1 | iOS and watch build in CI. Fix the `PillProbe` break. | S | It's broken today, and nothing would catch the next break |
| 2 | Paid Apple team (the Municipal Robotics org enrollment), APNs key, TestFlight | S (Cam's task) | Without it, no real device, no push, no Live Activity |
| 3 | Deploy the push relay on frog.toys. Fix the CF function, point `RemotePush.relay` at it, add caller auth (a per-Mac secret minted at pairing) and rate limits. | S | It isn't live today, and the default URL is wrong |
| 4 | **End-to-end encrypted push payloads.** The Mac encrypts with a key derived from the pairing code. A new Notification Service Extension decrypts on the phone. APNs and the relay see only ciphertext. | M | A privacy-first product can't put `$ rm -rf …` and diffs through two clouds in plaintext |
| 5 | **Off-LAN transport.** First, document BYO tunnel (Tailscale `host:port` already works on the phone, and `wss://` on the watch). Then an E2E rendezvous relay (WebSocket, PSK-encrypted, carrying only ciphertext): the ROADMAP's frog Pro "reach it from anywhere". | S then M | Away from home is the whole point, and it's when 83% of the wait happens |
| 6 | **The org on the phone.** Send `parent` in the bridge's session rows, then render `AttentionTree` (the needs-you lens plus the started-by tree) instead of the flat list. Notifications name the chain ("arm › lymb-bom needs you"). | S–M | That's the difference between an agent remote and an org remote |
| 7 | **One org Live Activity**: "3 need you · 14 running", plus the oldest waiting request. It replaces one activity per turn. | S | iOS caps Live Activities, and an org isn't one turn |
| 8 | Protocol version in `hello`/`welcome`, and bridge tests (a fixture Mac ⇄ a fixture phone) | S | App Store lag means Mac and phone versions will skew |
| 9 | Mac: keep awake while agents run or wait (a power assertion, as Codex and Cursor ask for) | S | When the Mac sleeps, the org stops, and the phone shows nothing |

**Maintenance cost.** Medium. Six targets already exist, and the incremental matrix is
iPhone × iPad layout × 4 extensions × watch. Most of it is FrogKit, so one change covers every
surface. The real costs:

- A second protocol, the bridge, has to be versioned.
- The relay is production infrastructure that has to be watched.
- An App Store release runs alongside the Mac's DMG release.

Mitigations: fixtures already drive every surface headless (`-fixtures YES`), and CI can build
all six schemes on the existing `macos-26` runner.

**Org fit. The strongest of the three.** Each unblock from the phone saves minutes of agent-time
for every worker under a blocked manager. The org's relayed-approval rules (standing lines,
"yes for routine") also make a natural phone primitive: approve once at the manager level, and
its workers inherit it. No competitor has an org to do that for (see [market.md](market.md)).

---

## (b) iPad full client (transcript + sessions + CAD viewer)

**User story.** "On the couch or on a trip with just an iPad, I run frog for real: read whole
transcripts, review diffs, start work and steer it, and look at the vcad part the agent just
changed."

**Already built.** More than you'd guess. The `Frog` target already runs on iPad: a
`NavigationSplitView` with the list beside the conversation (`FrogApp.swift`), the full
transcript, the Changes inspector, the composer, models and settings. It remains a *remote*. The
work still runs on the Mac.

**New work.**

| work | size | notes |
|---|---|---|
| iPad polish: keyboard shortcuts, pointer, Stage Manager windows, drag and drop | M | Table stakes for an iPad "client" |
| Mac-only features in the README's list (`@file`/`/skill` composer, terminal and preview panes, Settings: keys, permissions, MCP) | L | Each is a feature ported across a platform boundary. This is where drift lives. |
| CAD viewer | L+ | vcad is a separate repo. FrogKit has no 3D renderer, and the Mac renders through vcad. iPad would need a mesh/USDZ path, or vcad-render streaming images. It ties to the vcad app's own roadmap (the "one app, staged" decision), not to frog. |
| Standalone iPad (no Mac) | XL | Needs a cloud or edge engine to attach to. That's frog cloud's hosted sessions, not an iOS feature. |

**Maintenance cost. The highest.** A "full client" promises parity, and parity with a Mac app
that ships 200+ commits a day can't be kept. Every Mac feature becomes an iPad bug report.

**Org fit. Weak.** Steering the org is approvals and short nudges, and the phone does that. Deep
review happens when Cam is back at the desk anyway. A big screen doesn't change the org's
bottleneck.

**Verdict.** The iPad app comes nearly free as a layout of (a). Ship that and don't call it a
"full client". The CAD viewer belongs to vcad's roadmap.

---

## (c) On-device edge: Orin head-node companion and the local-model tier

**User story.** Two different stories go by this name:

1. "My phone runs a small model, so frog works offline and privately on the phone."
2. "My cortex head's Orin (or a home server) is a frog node, and my phone and watch reach it the
   way they reach the Mac."

**Already built.**

- A spike (`apps/ios-spike`, removed in November 2026; in git history) showed tang-llm links and
  runs in an iPhone app, capped by the free team's memory limit. No benchmarks were committed.
- `frog --listen` (crates/frog/src/listen.rs) answers one turn per HTTPS request from any
  client. It's `--chat` only and can't ask for permission. The iOS "house" client that used it
  was removed in October 2026.
- Product memory: the head Jetson works as a zest node when docked and idle, ~8B-class only.
  Orin NX can't fit Coder-Next.

**New work.**

| work | size | notes |
|---|---|---|
| Story 1, on-phone agent: a model plus a tool runtime on iOS. No shell, no git, a sandboxed filesystem, and a 4–8B model under jetsam limits. | L, and low value | The phone can't do the work frog is for (repos, builds). An on-phone coding agent is a demo, not a product. |
| Story 2, edge node: run `RemoteBridge`'s protocol from the engine side (`frog --serve` plus pairing, Rust instead of Swift), so a head, home server or Linux box is a bridge host the existing phone app attaches to | M–L | This is the real value. It also fixes the "Mac must be awake" weakness for people with an always-on box. It's engine and ops work. iOS doesn't change. |

**Maintenance cost.**

- Story 1: very high (a model runtime on two Apple OSes, memory tuning, App Store size).
- Story 2: moderate. It moves the bridge into the engine, so Mac and Linux share one
  implementation, which *reduces* drift.

**Org fit.**

- Story 1: none.
- Story 2: good, but later. An always-on node means the org survives a sleeping laptop. It's a
  server-side feature that (a) consumes, not a separate iOS surface. The local-freedom tier lives
  on user hardware with abliterated weights, and the phone is the remote for that hardware, not
  the hardware.

**Verdict.** Don't build an on-phone agent. Build Story 2 when the head ships or the Mac-awake
problem bites, as an engine feature behind the same phone app.

---

## Summary

| | value to the org story | new work | maintenance | already built |
|---|---|---|---|---|
| (a) iPhone remote, the org's pager (+ watch) | **high**: it attacks 83% of blocked agent-time | M total, mostly plumbing | medium | ~80% of the UI |
| (b) iPad full client | low | L–XL for parity, L+ for CAD | **highest** (parity drift) | the iPad layout, as part of (a) |
| (c1) on-phone agent | ~none | L | very high | spike only |
| (c2) edge node for the same remote | medium, later | M–L (engine) | moderate, and lowers drift | `--listen` pattern |
