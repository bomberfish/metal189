#!/bin/bash
# Captures the look scene with the advanced pipeline and builds a montage.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME=${1:-look}
SCENE=${SCENE:-look}
OUT="$ROOT/captures/$NAME"; mkdir -p "$OUT"; rm -f "$OUT"/[A-Z].png
sed "s#CAPTURE_\([A-Z]\)#$OUT/\1.png#g" "$ROOT/tests/scenes/$SCENE.txt" > "$OUT/script.txt"
shift
"$ROOT/tools/run-client.sh" -Dmetal189.shaders=true "$@" -Dmetal189.test="$OUT/script.txt" > "$OUT/log.txt" 2>&1
"$ROOT/.venv/bin/python" "$ROOT/tools/montage.py" "$OUT/montage.png" 2 $(ls "$OUT"/[A-Z].png)
grep -i 'exception\|advanced:' "$OUT/log.txt" | head -5
