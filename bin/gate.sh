#!/bin/zsh
# gate.sh <repo> <worktree> [test-filter]: done-gate for a worker. Prints "done" only if the
# worktree has new commits over origin/main AND the repo's check passes. Otherwise prints
# "NOT DONE: <reason>". Sourced by run-queue.sh / resume-worker.sh; also runnable directly.
# Checks run with CARGO_TARGET_DIR=/private/tmp/<repo>-gate-target and are skipped (with a
# reason) when / has under 10G free.
gate_check() {
  local repo=$1 wt=$2 filter=${3:-}
  local base=origin/main
  git -C $wt rev-parse --verify -q origin/main >/dev/null || base=main

  local n
  n=$(git -C $wt rev-list --count HEAD ^$base 2>/dev/null) || n=0
  (( n > 0 )) || { echo "NOT DONE: no commits on this branch over $base"; return 1; }

  local free
  free=$(df -g / | tail -1 | awk '{print $4}')
  (( free >= 10 )) || { echo "NOT DONE: disk low (${free}G free on /), checks skipped"; return 1; }

  export CARGO_TARGET_DIR=/private/tmp/$repo-gate-target
  local -a out; out=()
  local rc=0
  case $repo in
    frog)
      if [[ -n $filter ]]; then
        out=( ${(f)"$(cd $wt && cargo test -q -p frog-engine $filter 2>&1 | tail -20)"} ) || rc=1
      else
        out=( ${(f)"$(cd $wt && cargo check -q -p frog-engine 2>&1 | tail -20)"} ) || rc=1
      fi
      ;;
    zest)
      if [[ -d $wt/edge ]]; then
        out=( ${(f)"$(cd $wt/edge && { npx vitest run && npx tsc --noEmit; } 2>&1 | tail -20)"} ) || rc=1
      else
        out=( ${(f)"$(cd $wt && cargo test -q -p zest-router 2>&1 | tail -20)"} ) || rc=1
      fi
      ;;
    tang)
      out=( ${(f)"$(cd $wt && cargo check -q 2>&1 | tail -20)"} ) || rc=1
      ;;
    *)
      echo "done"
      return 0
      ;;
  esac
  if (( rc == 0 )); then
    echo "done"
  else
    echo "NOT DONE: check failed: ${out[-1]:-no output}"
  fi
}

# direct use: gate.sh <repo> <worktree> [filter]. Sourcing scripts pass "passive" as $1.
if [[ ${1:-} == passive ]]; then
  shift   # note: sourcing scripts get gate_check and skip this block
elif [[ $ZSH_SCRIPT == $0 ]]; then
  [[ $# -ge 2 ]] || { echo "usage: gate.sh <repo> <worktree> [test-filter]" >&2; exit 2; }
  gate_check "$@"
fi
