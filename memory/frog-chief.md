---
name: frog-chief
description: The CoS role is moving into frog. Home is ~/Developer/chief (AGENTS.md brief, bin/ scripts, memory fork). Runs on frog cloud Coder-Next.
metadata:
  type: project
---
2026-10-22: Cam chose to move the chief of staff into frog. Home: ~/Developer/chief (git repo). AGENTS.md is the brief, bin/spawn-worker.sh and bin/status.sh are the tools, and memory/ is a FORK of this memory dir (Cam: "fork into frog"), now canonical for the frog chief. This Claude copy is no longer synced.
Model: frog cloud Qwen3-Coder-Next. Plan: build pond step 1 (spawn/decide tools), move zest ops in as the first lead, then retire the Claude CoS once frog's chief handles a full day.
Related: [[delegate-dont-do]], [[questions-clickable]], [[manager-structure]].

2026-10-22 ~14:50Z: Cam chose a stronger model for the chief. Status test in frog: GLM-5.3 made ~5 factual errors (trusted stale notes and old logs); Opus 5.5 via Vercel (`vercel/anthropic/claude-opus-5.5`) verified live and caught real bugs (merge script repo arg, duplicate queue lines). Chief = Opus via Vercel; workers stay on GLM-5.3.
