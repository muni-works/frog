---
name: worker-rules
description: lessons from running frog workers on 2026-10-22 (disk, limits, resume, titles)
---
- Run at most 3 workers at once via queue lanes; share CARGO_TARGET_DIR per repo (~/Developer/.shared-target/<repo>); parallel builds filled the disk and corrupted sessions.
- Resume a dead worker with bin/resume-worker.sh (forks its last session); never `-c` (collides with locked or half-written sessions).
- Workers use ~/Developer/chief/bin/frog-worker (CLI built from main), not Frog.app's binary.
- Hosted models need an explicit output budget (frog#49); GLM thinking hit the gateway default and turns ended MaxTokens.
- Mid-stream gateway errors (Baseten "upstream stream ended") aren't retried yet: frog/stream-retry.
- Put the task first and the RULES after it in prompts, so session titles come from the task.
