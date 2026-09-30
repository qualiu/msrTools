"""Exercise the installed native hook against isolated synthetic Git repositories."""

from __future__ import annotations

import os
from pathlib import Path
import sys
from unittest import mock
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import check_line_width as audit
import install_git_hooks as installer
from test_line_width import RepositoryFixture


class InstallTests(RepositoryFixture):
    def setUp(self):
        super().setUp()
        checker = Path(audit.__file__).resolve()
        self.write("tools/check_line_width.py", f"import runpy\nrunpy.run_path({str(checker)!r}, run_name='__main__')\n")

    def install(self):
        with mock.patch.dict(os.environ, self.environment):
            return installer.install(self.root)

    def test_idempotence_preserves_message_hooks(self):
        hooks = self.root / ".git" / "hooks"
        originals = {}
        for name in ["prepare-commit-msg", "commit-msg"]:
            originals[name] = b"#!/bin/sh\nexit 0\n"
            (hooks / name).write_bytes(originals[name])
        self.assertTrue(self.install())
        self.assertFalse(self.install())
        self.assertEqual((hooks / "pre-commit").read_bytes(), installer.HOOK)
        for name, content in originals.items():
            self.assertEqual((hooks / name).read_bytes(), content)
        if os.name != "nt":
            self.assertNotEqual((hooks / "pre-commit").stat().st_mode & 0o111, 0)

    def test_unknown_precommit_is_preserved(self):
        target = self.root / ".git" / "hooks" / "pre-commit"
        original = b"#!/bin/sh\n# existing guard\nexit 1\n"
        target.write_bytes(original)
        with self.assertRaisesRegex(audit.AuditError, "Unknown existing pre-commit"):
            self.install()
        self.assertEqual(target.read_bytes(), original)
        target.write_bytes(installer.HOOK + b"# another guard\n")
        with self.assertRaisesRegex(audit.AuditError, "Unknown existing pre-commit"):
            self.install()
        self.assertEqual(target.read_bytes(), installer.HOOK + b"# another guard\n")

    def test_linked_routing_is_not_overwritten(self):
        with mock.patch.object(Path, "is_symlink", return_value=True):
            with self.assertRaisesRegex(audit.AuditError, "linked"):
                self.install()
        self.assertFalse((self.root / ".git" / "hooks" / "pre-commit").exists())

    def test_custom_routing_and_missing_checker_fail_closed(self):
        self.git("config", "core.hooksPath", "reviewed-hooks")
        with self.assertRaisesRegex(audit.AuditError, "core.hooksPath"):
            self.install()
        self.assertEqual(self.git("config", "--get", "core.hooksPath").stdout.strip(), b"reviewed-hooks")
        self.git("config", "--unset", "core.hooksPath")
        (self.root / "tools" / "check_line_width.py").unlink()
        with self.assertRaisesRegex(audit.AuditError, "missing"):
            self.install()
        self.assertFalse((self.root / ".git" / "hooks" / "pre-commit").exists())

    def test_native_commit_allows_valid_and_blocks_invalid(self):
        self.install()
        self.write("sample.py", "value = 1\n")
        self.git("add", "--", "sample.py", "tools/check_line_width.py")
        self.git("commit", "-m", "Accept synthetic valid source")
        accepted = self.git("rev-parse", "HEAD").stdout
        self.write("sample.py", "value = '" + "x" * 210 + "'\n")
        self.git("add", "--", "sample.py")
        rejected = self.git("commit", "-m", "Reject synthetic overwide source", check=False)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn(b"exceeds 200", rejected.stderr)
        self.assertEqual(self.git("rev-parse", "HEAD").stdout, accepted)
        self.write("sample.py", "value = 2\n")
        self.git("add", "--", "sample.py")
        self.git("commit", "-m", "Accept corrected synthetic source")


if __name__ == "__main__":
    unittest.main()
