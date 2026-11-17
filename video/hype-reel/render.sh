#!/bin/zsh
# Re-render the reel from the captured footage: frames, music, encode, contact sheet.
#   video/hype-reel/render.sh            (capture/run.sh first if footage/ is missing or stale)
# Needs uv, ffmpeg and rsvg-convert. CPU only; NPROC (default 6) sets the frame workers.
set -euo pipefail
cd ${0:A:h}
[[ -d footage/stream && -f footage/mark.png ]] || { print -u2 "no footage: run capture/run.sh first"; exit 1; }
PY=(uv run --quiet --with pillow==12.0.0 --with numpy==2.3.4 python)
rm -rf build/frames && mkdir -p build
NPROC=${NPROC:-6} nice $PY comp.py build/frames
$PY music.py build/music.wav
N=$(ls build/frames | wc -l | tr -d ' ')
nice ffmpeg -loglevel error -y -framerate 30 -i build/frames/%04d.png -i build/music.wav \
  -c:v libx264 -crf 17 -preset slow -pix_fmt yuv420p -c:a aac -b:a 256k -shortest \
  -metadata title="Frog" -movflags +faststart frog-hype-reel.mp4
ffprobe -v error -show_entries format=duration:stream=codec_name,width,height,r_frame_rate,pix_fmt -of compact frog-hype-reel.mp4
# The committed contact sheet: one frame every 1.5 s of the encoded mp4, 4 across.
ffmpeg -loglevel error -y -i frog-hype-reel.mp4 -vf "fps=2/3,scale=480:-1,tile=4x7" -frames:v 1 contact-sheet.png
print "frog-hype-reel.mp4 ($N frames) and contact-sheet.png"
