#!/bin/bash
# Baseline-renderer benchmark: tools/bench.sh [WIDTH HEIGHT] [extra run-client args]
# Runs tools/bench/base.txt (or $BENCH_SCRIPT: a path, or a name under tools/bench/) in a
# background window (pass --fg for a foreground one) and prints the fps lines.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W=${1:-3440}; H=${2:-1440}; shift 2 2>/dev/null
cp "$ROOT/run/config/metal189.properties" "$ROOT/captures/metal189.properties.bench"
LOG="${BENCH_LOG:-/tmp/m189-bench.log}"
SCRIPT="${BENCH_SCRIPT:-base.txt}"
[ -f "$SCRIPT" ] || SCRIPT="$ROOT/tools/bench/$SCRIPT"
timeout 600 "$ROOT/tools/run-client.sh" -Dmetal189.test="$SCRIPT" "$@" -- --width "$W" --height "$H" > "$LOG" 2>&1
cp "$ROOT/captures/metal189.properties.bench" "$ROOT/run/config/metal189.properties"
grep -E "fps .* = |Exception|FATAL" "$LOG" | sed 's/.*metal189-test fps //'
