# Idea: text chief in iMessage

Status: idea, parked 2026-11-12. Not scheduled.

Chief is the long-lived, pinned session that starts and runs the others (see "The chief pattern" in [reference.md](../reference.md)). The idea: you text chief like a contact, and it texts you when something needs you. Inspired by [miora](https://getmiora.com), an AI coach that lives in iMessage and WhatsApp.

## How others do it

Apple has no iMessage API for bots. Every iMessage assistant runs real Macs signed into real Apple IDs, with code that reads and sends messages, behind a REST API and webhooks. Providers: Sendblue, Linq, LoopMessage, Blooio (roughly $40–500/month plus per-number fees). AI-agent plans are often inbound-first (the bot can't start a chat), and Apple blocks numbers that look spammy.

## Option 1: bring your own Apple ID (local, power users)

- A chief Apple ID you own, signed into Messages on the one Mac that runs chief. Never a shared Frog Apple ID.
- A `frog-imessage` sidecar (like `frog-apple`, `frog-desktop`) reads `~/Library/Messages/chat.db` (Full Disk Access) and sends with AppleScript (Automation permission).
- Texts from the allow-listed number arrive as an `Op::Deliver` wrapped `<imessage from="…">`; chief's reply goes back through Messages, kept short.
- Chief can text first (a child finished, needs you, failed), with quiet hours and a digest mode.
- Your own Apple ID instead works for inbound (the message-yourself thread), but iOS doesn't notify you of your own sent messages, so chief can't get your attention. A hybrid fixes that: inbound by iMessage, outbound as a Frog iOS app push.
- Limits: the Mac must be awake and signed in; `chat.db` isn't a public API and can shift between macOS releases.

## Option 2: hosted Frog number (the product)

- One Frog iMessage number, run server-side by a provider at first, later possibly Frog's own Mac minis. The Apple ID lives only there; nothing is signed in on users' machines.
- Users verify their phone number once in the Frog app (a code). zest maps the sender to the verified account and routes to that user's chief. Unknown numbers get a "sign up at frog.toys" reply, never access.
- iMessage senders are Apple-authenticated; SMS is spoofable, so SMS fallback can read status but never act.
- Risky actions (merge, push, delete, spend) are confirmed with a Frog app push and Face ID, not a typed "y".
- zest owns the webhook contract, so the backend (provider or our own Macs) is swappable.
- Chief in Frog Cloud works directly. Chief on the user's Mac needs an outbound link from the Mac to zest, which is the relay question ("no relay for now"), to decide separately.

## Recommendation when picked up

v1: a provider, cloud chief only, phone verification, iMessage-only commands, risky actions confirmed in the app. Offer option 1 as "bring your own Apple ID" for fully local users. Decide the relay once cloud chief shows people use it.
