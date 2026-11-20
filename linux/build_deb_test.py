#!/usr/bin/env python3
import io
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import build_deb


class PackageBoundary(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="axo-deb-boundary-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def archive(self, extra=None):
        path = self.root / "runtime.tar.gz"
        with tarfile.open(path, "w:gz") as archive:
            for name in ("axo", "axod", "axod-infer", "axo-askpass", "AxoPi/index.js"):
                member = tarfile.TarInfo(name)
                member.size = 1
                archive.addfile(member, io.BytesIO(b"x"))
            if extra:
                archive.addfile(extra, io.BytesIO(b"x" * extra.size))
        return path

    def test_safe_payload_and_permissions(self):
        destination = self.root / "payload"
        destination.mkdir()
        build_deb.unpack_runtime(self.archive(), destination)
        self.assertEqual((destination / "axod").stat().st_mode & 0o777, 0o755)
        self.assertEqual((destination / "AxoPi/index.js").stat().st_mode & 0o777, 0o644)

    def test_paths_links_duplicates_and_extra_files_fail_before_extraction(self):
        for name, kind in [("../escape", tarfile.REGTYPE), ("/absolute", tarfile.REGTYPE),
                           ("axod", tarfile.REGTYPE), ("AxoPi/link.js", tarfile.SYMTYPE),
                           ("axo.db", tarfile.REGTYPE)]:
            with self.subTest(name=name):
                member = tarfile.TarInfo(name)
                member.type = kind
                member.linkname = "/etc/passwd" if kind == tarfile.SYMTYPE else ""
                destination = self.root / "rejected"
                with self.assertRaises(ValueError):
                    build_deb.unpack_runtime(self.archive(member), destination)
                self.assertFalse(destination.exists())

    def test_tree_is_headless_user_service_only_and_normalizes_umask(self):
        import os
        payload = self.root / "payload"
        payload.mkdir()
        for name in build_deb.BINARIES:
            (payload / name).write_bytes(b"owned executable fixture")
        (payload / "AxoPi").mkdir()
        (payload / "AxoPi/index.js").write_text("// owned fixture\n")
        root = self.root / "package"
        previous = os.umask(0o077)
        try:
            build_deb.assemble_tree(payload, root, "0.86.0-102", {"release_eligible": False})
            build_deb.write_control(root, "0.86.0-102", "libc6")
        finally:
            os.umask(previous)
        self.assertEqual({path.name for path in (root / "DEBIAN").iterdir()}, {"control"})
        self.assertEqual((root / "usr/bin/axo").readlink(), Path("../lib/axo/axo"))
        self.assertEqual((root / "usr/lib/axo/axo").stat().st_mode & 0o777, 0o755)
        self.assertEqual((root / "usr/lib/systemd/user").stat().st_mode & 0o777, 0o755)
        unit = (root / "usr/lib/systemd/user/axod.service").read_text()
        self.assertIn("--server-dir %h/.axo/server", unit)
        self.assertNotIn("User=root", unit)
        self.assertFalse((root / "home").exists())
        self.assertFalse((root / "etc/systemd/system").exists())

    def source(self):
        guard = self.root / "crates/axo-relay/src/sync/uploader.rs"
        guard.parent.mkdir(parents=True, exist_ok=True)
        guard.write_text("const AUTOMATIC_TRANSCRIPT_EVICTION: bool = false;\n")
        return self.root

    def git(self, dirty=False, integrated=True, primary=True, guard_ancestor=True):
        def output(*arguments, cwd=None):
            command = arguments[3:]
            if command[:1] == ("merge-base",) and not guard_ancestor:
                raise ValueError("missing retention ancestor")
            if command == ("rev-parse", "HEAD"): return "tip"
            if command == ("rev-parse", "origin/main"): return "tip" if integrated else "older"
            if command == ("status", "--porcelain"): return " M file" if dirty else ""
            if command == ("rev-parse", "--git-dir"): return ".git" if primary else "worktree"
            if command == ("rev-parse", "--git-common-dir"): return ".git"
            if command == ("branch", "--show-current"): return "main"
            return ""
        return output

    def test_release_requires_clean_integrated_primary_source(self):
        source = self.source()
        for flags in ({"dirty": True}, {"integrated": False}, {"primary": False}):
            with self.subTest(flags=flags), patch.object(build_deb, "run", side_effect=self.git(**flags)):
                with self.assertRaises(ValueError): build_deb.source_provenance(source, False)
                self.assertFalse(build_deb.source_provenance(source, True)["release_eligible"])
        with patch.object(build_deb, "run", side_effect=self.git()):
            self.assertTrue(build_deb.source_provenance(source, False)["release_eligible"])
            self.assertFalse(build_deb.source_provenance(source, True)["release_eligible"])

    def test_candidate_cannot_bypass_retention_guard(self):
        source = self.source()
        with patch.object(build_deb, "run", side_effect=self.git(guard_ancestor=False)):
            with self.assertRaises(ValueError): build_deb.source_provenance(source, True)
        (source / "crates/axo-relay/src/sync/uploader.rs").write_text("const AUTOMATIC_TRANSCRIPT_EVICTION: bool = true;\n")
        with patch.object(build_deb, "run", side_effect=self.git()):
            with self.assertRaises(ValueError): build_deb.source_provenance(source, True)


if __name__ == "__main__":
    unittest.main()
