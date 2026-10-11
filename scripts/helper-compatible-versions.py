#!/usr/bin/env python3
"""Declare only helper builds with identical execution and wire-contract sources."""
import json
import re
import subprocess
import sys

EXECUTION_PATHS = (
    "axod/src", "axod/Cargo.toml", "axod/Cargo.lock", "axod/build.rs",
    "pi-axo/*.ts", "pi-axo/tsconfig.json", "scripts/build-pi-adapter.mjs",
    "protocol/src", "protocol/schemas.json",
    "package.json", "package-lock.json", "bun.lock", "bun.lockb", "pnpm-lock.yaml", "yarn.lock",
    "protocol/package.json", "protocol/package-lock.json", "protocol/bun.lock", "protocol/bun.lockb",
)


def git(root, *args):
    return subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True, text=True).stdout.strip()


def compatible_versions(root, bundled_version):
    match = re.fullmatch(r"(.+) \([0-9a-f]{8,40}(?:-dirty)?\)", bundled_version)
    if not match:
        return []
    # Never attribute dirty/untracked execution code to a committed source tree.
    if git(root, "status", "--porcelain", "--untracked-files=all", "--", *EXECUTION_PATHS):
        return []
    versions = []
    for commit in git(root, "rev-list", "--max-count=64", "HEAD").splitlines():
        changed = git(root, "diff", "--name-only", commit, "HEAD", "--", *EXECUTION_PATHS)
        if changed:
            continue
        revision = git(root, "describe", "--always", "--abbrev=8", commit)
        versions.append(f"{match.group(1)} ({revision})")
    return versions


if __name__ == "__main__":
    print(json.dumps(compatible_versions(sys.argv[1], sys.argv[2])))
