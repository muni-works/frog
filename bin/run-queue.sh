#!/bin/zsh
# run-queue.sh <queue-file>: run jobs one at a time. Two lane formats, one job per line:
#   "repo|branch|task"   (pipe-separated; a note may follow a third |)
#   "repo branch [note]" (space-separated, task comes from the worker's queue or lane defaults;
#                         any third field is a note for the worker prompt)
# Waits for the worker to exit, then gates: prints "done" only if the worktree gained
# commits AND the repo check passed (see bin/gate.sh); otherwise "NOT DONE: <reason>".
set -uo pipefail
q=$1
source ~/Developer/chief/bin/gate.sh passive  # defines gate_check; passive = don't gate now

while IFS= read -r line; do
  line=${line%$'\r'}
  [[ -z $line || $line == \#* ]] && continue
  repo=""; branch=""; task=""; note=""
  if [[ $line == *'|'* ]]; then
    IFS='|' read -r repo branch task note <<< "$line"
  else
    # space-separated lane: "r w [note ...]" — the note is everything after the second field
    read -r repo branch note <<< "$line"
  fi
  [[ -z $repo || -z $branch ]] && continue
  [[ -n $note ]] && task="${task:+$task }note: $note"

  out=$(~/Developer/chief/bin/spawn-worker.sh "$repo" "$branch" "$task")
  echo "$(date -u +%H:%MZ) $out"
  pid=$(echo "$out" | sed -nE 's/worker pid ([0-9]+).*/\1/p')
  [[ -n $pid ]] && while kill -0 $pid 2>/dev/null; do sleep 20; done
  wt=~/Developer/$repo/.claude/worktrees/${branch//\//-}
  verdict=$(gate_check $repo $wt)
  echo "$(date -u +%H:%MZ) $verdict $repo:$branch"
done < $q
