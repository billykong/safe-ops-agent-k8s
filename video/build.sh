#!/usr/bin/env bash
# Builds the capstone video: narration, frames, then the MP4.
#   video/build.sh [OUT_DIR]      (default video/out)
# Tools go in TOOLS_DIR (default OUT_DIR/tools) on first run: resvg-js and
# ffmpeg-static from npm, Kokoro in a uv venv, and its model files (~350 MB).
# VOICE picks the Kokoro voice (default am_michael).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$(mkdir -p "${1:-$HERE/out}" && cd "${1:-$HERE/out}" && pwd)
TOOLS=${TOOLS_DIR:-$OUT/tools}
VOICE=${VOICE:-am_michael}
mkdir -p "$TOOLS"

if [ ! -x "$TOOLS/node_modules/ffmpeg-static/ffmpeg" ]; then
  (cd "$TOOLS" && npm init -y >/dev/null && npm i --silent @resvg/resvg-js@2.6.2 ffmpeg-static@5.2.0)
fi
if [ ! -x "$TOOLS/tts/bin/python" ]; then
  uv venv -q "$TOOLS/tts"
  VIRTUAL_ENV="$TOOLS/tts" uv pip install -q kokoro-onnx==0.4.9 soundfile
fi
mkdir -p "$TOOLS/models"
for f in kokoro-v1.0.onnx voices-v1.0.bin; do
  [ -s "$TOOLS/models/$f" ] || curl -sSL -o "$TOOLS/models/$f" "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/$f"
done
FFMPEG=$TOOLS/node_modules/ffmpeg-static/ffmpeg

echo "=== narration ($VOICE)"
"$TOOLS/tts/bin/python" -I "$HERE/tts.py" "$OUT" "$TOOLS/models" "$VOICE" 2>&1 | grep -v -i 'warn'
echo "=== frames"
rm -rf "$OUT/frames"
(cd "$TOOLS" && node "$HERE/render.js" "$OUT")
echo "=== video"
"$FFMPEG" -y -loglevel error -f concat -safe 0 -i "$OUT/frames.txt" -i "$OUT/narration.wav" \
  -vf "fps=30,format=yuv420p" -c:v libx264 -preset medium -crf 18 -tune stillimage \
  -af "loudnorm=I=-16:TP=-1.5:LRA=11" -c:a aac -b:a 192k -ar 48000 -shortest -movflags +faststart "$OUT/capstone.mp4"
echo "wrote $OUT/capstone.mp4, captions.srt and thumbnail.png"
