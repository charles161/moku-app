#!/bin/zsh
# Can every released Moku update to the latest, as the live feed offers it? Reproduces update problems without
# anyone's Mac (Charles, 2026-10-06: "make every prob or error reproducible"). For each DMG in build/releases (the same
# files as the GitHub releases), it takes the app as a person who installed it has it, then follows the feed's newest
# item the way Sparkle does:
#   - a delta from that build: applied with Sparkle's BinaryDelta, and the result must be the full update's app, byte
#     for byte. When it doesn't fit (0.1.8's and 0.1.9's DMG apps lack the stapled ticket the zip's app has: "Source
#     doesn't have expected hash"), Sparkle falls back to the full zip, so that's checked instead and noted;
#   - otherwise the full zip: its EdDSA signature against the app's public key, then its code signature and Team ID.
#   zsh scripts/check-updates.sh [feed URL]      (default: the live feed). Exits 1 when any version can't update.
set -euo pipefail
root=${0:A:h:h}
feed=${1:-https://moku-proxy.vercel.app/updates/appcast.xml}
tools=$(dirname "$(find "$root/build/snapshot/app/Moku/.build/artifacts" "$root/app/Moku/.build/artifacts" -name BinaryDelta -type f 2>/dev/null | head -1)")
[[ -x "$tools/BinaryDelta" ]] || { echo "Sparkle's BinaryDelta not found: build the app once (scripts/build-snapshot.sh)."; exit 1; }
work=$(mktemp -d); trap 'for m in "$work"/mnt-*(N); do hdiutil detach "$m" >/dev/null 2>&1 || true; done; rm -rf "$work"' EXIT
curl -sfL "$feed" -o "$work/appcast.xml"
# The newest item: its build, version, full zip and deltas (deltaFrom build, url, signature).
python3 - "$work/appcast.xml" > "$work/newest.txt" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
items = re.findall(r'<item>.*?</item>', s, flags=re.S)
newest = max(items, key=lambda i: int(re.search(r'<sparkle:version>(\d+)', i).group(1)))
build = re.search(r'<sparkle:version>(\d+)', newest).group(1)
version = re.search(r'shortVersionString>([\d.]+)', newest).group(1)
deltas = re.search(r'<sparkle:deltas>(.*?)</sparkle:deltas>', newest, flags=re.S)
main = re.sub(r'<sparkle:deltas>.*?</sparkle:deltas>', '', newest, flags=re.S)
full = re.search(r'<enclosure url="([^"]+)"[^>]*?sparkle:edSignature="([^"]+)"', main)
print('newest', build, version, full.group(1), full.group(2))
for d in re.findall(r'<enclosure url="([^"]+)" sparkle:deltaFrom="(\d+)"[^>]*?sparkle:edSignature="([^"]+)"', deltas.group(1) if deltas else ''):
    print('delta', d[1], d[0], d[2])
PY
read -r _ newBuild newVersion zipURL zipSig < <(grep '^newest' "$work/newest.txt")
echo "The feed's newest: $newVersion (build $newBuild)."
# Sparkle checks an update with the EdDSA key built into the installed (old) app: so does this, per version.
verified() {  # file, base64 signature, base64 public key
  node -e '
const crypto=require("crypto"), fs=require("fs"); const [file, sig, pub]=process.argv.slice(1);
const key=crypto.createPublicKey({key:Buffer.concat([Buffer.from("302a300506032b6570032100","hex"),Buffer.from(pub,"base64")]),format:"der",type:"spki"});
process.exit(crypto.verify(null, fs.readFileSync(file), key, Buffer.from(sig,"base64")) ? 0 : 1);' "$1" "$2" "$3"
}
# The full update, once: downloaded and unpacked.
curl -sfL "$zipURL" -o "$work/full.zip"
mkdir -p "$work/full" && ditto -x -k "$work/full.zip" "$work/full"
team=$(codesign -dv "$work/full/Moku.app" 2>&1 | sed -n 's/^TeamIdentifier=//p')
codesign --verify --deep --strict "$work/full/Moku.app" || { echo "FAIL: the full update's code signature."; exit 1; }
failed=0
for dmg in "$root"/build/releases/Moku-*.dmg(On); do
  mnt="$work/mnt-${dmg:t:r}"; mkdir -p "$mnt"
  hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$dmg" >/dev/null 2>&1
  oldBuild=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$mnt/Moku.app/Contents/Info.plist")
  oldVersion=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$mnt/Moku.app/Contents/Info.plist")
  feedURL=$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$mnt/Moku.app/Contents/Info.plist" 2>/dev/null || echo "")
  if [[ "$oldBuild" == "$newBuild" ]]; then echo "  $oldVersion: the latest itself."; hdiutil detach "$mnt" >/dev/null 2>&1; continue; fi
  if [[ -z "$feedURL" ]]; then echo "  $oldVersion: FAIL, no update feed in this build (it can never update)."; failed=1; hdiutil detach "$mnt" >/dev/null 2>&1; continue; fi
  oldTeam=$(codesign -dv "$mnt/Moku.app" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  oldKey=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$mnt/Moku.app/Contents/Info.plist" 2>/dev/null) || oldKey=""
  if [[ -z "$oldKey" ]] || ! verified "$work/full.zip" "$zipSig" "$oldKey"; then
    echo "  $oldVersion: FAIL, the full update's EdDSA signature doesn't verify with this build's key."; failed=1; hdiutil detach "$mnt" >/dev/null 2>&1; continue
  fi
  line=$(grep "^delta $oldBuild " "$work/newest.txt" || true)
  if [[ -n "$line" ]]; then
    read -r _ _ deltaURL deltaSig <<< "$line"
    curl -sfL "$deltaURL" -o "$work/d.delta"
    verified "$work/d.delta" "$deltaSig" "$oldKey" || { echo "  $oldVersion: FAIL, the delta's EdDSA signature."; failed=1; hdiutil detach "$mnt" >/dev/null 2>&1; continue; }
    rm -rf "$work/new" && mkdir -p "$work/new"
    if "$tools/BinaryDelta" apply "$mnt/Moku.app" "$work/new/Moku.app" "$work/d.delta" >"$work/delta.log" 2>&1 \
       && python3 "$root/scripts/same-app.py" "$work/new/Moku.app" "$work/full/Moku.app" >/dev/null; then
      echo "  $oldVersion → $newVersion: the delta applies to the DMG's app and gives the full update's app."
    elif [[ "$oldTeam" == "$team" ]]; then
      # Sparkle 2 then downloads the full update instead (check-update-live.sh shows it): it works, at full size. Macs that
      # updated to this version through Sparkle have the zip's app, which the delta fits. From 0.1.10 the DMG's app is the
      # zip's app (notarize.sh), so this is only 0.1.8's and 0.1.9's DMG installs.
      echo "  $oldVersion → $newVersion: the delta doesn't fit the DMG's app ($(tail -1 "$work/delta.log" | cut -c1-60)); Sparkle falls back to the full update (signed, Team $team)."
    else
      echo "  $oldVersion → $newVersion: FAIL, the delta doesn't fit the DMG's app and Team $oldTeam can't take the full update (Team $team)."; failed=1
    fi
  elif [[ "$oldTeam" == "$team" ]]; then
    echo "  $oldVersion → $newVersion: the full update (signed, Team $team)."
  else
    echo "  $oldVersion → $newVersion: FAIL, Team $oldTeam can't update to Team $team."; failed=1
  fi
  hdiutil detach "$mnt" >/dev/null 2>&1
done
exit $failed
