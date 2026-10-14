#!/bin/zsh
# Build Moku.app from app/Moku and sign it with the local Developer ID (or "Apple Development" where there is none).
# The bundle id and identity stay fixed, so macOS keeps the Screen Recording and Accessibility grants across rebuilds:
# the same Developer ID as releases, so switching between a release and a development build asks for nothing again.
set -euo pipefail
root=${0:A:h:h}
config=${1:-release}
# MOKU_APP_SOURCE builds another copy of app/ (scripts/build-snapshot.sh freezes one while lanes edit).
cd "${MOKU_APP_SOURCE:-$root/app}/Moku"
swift build -c "$config"
bin_dir=$(swift build -c "$config" --show-bin-path)
app="$root/build/Moku.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/Moku" "$app/Contents/MacOS/Moku"
# SwiftPM resource bundles travel inside Resources.
for bundle in "$bin_dir"/*.bundle(N); do cp -R "$bundle" "$app/Contents/Resources/"; done
# The art the runtime loads (MokuAssets looks in Resources/MokuAssets; SPEC.md marks the root).
assets="$app/Contents/Resources/MokuAssets"
# MOKU_ASSETS_DIR lets a build use another copy of the art (e.g. a tagged version) without touching assets/.
src="${MOKU_ASSETS_DIR:-$root/assets}"
mkdir -p "$assets/previews"
cp "$src/SPEC.md" "$assets/"
cp -R "$src/character" "$src/runtime" "$src/props" "$src/icons" "$src/world" "$assets/"
cp "$src"/previews/stage_*.png "$assets/previews/"
# The app icon, assets/icons/Moku.icon: Icon Composer layers (Moku and the cottage over sage). actool makes
# Assets.car, which macOS 26 and later draw themselves (the shape, the glass edge, dark mode, no grey frame), and
# Moku.icns for macOS 15. Needs Xcode 26 or later.
xcrun actool "$src/icons/Moku.icon" --compile "$app/Contents/Resources" --platform macosx --minimum-deployment-target 15.0 \
  --app-icon Moku --output-partial-info-plist "$(mktemp -t moku-icon).plist" >/dev/null
# Charles's calibration build (docs/specs/goal-aware-judging.md): goal-aware judging, the brain's /calibrate dashboard
# ("Calibrate…" in Moku's right-click menu) and screen text kept 14 days. Never a release: only a brain linked with
# calibrationBuild=1 reads MOKU_CALIBRATE at all (brain-go goaljudge.go), so a release's brain can't calibrate.
calibrate_key=""
brain_ldflags="-s -w"
if [[ "${MOKU_CALIBRATE:-0}" == 1 ]]; then
  [[ "${MOKU_RELEASE:-0}" != 1 ]] || { echo "MOKU_CALIBRATE is for Charles's own build, never a release."; exit 1; }
  calibrate_key="<key>MokuCalibrate</key><true/>"
  brain_ldflags="$brain_ldflags -X moku/brain/internal/brain.calibrationBuild=1"
fi
# The brain (brain-go/), built from the last commit so work in progress never reaches the running app: one binary
# in Resources/brain.
dev_env_key=""
if [[ "${MOKU_RELEASE:-0}" != 1 ]]; then
  ln -sf "$root/.env" "$root/build/.env"
  dev_env_key="<key>MokuDevEnv</key><string>$root/.env</string>"
fi
rm -rf "$root/build/brain-go-src" && mkdir -p "$root/build/brain-go-src" "$app/Contents/Resources/brain"
git -C "$root" archive HEAD brain-go | tar -x -C "$root/build/brain-go-src" --strip-components=1
(cd "$root/build/brain-go-src" && GOTOOLCHAIN=local CGO_ENABLED=0 go build -trimpath -ldflags "$brain_ldflags" -o "$app/Contents/Resources/brain/moku-brain" .)
# Sparkle (auto-update) travels in Frameworks. Its XPC services are for sandboxed apps only; Moku isn't sandboxed.
if [[ -d "$bin_dir/Sparkle.framework" ]]; then
  mkdir -p "$app/Contents/Frameworks"
  ditto "$bin_dir/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
  rm -rf "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$app/Contents/Frameworks/Sparkle.framework/XPCServices"
  otool -l "$app/Contents/MacOS/Moku" | grep -q "@executable_path/../Frameworks" || install_name_tool -add_rpath "@executable_path/../Frameworks" "$app/Contents/MacOS/Moku"
fi
# Only a release (scripts/release.sh, MOKU_RELEASE=1) carries the update feed and its public key: a development
# build never updates itself. The public key comes from the keychain, where Sparkle's generate_keys put it
# (MOKU_SPARKLE_PUBLIC_KEY overrides it, for a test key).
sparkle_keys=""
if [[ "${MOKU_RELEASE:-0}" == 1 ]]; then
  public_key=${MOKU_SPARKLE_PUBLIC_KEY:-$("${MOKU_APP_SOURCE:-$root/app}/Moku/.build/artifacts/sparkle/Sparkle/bin/generate_keys" -p 2>/dev/null || true)}
  [[ -n "$public_key" ]] || { echo "No update signing key. Run app/Moku/.build/artifacts/sparkle/Sparkle/bin/generate_keys once (it keeps the private key in your keychain)."; exit 1; }
  sparkle_keys="<key>SUFeedURL</key><string>${MOKU_UPDATES_URL:-https://moku-proxy.vercel.app/updates}/appcast.xml</string>
  <key>SUPublicEDKey</key><string>$public_key</string>
  <key>SUEnableAutomaticChecks</key><true/><key>SUAutomaticallyUpdate</key><true/><key>SUScheduledCheckInterval</key><integer>86400</integer>"
fi
# The llama.cpp server (scripts/fetch-llama-runtime.sh), for the local model the brain runs while the cloud fails.
if [[ -x "$root/build/llama-runtime/llama-server" && "${MOKU_LOCAL_MODEL:-1}" != 0 ]]; then  # MOKU_LOCAL_MODEL=0 leaves it out
  rm -rf "$app/Contents/Resources/llama" && cp -R "$root/build/llama-runtime" "$app/Contents/Resources/llama"
fi
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>ai.lightslips.moku</string>
  <key>CFBundleName</key><string>Moku</string>
  <key>CFBundleDisplayName</key><string>Moku</string>
  <key>CFBundleExecutable</key><string>Moku</string>
  <key>CFBundleIconFile</key><string>Moku</string>
  <key>CFBundleIconName</key><string>Moku</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${MOKU_VERSION:-0.1.0}</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>MokuRelayURL</key><string>https://moku-proxy.vercel.app</string>
  <key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>ai.lightslips.moku</string><key>CFBundleURLSchemes</key><array><string>moku</string></array></dict></array>
  <key>NSHighResolutionCapable</key><true/>
  <!-- RealityKit's USD import and renderer allocate and free hundreds of MB while Moku loads; the default allocator keeps
       the freed pages, so the footprint (Activity Monitor's Memory) stayed 100 to 400 MB higher for good. This asks it to
       give them back: Moku 446 → 357 MB, Tetsu 462 → 414 MB steady, no more CPU (docs/specs/launch-qa.md, lens 3).
       Launch Services sets it before the process starts, which is when the allocator reads it. -->
  <key>LSEnvironment</key><dict><key>MallocSpaceEfficient</key><string>1</string></dict>
  $dev_env_key
  $calibrate_key
  $sparkle_keys
</dict></plist>
PLIST
identities=$(security find-identity -v -p codesigning)
identity=$(print -r -- "$identities" | awk -F'"' '/Developer ID Application/ {print $2; exit}')
[[ -n "$identity" ]] || identity=$(print -r -- "$identities" | awk -F'"' '/Apple Development/ {print $2; exit}')
# Sign nested code first (Node, the llama.cpp server, Sparkle), then the app.
"$root/scripts/sign-nested.sh" "$app" "$identity"
"$root/scripts/sign-app.sh" "$app" "$identity"
echo "Built and signed $app with: $identity"
