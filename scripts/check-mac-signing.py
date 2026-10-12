"""Pure signing-selection regressions. No Keychain, service or signing effects."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch
import subprocess

spec = importlib.util.spec_from_file_location("mac_signing", Path(__file__).with_name("mac-signing.py"))
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)

FIRST = "A" * 40
SECOND = "B" * 40
DEVELOPMENT = f'  1) {FIRST} "Apple Development: Fixture (AAAAAAAAAA)"\n  1 valid identities found'
DEVELOPER_ID = f'  2) {SECOND} "Developer ID Application: Fixture (BBBBBBBBBB)"'


class SigningChecks(unittest.TestCase):
    def test_single_development_identity(self):
        self.assertEqual(signing.select_identity(DEVELOPMENT, None), signing.SigningIdentity(FIRST, "Apple Development"))

    def test_single_developer_id_identity(self):
        self.assertEqual(signing.select_identity(DEVELOPER_ID, None).kind, "Developer ID Application")

    def test_ambiguous_requires_explicit_fingerprint(self):
        available = DEVELOPMENT + "\n" + DEVELOPER_ID
        with self.assertRaises(ValueError): signing.select_identity(available, None)
        self.assertEqual(signing.select_identity(available, SECOND.lower()).kind, "Developer ID Application")

    def test_never_falls_back_to_ad_hoc_or_unknown_identity(self):
        for available, requested in [("0 valid identities found", None), (DEVELOPMENT, "-"), (DEVELOPMENT, SECOND),
                                      (f'1) {FIRST} "Apple Distribution: Fixture (AAAAAAAAAA)"', None)]:
            with self.assertRaises(ValueError): signing.select_identity(available, requested)

    def test_actual_code_directory_team_is_not_the_display_name_suffix(self):
        identity = signing.select_identity(DEVELOPMENT, None)
        facts = "Identifier=dev.leostera.axo.axod\nTeamIdentifier=RGH6S9S55G\nAuthority=Apple Development: Fixture (AAAAAAAAAA)\n"
        response = subprocess.CompletedProcess([], 0, stdout="", stderr=facts)
        with patch.object(signing.subprocess, "run", return_value=response):
            self.assertEqual(signing.verified_team(Path("owned-fixture"), identity, "dev.leostera.axo.axod"), "RGH6S9S55G")

    def test_signed_facts_fail_closed(self):
        identity = signing.select_identity(DEVELOPMENT, None)
        facts = "Identifier=dev.leostera.axo.axod\nTeamIdentifier=RGH6S9S55G\nAuthority=Apple Development: Fixture (AAAAAAAAAA)\n"
        invalid = [facts.replace("RGH6S9S55G", "not set"), facts.replace("dev.leostera.axo.axod", "other"),
                   facts.replace("Apple Development:", "Untrusted:"), facts + "Signature=adhoc\n"]
        for output in invalid:
            response = subprocess.CompletedProcess([], 0, stdout="", stderr=output)
            with patch.object(signing.subprocess, "run", return_value=response), self.assertRaises(ValueError):
                signing.verified_team(Path("owned-fixture"), identity, "dev.leostera.axo.axod")

    def test_rejects_malformed_fingerprints_and_team_ids(self):
        for line in [DEVELOPMENT.replace(FIRST, "A" * 39), DEVELOPMENT.replace("AAAAAAAAAA", "short"), "garbage"]:
            with self.assertRaises(ValueError): signing.select_identity(line, None)


if __name__ == "__main__":
    unittest.main()
