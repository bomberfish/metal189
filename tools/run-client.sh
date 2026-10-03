#!/bin/bash
# Launches the Forge 1.8.9 client with metal189 from an isolated game dir (run/).
# Defaults are safe for a shared desktop: the window stays in the background,
# never becomes key, and the pointer is never grabbed or warped.
#
#   tools/run-client.sh [--gl] [--fg] [-Dprop=value ...] [-- game args]
#     --gl   run vanilla OpenGL (metal189 transformers disabled) for reference
#     --fg   normal foreground window (only when explicitly wanted)
#     --jar-natives  load the dylib/metallib from the mod jar like a release install
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="${RUN_DIR:-$ROOT/run}"
PRISM="$HOME/Library/Application Support/PrismLauncher"
JAVA=${M189_JAVA:-/Library/Java/JavaVirtualMachines/zulu-8.jdk/Contents/Home/bin/java}
JVM=()
GAME=()
WINDOW=background
NATIVEDIR=(-Dmetal189.nativeDir="$ROOT/native/build")
while [ $# -gt 0 ]; do
  case "$1" in
    --gl) JVM+=(-Dmetal189.disable=true); shift ;;
    --fg) WINDOW=normal; shift ;;
    --jar-natives) NATIVEDIR=(); shift ;;
    --) shift; GAME+=("$@"); break ;;
    -D*|-X*) JVM+=("$1"); shift ;;
    *) GAME+=("$1"); shift ;;
  esac
done
mkdir -p "$RUN/mods" "$RUN/config"
[ -f "$RUN/classpath.txt" ] || python3 "$ROOT/tools/mkclasspath.py" "$RUN/natives" > "$RUN/classpath.txt"
cp "$ROOT/build/libs/metal189-0.1.0.jar" "$RUN/mods/metal189.jar"
[ -f "$RUN/config/splash.properties" ] || printf 'enabled=false\n' > "$RUN/config/splash.properties"
CP="$(cat "$RUN/classpath.txt")"
cd "$RUN"
exec "$JAVA" -Xmx4G -Xms1G -XX:+UseG1GC \
  -Djava.library.path="${M189_NATIVES:-$RUN/natives}" -Dorg.lwjgl.librarypath="${M189_NATIVES:-$RUN/natives}" \
  -Dapple.awt.UIElement=true \
  -Dmetal189.window="$WINDOW" -Dmetal189.noGrab=true \
  ${NATIVEDIR[@]+"${NATIVEDIR[@]}"} \
  -Dfml.ignoreInvalidMinecraftCertificates=true -Dfml.ignorePatchDiscrepancies=true \
  ${JVM[@]+"${JVM[@]}"} \
  -cp "$CP" net.minecraft.launchwrapper.Launch \
  --username Dev --version 1.8.9 --gameDir "$RUN" --assetsDir "$PRISM/assets" --assetIndex 1.8 \
  --uuid 0123456789abcdef0123456789abcdef --accessToken 0 --userProperties '{}' --userType legacy \
  --tweakClass net.minecraftforge.fml.common.launcher.FMLTweaker ${GAME[@]+"${GAME[@]}"}
