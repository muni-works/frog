#!/bin/sh
# Renders background.svg plus its text (IBM Plex, drawn by magick) to background.tiff (1x + 2x).
set -eu
cd "$(dirname "$0")"
F=../../FrogKit/UI/Fonts
render() { # <scale> <out>
    s=$1
    rsvg-convert -z "$s" background.svg -o "$2"
    magick "$2" \
        -font "$F/IBMPlexSans.ttf" -fill '#1b1d1a' -pointsize "$(echo "15*$s" | bc)" \
        -annotate "+$((50*s))+$(echo "36.5*$s/1" | bc)" frog \
        -font "$F/IBMPlexMono-Regular.ttf" -fill '#6b6f68' -pointsize "$(echo "11.5*$s" | bc)" \
        -gravity north -annotate "+0+$((311*s))" 'drag frog onto Applications' \
        "$2"
}
render 1 background.png
render 2 background@2x.png
tiffutil -cathidpicheck background.png background@2x.png -out background.tiff
