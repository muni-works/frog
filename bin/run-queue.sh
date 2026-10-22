#!/bin/zsh
# run-queue.sh <queue-file>: run jobs one at a time. Each job is a block "repo|branch|task" on a
# single line. Waits for frog cloud before each job and waits for the worker to exit.
q=$1
while IFS='|' read -r repo branch task; do
  [[ -z $repo || $repo == \#* ]] && continue
  until curl -s -m 8 https://api.frog.toys/status | grep -q "Serving now"; do sleep 30; done
  out=$(~/Developer/chief/bin/spawn-worker.sh "$repo" "$branch" "$task")
  echo "$(date -u +%H:%MZ) $out"
  pid=$(echo "$out" | sed -nE 's/worker pid ([0-9]+).*/\1/p')
  while kill -0 $pid 2>/dev/null; do sleep 20; done
  echo "$(date -u +%H:%MZ) done $repo:$branch"
done < $q
