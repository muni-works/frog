#!/bin/zsh
# Phase 3 captures (the turn line and the turn panel), light and dark, at 1280 and 375. Needs the
# parity gateway + vite on 5288 (../../parity/fixture.jsonl, whose turn 1 carries a pace record).
set -e
HERE=${0:A:h}
SHOT=$HERE/../../parity/web-shot.mjs
CODE=${CODE:-http://127.0.0.1:5288/s/s_parity}
for look in light dark; do
  for w in 1280 375; do
    h=$([[ $w == 375 ]] && echo 812 || echo 800)
    WEB_SHOT_SCROLL='.turn-foot' WEB_SHOT_HOVER='.turn-foot .turn-graph svg' node $SHOT $CODE $HERE/p3-turn-line-hover-$w-$look.png $w $h $look >/dev/null
    WEB_SHOT_SCROLL='.turn-foot' WEB_SHOT_CLICK='.turn-foot .turn-graph svg' node $SHOT $CODE $HERE/p3-turn-panel-$w-$look.png $w $h $look >/dev/null
    print "$look $w"
  done
done
