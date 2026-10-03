#!/bin/bash
# Captures the look scene with the advanced pipeline and builds a montage.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME=${1:-look}
OUT="$ROOT/captures/$NAME"; mkdir -p "$OUT"
sed "s#CAPTURE_\([A-Z]\)#$OUT/\1.png#g" "$ROOT/tests/scenes/look.txt" > "$OUT/script.txt"
shift
"$ROOT/tools/run-client.sh" -Dmetal189.shaders=true "$@" -Dmetal189.test="$OUT/script.txt" > "$OUT/log.txt" 2>&1
"$ROOT/.venv/bin/python" "$ROOT/tools/montage.py" "$OUT/montage.png" 2 "$OUT"/A.png "$OUT"/B.png "$OUT"/C.png "$OUT"/D.png "$OUT"/E.png
grep -i 'exception\|advanced:' "$OUT/log.txt" | head -5
