#!/bin/zsh
# Package build/Moku.app into build/Moku.dmg (drag to Applications). Build the app first (scripts/build-app.sh).
set -euo pipefail
root=${0:A:h:h}
app="$root/build/Moku.app"; dmg="$root/build/Moku.dmg"
[[ -d "$app" ]] || { echo "Build Moku.app first (scripts/build-app.sh)"; exit 1; }
[[ -x "$app/Contents/Resources/brain/moku-brain" ]] || echo "warning: this Moku.app has no brain (scripts/build-app.sh builds brain-go into it)"
stage=$(mktemp -d); cp -R "$app" "$stage/"; ln -s /Applications "$stage/Applications"
rm -f "$dmg"; hdiutil create -volname Moku -srcfolder "$stage" -ov -format UDZO "$dmg" >/dev/null; rm -rf "$stage"
echo "Created $dmg ($(du -h "$dmg" | cut -f1))"
