#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import subprocess
import tempfile

spec = importlib.util.spec_from_file_location("compatibility", Path(__file__).with_name("helper-compatible-versions.py"))
compatibility = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compatibility)

with tempfile.TemporaryDirectory(prefix="axo-helper-compatibility-") as directory:
    root = Path(directory)

    def git(*args):
        return subprocess.run(["git", "-C", directory, *args], check=True, capture_output=True, text=True).stdout.strip()

    def write(path, value):
        destination = root / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(value)

    def commit(message):
        git("add", ".")
        git("-c", "user.name=Axo Fixture", "-c", "user.email=fixture@invalid", "commit", "-m", message)
        return git("describe", "--always", "--abbrev=8", "HEAD")

    def versions():
        return compatibility.compatible_versions(root, f"0.1.0 ({git('describe', '--always', '--abbrev=8', 'HEAD')})")

    git("init", "--initial-branch=main")
    write("axod/src/runtime.rs", "execution v1")
    write("pi-axo/index.ts", "adapter v1")
    write("protocol/src/contracts.ts", "wire v1")
    initial = commit("initial execution")
    write("apple/AxoMacAxod/View.swift", "frontend v1")
    frontend = commit("frontend change")
    assert versions() == [f"0.1.0 ({frontend})", f"0.1.0 ({initial})"]
    write("axod/src/runtime.rs", "execution v2")
    execution = commit("execution change")
    assert versions() == [f"0.1.0 ({execution})"]
    write("apple/AxoMacAxod/View.swift", "frontend v2")
    assert versions() == [f"0.1.0 ({execution})"], "Frontend-only dirty state must not disable an unchanged helper"
    write("pi-axo/index.ts", "adapter v2")
    assert versions() == [], "Dirty execution may not claim committed compatibility"
    adapter = commit("adapter change")
    assert versions() == [f"0.1.0 ({adapter})"]
    write("protocol/src/contracts.ts", "wire v2")
    protocol = commit("wire change")
    assert versions() == [f"0.1.0 ({protocol})"]
    write("axod/src/untracked.rs", "unknown execution")
    assert versions() == [], "Untracked execution must fail closed"
    assert compatibility.compatible_versions(root, "unknown") == []

print("PASS: frontend-only helper compatibility; execution, adapter, wire, dirty/untracked source and unknown provenance fail closed")
