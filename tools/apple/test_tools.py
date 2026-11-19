import argparse
import json
import subprocess
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch
from pathlib import Path
from common import Release, approved, exclusive_json, private_directory, source_sha, version_parts
import install_mac
import install_mobile
from inspect_permissions import summarize


class ToolBoundaries(unittest.TestCase):
    def test_permission_owner_metadata_does_not_turn_a_denial_into_a_grant(self):
        helper = Path("/Applications/Axo.app/Contents/Helpers/axod")
        report = {"processId": 42, "developerTools": "notGranted", "credential": "never emit", "screenRecording": "future-state"}
        value = summarize(report, str(helper), 42, helper)
        self.assertTrue(value["installedHelperMatchesRunningPath"])
        self.assertTrue(value["daemonIsResponsibleProcess"])
        self.assertEqual(value["permissions"], {"developerTools": "notGranted", "screenRecording": "unknown"})
        self.assertNotIn("credential", json.dumps(value))
        value = summarize(report, None, None, helper)
        self.assertIsNone(value["daemonIsResponsibleProcess"])
        self.assertIsNone(value["installedHelperMatchesRunningPath"])
        with self.assertRaises(RuntimeError):
            summarize({"processId": True}, None, None, helper)

    def test_source_and_versions_are_parsed_without_coercing_bad_values(self):
        self.assertEqual(source_sha("a" * 40), "a" * 40)
        for value in ["main", "a" * 7, "A" * 40, "../source"]:
            with self.assertRaises(argparse.ArgumentTypeError):
                source_sha(value)
        self.assertEqual(version_parts("0.81"), (0, 81, 0))
        self.assertEqual(version_parts("0.81.0"), (0, 81, 0))
        for value in ["latest", "1", "0.81-beta", "0.٨١", None]:
            with self.assertRaises(RuntimeError):
                version_parts(value)

    def test_read_only_checks_need_no_mutation_approval_but_installs_do(self):
        base = ["--source", "a" * 40, "--team", "TEAM123456", "--run-dir", "/private/release-check"]
        self.assertEqual(install_mac.parse_args(base).mode, "check")
        with self.assertRaises(RuntimeError):
            install_mac.parse_args(base + ["--mode", "install"])
        mobile = ["--source", "a" * 40, "--artifact", "/private/app.ipa", "--run-dir", "/private/mobile-check"]
        self.assertEqual(install_mobile.parse_args(mobile).mode, "check")
        with self.assertRaises(RuntimeError):
            install_mobile.parse_args(mobile + ["--mode", "install"])
        with self.assertRaises(RuntimeError):
            install_mobile.parse_args(mobile + ["--mode", "install", "--approval-file", "/private/approval.json"])

    def test_mac_restart_requires_explicit_busy_scope_and_never_accepts_unknown_states(self):
        args = SimpleNamespace(approved_running_sessions=False, exempt_session="")
        with patch.object(install_mac, "rpc", return_value={"sessions": [{"id": "other", "status": "working"}]}):
            with self.assertRaises(RuntimeError):
                install_mac.check_sessions(args)
            args.approved_running_sessions = True
            install_mac.check_sessions(args)
        args.exempt_session = "self"
        with patch.object(install_mac, "rpc", return_value={"sessions": [{"id": "self", "status": "unknown"}]}):
            with self.assertRaises(RuntimeError):
                install_mac.check_sessions(args)

    def test_private_or_credential_bearing_manifest_urls_are_rejected(self):
        base = ["--source", "a" * 40, "--team", "TEAM123456", "--run-dir", "/private/release-check"]
        for url in ["http://example.test/latest.json", "https://user:secret@example.test/latest.json", "https://example.test/latest.json?token=private"]:
            with self.assertRaises(RuntimeError):
                install_mac.parse_args(base + ["--manifest-url", url])

    def test_run_state_stays_outside_git_and_is_private(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            repository = base / "repository"
            subprocess.run(["git", "-c", "init.defaultBranch=main", "init", "-q", str(repository)], check=True)
            with self.assertRaises(RuntimeError):
                private_directory(repository / "private-run")
            run = private_directory(base / "outside")
            self.assertEqual(run.stat().st_mode & 0o777, 0o700)

    def test_declined_approval_and_replayed_attempts_fail_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "approval.json"
            for action in ["decline", "cancel", None]:
                path.write_text(json.dumps({"action": action}))
                with self.assertRaises(RuntimeError):
                    approved(path)
            path.write_text(json.dumps({"action": "accept", "id": "synthetic"}))
            self.assertEqual(approved(path)["action"], "accept")
            attempt = Path(temporary) / "attempt.json"
            exclusive_json(attempt, {"source": "a" * 40})
            with self.assertRaises(FileExistsError):
                exclusive_json(attempt, {"source": "b" * 40})

    def test_release_builds_are_positive_integers_not_booleans(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = {"version": "0.81", "builds": {"mac": 353, "phone": 84, "axod": 97}, "apple": {"team": "TEAM123456"}}
            (root / "config.json").write_text(json.dumps(config))
            self.assertEqual(Release.read(root, "a" * 40).mobile_build, 84)
            config["builds"]["phone"] = True
            (root / "config.json").write_text(json.dumps(config))
            with self.assertRaises(RuntimeError):
                Release.read(root, "a" * 40)


if __name__ == "__main__":
    unittest.main()
