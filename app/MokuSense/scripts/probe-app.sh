#!/usr/bin/env bash
# Wraps moku-sense into build/Moku.app (bundle id ai.lightslips.moku, signed with the local
# "Apple Development" identity) so macOS attributes Accessibility and Screen Recording to Moku.app.
# The grants then carry over to the real app, which uses the same bundle id and signing identity.
#
#   scripts/probe-app.sh                       build and sign only
#   scripts/probe-app.sh --request-permissions --duration 60 --out build/probe.jsonl
#                                              build, sign, run with these moku-sense flags, print its output
set -euo pipefail

cd "$(dirname "$0")/.."
app="build/Moku.app"

swift build -c release --product moku-sense
binary="$(swift build -c release --show-bin-path)/moku-sense"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$binary" "$app/Contents/MacOS/Moku"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>ai.lightslips.moku</string>
    <key>CFBundleName</key>
    <string>Moku</string>
    <key>CFBundleDisplayName</key>
    <string>Moku</string>
    <key>CFBundleExecutable</key>
    <string>Moku</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAccessibilityUsageDescription</key>
    <string>Moku reads the title and text of the window you are working in, so it can tell when you drift and gently bring you back.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Moku reads the text of the window you are working in (on this Mac, never recorded or uploaded as images) to understand what you are working on.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Moku only checks whether a call is using the microphone, so it can stay quiet during meetings. It never listens.</string>
    <key>NSCameraUsageDescription</key>
    <string>Moku only checks whether a call is using the camera, so it can stay quiet during meetings. It never looks.</string>
</dict>
</plist>
PLIST

identity="$(security find-identity -v -p codesigning | awk '/"Apple Development/ { print $2; exit }')"
if [[ -z "$identity" ]]; then
    echo "probe-app: no \"Apple Development\" signing identity found (security find-identity -v -p codesigning)" >&2
    exit 1
fi
codesign --force --sign "$identity" --identifier ai.lightslips.moku "$app"
codesign --verify --strict "$app"
echo "probe-app: built and signed $app with identity $identity"

if [[ $# -gt 0 ]]; then
    # Apps started by `open` run in /, so a relative --out path is made absolute here.
    args=()
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--out" && $# -gt 1 && "$2" != /* ]]; then
            args+=("$1" "$PWD/$2")
            shift 2
        else
            args+=("$1")
            shift
        fi
    done
    out="build/probe.out.jsonl"
    err="build/probe.err.log"
    rm -f "$out" "$err"
    echo "probe-app: running open $app --args ${args[*]} (events in $out, log in $err)"
    # -W waits for Moku to exit; -n starts a fresh instance even if one is running.
    open -W -n --stdout "$PWD/$out" --stderr "$PWD/$err" "$app" --args "${args[@]}"
    cat "$err"
    cat "$out"
fi
