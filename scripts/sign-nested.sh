#!/bin/zsh
# Signs the code nested in Moku.app, innermost first, before the app itself is signed:
# the brain, the llama.cpp server and its libraries, and Sparkle.
# Usage: scripts/sign-nested.sh <Moku.app> <identity> [extra codesign flags, e.g. --timestamp]
set -euo pipefail
root=${0:A:h:h}
app=$1; identity=$2; shift 2
flags=(--force --options runtime "$@")
[[ -x "$app/Contents/Resources/brain/moku-brain" ]] && codesign $flags --sign "$identity" "$app/Contents/Resources/brain/moku-brain"
if [[ -d "$app/Contents/Resources/llama" ]]; then
  find "$app/Contents/Resources/llama" -type f -name '*.dylib' -exec codesign $flags --sign "$identity" {} \;
  codesign $flags --sign "$identity" "$app/Contents/Resources/llama/llama-server"
fi
sparkle="$app/Contents/Frameworks/Sparkle.framework"
if [[ -d "$sparkle" ]]; then
  codesign $flags --sign "$identity" "$sparkle/Versions/B/Autoupdate"
  codesign $flags --sign "$identity" "$sparkle/Versions/B/Updater.app"
  codesign $flags --sign "$identity" "$sparkle"
fi
