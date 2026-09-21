#!/usr/bin/env python3
import copy
import datetime
import hashlib
import importlib.util
import pathlib
import plistlib
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("signing", pathlib.Path(__file__).with_name("prepare-keychain-signing.py"))
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class SigningTests(unittest.TestCase):
    def testOnlyMatchingUnexpiredDistributionProfileCanProduceScopedEntitlements(self):
        app_id = "V9SQZ6B7RP.com.sharknia.ClaudeSessionWarmer"
        profile = {
            "TeamIdentifier": ["V9SQZ6B7RP"], "ProvisionsAllDevices": True,
            "ExpirationDate": datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None) + datetime.timedelta(days=1),
            "Entitlements": {"com.apple.application-identifier": app_id,
                             "com.apple.developer.team-identifier": "V9SQZ6B7RP",
                             "keychain-access-groups": ["V9SQZ6B7RP.*"]},
        }
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "entitlements.plist"
            with patch.object(signing.subprocess, "check_output", return_value=plistlib.dumps(profile)):
                signing.prepare(pathlib.Path("fixture"), output)
            self.assertEqual(plistlib.loads(output.read_bytes())["keychain-access-groups"], [app_id])
            output.unlink()
            bad_profiles = []
            for key, value in [("TeamIdentifier", ["OTHERTEAM"]), ("ProvisionsAllDevices", False),
                               ("ExpirationDate", datetime.datetime(2000, 1, 1))]:
                bad = copy.deepcopy(profile)
                bad[key] = value
                bad_profiles.append(bad)
            for key, value in [("com.apple.application-identifier", "V9SQZ6B7RP.other"),
                               ("keychain-access-groups", ["OTHERTEAM.*"]), ("get-task-allow", True)]:
                bad = copy.deepcopy(profile)
                bad["Entitlements"][key] = value
                bad_profiles.append(bad)
            for bad in bad_profiles:
                with patch.object(signing.subprocess, "check_output", return_value=plistlib.dumps(bad)):
                    with self.assertRaises(ValueError):
                        signing.prepare(pathlib.Path("fixture"), output)
                self.assertFalse(output.exists())
            certificate = b"public certificate fixture"
            fingerprint = hashlib.sha1(certificate).hexdigest().upper()
            profile["DeveloperCertificates"] = [certificate]
            with patch.object(signing.subprocess, "check_output", side_effect=[
                plistlib.dumps(profile), f'1) {fingerprint} "Developer ID fixture"'.encode()
            ]):
                signing.prepare(pathlib.Path("fixture"), output, "Developer ID fixture")
            self.assertTrue(output.exists())
            output.unlink()
            with patch.object(signing.subprocess, "check_output", side_effect=[
                plistlib.dumps(profile), f'1) {"A" * 40} "Developer ID fixture"'.encode()
            ]):
                with self.assertRaises(ValueError):
                    signing.prepare(pathlib.Path("fixture"), output, "Developer ID fixture")
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
