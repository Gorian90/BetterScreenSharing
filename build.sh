#!/bin/bash
# Bygger BetterScreenSharing.app i ./build
# Valfritt: SIGN_IDENTITY="Mitt certifikat" ./build.sh  (stabil signatur = behörigheter behålls mellan byggen)
set -euo pipefail
cd "$(dirname "$0")"

# Universell app: fungerar på både Apple Silicon och Intel.
swift build -c release --arch arm64 --arch x86_64
BINARY=".build/out/Products/Release/BetterScreenSharing"
[ -f "$BINARY" ] || BINARY=".build/apple/Products/Release/BetterScreenSharing"

APP="build/BetterScreenSharing.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
# Appikonen ritas av appen själv, så att projektet inte behöver några bildfiler.
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
"$BINARY" --write-iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"
# Stabil lokal signatur gör att macOS behåller behörigheterna (skärminspelning, kamera) mellan byggen.
# Skapas med ./signing/setup.sh; finns den inte signeras appen ad hoc.
KEYCHAIN="$PWD/signing/bss-signing.keychain-db"
if [ -z "${SIGN_IDENTITY:-}" ] && [ -f "$KEYCHAIN" ]; then
    security unlock-keychain -p bss "$KEYCHAIN"
    IDENTITY=$(security find-identity -p codesigning "$KEYCHAIN" | awk '/BetterScreenSharing Local/ {print $2; exit}')
    codesign --force --keychain "$KEYCHAIN" --sign "$IDENTITY" "$APP"
else
    codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
fi

echo "Done: $APP"
echo "Launch with: open \"$APP\""
