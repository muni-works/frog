#!/bin/sh
# Assemble what frog.toys serves into site/dist: the web app at /, the marketing page at
# /mac, and the rest of the site's files as they are. `npx wrangler deploy` from site/
# serves dist (wrangler.jsonc's assets.directory). Run from anywhere.
set -eu
cd "$(dirname "$0")"
npm --prefix ../apps/web ci --silent
npm --prefix ../apps/web run build --silent
rm -rf dist && mkdir -p dist/mac
cp -R install.sh node.sh pricing.html privacy.html terms.html favicon.svg icon.png shot-dark.png shot-light.png data energy dist/
# the cram design page: served at /cram.html when it goes live (Beat 2)
mkdir -p dist/design && cp -R design dist/design/
cp index.html dist/mac/index.html
# The app last: its index.html is the site's front page.
cp -R ../apps/web/dist/. dist/

# Cloudflare Web Analytics (cookieless; docs/privacy.md): the beacon goes into every page
# with the frog.toys site's token (public; CF_BEACON_TOKEN= turns it off). Its auto-install
# doesn't reach pages the Worker serves, so the beacon is built in.
CF_BEACON_TOKEN="${CF_BEACON_TOKEN-4a750530eff54d08b09df1613cd40b9a}"
if [ -n "$CF_BEACON_TOKEN" ]; then
  beacon="<script defer src=\"https://static.cloudflareinsights.com/beacon.min.js\" data-cf-beacon='{\"token\":\"$CF_BEACON_TOKEN\"}'></script>"
  find dist -name '*.html' | while read -r f; do
    grep -q cloudflareinsights "$f" || BEACON="$beacon" perl -0pi -e 's#</body>#$ENV{BEACON}</body>#i or s#\z#$ENV{BEACON}#' "$f"
  done
fi
