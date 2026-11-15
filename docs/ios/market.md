# Market scan: coding agents on iPhone, iPad and Watch (October 2026)

Web sources were checked on 2026-10-26. The claims are what each vendor's docs or launch posts
say. None of these products were hands-on tested.

## What the big players ship

| product | iOS surface | where the work runs | approvals from the phone | push / Live Activity | Watch | constraints |
|---|---|---|---|---|---|---|
| **Claude Code** (Anthropic) | The Claude app's Code tab, iPhone and iPad. Cloud sessions, Remote Control of a local session, Dispatch to the Desktop app.[^cc-mobile] | Cloud VMs, or your machine (Remote Control and Dispatch need it on)[^cc-mobile] | Yes: push "when actions required" for permission prompts and questions[^cc-rc] | Push (two `/config` toggles, no per-event config)[^cc-rc] | No first-party app found | Pro/Max/Team/Enterprise only, no API keys. **Not available if `ANTHROPIC_BASE_URL` points anywhere but api.anthropic.com**, or on Bedrock or Vertex.[^cc-rc] |
| **Codex** (OpenAI) | Inside the ChatGPT app, iPhone, iPad and Android. Preview since 2026-05-14.[^codex][^codex-date] | Your laptop, a Mac mini, a devbox or managed remote environments, through a "secure relay layer"[^codex] | Yes: "approve commands", answer questions, change models[^codex] | Real-time updates: screenshots, terminal output, diffs[^codex] | No first-party app found | "Keep your computer awake and online."[^codex-learn] The relay syncs session state through ChatGPT.[^codex] |
| **Cursor** | A native iOS app (iPhone and iPad, iOS 26+). Launched 2026-06-29.[^cursor-help][^cursor-launch] | Cloud agents in VMs, or Remote Control of the desktop Agents window. With Remote Control, "the agent loop moves to the cloud while its tools keep running on your machine".[^cursor-help] | Steer, review and merge PRs[^cursor-help] | **Live Activities tracking up to 8 agents at once**[^cursor-help] | No | Paid plans. Remote Control is beta, and you must keep the computer awake with the workspace open. The iPad layout has a sidebar, a split review and Pencil markup.[^cursor-help] |
| **GitHub Copilot** | GitHub Mobile: start and track cloud-agent sessions, native session logs, a Copilot tab[^gh-mobile][^gh-changelog] | GitHub's cloud (Actions runners) | PR review flow, not per-command approvals | GitHub notifications | No | Bound to GitHub repos and the cloud agent |
| **Devin** (Cognition) | **Waitlist only** for "Devin Mobile": start sessions and merge PRs[^devin] | The cloud, "or on your machine" per press coverage[^devin-press] | — | — | No | Not shipped |
| **Windsurf** | No first-party mobile app. Third-party bridges exist (e.g. CodeAgent Mobile, an Open VSX extension plus an app).[^windsurf3p] | — | Third-party only | — | — | — |

## Third parties: the watch is *not* novel for single-agent approvals

A cottage industry wraps other vendors' hooks and already does phone and watch approvals:

- **Agent Approve** (App Store). Hooks into Claude Code, Codex, Cursor, Copilot, Windsurf,
  OpenCode, OpenHands and others. Events go "through our cloud". It offers push, one-tap Apple
  Watch approvals, voice follow-ups, and centralized auto-approve/deny policies. It shows
  "subagent observability" for one agent (Antigravity).[^agentapprove]
- **BotBus** (App Store, Mac menu-bar host plus a Linux CLI). Approves Claude Code and Codex
  prompts from the watch, answers Asks by tap or dictation, interrupts, and starts tasks by
  voice. The watch syncs credentials from the phone through WatchConnectivity, then reaches a
  relay on its own over cellular.[^botbus]
- **claude-watch** (open source): watch control of Claude Code.[^claudewatch]
- Several "Claude Code from your phone" guides cover native Remote Control, Tailscale + mosh +
  Termux, and tmux over SSH.[^explainx]

So **"approve a permission from my watch" is table stakes**, not a moat. frog's watch app does
roughly what BotBus does today, and BotBus already has a watch-direct relay. Claiming the watch
as novel would be wrong.

## What nobody does: approvals for an *org* of agents

Every product above models the user ↔ one agent, or a flat list of agents. Agent Approve's
"centralized policies" are static rules, not a hierarchy. None of them has:

1. **The started-by tree on the phone.** "arm › lymb-bom › worker needs you", with its siblings
   and the manager's state. frog already has this logic in `AttentionTree.swift` and
   `SessionNesting.swift`. It only has to cross the bridge.
2. **Approvals that cascade down the hierarchy.** For example, "approve for this manager's
   subtree", or "relay counts for routine merges", the standing line the org already uses in
   text. Answering a manager's escalation unblocks N workers.
3. **A needs-you triage across the org**, ordered oldest-first with the cost of waiting
   (blocked children × time). The org pager's Live Activity becomes "3 need you · 14 running"
   rather than Cursor's "8 agents".
4. **Delegated authority as a first-class object**: the chief of staff decides, and the phone
   shows only what's above everyone's authority. Today that's prose in memory files.
   On a phone it becomes a visible, revocable grant.
5. **Any model, any host, with no vendor cloud reading the content.** Claude's Remote Control
   refuses custom base URLs. Codex and Cursor route through their own relays and clouds. frog's
   bridge is TLS-PSK, direct on the LAN. Done right (E2E-encrypted relay and push), it's the
   only first-party mobile remote that works with **local and abliterated models on your own
   hardware**: the local-freedom tier.

## Demand signal

1. **Cam (data point #1, measured).** 1,106 human approvals from Oct 22 to 26. The median wait
   was 16.5 s, but **8% of approvals produced 83% of the 58 blocked agent-hours**, because those
   came while he was away (inventory, "Demand data"). Volume dropped about 7× after the
   classifier and delegation work, and the away-from-desk tail stayed. Better rules make the
   remaining asks rarer and more important, which is exactly what a pager is for.
2. **The market converged on this surface in 2026.** Codex (May), Cursor (June), and Claude
   Remote Control (out of preview this year)[^aicatchup] all ship "steer your local agent from
   your phone". Devin has a waitlist. A coding agent launching without it looks unfinished.
3. **Third parties make money in the gaps.** A paid App Store app (Agent Approve) and BotBus
   exist only to add phone and watch approvals to other vendors' agents. People pay to not be
   chained to the desk.
4. **Counter-signal.** Nobody ships a full IDE on iPad. Cursor's iPad is "a control panel" with
   a bigger diff view, and the coverage calls it "remote control … not a mobile code
   editor".[^cursor-launch] No major player runs agents *on* the phone.

## Implications for frog

- Phone remote control is **parity**. Ship it or look behind.
- frog's **differentiation** is (1) org-aware approvals and (2) model-agnostic, private,
  self-hosted reach. Both depend on plumbing that frog lacks today: an E2E relay, encrypted push,
  and the tree over the bridge.
- An iPad "full client" and an on-phone model chase things the market has already decided
  against.

[^cc-mobile]: Claude Code on mobile, https://code.claude.com/docs/en/mobile
[^cc-rc]: Remote Control, https://code.claude.com/docs/en/remote-control (requirements, mobile push notifications)
[^codex]: OpenAI, "Work with Codex from anywhere", https://openai.com/index/work-with-codex-from-anywhere/
[^codex-date]: "Codex Mobile: Remote Agent Control from Your Phone via the ChatGPT App", https://codex.danielvaughan.com/2026/05/15/codex-mobile-chatgpt-app-relay-architecture-remote-agent-control/
[^codex-learn]: Codex on mobile, https://learn.chatgpt.com/docs/mobile
[^cursor-help]: Cursor for iOS (help), https://cursor.com/help/ai-features/mobile-app
[^cursor-launch]: "Cursor Ships Mobile App for Steering Coding Agents From iOS", https://webdeveloper.com/news/cursor-mobile-ios-agent-remote-control/ ; changelog https://cursor.com/changelog/ios-mobile-app
[^gh-mobile]: Using Copilot cloud agent on GitHub Mobile, https://docs.github.com/en/copilot/how-tos/use-copilot-agents/cloud-agent/use-cloud-agent-on-mobile
[^gh-changelog]: GitHub Changelog 2026-04-01, https://github.blog/changelog/2026-04-01-github-mobile-stay-in-flow-with-a-refreshed-copilot-tab-and-native-session-logs/
[^devin]: Devin Mobile waitlist, https://devin.ai/mobile
[^devin-press]: https://alphasignal.ai/news/cognition-brings-devin-mobile-to-iphone-so-developers-code-on-the-go
[^windsurf3p]: CodeAgent Mobile, https://www.codeagent-mobile.com/control-windsurf-from-phone ; and https://newly.app/tutorials/windsurf-to-mobile-app (no mobile in Windsurf's docs)
[^agentapprove]: Agent Approve, https://www.agentapprove.com/
[^botbus]: BotBus, "Using your Apple Watch to manage AI coding agents" (2026-09-29), https://botbus.io/en/blog/apple-watch-ai-coding-agent
[^claudewatch]: https://github.com/shobhit99/claude-watch
[^explainx]: https://www.explainx.ai/blog/claude-code-mobile-remote-control-phone-guide-2026
[^aicatchup]: https://aicatchup.com/news/claude-code-remote-control-phone-start
