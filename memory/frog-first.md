---
name: frog-first
description: Cam (2026-10-22) - do all work through frog (GLM-5.3 workers, chief in Frog.app); this Claude session only when impossible otherwise
metadata:
  type: feedback
---
Cam, 2026-10-22: "let's use frog for everything going forward - no more work here unless it's impossible without."
**Why:** Claude credits are nearly gone, and the point is dogfooding frog as the company's agent platform.
**How to apply:** route work to frog workers (~/Developer/chief/bin/spawn-worker.sh, default model vercel/zai/glm-5.3; or StartSession in Frog.app's chief session). Do hands-on work here only for things frog genuinely can't do (e.g. its own broken tooling blocking all workers), and say so first. Related: [[frog-chief]], [[delegate-dont-do]].
