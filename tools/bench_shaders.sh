#!/bin/bash
# Shaders benchmark with a given settings file: tools/bench_shaders.sh PROPERTIES [run-client args]
# (3440x1440 pixels: a 1720x720 retina window). Restores run/config/metal189.properties after.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
P=$1; shift
cp "$ROOT/run/config/metal189.properties" "$ROOT/captures/metal189.properties.shbench"
cp "$P" "$ROOT/run/config/metal189.properties"
BENCH_SCRIPT=shaders.txt "$ROOT/tools/bench.sh" 1720 720 -Dmetal189.retina=true "$@"
cp "$ROOT/captures/metal189.properties.shbench" "$ROOT/run/config/metal189.properties"
