#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
swift build -c release
# The visual build is rejected if any sampled silhouette clips or disconnects.
zsh scripts/verify-look.sh "${MOKU_LOOK_REVIEW_DIR:-$PWD/.build/look-review}"
APP="$PWD/.build/MokuVisualDemo.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MokuVisualDemo "$APP/Contents/MacOS/"
cp -R .build/release/MokuVisual_MokuVisual.bundle "$APP/Contents/Resources/"
ART="${MOKU_ASSETS_DIR:-${MOKU_ASSET_ROOT:-$PWD/../../assets}}"
mkdir -p "$APP/Contents/Resources/MokuAssets/previews"
cp "$ART/SPEC.md" "$APP/Contents/Resources/MokuAssets/"
for folder in character runtime icons props symbols lantern world onboarding; do
  ditto "$ART/$folder" "$APP/Contents/Resources/MokuAssets/$folder"
done
cp "$ART"/previews/stage_*.png "$APP/Contents/Resources/MokuAssets/previews/"
cp "$ART/icons/AppIcon.icns" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>MokuVisualDemo</string><key>CFBundleIdentifier</key><string>ai.lightslips.moku.demo</string><key>CFBundleName</key><string>Moku Visual Studio</string><key>CFBundleIconFile</key><string>AppIcon</string><key>CFBundleVersion</key><string>1</string><key>LSMinimumSystemVersion</key><string>15.0</string><key>NSHighResolutionCapable</key><true/><key>LSEnvironment</key><dict><key>MallocSpaceEfficient</key><string>1</string></dict></dict></plist>
PLIST
# MOKU_SIGNING_IDENTITY names a codesigning identity (`security find-identity -v -p codesigning`); without one the
# studio is signed ad hoc ("-"), which runs on this Mac.
codesign --force --sign "${MOKU_SIGNING_IDENTITY:--}" "$APP"
if [[ "${1:-}" != "--build-only" ]]; then
  open "$APP" --args "$@"
fi
