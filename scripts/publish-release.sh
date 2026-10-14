#!/bin/zsh
# Upload a built release to Cloudflare R2 (bucket moku-updates, https://updates.hellomoku.com): the update (zip, deltas,
# feed), which moku-proxy.vercel.app/updates redirects to (the feed every installed Moku checks), and the DMG, which the
# relay's /download redirects to.
#   scripts/publish-release.sh 0.1.1        (scripts/release.sh runs this at the end)
# Needs wrangler logged in to Cloudflare, and the Vercel CLI to the account that owns moku-proxy (to redeploy it).
set -euo pipefail
root=${0:A:h:h}
version=${1:?Pass the version, e.g. scripts/publish-release.sh 0.1.1}
updates="$root/build/updates"; dmg="$root/build/releases/Moku-$version.dmg"
[[ -f "$updates/Moku-$version.zip" && -f "$dmg" ]] || { echo "Build $version first (scripts/release.sh)."; exit 1; }
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
# The update files live on Cloudflare R2 (bucket moku-updates, https://updates.hellomoku.com), which the relay's /updates
# redirects to: Vercel Blob dropped 4 of 9 full downloads on an Indian mobile network, R2 none (2026-10-06, the probe).
# The zip and any deltas first, the feed last, so the feed never names a file that isn't up yet. Uploads drop on mobile
# networks too: each is tried three times.
r2put() {  # file, key, extra wrangler options
  local file=$1 key=$2; shift 2
  for try in 1 2 3; do
    npx --yes wrangler r2 object put "moku-updates/$key" --file "$file" --remote "$@" 2>&1 | grep -q "Upload complete" && { echo "> R2: $key"; return 0; }
    sleep 5
  done
  echo "R2 upload failed three times: $key"; return 1
}
r2put "$updates/Moku-$version.zip" "updates/Moku-$version.zip"
for delta in "$updates"/*.delta(N); do r2put "$delta" "updates/${delta:t}"; done
r2put "$updates/appcast.xml" updates/appcast.xml --content-type application/xml --cache-control max-age=60
# The DMG, under its own new name: never ask for it before it's up. Cloudflare keeps a 404 for 4 hours (asking for
# Moku-0.1.10.dmg before its upload left that address answering 404 after it, 2026-10-08).
r2put "$dmg" "downloads/Moku-$version.dmg" --content-type application/x-apple-diskimage
# /download points at this version's own DMG. Overwriting one Moku.dmg left the CDN serving the old one for an
# hour, so the relay's redirect moves to the new file instead (commit proxy/vercel.json after).
sed -i '' -E "s#\"destination\": \"[^\"]*Moku[^\"]*\.dmg\"#\"destination\": \"https://updates.hellomoku.com/downloads/Moku-$version.dmg\"#" "$root/proxy/vercel.json"
(cd "$root/proxy" && npx --yes vercel deploy --prod --yes >/dev/null 2>&1) || { echo "The relay didn't redeploy: /download still serves the previous DMG."; exit 1; }
# Every notarized DMG is kept as a GitHub release too (v<version>, private repo), so an update can be tested from any
# version to the latest: install that version's DMG, then Settings › Check for updates.
notes="$work/notes.md"
python3 - "$root/CHANGELOG.md" "$version" > "$notes" <<'PY'
import re, sys
text = open(sys.argv[1]).read(); version = sys.argv[2]
section = re.search(rf'^## {re.escape(version)} \(([0-9-]+)\)\n(.*?)(?=^## |\Z)', text, flags=re.M | re.S)
date, body = (section.group(1), section.group(2).strip()) if section else ('', 'See CHANGELOG.md.')
print(f"Moku {version}, released {date}. Notarized DMG for Apple silicon, macOS 15 or later.\n\n{body}\n\nKept here so updates can be tested from any version to the latest.")
PY
# The release names a commit GitHub has: the tag carries it up (a tag doesn't deploy the website, a push to home does).
# 0.1.10's release wasn't made because its commit was only on this Mac.
git -C "$root" push -q origin "HEAD:refs/tags/v$version" 2>/dev/null || true
gh release create "v$version" "$dmg" --repo charles161/moku --verify-tag --title "Moku $version" \
  --notes-file "$notes" --latest >/dev/null 2>&1 && echo "GitHub release v$version, with its DMG." \
  || echo "The GitHub release v$version wasn't made (gh logged in? the release already there?): make it by hand."
echo "Published Moku $version: https://hellomoku.com/download, and the feed at moku-proxy.vercel.app/updates/appcast.xml."
sleep 65  # the feed is cached 60 s
"$root/scripts/check-updates.sh" || echo "Some released versions can't update to $version (above): fix the feed now (e.g. remove its deltas)."
# The whole path as a Mac takes it, on this Mac: the version before this one (the feed's second item) checks, downloads
# and installs this one into a temp copy, Sparkle, the network and the installer included (check-update-live.sh).
read -r prevVersion prevBuild < <(curl -sfL https://moku-proxy.vercel.app/updates/appcast.xml | python3 -c '
import re, sys
items = sorted(((int(re.search(r"<sparkle:version>(\d+)", i).group(1)), re.search(r"shortVersionString>([\d.]+)", i).group(1))
                for i in re.findall(r"<item>.*?</item>", sys.stdin.read(), flags=re.S)), reverse=True)
print(items[1][1], items[1][0]) if len(items) > 1 else print()') || true
if [[ -n "${prevBuild:-}" ]]; then
  if zsh "$root/scripts/check-update-live.sh" --version "$prevVersion" --build "$prevBuild" --timeout 900 >"$work/update-live.log" 2>&1; then
    echo "Moku $prevVersion updates itself to $version on this Mac (check-update-live.sh: found, downloaded, checked, installed)."
  else
    grep -E "^FAIL|failedToDownloadUpdate|didAbortWithError" -A2 "$work/update-live.log" | head -20 || tail -5 "$work/update-live.log"
    echo "Moku $prevVersion didn't update to $version on this Mac (above). A network error is worth a second run: zsh scripts/check-update-live.sh --version $prevVersion --build $prevBuild"
  fi
fi
echo "Commit proxy/vercel.json (the /download redirect now names Moku-$version.dmg)."
