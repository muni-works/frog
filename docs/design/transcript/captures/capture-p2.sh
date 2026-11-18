#!/bin/zsh
# Phase 2 captures (the live row and its stats), light and dark, at 1280 and 375. Needs the live
# gateway + vite (../../parity/live.mjs --mode full on 8797, vite on 5286) and the stall gateway
# + vite (--mode stall on 8796, vite on 5285). Each shot loads the session fresh and waits until
# the streamed turn reaches the state named.
set -e
HERE=${0:A:h}
SHOT=$HERE/../../parity/web-shot.mjs
LIVE=${LIVE:-http://127.0.0.1:5286/s/s_live}
STALL=${STALL:-http://127.0.0.1:5285/s/s_live}
for look in light dark; do
  for w in 1280 375; do
    h=$([[ $w == 375 ]] && echo 812 || echo 800)
    WEB_SHOT_WAIT=5200 node $SHOT $LIVE $HERE/p2-thinking-$w-$look.png $w $h $look >/dev/null
    WEB_SHOT_WAIT=7400 WEB_SHOT_CLICK='.live-row button.line' node $SHOT $LIVE $HERE/p2-thinking-opened-$w-$look.png $w $h $look >/dev/null
    WEB_SHOT_WAIT=10400 node $SHOT $LIVE $HERE/p2-steps-$w-$look.png $w $h $look >/dev/null
    WEB_SHOT_WAIT=15800 WEB_SHOT_SCROLL='.live-tail' node $SHOT $LIVE $HERE/p2-writing-$w-$look.png $w $h $look >/dev/null
    WEB_SHOT_WAIT=21500 WEB_SHOT_SCROLL='.live-row' WEB_SHOT_CLICK='.thought .line' node $SHOT $LIVE $HERE/p2-waiting-$w-$look.png $w $h $look >/dev/null
    WEB_SHOT_WAIT=15000 node $SHOT $STALL $HERE/p2-stalled-$w-$look.png $w $h $look >/dev/null
    WEB_SHOT_WAIT=37000 node $SHOT $STALL $HERE/p2-quiet-call-$w-$look.png $w $h $look >/dev/null
    print "$look $w"
  done
done
