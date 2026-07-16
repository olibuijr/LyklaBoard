#!/usr/bin/env bash
# Render every generated HTML screenshot to an exact-pixel PNG with headless
# Chrome. No GUI automation, no uploads — Chrome's native --screenshot captures
# the rendered page directly (avoids the html2canvas file:// canvas-taint issue).
set -euo pipefail

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
HERE="$(cd "$(dirname "$0")" && pwd)"
HTML="$HERE/html"
EXPORT="$HERE/../export"
W=1260; H=2736

for f in "$HTML"/*.html; do
  base="$(basename "$f" .html)"           # e.g. 02_accents_is-IS
  loc="${base##*_}"                        # is-IS / en-US
  name="${base%_*}"                        # 02_accents
  mkdir -p "$EXPORT/$loc"
  out="$EXPORT/$loc/$name.png"
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars \
    --force-device-scale-factor=1 --default-background-color=FFFFFFFF \
    --window-size=$W,$H --screenshot="$out" "file://$f" >/dev/null 2>&1
  # verify dimensions
  dims=$(sips -g pixelWidth -g pixelHeight "$out" | awk '/pixel/{printf "%s ", $2}')
  echo "$out -> $dims"
done
