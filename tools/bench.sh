#!/bin/bash
# Baseline-renderer benchmark: tools/bench.sh [WIDTH HEIGHT] [extra run-client args]
# Runs tools/bench/base.txt (or $BENCH_SCRIPT: a path, or a name under tools/bench/) in a
# background window (pass --fg for a foreground one) and prints the fps lines.
# Sizes are points: on a 2x display a true 3440x1440 test is
#   tools/bench.sh 1720 720 --fg -Dmetal189.retina=true
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W=${1:-3440}; H=${2:-1440}; shift 2 2>/dev/null
cp "$ROOT/run/config/metal189.properties" "$ROOT/captures/metal189.properties.bench"
LOG="${BENCH_LOG:-/tmp/m189-bench.log}"
SCRIPT="${BENCH_SCRIPT:-base.txt}"
[ -f "$SCRIPT" ] || SCRIPT="$ROOT/tools/bench/$SCRIPT"
timeout 600 "$ROOT/tools/run-client.sh" -Dmetal189.test="$SCRIPT" "$@" -- --width "$W" --height "$H" > "$LOG" 2>&1
# never leave a test client behind (a hung shutdown, a timeout): only ours, by its game directory
pkill -f "net.minecraft.launchwrapper.Launch.*--gameDir ${RUN_DIR:-$ROOT/run}" 2>/dev/null
cp "$ROOT/captures/metal189.properties.bench" "$ROOT/run/config/metal189.properties"
grep -E "fps .* = |Exception|FATAL" "$LOG" | sed 's/.*metal189-test fps //'
