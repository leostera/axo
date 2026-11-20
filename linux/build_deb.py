#!/usr/bin/env python3
"""Build an offline native Debian package. Never publishes, installs or activates it."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import subprocess
import tarfile
import tempfile

BINARIES = ("axo", "axod", "axod-infer", "axo-askpass")
RETENTION_COMMITS = ("fcb6cce7259b9c74c40ce387687a8ac6463494f6", "eaa98a0dc5c0d83a4c5bc0ba2b00031931175ae4")
UNIT = """[Unit]
Description=Axo personal host daemon
After=network.target
[Service]
Type=simple
ExecStart=/usr/lib/axo/axod --server-dir %h/.axo/server --socket %h/.axo/server/axod.sock --host-credentials files
WorkingDirectory=%h
UMask=0077
Restart=on-failure
RestartSec=2
TimeoutStopSec=20
KillMode=control-group
[Install]
WantedBy=default.target
"""
GUIDE = """Axo headless Linux host
Verify the published SHA256 before installation. Stop your daemon before updating:
  systemctl --user stop axod.service
  sudo apt install ./axo_VERSION_amd64.deb
Then, as your login user (not root):
  systemctl --user daemon-reload
  systemctl --user enable --now axod.service
Ensure your agent executable is in the user manager's PATH.
This package never starts/restarts services or changes ~/.axo automatically.
Existing ~/.local/bin commands and user service overrides are not replaced.
Inspect/migrate manual installations explicitly before enabling this system-provided unit.
No automatic updater, rollback, signed APT repository or native terminal is included.
"""


def run(*arguments, cwd=None):
    result = subprocess.run(arguments, cwd=cwd, text=True, capture_output=True, timeout=120)
    if result.returncode:
        raise RuntimeError(f"{arguments[0]} failed ({result.returncode}): {result.stderr.strip()}")
    return result.stdout.strip()


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def source_provenance(source, candidate):
    def git(*args):
        return run("git", "-C", str(source), *args)
    if not candidate:
        git("fetch", "origin")
    for commit in RETENTION_COMMITS:
        git("merge-base", "--is-ancestor", commit, "HEAD")
    guard = (source / "crates/axo-relay/src/sync/uploader.rs").read_text()
    if "const AUTOMATIC_TRANSCRIPT_EVICTION: bool = false;" not in guard:
        raise ValueError("automatic transcript eviction must remain disabled")
    head, integrated = git("rev-parse", "HEAD"), git("rev-parse", "origin/main")
    dirty = bool(git("status", "--porcelain"))
    primary = git("rev-parse", "--git-dir") == git("rev-parse", "--git-common-dir")
    eligible = primary and not dirty and head == integrated and git("branch", "--show-current") == "main"
    if not candidate and not eligible:
        raise ValueError("release requires clean primary main matching origin/main; integrate and rebuild")
    return {"source_commit": head, "integrated_main": integrated, "dirty": dirty,
            "release_eligible": eligible and not candidate, "retention_commits": list(RETENTION_COMMITS)}


def unpack_runtime(archive, destination):
    with tarfile.open(archive) as package:
        members = []
        seen = set()
        total = 0
        for member in package:
            members.append(member)
            if len(members) > 256:
                raise ValueError("runtime exceeds member limit")
            name = PurePosixPath(member.name)
            if str(name) in seen or name.is_absolute() or ".." in name.parts:
                raise ValueError("duplicate or unsafe runtime path")
            seen.add(str(name))
            allowed = str(name) in BINARIES or (len(name.parts) == 2 and name.parts[0] == "AxoPi"
                       and name.suffix in (".js", ".mjs", ".json"))
            if member.isdir() and str(name) == "AxoPi":
                continue
            if not member.isfile() or not allowed:
                raise ValueError(f"unexpected runtime member: {member.name}")
            total += member.size
            if total > 2 * 1024**3:
                raise ValueError("runtime exceeds package limits")
        if not {"axod", "axod-infer", "axo-askpass", "AxoPi/index.js"} <= seen:
            raise ValueError("incomplete runtime")
        package.extractall(destination, members=members, filter="data")
    for path in destination.rglob("*"):
        path.chmod(0o755 if path.is_dir() or path.name in BINARIES else 0o644)


def assemble_tree(runtime, root, version, provenance):
    destination = root / "usr/lib/axo"
    destination.parent.mkdir(parents=True)
    shutil.copytree(runtime, destination)
    bindir = root / "usr/bin"
    bindir.mkdir(parents=True)
    for name in ("axo", "axod"):
        (bindir / name).symlink_to(f"../lib/axo/{name}")
    unit = root / "usr/lib/systemd/user/axod.service"
    unit.parent.mkdir(parents=True)
    unit.write_text(UNIT)
    docs = root / "usr/share/doc/axo"
    docs.mkdir(parents=True)
    (docs / "README.Debian").write_text(GUIDE.replace("VERSION", version))
    hashes = {name: digest(destination / name) for name in BINARIES}
    (docs / "release.json").write_text(json.dumps({**provenance, "package_version": version,
        "platform": "linux", "architecture": "amd64", "binary_sha256": hashes}, indent=2) + "\n")


def dependency_list(root, work):
    debian = work / "debian"
    debian.mkdir()
    (debian / "control").write_text("Source: axo\nSection: utils\nPriority: optional\nMaintainer: Axo <leandro@ostera.io>\n\nPackage: axo\nArchitecture: any\nDescription: Axo host\n")
    result = run("dpkg-shlibdeps", "-O", *("-e" + str(root / "usr/lib/axo" / name) for name in BINARIES), cwd=work)
    return next(line.removeprefix("shlibs:Depends=") for line in result.splitlines() if line.startswith("shlibs:Depends="))


def write_control(root, version, dependencies):
    control = root / "DEBIAN"
    control.mkdir()
    (control / "control").write_text(f"Package: axo\nVersion: {version}\nSection: utils\nPriority: optional\nArchitecture: amd64\nMaintainer: Axo <leandro@ostera.io>\nDepends: {dependencies}\nDescription: Axo personal host daemon and CLI\n Headless user-session host with explicit systemd user activation.\n")
    executables = {root / "usr/lib/axo" / name for name in BINARIES}
    for path in [root, *root.rglob("*")]:
        if not path.is_symlink():
            path.chmod(0o755 if path.is_dir() or path in executables else 0o644)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--candidate", action="store_true", help="non-publishable local artifact; never bypasses retention checks")
    args = parser.parse_args()
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        parser.error("native Linux x86_64 builder required")
    source = args.source.resolve(strict=True)
    provenance = source_provenance(source, args.candidate)
    config = json.loads((source / "config.json").read_text())
    version = config["version"] + ".0"
    build = config["builds"]["axod"]
    if not re.fullmatch(r"\d+\.\d+\.\d+", version) or type(build) is not int or build < 1:
        raise ValueError("invalid package version/build")
    package_version = f"{version}-{build}"
    with tempfile.TemporaryDirectory(prefix="axo-deb-build-") as temporary:
        work = Path(temporary)
        runtime = work / "runtime"
        runtime.mkdir()
        unpack_runtime(args.runtime.resolve(strict=True), runtime)
        if (runtime / "axo").exists() and digest(runtime / "axo") != digest(args.cli):
            raise ValueError("archive and supplied CLI differ")
        shutil.copy2(args.cli, runtime / "axo")
        (runtime / "axo").chmod(0o755)
        if run(str(runtime / "axod"), "--version") != f"axod {version} (build {build})":
            raise ValueError("daemon does not match package config")
        if run(str(runtime / "axo"), "--version") != f"axo {version}":
            raise ValueError("CLI does not match package config")
        root = work / "package"
        assemble_tree(runtime, root, package_version, provenance)
        dependencies = dependency_list(root, work)
        write_control(root, package_version, dependencies)
        args.output.mkdir(parents=True, exist_ok=True)
        suffix = ".candidate.deb" if args.candidate else ".deb"
        output = args.output / f"axo_{package_version}_amd64{suffix}"
        if output.exists():
            raise ValueError("refusing to overwrite an existing installer")
        env = dict(os.environ, SOURCE_DATE_EPOCH="0")
        descriptor, temporary_output = tempfile.mkstemp(prefix=".axo-deb-", suffix=".deb", dir=args.output)
        os.close(descriptor)
        staged = Path(temporary_output)
        try:
            subprocess.run(["dpkg-deb", "--root-owner-group", "--threads-max=2", "-Zxz", "-z3", "--build", str(root), str(staged)],
                           env=env, check=True, timeout=300)
            staged.chmod(0o644)
            os.link(staged, output)  # Atomic no-replace commit, including racing builders.
        finally:
            staged.unlink(missing_ok=True)
        result = {**provenance, "package_version": package_version, "artifact": str(output.resolve()), "sha256": digest(output),
                  "size": output.stat().st_size, "dependencies": dependencies,
                  "environment": {"kernel": platform.release(), "python": platform.python_version(),
                                  "machine": platform.machine(), "distribution": platform.freedesktop_os_release().get("PRETTY_NAME"),
                                  "libc": platform.libc_ver(), "dpkg": run("dpkg-deb", "--version").splitlines()[0]},
                  "packager_sha256": digest(Path(__file__)), "runtime_archive_sha256": digest(args.runtime)}
        output.with_suffix(output.suffix + ".json").write_text(json.dumps(result, indent=2) + "\n")
        output.with_suffix(output.suffix + ".sha256").write_text(f"{result['sha256']}  {output.name}\n")
        print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
