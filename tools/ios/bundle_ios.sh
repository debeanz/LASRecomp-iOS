#!/bin/bash
# make ipa (macOS with Xcode): build/ios/lasrecomp -> build/ios/LASRecomp-<version>-ios.ipa, an app bundle ad-hoc signed
# with its entitlements (tools/ios/entitlements.plist) for sideloading: SideStore / AltStore / LiveContainer re-sign it
# with your own Apple ID and keep them. The app holds the game code built from your own game files: keep the IPA to
# yourself. The game's data (romfs) is not in it: it is copied onto the iPhone with the Files app (tools/ios/README.md).
# Usage: tools/ios/bundle_ios.sh <executable> <version>
set -euo pipefail
cd "$(dirname "$0")/../.."
EXE=${1:-build/ios/lasrecomp}
VERSION=${2:-dev}
OUT=build/ios
APP="$OUT/Payload/LAS Recomp.app"
BUNDLE_ID=${IOS_BUNDLE_ID:-com.peiikai.lasrecomp.ios}
# (a bundle version must be numbers and dots: the run number in CI, else a date)
BUILD=${IOS_BUILD_NUMBER:-$(date +%Y%m%d.%H%M)}

rm -rf "$OUT/Payload"
mkdir -p "$APP"
cp "$EXE" "$APP/lasrecomp"
xcrun strip -x "$APP/lasrecomp" 2>/dev/null || true  # (local symbols only: crash logs keep the exported names)

# resources the runtime looks for next to the executable (runtime/paths.c rt_resource)
cp docs/icon/icon_1024.png "$APP/icon.png"
cp third_party/fonts/Baloo2/Baloo2-SemiBold.ttf "$APP/"
cp third_party/fonts/Baloo2/OFL.txt "$APP/Baloo2-OFL.txt"
cp third_party/fonts/DejaVu/DejaVuSans.ttf third_party/fonts/DejaVu/DejaVuSans-Bold.ttf "$APP/"
cp third_party/fonts/DejaVu/LICENSE "$APP/DejaVu-LICENSE.txt"
cp README.md LICENSE "$APP/"

# the home screen icon: PNGs named in Info.plist (no asset catalog needed for a sideloaded app)
for s in 120 152 167 180; do sips -z $s $s docs/icon/icon_1024.png --out "$APP/AppIcon-$s.png" >/dev/null; done

sed -e "s/@VERSION@/${VERSION#v}/g" -e "s/@BUILD@/$BUILD/g" -e "s/@BUNDLE_ID@/$BUNDLE_ID/g" \
    tools/ios/Info.plist > "$APP/Info.plist"
plutil -lint "$APP/Info.plist" >/dev/null
printf 'APPL????' > "$APP/PkgInfo"

codesign --force --sign - --entitlements tools/ios/entitlements.plist --timestamp=none "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q extended-virtual-addressing ||
    { echo "the signature lost the entitlements"; exit 1; }

IPA="$OUT/LASRecomp-${VERSION#v}-ios.ipa"
rm -f "$OUT"/*.ipa
(cd "$OUT" && zip -qry "$(basename "$IPA")" Payload)
echo "$IPA ($(du -h "$IPA" | cut -f1))"
