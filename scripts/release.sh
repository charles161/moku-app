#!/bin/zsh
# Ship a Moku release: a notarized DMG for new people, and a signed update that every installed Moku picks up
# on its own (Sparkle checks daily, downloads quietly, installs while the person is away).
#   MOKU_VERSION=0.2.0 scripts/release.sh
# Needs, one time: the Developer ID certificate and notarytool profile (see scripts/notarize.sh), and Sparkle's
# update signing key in the keychain (run build/snapshot/app/Moku/.build/artifacts/sparkle/Sparkle/bin/generate_keys once,
# or app/Moku/.build/…; back the private key up with `generate_keys -x <file>`: losing it means no more updates).
# Optional release notes: build/updates/Moku-<version>.md.
# At the end it publishes (scripts/publish-release.sh): the update and the DMG go to the moku-updates Blob store,
# served at moku-proxy.vercel.app/updates and /download. MOKU_PUBLISH=0 builds without publishing.
set -euo pipefail
root=${0:A:h:h}
version=${MOKU_VERSION:?Set MOKU_VERSION, e.g. MOKU_VERSION=0.2.0 scripts/release.sh}
updates_url=${MOKU_UPDATES_URL:-https://moku-proxy.vercel.app/updates}
updates="$root/build/updates"

# Everything ships inside the app: the native brain (built by build-app.sh) and the llama.cpp server.
[[ -x "$root/build/llama-runtime/llama-server" ]] || "$root/scripts/fetch-llama-runtime.sh"
MOKU_RELEASE=1 MOKU_VERSION=$version MOKU_UPDATES_URL=$updates_url "$root/scripts/build-snapshot.sh"
"$root/scripts/notarize.sh"

# The update: the notarized app, zipped the way Sparkle expects, and the appcast that announces it
# (signed with the keychain key). Deltas from the last two versions are on (MOKU_DELTAS, default 2): about 1 MB instead
# of 48, which matters on mobile networks that reset long downloads (2026-10-06: 3 of 5 cut off on Jio). A Mac whose app
# doesn't match the delta's source (0.1.8 and 0.1.9 installed from a DMG lacked the stapled ticket) falls back to the
# full zip, which works (scripts/check-update-live.sh shows it); from 0.1.10 the DMG's app is the zip's app.
mkdir -p "$updates"
ditto -c -k --sequesterRsrc --keepParent "$root/build/Moku.app" "$updates/Moku-$version.zip"
"$root/build/snapshot/app/Moku/.build/artifacts/sparkle/Sparkle/bin/generate_appcast" \
  --download-url-prefix "$updates_url/" --maximum-deltas "${MOKU_DELTAS:-2}" "$updates"
mkdir -p "$root/build/releases"; cp "$root/build/Moku.dmg" "$root/build/releases/Moku-$version.dmg"
echo "Moku $version is built: $root/build/releases/Moku-$version.dmg"
[[ "${MOKU_PUBLISH:-1}" == 0 ]] || "$root/scripts/publish-release.sh" "$version"
