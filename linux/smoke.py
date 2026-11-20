#!/usr/bin/env python3
"""Exercise a built Linux axod without a real account, Pi credentials, or user state."""
import argparse
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time


def rpc(path, method, params):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(5)
        connection.connect(str(path))
        request = {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
        connection.sendall(json.dumps(request).encode() + b"\n")
        response = json.loads(connection.makefile("rb").readline())
        if "error" in response:
            raise RuntimeError(f"{method}: {response['error']}")
        return response["result"]


def wait_for(description, check, daemon, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if daemon.poll() is not None:
            raise RuntimeError(f"daemon exited with {daemon.returncode}: {description}")
        value = check()
        if value:
            return value
        time.sleep(0.05)
    raise TimeoutError(description)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("axod", type=Path)
    parser.add_argument("--bundled-resources", action="store_true",
                        help="require the runtime's bundled Pi extension instead of a fixture")
    arguments = parser.parse_args()
    executable = arguments.axod.resolve(strict=True)
    repository = Path(__file__).resolve().parents[1]
    fixture = repository / "crates/axod/testdata/pi-fixture.sh"
    with tempfile.TemporaryDirectory(prefix="axo-linux-", dir="/tmp") as temporary:
        root = Path(temporary)
        home = root / "home"
        home.mkdir()
        ipc = root / "axod.sock"
        environment = dict(os.environ, HOME=str(home), AXO_PI_EXECUTABLE=str(fixture))
        if arguments.bundled_resources:
            environment.pop("AXO_PI_EXTENSION_PATH", None)
            environment.pop("AXO_RESOURCES_DIR", None)
        else:
            environment["AXO_PI_EXTENSION_PATH"] = str(repository / "crates/axo-server/testdata/pi-extension.js")
        daemon = subprocess.Popen([
            str(executable), "--server-dir", str(root / "server"),
            "--socket", str(ipc), "--host-credentials", "files",
            "--relay-url", "http://127.0.0.1:9",
        ], env=environment, stdin=subprocess.DEVNULL)
        try:
            wait_for("IPC socket", ipc.exists, daemon)
            def ready():
                health = rpc(ipc, "axo.daemon.health", {})
                return health if health["ready"] else None

            health = wait_for("daemon ready", ready, daemon)
            rpc(ipc, "axo.config.set", {"key": "shell.command", "value": "/bin/sh -l"})
            session = rpc(ipc, "axo.session.create", {"folder": str(home)})
            terminal = next(pane for pane in session["shells"] if pane["role"] == "terminal")
            ids = {"sessionId": session["id"], "shellId": terminal["id"]}
            rpc(ipc, "axo.terminal.write", dict(ids, text="printf 'AXO_%s\\n' LINUX_OK\r"))
            wait_for("PTY output", lambda: "AXO_LINUX_OK" in rpc(ipc, "axo.terminal.screen", ids)["text"], daemon)
            rpc(ipc, "axo.session.close", {"sessionId": session["id"]})
            daemon.send_signal(signal.SIGTERM)
            if daemon.wait(timeout=10) != 0:
                raise RuntimeError("unclean daemon shutdown")
            print(json.dumps({"status": "passed", "version": health["version"],
                              "checks": ["health RPC", "session creation", "PTY input/output", "session close", "SIGTERM shutdown"]}))
        finally:
            if daemon.poll() is None:
                daemon.kill()
                daemon.wait()


if __name__ == "__main__":
    main()
