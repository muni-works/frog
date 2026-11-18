#!/bin/zsh
# Phase 1 captures of the web transcript, light and dark, at 1280 and 375 wide. Needs the parity
# gateway + vite on 5288 (docs/design/parity/fixture.jsonl) and the long-prose gateway + vite on
# 5287 (long-prose.jsonl); see README.md in this folder. Writes PNGs next to this script.
set -e
HERE=${0:A:h}
SHOT=$HERE/../../parity/web-shot.mjs
CODE=${CODE:-http://127.0.0.1:5288/s/s_parity}
PROSE=${PROSE:-http://127.0.0.1:5287/s/s_parity}
for look in light dark; do
  for w in 1280 375; do
    h=$([[ $w == 375 ]] && echo 812 || echo 800)
    WEB_SHOT_SCROLL='.tx > .turn' node $SHOT $CODE $HERE/coding-turn-$w-$look.png $w $h $look >/dev/null
    WEB_SHOT_SCROLL='.line-row[data-state="failed"]' node $SHOT $CODE $HERE/failed-opened-$w-$look.png $w $h $look >/dev/null
    WEB_SHOT_CLICK='.line-row.fold .line' WEB_SHOT_SCROLL='.line-row.fold' WEB_SHOT_HOVER='.fold-steps .line-row .line' node $SHOT $CODE $HERE/fold-opened-$w-$look.png $w $h $look >/dev/null
    WEB_SHOT_SCROLL='.tx > .turn' node $SHOT $PROSE $HERE/long-prose-$w-$look.png $w $h $look >/dev/null
    print "$look $w"
  done
done
