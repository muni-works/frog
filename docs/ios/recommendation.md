# Recommendation: ship the iPhone as the org's pager first

Inputs: [inventory.md](inventory.md) (what exists), [surfaces.md](surfaces.md) (the three
candidates), [market.md](market.md) (what others ship). This doc is opinionated on purpose. The
direction is Cam's call.

## The call

**First surface: (a) the iPhone remote, built as the org's pager.** Approve, deny and answer
from the lock screen and the wrist. The phone shows the attention tree, not a flat list. It
reaches the Mac from anywhere, with end-to-end encryption. iPad comes along as a layout of the
same app. The existing watch app ships later, as stage 2.

### Why (top 3)

1. **It attacks the org's actual bottleneck, and we measured it.** Oct 22–26 had 1,106 human
   approvals with a 16.5 s median. But 8% of them, the ones that waited more than 5 minutes,
   made up **83% of 58 blocked agent-hours**. Those waits happen when Cam is away from the desk.
   No other surface moves that number. Better classifiers cut the volume about 7× and left the
   tail.
2. **It's ~80% built, and the missing 20% is plumbing, not product.** The repo has six targets
   and ~4,400 lines of Swift. The phone already renders the Mac's transcript through FrogKit.
   Pushes, Allow/Deny with Face ID, the diff on long-press, Live Activities and the watch app all
   exist. What's missing: a paid Apple team, a deployed relay, a way off the LAN, encrypted
   payloads, the tree over the bridge, and a CI build. Every item is S–M.
3. **It's parity and differentiation at once.** Claude, Codex and Cursor all ship phone remote
   control in 2026, so a launch without it looks unfinished. None of them has an *org*: no
   started-by tree, no approvals that cascade down a hierarchy, no delegated authority. And
   Claude's Remote Control refuses custom endpoints. frog's would be the first-party remote that
   works for **local and abliterated models on your own hardware**, with no vendor cloud reading
   the content.

## Ranking

| rank | surface | org value | effort | call |
|---|---|---|---|---|
| 1 | (a) iPhone org pager (+ iPad layout) | high | M, mostly plumbing | **build now** |
| 2 | Native watch app v2 (`Watch/DESIGN.md`) | medium-high, the fastest unblock | S–M on top of (a) | after (a) is stable |
| 3 | (c2) Edge node: the bridge protocol hosted by the engine, so a head, home server or Linux box can host the phone | medium, later | M–L (engine) | when the cortex head ships or Mac-sleep bites |
| 4 | (b) iPad "full client" with parity and a CAD viewer | low | L–XL | **don't** |
| 5 | (c1) On-phone agent or model | ~none | L | **don't** |

## Staged plan (gates, not dates)

Each stage ends at a measurable gate, per the master plan's "gates, not calendars".

**Stage 0: stop the bleeding (S, before the repo goes public).**

- Fix the `PillProbe` build break (`FrogFace.swift:34`).
- Add all six iOS and watch schemes to `ci.yml` (Simulator, `CODE_SIGNING_ALLOWED=NO`) on the
  existing `macos-26` job.
- Point `RemotePush.relay` at frog.toys and fix `site/functions/api/push.js`.

*Gate:* CI is green on all seven schemes (Mac plus the six iOS and watch). It matters because
frog goes public on Oct 29 with `apps/ios` in the tree, and that tree doesn't compile today.

**Stage 1: Cam's pager (M). Dogfood on TestFlight.**

- **Cam's task:** finish the Municipal Robotics Apple org enrollment, then the APNs key and
  TestFlight. This is the critical path. Nothing reaches a real phone without it.
- Relay live, with per-Mac caller auth and rate limits.
- **E2E-encrypted push:** the Mac encrypts with a pairing-derived key, and a new Notification
  Service Extension decrypts. The relay and APNs see only ciphertext.
- Off-LAN: support and document BYO tunnel (Tailscale `host:port`) now.
- Bridge sends `parent`. The phone list becomes `AttentionTree` (a needs-you lens plus the org
  tree). Notifications name the chain ("arm › lymb-bom needs you").
- One org Live Activity ("3 need you · 14 running · oldest: 6 min"), replacing per-turn
  activities.
- Protocol version in `hello`/`welcome`. Bridge round-trip tests against fixtures.
- Mac: a power assertion while agents run or wait.
- The watch gets mirrored actionable notifications for free here. Don't touch the watch app yet.

*Gate:* a week of Cam's real use. **Blocked agent-hours from waits over 5 minutes fall by at
least half** against the Oct 22–26 baseline, on the same measure (`layer: ask` →
`permission_resolved`), with no missed or duplicate approvals.

**Stage 2: public (M). Target the ~Nov 17 launch beat, only if the stage 1 gate has passed.
Otherwise ship at the next beat.**

- The hosted **E2E rendezvous relay** (ciphertext only) for reaching the Mac from anywhere
  without a tunnel.
- Org primitives on the phone: approve for a manager's subtree, and standing grants that are
  visible and revocable (today's "relayed approvals" made into objects).
- The native watch app, through `DESIGN.md`'s proposals: a notification scene, Allow/Deny as
  words, "Always allow", and a watch that reaches the relay on its own.
- App Store listing, with iPad as a layout, not a pitch.

*Gate:* an outside user pairs and approves off-LAN on the first try, and the crash-free rate
holds.

**Stage 3: edge node (M–L, engine).** Move the bridge protocol into `frog --serve` (Rust), so the
Mac and Linux share one implementation and a cortex head or home box can host the phone. The
phone app doesn't change. *Gate:* the org survives a closed MacBook lid.

## What not to build

- **An iPad "full client" built for parity.** The Mac lands 200+ commits a day, and parity
  can't be kept. Ship iPad as a layout of the remote. List the Mac-only features in the app,
  plainly.
- **A CAD viewer in frog's iOS app.** It belongs to vcad's roadmap (the staged one-app
  decision), not to the remote.
- **An on-phone coding agent or model.** There's no shell, no repos and no builds, and 4–8B
  models run under jetsam limits. The market agrees: nobody ships one. The local-freedom tier
  lives on *your hardware*, and the phone is its remote.
- **Approval *policy* as a phone feature.** Policy belongs to the engine's classifier and the
  delegation pipeline. The phone shows and answers. It doesn't decide.
- **Android.** Not before the iOS pager clears stage 2.

## Pricing (flagged for Cam)

The ROADMAP puts "approving from your phone" and "reach your GPU from anywhere" under frog Pro.
Proposal:

- **Free:** LAN and BYO-tunnel remote, plus push through the relay, rate-limited. Push costs
  next to nothing, and gating it would break the local-freedom story.
- **Pro:** the hosted E2E relay, which is real infrastructure with real cost.

This keeps "complete product" true on the free tier and gives Pro a concrete reason to exist.

## Honest risks

1. **The test matrix multiplies, and drift is already here.** One Mac app becomes the Mac plus
   iPhone, iPad, four extensions, the watch and its complication. The `PillProbe` break shows the
   failure mode: a Mac benchmark commit broke five iOS and watch targets, and nobody knew.
   *Mitigation:* stage 0's CI gate is non-negotiable, and the fixtures drive every surface
   headless.
2. **Bridge version skew.** Mac DMGs ship daily, while App Store review takes days. A second
   protocol with no version field will break phones silently. *Mitigation:* versioned
   `hello`/`welcome` with a "your Mac is newer" state, and the bridge as a contract with tests.
3. **SwiftUI and watchOS constraints.**
   - No raw sockets on the watch, which is why it uses `URLSession` `wss://` and not the phone's
     TLS-PSK.
   - Tight background runtime. WatchConnectivity is best-effort, and complication refreshes are
     budgeted.
   - The watch app has no notification scene yet, so wrist answers depend on mirroring until
     stage 2.
   - The watch build compiles only `Core` and `UI/Basics`, so any FrogKit change that crosses a
     folder breaks it (see risk 1).
4. **Approving irreparable actions from a lock screen.** Cam's rule is to care only about
   irreparable harm. *Mitigation:*
   - Allow already needs Face ID.
   - The irreparable class (`rm`, `ssh`, pushes, deploys: whatever the classifier flags) shows
     the full command on the phone, and the watch can only *deny* it.
   - The phone never offers "always allow" for that class.
5. **Privacy debt if stage 1 is rushed.** Plaintext command text and diffs through the frog
   relay and APNs would contradict privacy-first. E2E push is in stage 1 for that reason, not
   in stage 2.
6. **The Mac is a single point of failure.** If the lid closes, the org stops, and the pager
   shows nothing. The power assertion helps. Only stage 3 fixes it.
7. **Apple enrollment is out of our hands.** D-U-N-S and org verification gate APNs, TestFlight
   and the App Store. If it slips, stage 1 slips with it, whatever the engineering.
8. **Focus cost.** Two launch beats are in flight. Stage 0 is small and protects the Oct 29
   public repo. Stages 1–2 should be one owner's lane, not spread across the org.
