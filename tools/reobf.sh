#!/bin/bash
# Reobfuscates the dev jar (MCP names) into the release jar (SRG names).
set -euo pipefail
cd "$(dirname "$0")/.."
JAVA8=/Library/Java/JavaVirtualMachines/zulu-8.jdk/Contents/Home/bin
ASM="$HOME/Library/Application Support/PrismLauncher/libraries/org/ow2/asm/asm-all/5.0.3/asm-all-5.0.3.jar"
LOOM="$HOME/.gradle/caches/essential-loom/1.8.9/de.oceanlabs.mcp.mcp_stable.1_8_9.22-1.8.9-forge-1.8.9-11.15.1.1902-1.8.9"
mkdir -p build/tools
if [ ! -f build/tools/Remap.class ] || [ tools/remap/Remap.java -nt build/tools/Remap.class ]; then
  "$JAVA8/javac" -nowarn -cp "$ASM" -d build/tools tools/remap/Remap.java
fi
"$JAVA8/java" -cp "build/tools:$ASM" Remap "$1" "$2" "$LOOM/mappings-srg-named.srg" "$LOOM/minecraft-mapped.jar" "$LOOM/forge/forge-mapped.jar"
