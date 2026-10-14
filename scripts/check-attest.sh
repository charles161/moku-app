#!/bin/zsh
# Does App Attest work with this provisioning profile? (docs/specs/app-attest.md §6–7)
#   1. Builds a windowless probe with Moku's identifier, signs it as Moku.app would be (scripts/sign-app.sh: the profile is
#      checked first, then embedded with scripts/Moku.entitlements).
#   2. Runs it: it asks Apple to attest a fresh key, as the install does, and writes build/attest-sample.json.
#   3. Checks that sample with the relay's own verifier against Apple's real root certificate.
# Needs build/profiles/Moku.provisionprofile (or MOKU_PROFILE=path). The probe has no window and keeps nothing. If macOS
# kills it (Killed: 9), the profile and the entitlements don't agree: the same would kill Moku, so don't ship that profile.
set -euo pipefail
root=${0:A:h:h}
profile=${MOKU_PROFILE:-$root/build/profiles/Moku.provisionprofile}
if [[ ! -f "$profile" ]]; then
  cat <<TEXT
No provisioning profile at $profile.

In developer.apple.com › Certificates, Identifiers & Profiles:
  1. Identifiers › ai.lightslips.moku › turn on App Attest › Save.
  2. Profiles › + › Developer ID (distribution outside the Mac App Store) › that App ID › your Developer ID Application
     certificate › Generate › Download.
  3. Save it as $profile and run this again.
If step 1 or 2 isn't offered for this App ID, say what the page shows.
TEXT
  exit 2
fi
identity=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')
[[ -n "$identity" ]] || { echo "No Developer ID Application certificate in the keychain."; exit 1; }

work="$root/build/attest-probe"; app="$work/Moku.app"
rm -rf "$work"; mkdir -p "$app/Contents/MacOS"
swiftc -O -o "$app/Contents/MacOS/AttestProbe" "$root/scripts/attest-probe/main.swift"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>ai.lightslips.moku</string>
  <key>CFBundleName</key><string>Moku</string>
  <key>CFBundleExecutable</key><string>AttestProbe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
MOKU_PROFILE="$profile" "$root/scripts/sign-app.sh" "$app" "$identity" --options runtime --timestamp
codesign --verify --strict "$app"
sample="$root/build/attest-sample.json"; rm -f "$sample"
challenge="probe.$(date +%s).challenge"
device=$(printf 'a%.0s' {1..64})
echo "--- running the probe"
set +e
"$app/Contents/MacOS/AttestProbe" "$challenge" "$device" "$sample"
status=$?
set -e
case $status in
  0) ;;
  137|9) echo "macOS killed the probe: the profile doesn't match the entitlements (or the certificate). Don't ship this profile."; exit 1 ;;
  2) echo "App Attest isn't available to this build."; exit 1 ;;
  *) echo "The probe failed (exit $status)."; exit 1 ;;
esac
echo "--- the relay's verifier, against Apple's real root"
node "$root/proxy/scripts/check-attest-sample.js" "$sample"
rm -rf "$work"
