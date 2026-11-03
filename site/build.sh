#!/bin/sh
# Assemble what frog.toys serves into site/dist: the web app at /, the marketing page at
# /mac, and the rest of the site's files as they are. `npx wrangler deploy` from site/
# serves dist (wrangler.jsonc's assets.directory). Run from anywhere.
set -eu
cd "$(dirname "$0")"
npm --prefix ../apps/web ci --silent
npm --prefix ../apps/web run build --silent
rm -rf dist && mkdir -p dist/mac
cp -R favicon.svg icon.png shot-dark.png shot-light.png data energy dist/
# the cram design page: served at /cram.html when it goes live (Beat 2)
mkdir -p dist/design && cp -R design dist/design/
cp index.html dist/mac/index.html
# The app last: its index.html is the site's front page.
cp -R ../apps/web/dist/. dist/
