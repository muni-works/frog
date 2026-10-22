---
name: agent-model-policy
description: "Cam's rule for agent models — sessions I start run Opus 5.5, never fast mode; their sub-agents pick Opus or Sonnet at their discretion"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 8c3dcc85-ad81-4ab4-9e67-2dd50bec4698
  modified: 2026-10-20T23:39:40.662Z
---

Every session I (chief of staff) start runs on claude-opus-5-5 ("cheap opus", i.e. not fast mode). Sub-agents those sessions open: their own call between Opus and Sonnet. Never fast mode for any agent.

**Why:** cost — Cam said so on 2026-10-20 while scaling up the manager structure.
**How to apply:** after each start_session, check get_session (model, fastMode) and fix with set_session_model / set_session_fast_mode(false). Include the rule in every manager brief so it propagates. Related: [[manager-structure]].
