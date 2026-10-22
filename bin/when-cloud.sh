#!/bin/zsh
# when-cloud.sh <spawn-worker args...>: wait until frog cloud answers, then spawn.
for i in {1..60}; do
  out=$(cd /tmp && perl -e 'alarm 60; exec @ARGV' /Applications/Frog.app/Contents/Resources/frog -m cloud/qwen3-coder-next -p "reply with just: ok" 2>&1 | tail -1)
  [[ $out == ok* ]] && break; sleep 30
done
exec ~/Developer/chief/bin/spawn-worker.sh "$@"
