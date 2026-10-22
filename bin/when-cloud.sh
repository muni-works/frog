#!/bin/zsh
# when-cloud.sh <spawn-worker args...>: wait until frog cloud reports serving, then spawn.
# Checks the public status page (creates no frog sessions).
for i in {1..120}; do
  curl -s -m 8 https://api.frog.toys/status | grep -q "Serving now" && break
  sleep 30
done
exec ~/Developer/chief/bin/spawn-worker.sh "$@"
