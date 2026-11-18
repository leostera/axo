import copy
import datetime as dt
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location("preflight", sys.argv.pop(1))
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)

TEAM = "TESTTEAM01"
PREFIX = "OTHERPRE01"
BUNDLE = "dev.leostera.axo"
NOW = dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)


def fixture(channel="development", apns=False, migration=False):
    debugging = channel == "development"
    entitlements = {
        "application-identifier": PREFIX + "." + BUNDLE,
        "com.apple.developer.team-identifier": TEAM,
        "get-task-allow": debugging,
        "keychain-access-groups": [PREFIX + "." + BUNDLE],
    }
    if migration:
        entitlements["keychain-access-groups"].append(PREFIX + ".dev.leostera.axo.migration")
    if apns:
        entitlements["aps-environment"] = "development" if debugging else "production"
    profile = {
        "TeamIdentifier": [TEAM],
        "Platform": ["iOS"],
        "ApplicationIdentifierPrefix": [PREFIX],
        "ExpirationDate": dt.datetime(2030, 1, 1),
        "Entitlements": copy.deepcopy(entitlements),
    }
    profile["Entitlements"]["keychain-access-groups"] = [PREFIX + ".*"]
    if channel != "app-store-connect":
        profile["ProvisionedDevices"] = ["synthetic-owned-device"]
    info = {"CFBundleIdentifier": BUNDLE}
    if migration:
        info.update(AXOIdentityProbeMode="destination", AXOIdentityProbeAccessGroup=PREFIX + ".dev.leostera.axo.migration")
    return info, entitlements, profile


class MobileGraphScopeTests(unittest.TestCase):
    def parse(self, info, **changes):
        values = dict(watch=BUNDLE + ".watch", channel="development", migration=True,
                      existing=False, apns=False, mobile_only=True)
        values.update(changes)
        return policy.mobile_children(info, **values)

    def test_mobile_only_is_an_explicit_read_only_destination_probe(self):
        info = {"AXOIdentityProbeScope": "mobile-only", "AXOIdentityProbeMode": "destination"}
        self.assertEqual(self.parse(info), frozenset())
        for change in [dict(channel="ad-hoc"), dict(channel="app-store-connect"),
                       dict(migration=False), dict(existing=True), dict(apns=True), dict(mobile_only=False)]:
            with self.assertRaises(policy.GateError):
                self.parse(info, **change)
        for info in [{}, {"AXOIdentityProbeScope": "mobile-only", "AXOIdentityProbeMode": "source"},
                     {"AXOIdentityProbeScope": "unknown", "AXOIdentityProbeMode": "destination"}]:
            with self.assertRaises(policy.GateError):
                self.parse(info)

    def test_transfer_scope_cannot_be_used_for_production_or_to_drop_source_companions(self):
        info = {"AXOIdentityMigrationScope": "mobile-only", "AXOIdentityMigrationMode": "destination"}
        self.assertEqual(self.parse(info, mobile_only=False, transfer=True, apns=True), frozenset())
        for change in [dict(channel="ad-hoc"), dict(channel="app-store-connect"), dict(migration=False),
                       dict(mobile_only=True), dict(existing=True)]:
            args = dict(mobile_only=False, transfer=True)
            args.update(change)
            with self.assertRaises(policy.GateError):
                self.parse(info, **args)
        self.assertEqual(self.parse({}, mobile_only=False, transfer=True, existing=True),
                         frozenset({BUNDLE + ".watch", BUNDLE + ".watch.complications"}))
        with self.assertRaises(policy.GateError):
            self.parse(info, mobile_only=False)

    def test_normal_and_full_preservation_graphs_still_require_watch_and_widget(self):
        for migration in [False, True]:
            self.assertEqual(self.parse({}, mobile_only=False, migration=migration),
                             frozenset({BUNDLE + ".watch", BUNDLE + ".watch.complications"}))


class MobilePolicyTests(unittest.TestCase):
    def check(self, values, channel="development", apns=False, migration=False):
        policy.mobile_policy(*values, bundle_id=BUNDLE, team=TEAM, channel=channel, apns=apns, migration=migration, now=NOW)

    def test_signed_push_routing_cannot_cross_environments(self):
        for channel, environment in [("development", "sandbox"), ("ad-hoc", "production")]:
            values = fixture(channel, apns=True)
            values[0]["AXOPushEnvironment"] = environment
            self.check(values, channel, apns=True)
            values[0]["AXOPushEnvironment"] = "production" if environment == "sandbox" else "sandbox"
            with self.assertRaises(policy.GateError):
                self.check(values, channel, apns=True)

    def test_all_channels_use_actual_prefix_not_team(self):
        for channel in ["development", "ad-hoc", "app-store-connect"]:
            for apns in [False, True]:
                self.check(fixture(channel, apns), channel, apns)

    def test_rejects_wrong_identity_team_prefix_expiry_and_profile_class(self):
        for change in [
            lambda i, e, p: i.update(CFBundleIdentifier=BUNDLE + ".other"),
            lambda i, e, p: p.update(TeamIdentifier=["OTHERTEAM1"]),
            lambda i, e, p: p.update(Platform=["OSX"]),
            lambda i, e, p: p.update(ApplicationIdentifierPrefix=[TEAM]),
            lambda i, e, p: p.update(ApplicationIdentifierPrefix=[PREFIX, TEAM]),
            lambda i, e, p: p.update(ExpirationDate=NOW - dt.timedelta(seconds=1)),
            lambda i, e, p: p["Entitlements"].update({"application-identifier": PREFIX + ".*"}),
            lambda i, e, p: e.update({"get-task-allow": False}),
            lambda i, e, p: p["Entitlements"].update({"get-task-allow": False}),
            lambda i, e, p: p.update(ProvisionsAllDevices=True),
            lambda i, e, p: p.update(ProvisionedDevices=[]),
            lambda i, e, p: p.update(ProvisionedDevices="not-a-list"),
            lambda i, e, p: e.update({"keychain-access-groups": [TEAM + "." + BUNDLE]}),
            lambda i, e, p: p["Entitlements"].update({"keychain-access-groups": ["UNRELATED.*"]}),
        ]:
            values = fixture()
            change(*values)
            with self.assertRaises(policy.GateError):
                self.check(values)

    def test_signed_team_is_optional_but_cannot_contradict_profile_and_signature(self):
        values = fixture()
        del values[1]["com.apple.developer.team-identifier"]
        self.check(values)
        values[1]["com.apple.developer.team-identifier"] = "OTHERTEAM1"
        with self.assertRaises(policy.GateError):
            self.check(values)

    def test_only_the_installed_development_companions_retain_the_shipped_wildcard(self):
        for identifier in ["dev.leostera.axo.phone.watchkitapp", "dev.leostera.axo.phone.watchkitapp.complications"]:
            values = fixture()
            values[0]["CFBundleIdentifier"] = identifier
            for entitlements in [values[1], values[2]["Entitlements"]]:
                entitlements["application-identifier"] = PREFIX + "." + identifier
                entitlements["keychain-access-groups"] = [PREFIX + ".*"]
            policy.mobile_policy(*values, bundle_id=identifier, team=TEAM, channel="development", now=NOW)
            values[1]["get-task-allow"] = False
            values[2]["Entitlements"]["get-task-allow"] = False
            with self.assertRaises(policy.GateError):
                policy.mobile_policy(*values, bundle_id=identifier, team=TEAM, channel="ad-hoc", now=NOW)
        canonical = fixture()
        canonical[1]["keychain-access-groups"] = [PREFIX + ".*"]
        with self.assertRaises(policy.GateError):
            self.check(canonical)

    def test_production_channels_reject_development_or_enterprise_or_wrong_device_scope(self):
        for channel in ["ad-hoc", "app-store-connect"]:
            with self.assertRaises(policy.GateError):
                self.check(fixture("development"), channel)
            values = fixture(channel)
            values[2]["ProvisionsAllDevices"] = True
            with self.assertRaises(policy.GateError):
                self.check(values, channel)
        with self.assertRaises(policy.GateError):
            self.check(fixture("ad-hoc"), "app-store-connect")
        with self.assertRaises(policy.GateError):
            self.check(fixture("app-store-connect"), "ad-hoc")

    def test_apns_is_required_and_cannot_cross_environments(self):
        with self.assertRaises(policy.GateError):
            self.check(fixture(), apns=True)
        for channel in ["development", "ad-hoc", "app-store-connect"]:
            values = fixture(channel, apns=True)
            values[1]["aps-environment"] = "production" if channel == "development" else "development"
            with self.assertRaises(policy.GateError):
                self.check(values, channel, apns=True)
            with self.assertRaises(policy.GateError):
                self.check(values, channel, apns=False)

    def test_existing_watch_probe_retains_its_default_group_and_requires_signed_mode(self):
        identifier = "dev.leostera.axo.phone.watchkitapp"
        values = fixture(migration=True)
        values[0].update(CFBundleIdentifier=identifier, AXOIdentityProbeMode="source")
        for entitlements in [values[1], values[2]["Entitlements"]]:
            entitlements["application-identifier"] = PREFIX + "." + identifier
        values[1]["keychain-access-groups"][0] = PREFIX + ".*"
        policy.mobile_policy(*values, bundle_id=identifier, team=TEAM, channel="development", migration=True, now=NOW)
        values[0]["AXOIdentityProbeMode"] = "destination"
        with self.assertRaises(policy.GateError):
            policy.mobile_policy(*values, bundle_id=identifier, team=TEAM, channel="development", migration=True, now=NOW)

    def test_migration_is_explicit_development_only_and_only_the_one_shared_group(self):
        self.check(fixture(migration=True), migration=True)
        with self.assertRaises(policy.GateError):
            self.check(fixture(migration=True), migration=False)
        with self.assertRaises(policy.GateError):
            self.check(fixture(), migration=True)
        with self.assertRaises(policy.GateError):
            self.check(fixture("app-store-connect", migration=True), "app-store-connect", migration=True)
        values = fixture(migration=True)
        values[1]["keychain-access-groups"].reverse()
        with self.assertRaises(policy.GateError):
            self.check(values, migration=True)
        values = fixture(migration=True)
        values[1]["keychain-access-groups"].append(PREFIX + ".unrelated")
        with self.assertRaises(policy.GateError):
            self.check(values, migration=True)


class DeveloperIDPolicyTests(unittest.TestCase):
    details = "CodeDirectory v=20500 size=123 flags=0x10000(runtime) hashes=1\nTimestamp=Jan 1, 2026 at 00:00:00\n"

    def check(self, entitlements=None, details=None, info=None):
        policy.developer_id_policy(info or {"CFBundleIdentifier": BUNDLE}, entitlements or {},
                                   self.details if details is None else details, bundle_id=BUNDLE)

    def test_runtime_and_timestamp_required(self):
        self.check()
        for details in ["", self.details.replace("0x10000", "0x0"), self.details.split("Timestamp")[0], self.details.replace("Jan 1, 2026 at 00:00:00", "none")]:
            with self.assertRaises(policy.GateError):
                self.check(details=details)

    def test_debugging_jit_and_signature_bypasses_are_rejected(self):
        for key in ["get-task-allow", "com.apple.security.get-task-allow", "com.apple.security.cs.allow-jit",
                    "com.apple.security.cs.disable-library-validation", "com.apple.security.cs.allow-unsigned-executable-memory"]:
            with self.assertRaises(policy.GateError):
                self.check({key: True})
        with self.assertRaises(policy.GateError):
            self.check(info={"CFBundleIdentifier": "wrong.identity"})


class ProfileSignerTests(unittest.TestCase):
    def test_apple_chain_alone_does_not_authorize_developer_issued_profiles(self):
        self.assertTrue(policy.is_provisioning_signer("subject=CN=Apple iPhone OS Provisioning Profile Signing,OU=Apple Certification Authority,O=Apple Inc.,C=US"))
        self.assertTrue(policy.is_provisioning_signer("subject=C=US,O=Apple Inc.,CN=Apple iPhone OS Provisioning Profile Signing"))
        for name in ["CN=Apple Development: A Developer", "CN=Developer ID Application: A Developer",
                     r"CN=Apple Development: A Developer\,CN=Apple iPhone OS Provisioning Profile Signing",
                     r"O=Developer\,CN=Apple iPhone OS Provisioning Profile Signing,C=US",
                     "CN=Apple iPhone OS Provisioning Profile Signing,CN=Other,C=US",
                     "CN=Apple iPhone OS Provisioning Profile Signing Wrong Role,O=Apple Inc."]:
            self.assertFalse(policy.is_provisioning_signer("subject=" + name))


class ArchiveTests(unittest.TestCase):
    def test_only_one_bounded_root_app_and_no_escaping_paths_or_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "test.ipa"
            with zipfile.ZipFile(archive, "w") as writer:
                writer.writestr("Payload/Axo.app/Info.plist", b"synthetic")
            self.assertEqual(policy.unpack_ipa(archive, root / "ok").name, "Axo.app")
            for name in ["../outside", "/absolute", "Payload/../../outside", "Payload\\escape", "Payload//Axo.app/file", "./Payload/Axo.app/file"]:
                with zipfile.ZipFile(archive, "w") as writer:
                    writer.writestr(name, b"no")
                with self.assertRaises(policy.GateError):
                    policy.unpack_ipa(archive, root / "unsafe")
            with zipfile.ZipFile(archive, "w") as writer:
                entry = zipfile.ZipInfo("Payload/link")
                entry.create_system = 3
                entry.external_attr = 0o120777 << 16
                writer.writestr(entry, "../outside")
            with self.assertRaises(policy.GateError):
                policy.unpack_ipa(archive, root / "symlink")
            with zipfile.ZipFile(archive, "w") as writer:
                writer.writestr("Payload/First.app/Info.plist", b"one")
                writer.writestr("Payload/Second.app/Info.plist", b"two")
            with self.assertRaises(policy.GateError):
                policy.unpack_ipa(archive, root / "two")


if __name__ == "__main__":
    unittest.main()
