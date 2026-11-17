import datetime as dt
import importlib.util
import sys
import unittest

spec = importlib.util.spec_from_file_location("probe_info", sys.argv.pop(1))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

TEAM = "TESTTEAM01"
PREFIX = "OTHERPRE01"


def fixture(bundle):
    return {
        "TeamIdentifier": [TEAM],
        "ApplicationIdentifierPrefix": [PREFIX],
        "ExpirationDate": dt.datetime(2100, 1, 1),
        "ProvisionedDevices": ["synthetic-owned-device"],
        "Platform": ["iOS"],
        "Entitlements": {
            "application-identifier": PREFIX + "." + bundle,
            "com.apple.developer.team-identifier": TEAM,
            "get-task-allow": True,
            "keychain-access-groups": [PREFIX + ".*"],
        },
    }


class ProbeInfoTests(unittest.TestCase):
    def test_each_exact_role_uses_actual_prefix_without_exporting_profile_metadata(self):
        for mode, bundles in [
            ("source", ["dev.leostera.axo.phone", "dev.leostera.axo.phone.watchkitapp"]),
            ("destination", ["dev.leostera.axo", "dev.leostera.axo.watch"]),
        ]:
            for bundle in bundles:
                info = module.probe_info(fixture(bundle), bundle_id=bundle, mode=mode, team=TEAM)
                self.assertEqual(info, {
                    "AXOIdentityProbeMode": mode,
                    "AXOIdentityProbeAccessGroup": PREFIX + ".dev.leostera.axo.migration",
                })

    def test_wrong_role_profile_team_prefix_or_group_is_refused(self):
        bundle = "dev.leostera.axo.phone"
        with self.assertRaises(ValueError):
            module.probe_info(fixture(bundle), bundle_id=bundle, mode="destination", team=TEAM)
        for change in [
            lambda p: p.update(TeamIdentifier=["OTHERTEAM1"]),
            lambda p: p.update(ApplicationIdentifierPrefix=[TEAM]),
            lambda p: p.update(ApplicationIdentifierPrefix=[PREFIX, TEAM]),
            lambda p: p.update(Entitlements="bad-type"),
            lambda p: p["Entitlements"].update({"application-identifier": PREFIX + ".*"}),
            lambda p: p["Entitlements"].update({"keychain-access-groups": ["UNRELATED.*"]}),
            lambda p: p["Entitlements"].update({"keychain-access-groups": PREFIX + ".*"}),
            lambda p: p["Entitlements"].update({"get-task-allow": False}),
            lambda p: p.update(ProvisionedDevices=[]),
            lambda p: p.update(ProvisionedDevices="bad-type"),
            lambda p: p.update(ProvisionsAllDevices=True),
            lambda p: p.update(Platform=["OSX"]),
            lambda p: p.update(ExpirationDate=dt.datetime(2000, 1, 1)),
        ]:
            profile = fixture(bundle)
            change(profile)
            with self.assertRaises(ValueError):
                module.probe_info(profile, bundle_id=bundle, mode="source", team=TEAM)


if __name__ == "__main__":
    unittest.main()
