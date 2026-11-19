#!/usr/bin/env python3
"""Operate one exact-source Mac update; stage this file and common.py together on a host."""
import argparse
import json
import os
import platform
import plistlib
import shlex
import socket
import subprocess
import time
from pathlib import Path
from urllib.parse import urlparse
from common import approved, exclusive_json, positive_build, private_directory, require, source_sha, version_parts


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=source_sha)
    parser.add_argument("--team", required=True)
    parser.add_argument("--run-dir", required=True, type=Path)
    parser.add_argument("--approval-file", type=Path)
    parser.add_argument("--manifest-url", default="https://axo.leostera.dev/cdn/latest.json")
    parser.add_argument("--mode", choices=["check", "install", "idle", "restart"], default="check")
    parser.add_argument("--approved-running-sessions", action="store_true")
    parser.add_argument("--exempt-session", default="")
    parser.add_argument("--delay-seconds", type=int, default=0)
    args = parser.parse_args(argv)
    require(args.delay_seconds >= 0, "Invalid delay")
    if args.mode in ("install", "restart"):
        require(args.approval_file is not None, "Writes require scoped human acceptance")
    url = urlparse(args.manifest_url)
    require(url.scheme == "https" and url.hostname and not url.username and not url.password
            and not url.query and not url.fragment, "Use a public HTTPS manifest without credentials")
    require(len(args.team) == 10 and args.team.isalnum(), "Invalid team")
    return args


def rpc(method):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(5)
        connection.connect(str(Path.home() / "Library/Application Support/Axo/run/axod.sock"))
        connection.sendall((json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": {}}) + "\n").encode())
        data = b""
        while b"\n" not in data:
            part = connection.recv(65536)
            require(part and len(data) + len(part) < 16_000_000, "Invalid daemon response")
            data += part
        response = json.loads(data.split(b"\n")[0])
        require("error" not in response, "Daemon rejected read-only inspection")
        return response["result"]


def check_sessions(args):
    allowed = {"ready", "unavailable"}
    if args.approved_running_sessions:
        allowed |= {"working", "starting", "needsAttention"}
    known = {"ready", "unavailable", "working", "starting", "needsAttention"}
    blocked = [session for session in rpc("axo.session.catalog")["sessions"]
               if session.get("status") not in known or
               (session["id"] != args.exempt_session and session.get("status") not in allowed)]
    require(not blocked, "Unapproved busy or unknown Session state; cutover held")


def load_manifest(args, root):
    path = root / "manifest.json"
    if not path.exists():
        subprocess.run(["curl", "-fsS", args.manifest_url, "-o", str(path)], check=True, timeout=30)
    value = json.loads(path.read_text())
    require(value["commit"] == args.source, "Public manifest changed; reconcile release source")
    version_parts(value["version"])
    positive_build(value["build"])
    positive_build(value["axodBuild"])
    require(set(value["artifacts"]) == set(value["integrity"]), "Missing archive integrity")
    return value


def daemon_ready(manifest):
    health = rpc("axo.daemon.health")
    require(health["buildNumber"] <= manifest["axodBuild"], "Never downgrade a newer daemon")
    return (health["buildNumber"] == manifest["axodBuild"] and health.get("ready") is True
            and health["version"] in (manifest["version"], manifest["version"] + ".0"))


def app_installed(args, manifest):
    found = False
    for app in [Path("/Applications/Axo.app"), Path.home() / "Applications/Axo.app"]:
        info = app / "Contents/Info.plist"
        if not info.is_file():
            continue
        value = plistlib.loads(info.read_bytes())
        require(int(value["CFBundleVersion"]) <= manifest["build"] and
                version_parts(value["CFBundleShortVersionString"]) <= version_parts(manifest["version"]),
                "Never downgrade a newer app")
        if (value["CFBundleShortVersionString"], int(value["CFBundleVersion"])) != (manifest["version"], manifest["build"]):
            continue
        embedded = value.get("AXOGitCommit", "")
        require(len(embedded) >= 7 and args.source.startswith(embedded), "Installed source differs")
        require(int(value["AXODBuildNumber"]) == manifest["axodBuild"], "Installed daemon metadata differs")
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True, timeout=30)
        result = subprocess.run(["codesign", "-dv", "--verbose=4", str(app)], capture_output=True, text=True, check=True)
        details = result.stdout + result.stderr
        require("Authority=Developer ID Application: " in details and "TeamIdentifier=" + args.team in details,
                "Target metadata exists without the expected Developer ID signature; inspect before replacement")
        subprocess.run(["xcrun", "stapler", "validate", str(app)], check=True, timeout=30)
        found = True
    return found


def restart_if_needed(args, manifest):
    if daemon_ready(manifest):
        return
    check_sessions(args)
    subprocess.run(["launchctl", "kill", "SIGTERM", "gui/" + str(os.getuid()) + "/dev.leostera.axo.axod"], check=True, timeout=10)
    time.sleep(3)


def invocation(args, mode):
    result = ["python3", str(Path(__file__).resolve()), "--source", args.source, "--team", args.team,
              "--run-dir", str(args.run_dir), "--approval-file", str(args.approval_file),
              "--manifest-url", args.manifest_url, "--mode", mode, "--exempt-session", args.exempt_session]
    if args.approved_running_sessions:
        result.append("--approved-running-sessions")
    return shlex.join(result)


def install(args, root, manifest):
    def record(status):
        temporary = root / "rollout.tmp"
        temporary.write_text(json.dumps({"status": status, "source": args.source, "version": manifest["version"],
                                         "appBuild": manifest["build"], "daemonBuild": manifest["axodBuild"]}))
        temporary.replace(root / "rollout.json")

    time.sleep(args.delay_seconds)
    if app_installed(args, manifest) and daemon_ready(manifest):
        record("installed")
        return
    check_sessions(args)
    try:
        if not app_installed(args, manifest):
            url = urlparse(args.manifest_url)
            raw = root / "public-install.sh"
            subprocess.run(["curl", "-fsS", url.scheme + "://" + url.netloc + "/install", "-o", str(raw)], check=True, timeout=30)
            script = raw.read_text()
            fetch = 'status=$(curl -sSL -o "$stage/latest.json" -w \'%{http_code}\' "$AXO_ORIGIN/cdn/latest.json") || fail "could not fetch latest.json"'
            require(script.count(fetch) == 1, "Public installer changed; inspect before activation")
            script = script.replace(fetch, "cp " + shlex.quote(str(root / "manifest.json")) + ' "$stage/latest.json" || fail "Could not pin release"\nstatus=200')
            quit_marker, start_marker = 'say "Quitting the running Axo"', 'say "Starting Axo"'
            require(script.count(quit_marker) == script.count(start_marker) == 1, "Public installer lifecycle changed")
            script = script.replace(quit_marker, invocation(args, "idle") + ' || fail "Cutover held"\n' + quit_marker)
            script = script.replace(start_marker, invocation(args, "restart") + ' || fail "Graceful restart not confirmed"\n' + start_marker)
            pinned = root / "install-pinned.sh"
            pinned.write_text(script)
            record("installing")
            subprocess.run(["/bin/sh", str(pinned)], check=True, timeout=240,
                           env=dict(os.environ, AXO_PAIRING_CODE="", AXO_INSTALL_CLI="0"))
        else:
            restart_if_needed(args, manifest)
        require(app_installed(args, manifest), "Target app not verified")
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            try:
                if daemon_ready(manifest):
                    record("installed")
                    print("Verified exact-source " + manifest["version"] + " app and healthy daemon; existing data retained", flush=True)
                    return
            except (OSError, RuntimeError):
                pass
            time.sleep(2)
        raise RuntimeError("Daemon readiness not verified; no forced restart attempted")
    except Exception:
        record("heldOrFailed")
        raise


def main(argv=None):
    args = parse_args(argv)
    require(platform.system() == "Darwin" and platform.machine() in ("arm64", "x86_64"), "Use a supported Mac")
    os.umask(0o077)
    if args.mode in ("install", "restart"):
        approved(args.approval_file)
    root = private_directory(args.run_dir)
    args.run_dir = root
    if args.approval_file:
        args.approval_file = args.approval_file.resolve()
    if args.mode == "install":
        exclusive_json(root / "install.lock", {"source": args.source})
    manifest = load_manifest(args, root)
    if args.mode == "check":
        print(json.dumps({"version": manifest["version"], "appInstalled": app_installed(args, manifest), "daemonReady": daemon_ready(manifest)}))
    elif args.mode == "idle":
        check_sessions(args)
    elif args.mode == "restart":
        restart_if_needed(args, manifest)
    else:
        install(args, root, manifest)


if __name__ == "__main__":
    main()
