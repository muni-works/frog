#!/bin/zsh
# spawn-worker.sh <repo> <branch> "<task>" [model]
# Creates a worktree off origin/main and runs a frog worker there in the background.
set -euo pipefail
repo=$1 branch=$2 task=$3 model=${4:-vercel/zai/glm-5.3}
root=~/Developer/$repo
name=${branch//\//-}
wt=$root/.claude/worktrees/$name
log=~/Developer/chief/logs/$(date +%Y%m%d-%H%M%S)-$repo-$name.log

[[ -d $root/.git ]] || { echo "no repo at $root" >&2; exit 1; }
git -C $root fetch -q origin 2>/dev/null || { u=$(git -C $root remote get-url origin | sed -E "s#git@github.com:#https://github.com/#"); git -C $root fetch -q $u "+refs/heads/main:refs/remotes/origin/main" 2>/dev/null || echo "warn: fetch failed, using local origin/main" >&2; }
if [[ ! -d $wt ]]; then
  git -C $root worktree add -q -b $branch $wt origin/main 2>/dev/null \
    || git -C $root worktree add -q $wt $branch
fi

cd $wt
rules="RULES: work ONLY inside $wt (a git worktree). Never cd into ~/Developer/$repo or any other checkout; write with relative paths here; reading elsewhere is fine. Keep command output small (| head -80, jq/grep filters). Commit on this branch when a step is done.

"
CARGO_TARGET_DIR=~/Developer/.shared-target/$repo nohup ~/Developer/chief/bin/frog-worker -m $model -p "$task

$rules" > $log 2>&1 &
echo "worker pid $! · $repo:$branch · $wt"
echo "log $log"
