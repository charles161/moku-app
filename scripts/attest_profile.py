#!/usr/bin/env python3
"""Whether a provisioning profile can go inside Moku.app (docs/specs/app-attest.md §7).

Moku claims a restricted entitlement (Apple App Attest) and macOS only honours it when an embedded profile allows
exactly that: the right team and App ID, the entitlement, the certificate the app is signed with, and a date still in
the future. A profile that falls short doesn't make App Attest fail quietly: macOS kills the app at launch, on every
Mac that gets it. So scripts/sign-app.sh embeds a profile only when this says nothing is wrong.

    attest_profile.py <profile> <entitlements.plist> <signing identity name>

Prints what the profile is (team, App ID, expiry) and exits 0, or prints each problem and exits 1.
"""
import datetime
import hashlib
import plistlib
import re
import subprocess
import sys

TEAM = "HTM2272E7P"
APP_ID = f"{TEAM}.ai.lightslips.moku"
WARN_DAYS = 30


def check(profile: dict, entitlements: dict, signing_sha1s: set, now: datetime.datetime):
    """(errors, warnings) for a decoded profile against the entitlements the app is signed with."""
    errors, warnings = [], []
    granted = profile.get("Entitlements", {})
    if TEAM not in profile.get("TeamIdentifier", []):
        errors.append(f"the profile is for team {profile.get('TeamIdentifier')}, not {TEAM}")
    if granted.get("com.apple.application-identifier") != APP_ID:
        errors.append(f"the profile's App ID is {granted.get('com.apple.application-identifier')}, not {APP_ID}")
    if profile.get("ProvisionedDevices"):
        errors.append("a development or ad hoc profile (it lists devices): only those Macs could open Moku. "
                      "Make a Developer ID profile")
    for key, value in entitlements.items():
        if key not in granted:
            errors.append(f"the profile doesn't grant {key}")
        elif granted[key] != value:
            errors.append(f"{key} is {value!r} in Moku.entitlements but the profile grants {granted[key]!r}")
    expires = profile.get("ExpirationDate")
    if not expires:
        errors.append("the profile has no expiry date")
    else:
        # plistlib gives naive UTC datetimes.
        days = (expires - now).days
        if expires <= now:
            errors.append(f"the profile expired on {expires:%Y-%m-%d}")
        elif days < WARN_DAYS:
            warnings.append(f"the profile expires in {days} days ({expires:%Y-%m-%d}): renew it and rebuild")
    held = {hashlib.sha1(der).hexdigest().upper() for der in profile.get("DeveloperCertificates", [])}
    if not signing_sha1s & held:
        errors.append("the profile doesn't include the certificate Moku is signed with")
    return errors, warnings


def certificate_sha1s(identity: str) -> set:
    """SHA-1 of every keychain certificate whose name matches `identity`."""
    out = subprocess.run(["security", "find-certificate", "-c", identity, "-a", "-Z"], capture_output=True, text=True).stdout
    return set(re.findall(r"SHA-1 hash: ([0-9A-F]{40})", out))


def main(argv):
    if len(argv) != 4:
        print(__doc__)
        return 2
    profile_path, entitlements_path, identity = argv[1:]
    decoded = subprocess.run(["security", "cms", "-D", "-i", profile_path], capture_output=True)
    if decoded.returncode != 0:
        print(f"{profile_path} isn't a provisioning profile macOS can read")
        return 1
    profile = plistlib.loads(decoded.stdout)
    with open(entitlements_path, "rb") as f:
        entitlements = plistlib.load(f)
    errors, warnings = check(profile, entitlements, certificate_sha1s(identity), datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None))
    for line in warnings:
        print(f"warning: {line}", file=sys.stderr)
    if errors:
        print("\n".join(errors))
        return 1
    print(f"{profile.get('Name', 'profile')}, team {TEAM}, App ID {APP_ID}, expires {profile['ExpirationDate']:%Y-%m-%d}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
