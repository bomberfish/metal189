#!/bin/bash
# Runs a scene script under vanilla GL and metal189 and diffs the captures.
#   tools/compare-scene.sh run/scene_x.txt name [fresh]   (fresh: delete worlds first)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCENE="$1"; NAME="$2"
OUT="$ROOT/captures/$NAME"
mkdir -p "$OUT"
mk() { sed "s#CAPTURE_\([A-Z]\)#$OUT/$1_\1.png#g" "$SCENE" > "$OUT/script_$1.txt"; }
mk gl; mk mt
"$ROOT/tools/run-client.sh" --gl -Dmetal189.test="$OUT/script_gl.txt" > "$OUT/gl.log" 2>&1
"$ROOT/tools/run-client.sh" -Dmetal189.shaders=false -Dmetal189.test="$OUT/script_mt.txt" > "$OUT/mt.log" 2>&1
for f in "$OUT"/gl_*.png; do
  b=$(basename "$f" .png); k=${b#gl_}
  [ -f "$OUT/mt_$k.png" ] || { echo "$k: missing metal capture"; continue; }
  printf '%s: ' "$k"; "$ROOT/.venv/bin/python" "$ROOT/tools/imgdiff.py" "$f" "$OUT/mt_$k.png" "$OUT/diff_$k.png" | head -1
done
grep -h 'Exception\|ERROR' "$OUT/mt.log" | grep -v 'twitch\|signature data' | head -5
