#!/bin/bash
# Builds a universal (Apple Silicon + Intel) AppMixer.app into ./build and signs it.
#   VERSION        version string for Info.plist (default: the value in Info.plist); also accepted as $1
#   SIGN_IDENTITY  codesigning identity (default: a "* Local Signing" certificate if present, else ad hoc)
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-${VERSION:-}}"
MIN_MACOS=14.2
BINS=()
for ARCH in arm64 x86_64; do
    TRIPLE="$ARCH-apple-macosx$MIN_MACOS"
    # Separate scratch paths: the two triples otherwise trip over each other's incremental build state.
    swift build -c release --triple "$TRIPLE" --scratch-path ".build/$ARCH"
    BINS+=("$(swift build -c release --triple "$TRIPLE" --scratch-path ".build/$ARCH" --show-bin-path)/AppMixer")
done

APP=build/AppMixer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/AppMixer"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [[ -n "$VERSION" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi

# Sign with a stable certificate when available so macOS keeps granted permissions across rebuilds
# (an ad-hoc signature changes on every build, which makes macOS ask again).
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -p codesigning 2>/dev/null | awk -F'"' '/Local Signing"/ {print $2; exit}')}"
codesign --force --deep --sign "${IDENTITY:--}" --identifier dev.appmixer.AppMixer "$APP"
echo "Built $(pwd)/$APP ($(lipo -archs "$APP/Contents/MacOS/AppMixer"), version $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist"), signed by ${IDENTITY:-ad hoc})"
