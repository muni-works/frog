#!/bin/sh
# concatenates src/ into one self-contained index.html
cd "$(dirname "$0")"
{
  printf '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n<title>frog · background work</title>\n<!-- built by build.sh from src/; edit src/, not this file -->\n<style>\n'
  cat src/tokens.css src/app.css src/screens.css
  printf '</style>\n</head>\n<body class="dark">\n'
  cat src/body.html
  printf '<script>\n'
  cat src/core.js src/screens.js src/agent.js src/main.js
  printf '</script>\n</body>\n</html>\n'
} > index.html
