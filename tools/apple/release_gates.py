#!/usr/bin/env python3
"""Run repeatable Bazel-only Apple/web release gates and retain source-bound build evidence."""
import argparse
import hashlib
import json
import os
import plistlib
import subprocess
import sys
import zipfile
from pathlib import Path
from common import Release, exclusive_json, git, private_directory, require, source_sha


TESTS = [
    "//apple/AxoKit:AxoKitTests", "//apple/AxoSessionUI:AxoSessionUITests",
    "//apple/AxoMac:AxoMacTests", "//apple/AxoClient:AxoClientTests", "//apple/AxoProtocol:AxoProtocolTests",
    "//apple/AxoMobile:AxoMobileModelTests", "//apple/AxoWatchModel:AxoWatchModelTests",
    "//apple/AxoCompanion:AxoCompanionTests", "//packages/pi-axo:test",
    "//packages/pi-axo:typecheck_tests", "//packages/axo-web-app:test",
    "//packages/axo-api:test", "//packages/axo-api:schema_check", "//crates/axo-relay:axo_relay_tests",
    "//packages/axo-api-worker:session_sync_test", "//crates/axo-agent:axo_agent_tests", "//crates/axo-protocol:axo_protocol_tests",
    "//packages/axo-web-app:composer_browser_test",
    "//packages/axo-web-app:slash_browser_test", "//packages/axo-web-app:elicitations_browser_test",
    "//packages/axo-web-app:sidebar_browser_test", "//specs:recovery_test",
    "//bazel/publish:publish_test", "//bazel/publish:release_test",
    "//bazel/apple:distribution_preflight_test", "//tools/apple:test",
]


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=source_sha, required=True)
    parser.add_argument("--run-dir", type=Path, required=True)
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[2])
    return parser.parse_args(argv)


def artifact(repository, label):
    output = subprocess.check_output(["bazel", "cquery", label, "--output=files"], cwd=repository, text=True)
    paths = [repository / line for line in output.splitlines() if line.strip()]
    require(len(paths) == 1 and paths[0].is_file(), "Expected one real artifact, not a skipped target: " + label)
    return {"path": str(paths[0]), "sha256": hashlib.sha256(paths[0].read_bytes()).hexdigest()}


def main(argv=None):
    args = parse_args(argv)
    os.umask(0o077)
    repository = args.repository.resolve()
    output = private_directory(args.run_dir)
    require(not (output / "build-evidence.json").exists(), "Retain completed evidence; choose a fresh gate run")
    release = Release.read(repository, args.source)
    status = output / "gates-status.json"
    status.write_text(json.dumps({"source": args.source, "status": "running"}))

    def unchanged():
        require(not git(repository, "status", "--porcelain") and git(repository, "rev-parse", "HEAD") == args.source,
                "Gate source changed or is dirty")

    def bazel(*arguments):
        unchanged()
        subprocess.run(["bazel", *arguments], cwd=repository, check=True)

    try:
        bazel("test", *TESTS, "--test_output=errors")
        bazel("test", "//crates/axo-server:axo_server_tests", "--test_arg=--test-threads=1", "--test_output=errors")
        bazel("build", "//packages/axo-web-app:typecheck", "//packages/axo-api-worker:typecheck",
              "//tools/apple:typecheck", "//apple/AxoMac:Axo_zip")
        bazel("test", "//apple/AxoMac:package_test", "--test_output=errors")
        bazel("test", "//apple/AxoMobile:distribution_archive_test", "--watchos_cpus=device_arm64", "--test_output=errors")
        # Use one valid XCTest class filter, not a regex/pipe (which silently selects zero tests).
        bazel("test", "//apple/AxoMobile:AxoMobileRegressionUITests", "//apple/AxoMobile:AxoMobileTabletUITests",
              "--test_filter=AxoMobileSlashMenuTests", "--local_test_jobs=1", "--test_output=errors")
        bazel("test", "//apple/AxoMobile:AxoMobileRegressionUITests", "//apple/AxoMobile:AxoMobileTabletUITests",
              "--test_filter=AxoMobileDraftModelTests", "--local_test_jobs=1", "--test_output=errors")
        bazel("run", "//apple:xcodeproj")
        unchanged()
        mac = artifact(repository, "//apple/AxoMac:Axo_zip")
        mobile_output = subprocess.check_output(["bazel", "cquery", "//apple/AxoMobile:AxoMobile_ipa",
                                                "--watchos_cpus=device_arm64", "--output=files"], cwd=repository, text=True)
        mobile_paths = [repository / line for line in mobile_output.splitlines() if line.strip()]
        require(len(mobile_paths) == 1 and mobile_paths[0].is_file(), "Missing full companion IPA")
        mobile = {"path": str(mobile_paths[0]), "sha256": hashlib.sha256(mobile_paths[0].read_bytes()).hexdigest()}
        with zipfile.ZipFile(mac["path"]) as archive:
            info = plistlib.loads(archive.read("Axo.app/Contents/Info.plist"))
        require((info["CFBundleShortVersionString"], int(info["CFBundleVersion"]), int(info["AXODBuildNumber"])) ==
                (release.version, release.mac_build, release.daemon_build), "Mac release metadata differs")
        embedded = info.get("AXOGitCommit", "")
        require(len(embedded) >= 7 and args.source.startswith(embedded), "Mac archive source differs")
        unchanged()
        exclusive_json(output / "build-evidence.json", {"source": args.source, "version": release.version,
                       "macBuild": release.mac_build, "mobileBuild": release.mobile_build,
                       "daemonBuild": release.daemon_build, "artifacts": {"mac": mac, "mobile": mobile}})
        status.write_text(json.dumps({"source": args.source, "status": "passed"}))
        print("Verified source-bound release gates and retained build-evidence.json")
        return 0
    except Exception as error:
        status.write_text(json.dumps({"source": args.source, "status": "failed", "category": type(error).__name__}))
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
