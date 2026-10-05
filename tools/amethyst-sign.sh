#!/bin/bash
# Re-signs an Amethyst (iOS) .ipa with a development identity and profile so it can be
# installed over USB and debugged (get-task-allow), which is how JIT gets enabled from
# this Mac (tools/amethyst-jit.py).
#
#   tools/amethyst-sign.sh IN.ipa PROFILE.mobileprovision "IDENTITY" OUT.ipa
#
# JRE8=<unpacked jre8-ios-aarch64> replaces the bundled Java 8 (Amethyst's July builds carry
# one without the JIT26 fixes that iOS 27 needs: angelauramc-openjdk-build f03a5a05).
#
# The bundle id becomes the profile's; every Mach-O in the bundle (frameworks, the JREs'
# dylibs) is signed with IDENTITY, since iOS only loads the app team's code.
set -euo pipefail
IN=$1 PROFILE=$2 IDENTITY=$3 OUT=$4
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

unzip -q "$IN" -d "$WORK"
APP=$(ls -d "$WORK"/Payload/*.app)

security cms -D -i "$PROFILE" > "$WORK/profile.plist"
APPID=$(plutil -extract Entitlements.application-identifier raw "$WORK/profile.plist")
TEAM=$(plutil -extract TeamIdentifier.0 raw "$WORK/profile.plist")
BUNDLE=${APPID#"$TEAM".}

# Entitlements: the profile's, minus wildcard keychain groups.
plutil -extract Entitlements xml1 -o "$WORK/ent.plist" "$WORK/profile.plist"
plutil -remove keychain-access-groups "$WORK/ent.plist" 2>/dev/null || true

if [ -n "${JRE8:-}" ]; then
    J="$APP/java_runtimes/java-8-openjdk"
    cp "$J/lib/libawt_xawt.dylib" "$WORK/libawt_xawt.dylib" 2>/dev/null || true
    rm -rf "$J" && mkdir -p "$J" && cp -R "$JRE8"/. "$J"/
    [ -f "$WORK/libawt_xawt.dylib" ] && cp "$WORK/libawt_xawt.dylib" "$J/lib/"
    echo "Java 8 replaced from $JRE8"
fi

plutil -replace CFBundleIdentifier -string "$BUNDLE" "$APP/Info.plist"
cp "$PROFILE" "$APP/embedded.mobileprovision"
find "$APP" -name _CodeSignature -type d -prune -exec rm -rf {} +

# Loose Mach-O files first (dylibs, framework binaries are covered by signing the
# framework afterwards), deepest paths first.
find "$APP" -type f ! -path "*/_CodeSignature/*" -print0 | while IFS= read -r -d '' f; do
    if [ "$f" != "$APP/$(plutil -extract CFBundleExecutable raw "$APP/Info.plist")" ] \
        && file -b "$f" | grep -q Mach-O; then echo "$f"; fi
done | awk '{ print length($0) "\t" $0 }' | sort -rn | cut -f2- > "$WORK/macho.txt"
while IFS= read -r f; do
    codesign -f -s "$IDENTITY" --timestamp=none "$f" 2>/dev/null
done < "$WORK/macho.txt"
for fw in "$APP"/Frameworks/*.framework; do
    codesign -f -s "$IDENTITY" --timestamp=none "$fw"
done
codesign -f -s "$IDENTITY" --timestamp=none --entitlements "$WORK/ent.plist" "$APP"
codesign --verify --deep --strict "$APP"

rm -f "$OUT"
OUT_ABS=$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")
(cd "$WORK" && zip -qry "$OUT_ABS" Payload)
echo "signed $BUNDLE -> $OUT"
