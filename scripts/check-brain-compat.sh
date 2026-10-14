#!/bin/zsh
# Can a released brain work on today's data, and can today's brain read what it wrote? (A downgrade, then the update
# back.) Reproducible without touching anyone's Moku: both brains run on a copy of a store, on their own ports, with no
# model credentials (no AI calls).
#   zsh scripts/check-brain-compat.sh <old version, e.g. 0.1.7> [store to copy, default ~/.moku/moku.sqlite]
# Exits 1 when the old brain can't read or write the copy, or the current brain can't read it afterwards.
set -euo pipefail
root=${0:A:h:h}
version=${1:?Pass a released version, e.g. 0.1.7}
store=${2:-$HOME/.moku/moku.sqlite}
dmg="$root/build/releases/Moku-$version.dmg"
if [[ ! -f "$dmg" ]]; then  # not built on this Mac: the GitHub release's copy
  dmg="$(mktemp -d)/Moku-$version.dmg"
  gh release download "v$version" --repo charles161/moku --pattern "Moku-$version.dmg" --dir "${dmg:h}"
fi
work=$(mktemp -d); mnt="$work/mnt"; mkdir -p "$work/home" "$mnt"
trap 'kill $old $new 2>/dev/null || true; hdiutil detach "$mnt" >/dev/null 2>&1 || true; rm -rf "$work"' EXIT
sqlite3 "$store" ".backup '$work/home/moku.sqlite'"  # a consistent copy, even while Moku runs
hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$dmg" >/dev/null 2>&1
cp "$mnt/Moku.app/Contents/Resources/brain/moku-brain" "$work/old-brain"; hdiutil detach "$mnt" >/dev/null 2>&1
(cd "$root/brain-go" && GOTOOLCHAIN=local go build -o "$work/new-brain" .)
token=$(openssl rand -hex 24); failed=0
up() { for i in {1..40}; do curl -s -o /dev/null "http://127.0.0.1:$1/health" && return 0; sleep 0.25; done; return 1; }
get() { curl -s -o /dev/null -w '%{http_code}' -H "authorization: Bearer $token" "http://127.0.0.1:$1$2"; }
cd "$work"
env -i HOME="$work" PATH=/usr/bin:/bin MOKU_HOME="$work/home" MOKU_LOCAL_MODEL=off MOKU_BRAIN_TOKEN="$token" ./old-brain --port 8047 > old.log 2>&1 & old=$!
up 8047 || { echo "FAIL: the $version brain didn't start on this data"; tail -3 old.log; exit 1; }
for p in /v1/world /v1/config /v1/threads /v1/today /v1/counts; do
  code=$(get 8047 $p); [[ $code == 200 ]] || { echo "FAIL: $version GET $p: $code"; failed=1; }
done
for n in 1 2 3; do  # three moments written by the old brain
  now=$(( $(date +%s) * 1000 + n ))
  body="{\"id\":\"compat-$now\",\"ts\":$now,\"app\":{\"bundleId\":\"com.apple.dt.Xcode\",\"name\":\"Xcode\"},\"window\":{\"title\":\"compat.swift\"},\"text\":null,\"textSource\":null,\"textHash\":null,\"activity\":{\"keysPerMinute\":40,\"clicksPerMinute\":2,\"scrollsPerMinute\":1,\"idleSeconds\":0},\"context\":{\"inCall\":false,\"sharingScreen\":false,\"micInUse\":false,\"cameraInUse\":false}}"
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' -H "authorization: Bearer $token" --data "$body" http://127.0.0.1:8047/v1/judge)
  [[ $code == 200 ]] || { echo "FAIL: $version POST /v1/judge: $code"; failed=1; }
done
kill $old; wait $old 2>/dev/null || true
written=$(sqlite3 "$work/home/moku.sqlite" "select count(*) from samples where id like 'compat-%'")
[[ $written == 3 ]] || { echo "FAIL: $version wrote $written of 3 moments"; failed=1; }
env -i HOME="$work" PATH=/usr/bin:/bin MOKU_HOME="$work/home" MOKU_LOCAL_MODEL=off MOKU_BRAIN_TOKEN="$token" ./new-brain --port 8048 > new.log 2>&1 & new=$!
up 8048 || { echo "FAIL: today's brain didn't start on the data $version wrote"; tail -3 new.log; exit 1; }
for p in /v1/world /v1/today "/v1/days?from=$(date -v-7d +%Y-%m-%d)&to=$(date +%Y-%m-%d)"; do
  code=$(get 8048 "$p"); [[ $code == 200 ]] || { echo "FAIL: today's GET $p: $code"; failed=1; }
done
grep -iqE "panic|fatal|damaged" old.log new.log && { echo "FAIL: a panic or a damaged store in the logs"; failed=1; }
(( failed )) || echo "$version's brain reads and writes this data, and today's brain reads it back."
exit $failed
