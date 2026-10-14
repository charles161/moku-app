#!/bin/zsh
# Signs Moku.app itself, after scripts/sign-nested.sh has signed what's inside it.
# Usage: scripts/sign-app.sh <Moku.app> <identity> [extra codesign flags, e.g. --options runtime --timestamp]
#
# With build/profiles/Moku.provisionprofile in place (a Developer ID profile for ai.lightslips.moku with App Attest, made in
# Apple's developer portal; docs/specs/app-attest.md §6) the profile goes inside the app and the app claims App Attest
# (scripts/Moku.entitlements). Without it nothing changes: no entitlement, no profile, no App Attest.
#
# A profile that is there but wrong stops the build, never "signs without": the app killed at launch on every Mac is the
# cost of a bad one (scripts/attest_profile.py says what's wrong). Take the file out of build/profiles to build without.
set -euo pipefail
root=${0:A:h:h}
app=$1; identity=$2; shift 2
profile=${MOKU_PROFILE:-$root/build/profiles/Moku.provisionprofile}
entitlements="$root/scripts/Moku.entitlements"
rm -f "$app/Contents/embedded.provisionprofile"
claims=()
if [[ -f "$profile" ]]; then
  if ! summary=$(python3 "$root/scripts/attest_profile.py" "$profile" "$entitlements" "$identity" 2>&1); then
    echo "The provisioning profile $profile can't go in Moku.app:" >&2
    print -r -- "$summary" >&2
    exit 1
  fi
  cp "$profile" "$app/Contents/embedded.provisionprofile"
  claims=(--entitlements "$entitlements")
  echo "App Attest: profile embedded ($summary)"
fi
codesign --force "$@" $claims --sign "$identity" "$app"
