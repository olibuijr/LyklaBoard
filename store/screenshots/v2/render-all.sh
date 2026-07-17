#!/usr/bin/env bash
#
# render-all.sh — one command from cached captures to final store PNGs.
#
#   Stage B: Blender renders (build_scene.py, headless, per-shot pose)
#   Stage C: compose.py — reads copy.md FRESH, draws gradient + captions,
#            writes export/{en-US,is-IS}/*.png @1260x2736 + contact-sheet.png
#
# Stage A (simulator captures) is cached; refresh with ./capture.sh first if
# the keyboard/UI changed. Shot 6 (privacy — no typing) reuses the hero
# capture in a steeper pose; its message is carried by the caption.
#
# Usage: store/screenshots/v2/render-all.sh [--skip-render]
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

BLENDER="/Applications/Blender.app/Contents/MacOS/Blender"
[ -x "$BLENDER" ] || { echo "Blender not found at $BLENDER"; exit 1; }

declare -A CAPTURE_FOR=(
  [1]=01-raw.png [2]=02-raw.png [3]=03-raw.png
  [4]=04-raw.png [5]=05-raw.png [6]=01-raw.png
)

if [ "${1:-}" != "--skip-render" ]; then
  for SHOT in 1 2 3 4 5 6; do
    CAP="captures/${CAPTURE_FOR[$SHOT]}"
    [ -f "$CAP" ] || { echo "missing $CAP — run capture.sh"; exit 1; }
    SAVE=()
    [ "$SHOT" = 1 ] && SAVE=(--save-blend blender/phone.blend)
    echo "== render shot $SHOT =="
    "$BLENDER" --background --python build_scene.py -- \
      --shot "$SHOT" --capture "$CAP" --out "blender/render-0$SHOT.png" \
      "${SAVE[@]}" 2>&1 | grep -E "RENDER_OK|Error|Traceback" || true
    [ -f "blender/render-0$SHOT.png" ] || { echo "render $SHOT failed"; exit 1; }
  done
fi

echo "== compose =="
python3 compose.py
echo "== done: store/screenshots/v2/export + contact-sheet.png =="
