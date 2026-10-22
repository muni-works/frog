#!/bin/zsh
# disk-clean.sh <safe|caches|worktrees>: delete what the disk-inventory lists name, with
# guards re-checked right before each delete. Logs to /private/tmp/chief-clean.log.
set -uo pipefail
mode=$1
log=/private/tmp/chief-clean.log
cwds=$(for p in $(pgrep -f 'frog'); do lsof -a -p $p -d cwd -Fn 2>/dev/null | sed -n 's/^n//p'; done | sort -u)
active() {  # touched in the last 30 min (depth 3), or some agent's cwd is inside it
  [[ -n $(find "$1" -maxdepth 3 -newermt '-30 minutes' 2>/dev/null | head -1) ]] && return 0
  while read -r c; do [[ -n $c && ( $c == $1 || $c == $1/* || $1 == $c/* ) ]] && return 0; done <<< "$cwds"
  return 1
}
freed=0; skipped=0
case $mode in
  safe)
    while read -r p; do
      [[ $p == \#* || -z $p ]] && continue; p=${p/#\~/$HOME}; [[ -d $p ]] || continue
      [[ $p == $HOME/Developer/* ]] || { echo "GUARD outside Developer: $p" >> $log; continue; }
      case ${p:t} in target|node_modules|.build|DerivedData|dist|.next|build|__pycache__|.venv|venv|.pytest_cache|.mypy_cache|.ruff_cache|.gradle) ;; *) echo "GUARD name: $p" >> $log; continue;; esac
      if active "$p"; then echo "SKIP active: $p" >> $log; (( skipped++ )); continue; fi
      k=$(du -sk "$p" 2>/dev/null | cut -f1); rm -rf "$p" && (( freed += ${k:-0} )) && echo "DEL ${k}K $p" >> $log
    done < /private/tmp/del-safe.txt ;;
  caches)
    xcrun simctl delete unavailable >/dev/null 2>&1; xcrun simctl shutdown all >/dev/null 2>&1
    while read -r p; do
      [[ $p == \#* || -z $p ]] && continue; p=${p/#\~/$HOME}; [[ -e $p ]] || continue
      case $p in $HOME/.cache|$HOME/.cache/*|$HOME/Library/Caches|$HOME/Library/Caches/*|$HOME/Library/Developer/Xcode/DerivedData|$HOME/Library/Developer/CoreSimulator|$HOME/.npm/_cacache|$HOME/Library/pnpm/store|$HOME/.cargo/registry/cache) ;; *) echo "GUARD cache path: $p" >> $log; continue;; esac
      if [[ $p == $HOME/Library/Developer/CoreSimulator ]]; then k=$(du -sk "$p" 2>/dev/null | cut -f1); xcrun simctl delete all >/dev/null 2>&1; rm -rf "$p/Caches" 2>/dev/null; echo "DEL simctl all (was ${k}K)" >> $log; continue; fi
      k=$(du -sk "$p" 2>/dev/null | cut -f1); rm -rf "$p" 2>/dev/null; echo "DEL ${k}K $p" >> $log; (( freed += ${k:-0} ))
    done < /private/tmp/del-caches.txt ;;
  worktrees)
    while read -r line; do
      [[ $line == \#* || -z $line ]] && continue; p=${line##*$'\t'}; p=${p/#\~/$HOME}; [[ -d $p ]] || continue
      [[ $p == $HOME/Developer/*/.claude/worktrees/* || $p == $HOME/Developer/*/.frog/worktrees/* ]] || { echo "GUARD not a worktree path: $p" >> $log; continue; }
      if active "$p"; then echo "SKIP active: $p" >> $log; (( skipped++ )); continue; fi
      if [[ -n $(git -C "$p" status --porcelain 2>/dev/null | head -1) ]]; then echo "KEEP dirty: $p" >> $log; (( skipped++ )); continue; fi
      main=$(git -C "$p" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); main=${main%/.git}
      k=$(du -sk "$p" 2>/dev/null | cut -f1)
      if git -C "$main" worktree remove "$p" 2>>$log; then echo "RM-WT ${k}K $p" >> $log; (( freed += ${k:-0} )); else echo "FAIL wt: $p" >> $log; fi
    done < /private/tmp/del-stale-worktrees.txt
    for r in $(grep -v '^#' /private/tmp/del-stale-worktrees.txt | awk -F'\t' '{print $NF}' | sed -E "s#^~#$HOME#; s#/\.(claude|frog)/worktrees/.*##" | sort -u); do git -C "$r" worktree prune 2>/dev/null; done ;;
esac
printf "%s: freed %.1fG, skipped %d\n" $mode $(( freed / 1048576.0 )) $skipped | tee -a $log
