---
name: codex-agents
description: Since 2026-10-21 Claude usage is nearly exhausted — all Claude managers paused; chief of staff dispatches work to Codex agents (codex exec, ChatGPT subscription) instead
metadata:
  type: project
---
Cam (2026-10-21 evening): Claude weekly usage 90% + $4k credits spent; "pause everything here, and use codex agents through you". All Claude manager sessions told to commit, push and go idle (zest: no always-on, pods terminated).

How to dispatch: `cd <repo worktree> && codex exec --skip-git-repo-check -s workspace-write "<task>"` (read-only tasks: `-s read-only`). Codex CLI via Homebrew cask (`brew reinstall --cask codex` if broken). Logged in with ChatGPT; default model is gpt-6-luna. Don't set `model` in ~/.codex/config.toml — gpt-6-astra etc. are rejected on the ChatGPT plan (backup at config.toml.bak).

**Why:** Codex is a flat-rate subscription; Claude spend is unaffordable this week.
**How to apply:** be frugal in Claude — short turns, no Monitor watcher, run codex jobs in background (run_in_background) and read only their final summaries; one worktree per codex task; codex commits locally, I review diffs before any push/merge. Related: [[delegate-dont-do]], [[manager-structure]].
Gotchas: codex's workspace-write sandbox can't commit inside git worktrees (git dir outside workspace) — I commit after reviewing, or add the repo .git dir as writable. Codex may change security defaults to 'fix' things — review diffs; prefer local config (frog: ~/.config/frog/config.toml [sandbox] allow_read/allow_keychain).
Queued for 'frog fixes frog' (via codex/ backend once it lands): composer model default — app setting 'New messages use: last model in this chat | fixed default', default = last in chat; new chats use last picked anywhere. Bug seen: chat used Qwen3 Coder Next (frog cloud) but composer showed Qwen3 4B. Flow: frog on codex/default → PR → merge → rebuild + relaunch Frog.app.
Next frog-fixes-frog job (queued 2026-10-21): CLI and app aware of each other — 'frog -p'/CLI sessions saved to the same session store, appear live in Frog.app's sidebar (running badge, streaming transcript), and the app can attach/continue them; CLI can list/attach app sessions.
Queued (Cam 2026-10-21): print the cortex ear panels FROM THE vcad MAC APP, not CLI. After codex/p1s-connect (SNI=serial fix) lands: Codex job for minimal Mac File ▸ Print… — open STL/3MF or current part, slice with vcad-slicer (no supports), preview, printer from ~/.config/vcad/printers.toml, LAN send, live status/camera, Cam's click to start. Printer now 192.168.2.160, fw 01.10.

2026-10-21 late: codex rollout logs report plan_type=free, primary 30-day window 100% used, running on credits (~62k balance). Cam chose: default agents to frog cloud once 128k is live; codex only as fallback. Limits shown via rate_limits in ~/.codex/sessions rollout files.
