#!/bin/zsh
# status.sh: quick board for the chief.
echo "== workers running"
pgrep -fl "Resources/frog -m" | grep -v -- "--serve" | sed -E 's/ -p .*//' || echo "none"

echo "\n== recent worker logs (last line each)"
for f in $(ls -t ~/Developer/chief/logs/*.log 2>/dev/null | head -6); do
  printf "%s: " ${f:t}; tail -c 160 $f | tr '\n' ' ' | cut -c1-150; echo
done

echo "\n== open PRs"
for r in ecto/frog ecto/tang ecto/zest ecto/vcad ecto/muni ecto/home; do
  gh pr list -R $r --json number,title,isDraft -q '.[] | "\(.number) \(if .isDraft then "[draft] " else "" end)\(.title)"' 2>/dev/null \
    | head -5 | sed "s#^#$r#"
done

echo "\n== frog cloud"
curl -s -m 8 -o /dev/null -w "api.frog.toys/health %{http_code}\n" https://api.frog.toys/health

echo "\n== disk"
df -h / | tail -1 | awk '{print $4" free"}'
