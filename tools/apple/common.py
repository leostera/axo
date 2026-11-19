"""Shared, credential-free boundaries for operated Apple release tools."""
import argparse
import json
import os
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def source_sha(value):
    if not re.fullmatch(r"[a-f0-9]{40}", value):
        raise argparse.ArgumentTypeError("source must be a full lowercase Git SHA")
    return value


def version_parts(value):
    require(isinstance(value, str) and re.fullmatch(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?", value), "Invalid version")
    parts = tuple(int(part) for part in value.split("."))
    return parts + (0,) * (3 - len(parts))


def positive_build(value):
    require(type(value) is int and 0 < value < 1_000_000_000, "Invalid build number")
    return value


def git(repository, *args):
    return subprocess.check_output(["git", "-C", str(repository), *args], text=True).strip()


def require_published_main(repository, source):
    require(not git(repository, "status", "--porcelain"), "Commit changes before release operations")
    require(git(repository, "branch", "--show-current") == "main", "Use main")
    require(git(repository, "rev-parse", "--git-dir") == git(repository, "rev-parse", "--git-common-dir"), "Use the primary clone")
    require(git(repository, "rev-parse", "HEAD") == source == git(repository, "rev-parse", "origin/main"), "Source must equal clean published main; fetch/reconcile first")


def private_directory(path):
    path = Path(path)
    require(not path.is_symlink(), "Run directory must not be a symlink")
    path = path.resolve()
    parent = next(p for p in [path, *path.parents] if p.exists())
    probe = subprocess.run(["git", "-C", str(parent), "rev-parse", "--is-inside-work-tree"], capture_output=True, text=True)
    require(probe.returncode != 0 or probe.stdout.strip() != "true", "Keep run state, profiles and device metadata outside Git")
    path.mkdir(parents=True, mode=0o700, exist_ok=True)
    require(path.stat().st_uid == os.getuid(), "Run directory must belong to this user")
    path.chmod(0o700)
    return path


def approved(path):
    """Correlate an operator's real approval receipt; this file is not an authority token."""
    value = json.loads(Path(path).read_text())
    require(isinstance(value, dict) and value.get("action") == "accept", "A fresh scoped human acceptance is required")
    return value


def exclusive_json(path, value):
    fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(fd, "w") as output:
        json.dump(value, output)


@dataclass(frozen=True)
class Release:
    source: str
    version: str
    mac_build: int
    mobile_build: int
    daemon_build: int
    team: str

    @classmethod
    def read(cls, repository, source):
        config = json.loads((Path(repository) / "config.json").read_text())
        version_parts(config["version"])
        builds = config["builds"]
        team = config["apple"]["team"]
        require(re.fullmatch(r"[A-Z0-9]{10}", team), "Invalid Apple team")
        return cls(source_sha(source), config["version"], positive_build(builds["mac"]),
                   positive_build(builds["phone"]), positive_build(builds["axod"]), team)
