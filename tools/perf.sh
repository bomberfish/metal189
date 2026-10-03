#!/bin/bash
# Benchmarks a scene at a given resolution under several renderer configurations.
#   tools/perf.sh SCENE WIDTH HEIGHT name:"jvm args" [name:"jvm args" ...]
# e.g. tools/perf.sh tests/scenes/perf_forest.txt 1920 1080 base: adv:-Dmetal189.shaders=true
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCENE="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; W=$2; H=$3; shift 3
OUT="$ROOT/captures/perf"; mkdir -p "$OUT"
OPT="$ROOT/run/options.txt"
cp "$OPT" "$OUT/options.backup"
trap 'cp "$OUT/options.backup" "$OPT"' EXIT
grep -v '^override\(Width\|Height\):' "$OUT/options.backup" > "$OPT"
printf 'overrideWidth:%s\noverrideHeight:%s\n' "$W" "$H" >> "$OPT"
for cfg in "$@"; do
  name=${cfg%%:*}; args=${cfg#*:}
  # shellcheck disable=SC2086
  timeout 300 "$ROOT/tools/run-client.sh" $args -Dmetal189.gpuStats=true -Dmetal189.test="$SCENE" > "$OUT/$name.log" 2>&1
  echo "== $name"
  grep -E "metal189-test fps|gpu frame time" "$OUT/$name.log" | sed 's/.*\] //' | tail -5
done
