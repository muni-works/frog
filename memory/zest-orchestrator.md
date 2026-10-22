---
name: zest-orchestrator
description: "the zest agent" = the tang gateway orchestrator session that owns the tang child sessions and RunPod spend
metadata:
  type: project
---

"zest agent" means session local_371045eb-1660-48fa-a9ac-9ffafdf0cc66 (titled "Cloudflare Workers for Tang LLM gateway", app now shows it as "zest"). It spawned the tang child sessions (gpt-oss, flash-coder-requant, h200-fixes, qwen3-coder-next, model-support, kernel-registry, kv-ttl).

As of 2026-10-20 Cam gave it standing orders: manage RunPod costs (can spend the whole balance, ~$51 then), keep children on task, unblock them itself, no idle agents under it. Escalate only for spend beyond balance, merge/deploy, deletes, product decisions.

Two RunPod accounts: `runpodctl` on the Mac is the campedersen.com account (~$51, no pods); the RunPod MCP is the muni account where tang pods actually run. MCP can't read the muni balance — only the console Billing page shows it.

**Why:** Cam wants me (chief of staff) to supervise, and zest to run the tang fleet.
**How to apply:** route tang/RunPod issues to zest first; flag to Cam only what zest escalates or what sits blocked >10 min.
