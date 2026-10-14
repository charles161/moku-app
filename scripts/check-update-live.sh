#!/bin/zsh
# Does an old Moku really update itself from a feed? Runs Sparkle 2 exactly as Moku does (the same framework, settings,
# update key and Developer ID signature) in a tiny app with no windows, as an old version, and writes down every step:
# the feed's items and why each was taken or skipped, the download (URL, network priority, time), the installer's
# unpacking and signature checks, the install into its own temp copy, and every error with all its layers.
# check-updates.sh checks the files offline; this checks the whole path on this Mac, network included
# (Charles, 2026-10-06: "make every prob or error reproducible").
#
#   zsh scripts/check-update-live.sh [options]
#     --version 0.1.7 --build 202610021015   the Moku to pretend to be (default 0.1.7; a build sets the delta it gets)
#     --feed URL                             the feed (default: the live one, https://moku-proxy.vercel.app/updates/appcast.xml)
#     --feed-file appcast.xml                a feed file, served from 127.0.0.1 (its enclosure URLs stay as written)
#     --files dir                            with --feed-file: serve the archives too, from dir (e.g. build/updates), each
#                                            enclosure URL pointed at 127.0.0.1 by its file name: Sparkle's logic without
#                                            the network or the CDN
#     --mode scheduled|background|user       Moku at launch (default) | the background check | Settings › Check for updates
#     --install quit|now|none                install into the temp copy when the probe quits (default) | at once | never
#                                            ("now" is the path that may show Sparkle's own "Installing…" window briefly)
#     --timeout 900                          give up after this many seconds
#     --out dir                              save the probe's log and Sparkle's own log there
#     --keep                                 keep the temp folder (the installed app)
#
# The probe is a Moku.app (Sparkle's installer looks for the host's file name in the update) with its own bundle id,
# ai.lightslips.moku.updateprobe, so its defaults, caches and installer are its own: it never touches /Applications/Moku.app,
# ~/.moku or Moku's settings, and never relaunches (with --install the temp copy becomes the real Moku, which must not run
# beside the installed one). Exits 0 when the update was found, downloaded, checked and (unless --install none) installed.
set -euo pipefail
root=${0:A:h:h}
version=0.1.7; build=202610021015
feed=https://moku-proxy.vercel.app/updates/appcast.xml; feedFile=""
mode=scheduled; install=quit; timeout=900; keep=0; out=""; files=""
publicKey=LOWr+rU3GRSozh3ozc3Nb7Ep8CntG5iatDoF+0cWIJQ=   # Moku's (AGENTS.md)
probeId=ai.lightslips.moku.updateprobe
while (( $# )); do
  case $1 in
    --version) version=$2; shift 2;; --build) build=$2; shift 2;;
    --feed) feed=$2; shift 2;; --feed-file) feedFile=${2:A}; shift 2;;
    --mode) mode=$2; shift 2;; --install) install=$2; shift 2;;
    --timeout) timeout=$2; shift 2;; --keep) keep=1; shift;; --out) out=${2:A}; shift 2;; --files) files=${2:A}; shift 2;;
    *) echo "unknown option $1 (see the top of $0)"; exit 64;;
  esac
done
[[ $mode == (scheduled|background|user) && $install == (quit|now|none) ]] || { echo "--mode scheduled|background|user, --install quit|now|none"; exit 64; }
[[ -z "$files" || -n "$feedFile" ]] || { echo "--files needs --feed-file"; exit 64; }
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Sparkle as app/Moku resolves it (SPARKLE_FRAMEWORK overrides, e.g. another checkout's).
framework=${SPARKLE_FRAMEWORK:-$(find "$root/app/Moku/.build/artifacts" "$root/build/snapshot/app/Moku/.build/artifacts" -path '*macos-arm64_x86_64/Sparkle.framework' -maxdepth 6 -type d 2>/dev/null | head -1)}
if [[ -z "$framework" ]]; then
  echo "Resolving app/Moku's packages for Sparkle…"; (cd "$root/app/Moku" && swift package resolve >/dev/null)
  framework=$(find "$root/app/Moku/.build/artifacts" -path '*macos-arm64_x86_64/Sparkle.framework' -maxdepth 6 -type d | head -1)
fi
[[ -d "$framework" ]] || { echo "Sparkle.framework not found"; exit 1; }
identity=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')
[[ -n "$identity" ]] || { echo "No Developer ID Application identity in the keychain."; exit 1; }

work=$(mktemp -d "${TMPDIR:-/tmp}/moku-update-probe.XXXXXX")
app="$work/Moku.app"; log="$work/probe.log"
server=""; probe=""
cleanup() {
  [[ -n "$probe" ]] && kill "$probe" 2>/dev/null || true
  [[ -n "$server" ]] && kill "$server" 2>/dev/null || true
  pkill -f "Autoupdate.* $probeId( |\$)" 2>/dev/null || true
  pkill -f "Updater.*$work" 2>/dev/null || true
  for bundle in "$app" "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"; do [[ -d "$bundle" ]] && "$lsregister" -u "$bundle" >/dev/null 2>&1 || true; done
  if (( keep )); then echo "Kept $work (delete it when done: the app in it may be the real Moku)."; else rm -rf "$work"; fi
  defaults delete "$probeId" >/dev/null 2>&1 || true
  rm -rf "$HOME/Library/Caches/$probeId" "$HOME/Library/Preferences/$probeId.plist"
}
trap cleanup EXIT INT TERM

# The probe: compiled once per source change into build/update-probe.
bin="$root/build/update-probe/UpdateProbe-$(shasum "$root/scripts/update-probe/UpdateProbe.swift" | cut -c1-12)"
if [[ ! -x "$bin" ]]; then
  echo "Compiling the probe…"
  mkdir -p "${bin:h}"
  swiftc -O -swift-version 5 -target arm64-apple-macos15.0 -F "${framework:h}" -framework Sparkle \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks "$root/scripts/update-probe/UpdateProbe.swift" -o "$bin.tmp" 2>&1 | grep -v "warning:" | grep -v "^\s*$" || true
  [[ -x "$bin.tmp" ]] && mv "$bin.tmp" "$bin" || { echo "The probe didn't compile."; exit 1; }
fi

# The bundle, laid out and signed as build-app.sh and notarize.sh do Moku's (no XPC services; nested code first, with
# a timestamp, so Sparkle's executable has the size deltas are made against).
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks"
cp "$bin" "$app/Contents/MacOS/UpdateProbe"
ditto "$framework" "$app/Contents/Frameworks/Sparkle.framework"
rm -rf "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$app/Contents/Frameworks/Sparkle.framework/XPCServices"
if [[ -n "$feedFile" ]]; then
  port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
  mkdir -p "$work/feed" && cp "$feedFile" "$work/feed/appcast.xml"
  if [[ -n "$files" ]]; then
    for archive in "$files"/*.(zip|delta)(N); do ln -s "$archive" "$work/feed/${archive:t}"; done
    sed -i '' -E "s#url=\"[^\"]*/([^/\"]+\.(zip|delta))\"#url=\"http://127.0.0.1:$port/\1\"#g" "$work/feed/appcast.xml"
  fi
  python3 -m http.server "$port" --bind 127.0.0.1 --directory "$work/feed" >"$work/server.log" 2>&1 &
  server=$!
  feed="http://127.0.0.1:$port/appcast.xml"
  for _ in {1..50}; do curl -sf -o /dev/null "$feed" && break; sleep 0.1; done
fi
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$probeId</string>
  <key>CFBundleName</key><string>Moku Update Probe</string>
  <key>CFBundleExecutable</key><string>UpdateProbe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>SUFeedURL</key><string>$feed</string>
  <key>SUPublicEDKey</key><string>$publicKey</string>
  <key>SUEnableAutomaticChecks</key><true/><key>SUAutomaticallyUpdate</key><true/><key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict></plist>
PLIST
"$root/scripts/sign-nested.sh" "$app" "$identity" --timestamp >/dev/null 2>&1 || "$root/scripts/sign-nested.sh" "$app" "$identity"
codesign --force --options runtime --timestamp --sign "$identity" "$app" 2>/dev/null || codesign --force --options runtime --sign "$identity" "$app"
codesign --verify --deep --strict "$app"

# A Mac that has run this Moku before (as Moku's own settings look): launched before, automatic updates on, and for
# "scheduled" the last check two days ago, so Sparkle checks as it starts.
defaults delete "$probeId" >/dev/null 2>&1 || true
rm -rf "$HOME/Library/Caches/$probeId"
defaults write "$probeId" SUHasLaunchedBefore -bool true
defaults write "$probeId" SUAutomaticallyUpdate -bool true
if [[ $mode == scheduled ]]; then lastCheck=$(date -u -v-2d +%Y-%m-%dT%H:%M:%SZ); else lastCheck=$(date -u +%Y-%m-%dT%H:%M:%SZ); fi
defaults write "$probeId" SULastCheckTime -date "$lastCheck"

echo "Probe: Moku $version (build $build) · feed $feed · mode $mode · install $install"
echo "       $app (Team $(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p'))"
started=$(date "+%Y-%m-%d %H:%M:%S")
"$app/Contents/MacOS/UpdateProbe" --mode "$mode" --install "$install" --timeout "$timeout" >"$log" 2>&1 &
probe=$!
tail -f "$log" & tailer=$!
wait "$probe" || true; probe=""
sleep 0.5; kill "$tailer" 2>/dev/null || true

# The installer runs on after the probe quits: wait for it, then say what's in the temp copy now.
if [[ $install != none ]]; then
  for _ in {1..120}; do pgrep -f "Autoupdate.* $probeId( |\$)" >/dev/null || break; sleep 1; done
fi
echo
echo "── Sparkle's own log (UpdateProbe, its installer and progress agent) ──"
/usr/bin/log show --start "$started" --style compact --info \
  --predicate 'subsystem == "org.sparkle-project.Sparkle" AND (process == "UpdateProbe" OR process == "Autoupdate" OR process == "Updater")' 2>/dev/null \
  | grep -v "^Timestamp" | cut -c1-400 | tee "$work/sparkle.log" || true
echo
echo "── HTTP: the requests Sparkle made, replayed with curl (one byte of each archive: the status and redirects, not the file) ──"
{ echo "$feed"; sed -n 's/.*willDownloadUpdate: GET \([^ ]*\).*/\1/p' "$log"; } | sort -u | while read -r url; do
  print -r -- "$url"
  range=(); [[ $url == *.xml ]] || range=(-r 0-0)
  curl -sS -o /dev/null -L $range --max-time 60 -D "$work/headers.txt" -w "    %{http_code} after %{num_redirects} redirect(s) → %{url_effective} · %{time_total} s · HTTP/%{http_version}\n" "$url" 2>&1 || true
  # Vercel's firewall can answer with a JavaScript challenge (403), which Sparkle can't pass.
  grep -i "^x-vercel-mitigated" "$work/headers.txt" | sed 's/^/    Vercel firewall: /' || true
done
echo
installed=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" -c "Print :CFBundleShortVersionString" -c "Print :CFBundleVersion" "$app/Contents/Info.plist" 2>/dev/null | paste -sd' ' -)
echo "── Result ──"
echo "The temp copy is now: $installed"
ok=1
grep -q "didFindValidUpdate\|updaterDidNotFindUpdate" "$log" || { echo "FAIL: no answer from the feed (its error is above)"; ok=0; }
if grep -q "didFindValidUpdate" "$log"; then
  grep -q "willInstallUpdateOnQuit\|showReadyToInstallAndRelaunch" "$log" || { echo "FAIL: the update was found but not downloaded and checked"; ok=0; }
  if [[ $install != none && $ok == 1 ]]; then
    if [[ "$installed" == ai.lightslips.moku\ * ]] && codesign --verify --deep --strict "$app" 2>/dev/null; then
      echo "OK: installed into the temp copy: $installed, signature valid (Team $(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p'))."
    else
      echo "FAIL: not installed (the temp copy is still the probe)."; ok=0
    fi
  fi
fi
grep -q "with error:" "$log" && echo "Errors: $(grep -c 'with error:' "$log") cycle(s) ended with an error; see above."
(( ok )) && echo "OK: Moku $version → $(sed -n 's/.*didFindValidUpdate: \([0-9.]*\).*/\1/p' "$log" | head -1) works through this feed on this Mac." || true
if [[ -n "$out" ]]; then mkdir -p "$out" && cp "$log" "$work/sparkle.log" "$out/" && echo "Logs: $out/probe.log, $out/sparkle.log"; fi
(( ok ))
