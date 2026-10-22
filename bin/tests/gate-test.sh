#!/bin/zsh
# gate-test.sh: self-checks for the queue-gate hardening. Builds a throwaway repo + origin
# under /private/tmp/chief-gate-test (deleted on exit) and verifies:
#   (a) a branch with 0 new commits gates NOT DONE
#   (b) a new worktree branch tracks origin/<branch>, not origin/main
#   (c) a space-separated lane line with a note parses into r, w and note
#   (d) a lane line without a note parses with an empty note
#   (e) a pipe-separated line with a note keeps pipe semantics
# Never touches real repos, queues or logs. No network.
set -uo pipefail
W=${0:A:h:h:h}                        # repo root (absolute): $0 -> file -> tests -> bin -> repo
T=/private/tmp/chief-gate-test
rm -rf $T; mkdir -p $T; trap 'rm -rf $T' EXIT

fail=0
ok()   { echo "ok   - $1"; }
bad()  { echo "FAIL - $1"; fail=1; }

# --- fixture: origin repo + clone with branches
git init -q --bare $T/origin.git
git init -q $T/upstream && git -C $T/upstream commit -q --allow-empty -m base \
  && git -C $T/upstream remote add origin $T/origin.git \
  && git -C $T/upstream push -q origin HEAD:refs/heads/main
git clone -q $T/origin.git $T/clone

# (a) a branch with 0 commits over main -> NOT DONE
git -C $T/clone checkout -q -b empty-branch main
r=$(zsh $W/bin/gate.sh demo $T/clone 2>/dev/null)
[[ $r == "NOT DONE: no commits"* ]] && ok "(a) 0-commit branch -> NOT DONE ($r)" || bad "(a) expected NOT DONE, got: $r"
git -C $T/clone commit -q --allow-empty -m "real work"
r=$(zsh $W/bin/gate.sh demo $T/clone 2>/dev/null)
[[ $r == "done" ]] && ok "(a2) commits present -> done (unknown repo skips checks)" || bad "(a2) expected done, got: $r"

# (b) new worktree branch tracks origin/<branch> — like spawn-worker.sh does
git -C $T/clone checkout -q -b feature-x main && git -C $T/clone commit -q --allow-empty -m feature \
  && git -C $T/clone push -q origin feature-x   # so origin/feature-x exists
git -C $T/clone checkout -q main                # feature-x stays for the worktree to create
wt=$T/clone/.claude/worktrees/gate-b
git -C $T/clone branch -D feature-x >/dev/null  # spawn-worker creates the branch in the worktree
git -C $T/clone worktree add -q --no-track -b feature-x $wt origin/main 2>/dev/null
git -C $wt config branch.feature-x.remote origin
git -C $wt config branch.feature-x.merge refs/heads/feature-x
up=$(git -C $wt rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)
[[ $up == origin/feature-x ]] && ok "(b) upstream is origin/feature-x" || bad "(b) upstream is '$up', want origin/feature-x"
# reproduce the old behavior to prove the test can catch it
wt_old=$T/clone/.claude/worktrees/gate-b2
git -C $T/clone worktree add -q -b feature-old $wt_old origin/main 2>/dev/null
up_old=$(git -C $wt_old rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)
[[ $up_old == origin/main ]] && ok "(b2) control: old -b form gives origin/main (test catches it)" || bad "(b2) control unexpected: '$up_old'"

# (c)+(d) lane parsing: replicate run-queue.sh's loop without spawning workers
parse() {
  local line=$1 repo branch task note
  if [[ $line == *'|'* ]]; then
    IFS='|' read -r repo branch task note <<< "$line"
  else
    read -r repo branch note <<< "$line"
  fi
  REPLY_R=$repo REPLY_W=$branch REPLY_NOTE=$note
}
parse "frog frog-tool-output-caps keep the good partial work"
[[ $REPLY_R == frog && $REPLY_W == frog-tool-output-caps && $REPLY_NOTE == "keep the good partial work" ]] \
  && ok "(c) 'r w note' parses into r, w, note" || bad "(c) got r='$REPLY_R' w='$REPLY_W' note='$REPLY_NOTE'"
[[ $REPLY_W != *" keep"* ]] && ok "(c2) w is just the branch (no note bleed into cd path)" || bad "(c2) note bled into w: '$REPLY_W'"
parse "tang tang-fast-boot"
[[ $REPLY_R == tang && $REPLY_W == tang-fast-boot && -z $REPLY_NOTE ]] \
  && ok "(d) no-note lane parses with empty note" || bad "(d) got note='$REPLY_NOTE'"
parse "zest|zest-accounts-stripe|do billing|note: continue branch"
[[ $REPLY_R == zest && $REPLY_W == zest-accounts-stripe && $REPLY_NOTE == "note: continue branch" ]] \
  && ok "(e) pipe line with note parses" || bad "(e) got r='$REPLY_R' w='$REPLY_W' note='$REPLY_NOTE'"

# syntax check every changed script
for s in bin/gate.sh bin/run-queue.sh bin/resume-worker.sh bin/resume-worker.run.sh bin/spawn-worker.sh; do
  zsh -n $W/$s 2>/dev/null && ok "zsh -n $s" || bad "zsh -n $s"
done

echo; (( fail )) && { echo "RESULT: FAIL"; exit 1; } || echo "RESULT: all green"
