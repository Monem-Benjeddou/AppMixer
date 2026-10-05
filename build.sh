#!/bin/zsh
# Builds AppMixer.app (ad-hoc signed) into ./build. Pass a version to stamp it: ./build.sh 1.2.0
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:-}"
for arch in arm64 x86_64; do
  swift build -c release --triple "$arch-apple-macosx14.2" --scratch-path ".build/$arch"
done
APP=build/AppMixer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create .build/arm64/release/AppMixer .build/x86_64/release/AppMixer \
  -output "$APP/Contents/MacOS/AppMixer"
cp Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
if [[ -n "$VERSION" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
codesign --force --sign - "$APP"
echo "Built $APP"
