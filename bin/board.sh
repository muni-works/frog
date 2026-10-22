#!/bin/zsh
# board.sh: one-shot visibility board — sessions, worker procs, logs, CI, cloud, disk.
# Also writes logs/board.md with a timestamp header.
set -uo pipefail
out=""

add() { out+="$*"$'\n'; }
# everything the board prints also lands in out (via a wrapper): stdout is tee'd
exec > >(tee /tmp/board.out) 2>/dev/null
trap 'add_from=/tmp/board.out' EXIT

echo "== sessions ($(date +%H:%M))"
probes=0
typeset -a lines; lines=()
while IFS=$'\t' read -r id cwd title; do
  [[ -z $id ]] && continue
  if [[ $title == "reply with just: ok" || $title == "hey" || $title == "hi" || $title == "Untitled" || $title == "greeting" ]]; then
    (( probes++ )); continue
  fi
  repo=${cwd:h:t}; [[ $cwd == */.claude/worktrees/* ]] && repo="$repo/${cwd:t}"
  state=idle; [[ -f /Users/cam/.local/share/frog/sessions/$id.live ]] && state=RUN
  label=${title[1,40]}
  lines+=("$(printf "%-3s %-38s %s" "$state" "$repo" "$label")")
done < <(~/Developer/chief/bin/frog-worker --sessions --json | jq -r '.[] | [.id, .cwd, (.title // "Untitled")] | @tsv' 2>/dev/null | sort -u)
(( probes )) && lines+=("($probes probes)")
printf "%s\n" "${(O)lines[@]}" 2>/dev/null | head -28

echo ""
echo "== worker procs"
pids=$(pgrep -f "bin/frog-worker -m" 2>/dev/null)
if [[ -n $pids ]]; then
  for p in $(echo $pids | head -10); do
    d=$(lsof -a -p $p -d cwd -Fn 2>/dev/null | grep ^n | sed 's/^n//' | sed 's#.*/worktrees/##')
    echo "pid $p ${d:-?}"
  done
else
  echo "none"
fi

echo ""
echo "== latest logs"
for f in $(ls -t ~/Developer/chief/logs/*.log 2>/dev/null | head -8); do
  age=$(( $(date +%s) - $(stat -f %m $f) ))
  flag=""; (( age > 1200 )) && flag=" [stale ${age}s]"
  printf "%s: %s%s\n" "${f:t}" "$(tail -c 140 $f | tr '\n' ' ' | cut -c1-140)" "$flag"
done

echo ""
gh run list -R ecto/frog -b main -L 1 --json conclusion,headSha,displayTitle -q '.[0] | "frog main CI: \(.conclusion // "pending") \(.headSha[0:7]) \(.displayTitle)"' 2>/dev/null
echo "frog cloud: $(curl -s -m 8 https://api.frog.toys/status | grep -c 'Serving now') serving"
echo "disk: $(df -g / | tail -1 | awk '{print $4}')G free"

exec >&- 2>&-  # wait for tee to flush
{ echo "# board $(date '+%Y-%m-%d %H:%M')"; echo; cat /tmp/board.out; } > ~/Developer/chief/logs/board.md
