#!/usr/bin/env python3
"""Real dpkg install/reinstall/update under fakeroot, with private headless daemon state."""
import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import sqlite3
import subprocess
import tempfile

from build_deb import assemble_tree, digest, run, write_control
from smoke import rpc, wait_for


def install(package, root):
    database = root / "var/lib/dpkg"
    database.mkdir(parents=True, exist_ok=True)
    (database / "status").touch(exist_ok=True)
    # Only this private package database/root is changed. No maintainer scripts
    # exist; force-depends omits empty-sysroot dependency records, not ABI checks.
    run("env", "PATH=/usr/sbin:/sbin:" + os.environ.get("PATH", "/usr/bin:/bin"),
        "fakeroot", "dpkg", "--root=" + str(root), "--force-depends", "--no-triggers", "--install", str(package))
    return run("dpkg-query", "--admindir=" + str(database), "--show", "--showformat=${Version}", "axo")


@contextmanager
def host(root, fixture):
    home = root / "h"
    home.mkdir(exist_ok=True)
    env = {key: os.environ[key] for key in ("PATH", "LANG", "LC_ALL", "LD_LIBRARY_PATH") if key in os.environ}
    env.update(HOME=str(home), AXO_PI_EXECUTABLE=str(fixture))
    for key, directory in (("XDG_RUNTIME_DIR", "run"), ("XDG_CONFIG_HOME", "config"),
                           ("XDG_STATE_HOME", "state"), ("XDG_DATA_HOME", "data"), ("XDG_CACHE_HOME", "cache")):
        path = home / directory
        path.mkdir(mode=0o700, exist_ok=True)
        env[key] = str(path)
    socket = root / "s"
    log = (root / "daemon.log").open("a+")
    daemon = subprocess.Popen([str(root / "usr/lib/axo/axod"), "--server-dir", str(home / ".axo/server"),
        "--socket", str(socket), "--relay-url", "http://127.0.0.1:9", "--host-credentials", "files"],
        env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
    try:
        def ready():
            try:
                health = rpc(socket, "axo.daemon.health", {})
                return health if health["ready"] else None
            except (OSError, RuntimeError):
                return None
        health = wait_for("installed daemon readiness", ready, daemon, timeout=25)
        yield home, socket, health
    finally:
        if daemon.poll() is None:
            daemon.send_signal(signal.SIGTERM)
            try:
                status = daemon.wait(timeout=15)
            finally:
                if daemon.poll() is None:
                    daemon.kill()
                    daemon.wait()
            if status != 0:
                raise RuntimeError("installed daemon did not stop cleanly")
        elif daemon.returncode != 0:
            raise RuntimeError("installed daemon exited unexpectedly")
        log.close()


def identity(home):
    with sqlite3.connect(f"file:{home / '.axo/server/axo.db'}?mode=ro", uri=True) as database:
        database.execute("PRAGMA query_only=ON")
        return database.execute("SELECT value FROM daemon_metadata WHERE key='host_id'").fetchone()[0]


def seed(root, fixture):
    with host(root, fixture) as (home, socket, health):
        rpc(socket, "axo.config.set", {"key": "shell.command", "value": "/bin/sh -l"})
        session = rpc(socket, "axo.session.create", {"folder": str(home)})
        rpc(socket, "axo.session.rename", {"sessionId": session["id"], "name": "Owned native update"})
        sentinel = home / ".axo/install-preservation-sentinel"
        sentinel.write_text("owned disposable state\n")
        return {"host_id": identity(home), "session_id": session["id"], "health": health,
                "pane_ids": sorted(pane["id"] for pane in session["shells"])}


def restored(root, fixture, before):
    with host(root, fixture) as (home, socket, health):
        assert identity(home) == before["host_id"]
        session = next(row for row in rpc(socket, "axo.session.catalog", {})["sessions"] if row["id"] == before["session_id"])
        assert session["manualName"] == "Owned native update"
        assert sorted(pane["id"] for pane in session["shells"]) == before["pane_ids"]
        assert rpc(socket, "axo.config.get", {"key": "shell.command"})["value"] == "/bin/sh -l"
        assert (home / ".axo/install-preservation-sentinel").read_text() == "owned disposable state\n"
        cli = subprocess.check_output([str(root / "usr/bin/axo"), "--socket", str(socket), "--json", "daemon", "status"],
                                     text=True, env=dict(os.environ, HOME=str(home)), timeout=10)
        assert json.loads(cli) == health
        return health


def old_fixture(runtime, work):
    version = run(str(runtime / "axod"), "--version")
    match = re.fullmatch(r"axod (\d+\.\d+\.\d+) \(build (\d+)\)", version)
    if not match:
        raise ValueError("older runtime has no valid version")
    payload = work / "old-payload"
    payload.mkdir()
    # An older real runtime, binaries/resources only. Never copy personal DB,
    # credential backups, logs, install receipts, or any live-state directories.
    for name in ("axo", "axod", "axod-infer", "axo-askpass"):
        shutil.copy2(runtime / name, payload / name)
    shutil.copytree(runtime / "AxoPi", payload / "AxoPi")
    root = work / "old-package"
    package_version = f"{match[1]}-{match[2]}"
    assemble_tree(payload, root, package_version, {"test_fixture": True, "release_eligible": False})
    write_control(root, package_version, "libc6")
    output = work / "old-fixture-only.deb"
    subprocess.run(["dpkg-deb", "--root-owner-group", "--threads-max=2", "-Zxz", "-z3", "--build", str(root), str(output)],
                   check=True, stdout=subprocess.DEVNULL)
    return output, package_version


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("installer", type=Path)
    parser.add_argument("--old-runtime", type=Path, required=True)
    parser.add_argument("--pi-fixture", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    package, fixture = args.installer.resolve(strict=True), args.pi_fixture.resolve(strict=True)
    expected = run("dpkg-deb", "--field", str(package), "Version")
    with tempfile.TemporaryDirectory(prefix="ad-") as temporary:
        work = Path(temporary)
        # Reject hidden activation hooks before allowing even a disposable install.
        subprocess.run(["dpkg-deb", "--control", str(package), str(work / "control")], check=True)
        assert {path.name for path in (work / "control").iterdir()} == {"control"}
        fresh = work / "f"
        assert install(package, fresh) == expected
        before = seed(fresh, fixture)
        assert install(package, fresh) == expected
        fresh_health = restored(fresh, fixture, before)
        old, old_version = old_fixture(args.old_runtime.resolve(strict=True), work)
        subprocess.run(["dpkg", "--compare-versions", old_version, "lt", expected], check=True)
        upgrade = work / "u"
        assert install(old, upgrade) == old_version
        previous = seed(upgrade, fixture)
        assert install(package, upgrade) == expected
        after = restored(upgrade, fixture, previous)
        result = {"status": "passed", "artifact": str(package), "sha256": digest(package),
            "environment": {"distribution": platform.freedesktop_os_release().get("PRETTY_NAME"),
                            "kernel": platform.release(), "machine": platform.machine(), "root": "private fakeroot/dpkg sysroot"},
            "dependency_database_checks": "omitted in empty sysroot; binaries executed against native host ABI",
            "service_activation": "not attempted; package has no maintainer scripts",
            "checks": ["fresh install", "idempotent reinstall", "older real runtime upgrade", "CLI/daemon readiness",
                       "host identity", "session and pane IDs", "settings", "user-state sentinel"],
            "from": previous["health"], "to": after, "fresh": fresh_health}
        args.output.write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
