#!/bin/zsh
# merge-when-green.sh <repo> <pr>...: wait for each PR's checks, squash-merge when all pass.
repo=$1; shift
for pr in "$@"; do
  for i in {1..90}; do
    s=$(gh pr checks $pr -R $repo 2>/dev/null | awk -F'\t' '{print $2}' | grep -vE "skipping" | sort -u | tr '\n' ' ')
    [[ $s == *fail* ]] && { echo "$repo#$pr failing: $s"; break; }
    [[ $s == "pass " ]] && { gh pr merge $pr -R $repo --squash >/dev/null 2>&1; echo "$repo#$pr $(gh pr view $pr -R $repo --json state -q .state)"; break; }
    sleep 60
  done
done
