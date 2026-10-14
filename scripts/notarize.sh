#!/bin/zsh
# Sign Moku.app with a Developer ID, notarize the DMG with Apple and staple the ticket, so testers
# can open it without Gatekeeper warnings. Needs (one time, from Charles):
#   1. A "Developer ID Application" certificate in the keychain (Apple Developer Program).
#   2. xcrun notarytool store-credentials moku-notary --apple-id <id> --team-id <team> --password <app-specific password>
set -euo pipefail
root=${0:A:h:h}
app="$root/build/Moku.app"; dmg="$root/build/Moku.dmg"
identity=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')
[[ -n "$identity" ]] || { echo "No Developer ID Application certificate found. See the header of this script."; exit 1; }
"$root/scripts/sign-nested.sh" "$app" "$identity" --timestamp
"$root/scripts/sign-app.sh" "$app" "$identity" --options runtime --timestamp
# The app first: notarized and stapled before it goes into the DMG, so the DMG's app and the update zip's app
# (scripts/release.sh) are the same bytes. Sparkle's deltas are made from the zip and check the installed app's hash:
# with the ticket stapled only after the DMG was made, every Mac installed from the DMG failed its delta (0.1.9,
# 2026-10-06: "An error occurred while downloading the update").
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
ditto -c -k --keepParent "$app" "$work/Moku.zip"
xcrun notarytool submit "$work/Moku.zip" --keychain-profile moku-notary --wait
xcrun stapler staple "$app"
"$root/scripts/make-dmg.sh"
codesign --force --timestamp --sign "$identity" "$dmg"
xcrun notarytool submit "$dmg" --keychain-profile moku-notary --wait
xcrun stapler staple "$dmg"
# The DMG's app must be the app that's zipped for the update, byte for byte.
mount=$(mktemp -d)
hdiutil attach -nobrowse -readonly -mountpoint "$mount" "$dmg" >/dev/null
python3 "$root/scripts/same-app.py" "$app" "$mount/Moku.app" || { hdiutil detach "$mount" >/dev/null; echo "The DMG's app differs from build/Moku.app."; exit 1; }
hdiutil detach "$mount" >/dev/null
echo "Notarized and stapled: $dmg"
