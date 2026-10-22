#!/bin/zsh
# sync-memory.sh: mirror chief/memory/*.md into frog's project memory for ~/Developer/chief,
# as notes frog loads at session start and searches with Recall. Re-run after editing memory/.
set -euo pipefail; setopt null_glob
src=~/Developer/chief/memory
dst=~/.local/share/frog/memory/projects/-Users-cam-Developer-chief
mkdir -p $dst
rm -f $dst/chief-*.md(N)
for f in $src/*.md; do
  n=$(basename $f .md); # MEMORY is the index; the rest are Claude-era notes about Claude sessions and models.
  [[ $n == (MEMORY|manager-structure|trust-chief-of-staff|zest-orchestrator|codex-agents|agent-model-policy) ]] && continue
  created=$(date -r $f +%Y-%m-%dT%H:%M:%SZ)
  # Drop the source file's own frontmatter; frog's goes on top.
  body=$(awk 'NR==1&&/^---$/{f=1;next} f&&/^---$/{f=0;next} !f' $f)
  printf -- "---\nid: chief-%s\ncreated: %s\nscope: project\nsource: chief-sync\n---\n%s\n" "$n" "$created" "$body" > $dst/chief-$n.md
done
ls $dst/chief-*.md | wc -l | xargs echo "synced notes:"
