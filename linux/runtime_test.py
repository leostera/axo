#!/usr/bin/env python3
"""Headless archive contracts on private state only; never installs a host service."""
import json
import os
from pathlib import Path
import shutil
import signal
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
import unittest

from smoke import rpc, wait_for

ARCHIVE = Path(sys.argv.pop(1)).resolve(strict=True)
FIXTURE = Path(sys.argv.pop(1)).resolve(strict=True)


class RuntimeContract(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="axo-runtime-contract-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.runtime = self.root / "release-a"
        self.runtime.mkdir()
        with tarfile.open(ARCHIVE) as archive:
            archive.extractall(self.runtime, filter="data")
        self.home = self.root / "home"
        self.home.mkdir()
        # Neither resource overrides nor graphical/account environment may escape
        # into this private daemon. The only Pi is an owned, credential-free fixture.
        self.environment = {key: os.environ[key]
                            for key in ("PATH", "LANG", "LC_ALL", "LD_LIBRARY_PATH", "TZ")
                            if key in os.environ}
        self.environment.update(HOME=str(self.home), AXO_PI_EXECUTABLE=str(FIXTURE))
        for key in ("XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_RUNTIME_DIR"):
            directory = self.root / key.lower()
            directory.mkdir(mode=0o700)
            self.environment[key] = str(directory)
        self.ipc = self.root / "host.sock"
        self.daemon = None
        self.log = (self.root / "daemon.log").open("w+")
        self.addCleanup(self.log.close)
        self.addCleanup(self.stop)

    def cli(self, runtime, *arguments, check=True):
        return subprocess.run([str(runtime / "axo"), "--socket", str(self.ipc),
                               "--json", "--timeout-ms", "5000", *arguments],
                              env=self.environment, text=True, capture_output=True,
                              timeout=15, check=check)

    def start(self, runtime):
        self.daemon = subprocess.Popen([
            str(runtime / "axod"), "--server-dir", str(self.root / "server"),
            "--socket", str(self.ipc), "--host-credentials", "files",
            "--relay-url", "http://127.0.0.1:9",
        ], env=self.environment, stdin=subprocess.DEVNULL, stdout=self.log, stderr=self.log)

        def ready():
            try:
                health = rpc(self.ipc, "axo.daemon.health", {})
                return health if health["ready"] else None
            except (OSError, RuntimeError):
                return None
        try:
            # Restored sleeping fixtures do not bind a Pi bridge. The production
            # launch-readiness grace is 15 seconds, longer than smoke.py\'s default.
            return wait_for("headless runtime ready", ready, self.daemon, timeout=25)
        except Exception:
            self.log.flush()
            server_log = self.root / "server/stderr.log"
            detail = server_log.read_text() if server_log.exists() else ""
            raise AssertionError((self.root / "daemon.log").read_text() + detail)

    def stop(self):
        if self.daemon is None:
            return
        if self.daemon.poll() is not None:
            self.assertEqual(self.daemon.returncode, 0, "runtime exited unexpectedly")
            return
        self.daemon.send_signal(signal.SIGTERM)
        try:
            self.assertEqual(self.daemon.wait(timeout=15), 0, "unclean runtime stop")
        finally:
            if self.daemon.poll() is None:
                self.daemon.kill()
                self.daemon.wait(timeout=5)

    def host_id(self):
        with sqlite3.connect(f"file:{self.root / 'server/axo.db'}?mode=ro", uri=True) as database:
            database.execute("PRAGMA query_only=ON")
            return database.execute("SELECT value FROM daemon_metadata WHERE key='host_id'").fetchone()[0]

    def test_archive_is_a_complete_headless_runtime(self):
        for name in ("axo", "axod", "axo-askpass", "axod-infer"):
            self.assertTrue(os.access(self.runtime / name, os.X_OK), f"missing executable: {name}")
        self.assertTrue((self.runtime / "AxoPi/index.js").is_file())
        health = self.start(self.runtime)
        status = json.loads(self.cli(self.runtime, "daemon", "status").stdout)
        self.assertTrue(status["ready"])
        self.assertEqual(status["version"], health["version"])
        self.assertEqual(status["buildNumber"], health["buildNumber"])
        self.assertFalse(json.loads(self.cli(self.runtime, "relay", "status").stdout)["linked"])

    def test_cli_install_is_idempotent_and_never_replaces_a_command(self):
        directory = self.home / ".local/bin"
        self.cli(self.runtime, "cli", "install")
        self.cli(self.runtime, "cli", "install")
        self.assertEqual((directory / "axo").resolve(), self.runtime / "axo")
        candidate = self.root / "candidate"
        shutil.copytree(self.runtime, candidate)
        refused = self.cli(candidate, "cli", "install", check=False)
        self.assertNotEqual(refused.returncode, 0, "link installation is not an automatic updater")
        self.assertEqual((directory / "axo").resolve(), self.runtime / "axo")
        foreign = self.home / "foreign-bin"
        foreign.mkdir()
        command = foreign / "axo"
        command.write_text("owned foreign command\n")
        refused = self.cli(self.runtime, "cli", "install", "--dir", str(foreign), check=False)
        self.assertNotEqual(refused.returncode, 0)
        self.assertEqual(command.read_text(), "owned foreign command\n")

    def test_relocated_candidate_restores_identity_sessions_and_settings(self):
        self.start(self.runtime)
        rpc(self.ipc, "axo.config.set", {"key": "shell.command", "value": "/bin/sh -l"})
        session = rpc(self.ipc, "axo.session.create", {"folder": str(self.home)})
        rpc(self.ipc, "axo.session.rename", {"sessionId": session["id"], "name": "owned restart contract"})
        identity = self.host_id()
        self.stop()
        candidate = self.root / "release-b with spaces"
        shutil.copytree(self.runtime, candidate)
        self.start(candidate)
        self.assertEqual(self.host_id(), identity)
        sessions = json.loads(self.cli(candidate, "session", "list").stdout)
        restored = next(row for row in sessions if row["id"] == session["id"])
        self.assertEqual(restored.get("manualName") or restored["name"], "owned restart contract")
        self.assertEqual({pane["id"] for pane in restored["shells"]},
                         {pane["id"] for pane in session["shells"]})
        self.assertEqual(rpc(self.ipc, "axo.config.get", {"key": "shell.command"})["value"], "/bin/sh -l")


if __name__ == "__main__":
    unittest.main()
