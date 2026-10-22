#!/bin/zsh
# session-wait.sh <session-id-prefix> [timeout_s=900]: wait until a frog session is
# idle/ended. Exit 0 when settled, 124 on timeout.
set -uo pipefail
prefix=$1; timeout=${2:-900}
deadline=$(( $(date +%s) + timeout ))
while true; do
  now=$(date +%s); (( now > deadline )) && { echo "timeout: no session '${prefix}' or still running"; exit 124; }
  line=$(~/Developer/chief/bin/frog-worker --sessions --json 2>/dev/null | jq -r --arg p "$prefix" \
    '[.[] | select(.id | startswith($p))][0] // empty | "\(.id) \(.title)"' 2>/dev/null) || line=""
  if [[ -n $line ]]; then
    id=${line%% *}
    if [[ -f /Users/cam/.local/share/frog/sessions/$id.live ]]; then
      echo "running $line"
    else
      echo "idle $line"; exit 0
    fi
  fi
  sleep 10
done
