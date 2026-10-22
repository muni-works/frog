#!/bin/zsh
# resume-worker.sh <repo> <worktree-name> [note]: fork the worker's last session in its worktree and
# continue (a fork never collides with a locked or half-written session). Runs in the foreground.
set -uo pipefail
wt=~/Developer/$1/.claude/worktrees/$2
log=~/Developer/chief/logs/$(date +%Y%m%d-%H%M%S)-$1-$2-resume.log
cd $wt || exit 1
[[ $2 == frog-cf-gateway-eval ]] && { set -a; source ~/.config/cloudflare/keys.txt; set +a; }
export CARGO_TARGET_DIR=~/Developer/.shared-target/$1
id=$(~/Developer/chief/bin/frog-worker --sessions --json 2>/dev/null | jq -r '.[0].id')
~/Developer/chief/bin/frog-worker -m vercel/zai/glm-5.3 --accept-edits --fork $id -p "You were stopped (step limit / disk full; both fixed). ${3:-} Check git status and git diff for your partial work, finish the task, run the relevant tests, and commit on this branch with git commit -s. Stay inside $wt. Don't delete build dirs outside it. Reply with a short summary of what you committed." > $log 2>&1
echo "$(date +%H:%M) done $1:$2 $(git log --oneline -1)"
