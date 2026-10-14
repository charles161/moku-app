"""python3 -m unittest scripts/test_attest_profile.py: whether a provisioning profile may go inside Moku.app."""
import datetime
import hashlib
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import attest_profile as ap  # noqa: E402

NOW = datetime.datetime(2026, 10, 12)
CERT = b"developer-id-certificate-der"
SHA1 = hashlib.sha1(CERT).hexdigest().upper()
ENTITLEMENTS = {
    "com.apple.application-identifier": ap.APP_ID,
    "com.apple.developer.team-identifier": ap.TEAM,
    "com.apple.developer.devicecheck.appattest-environment": "production",
}


def profile(**changes):
    good = {
        "Name": "Moku Developer ID",
        "TeamIdentifier": [ap.TEAM],
        "ExpirationDate": NOW + datetime.timedelta(days=365),
        "DeveloperCertificates": [CERT],
        "Entitlements": dict(ENTITLEMENTS),
    }
    good.update(changes)
    return good


class ProfileCheck(unittest.TestCase):
    def check(self, p, entitlements=ENTITLEMENTS, sha1s=frozenset({SHA1})):
        return ap.check(p, entitlements, set(sha1s), NOW)

    def test_a_right_profile_has_nothing_wrong(self):
        self.assertEqual(self.check(profile()), ([], []))

    def test_another_team(self):
        errors, _ = self.check(profile(TeamIdentifier=["ABCDE12345"]))
        self.assertEqual(len(errors), 1)
        self.assertIn("ABCDE12345", errors[0])

    def test_another_app_id_or_a_wildcard(self):
        for app_id in ("HTM2272E7P.com.other.app", "HTM2272E7P.*", None):
            entitlements = dict(ENTITLEMENTS)
            entitlements["com.apple.application-identifier"] = app_id
            errors, _ = self.check(profile(Entitlements=entitlements))
            self.assertTrue(any("App ID" in e for e in errors), app_id)

    def test_a_profile_without_the_app_attest_entitlement(self):
        granted = {k: v for k, v in ENTITLEMENTS.items() if "appattest" not in k}
        errors, _ = self.check(profile(Entitlements=granted))
        self.assertEqual(errors, ["the profile doesn't grant com.apple.developer.devicecheck.appattest-environment"])

    def test_the_environment_must_match_what_the_app_claims(self):
        granted = dict(ENTITLEMENTS)
        granted["com.apple.developer.devicecheck.appattest-environment"] = "development"
        errors, _ = self.check(profile(Entitlements=granted))
        self.assertEqual(len(errors), 1)
        self.assertIn("'production'", errors[0])

    def test_a_development_profile_lists_devices(self):
        errors, _ = self.check(profile(ProvisionedDevices=["00008103-0000"]))
        self.assertTrue(any("lists devices" in e for e in errors))

    def test_an_expired_profile_is_an_error_and_a_soon_to_expire_one_a_warning(self):
        errors, _ = self.check(profile(ExpirationDate=NOW - datetime.timedelta(days=1)))
        self.assertTrue(any("expired on 2026-10-11" in e for e in errors))
        errors, warnings = self.check(profile(ExpirationDate=NOW + datetime.timedelta(days=10)))
        self.assertEqual(errors, [])
        self.assertEqual(len(warnings), 1)
        self.assertIn("10 days", warnings[0])

    def test_no_expiry_is_an_error(self):
        p = profile()
        del p["ExpirationDate"]
        errors, _ = self.check(p)
        self.assertEqual(errors, ["the profile has no expiry date"])

    def test_the_signing_certificate_must_be_in_the_profile(self):
        errors, _ = self.check(profile(), sha1s={"0" * 40})
        self.assertEqual(errors, ["the profile doesn't include the certificate Moku is signed with"])
        errors, _ = self.check(profile(), sha1s=set())
        self.assertEqual(len(errors), 1)

    def test_any_of_several_certificates_with_the_same_name_will_do(self):
        self.assertEqual(self.check(profile(), sha1s={"0" * 40, SHA1}), ([], []))

    def test_every_problem_is_listed_not_just_the_first(self):
        errors, _ = self.check(profile(TeamIdentifier=["X"], ExpirationDate=NOW - datetime.timedelta(days=2)), sha1s=set())
        self.assertEqual(len(errors), 3)


if __name__ == "__main__":
    unittest.main()
