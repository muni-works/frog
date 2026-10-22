#!/bin/zsh
# wait-ci.sh <repo> <branch> [timeout_s=1200]: poll the newest GitHub Actions run on a
# branch; exit 0 SUCCESS, 1 FAILURE, 124 timeout. One line per state change.
set -uo pipefail
repo=$1; branch=$2; timeout=${3:-1200}
deadline=$(( $(date +%s) + timeout ))
last=""
while true; do
  now=$(date +%s); (( now > deadline )) && { echo "timeout after ${timeout}s (last: ${last:-none})"; exit 124; }
  read -r conc sha title <<<"$(gh run list -R ecto/$repo -b $branch -L 1 --json conclusion,headSha,displayTitle -q '.[0] | "\(.conclusion // "pending") \(.headSha) \(.displayTitle)"' 2>/dev/null)"
  cur="${conc:-pending}"
  if [[ $cur != $last ]]; then
    echo "${cur} ${sha[0,7]} ${title}"
    last=$cur
    [[ $cur == success ]] && exit 0
    [[ $cur == failure ]] && exit 1
  fi
  sleep 15
done
