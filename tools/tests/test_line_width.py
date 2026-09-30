"""Synthetic layout fixtures; no real repository source or credentials are copied."""

from __future__ import annotations

from contextlib import redirect_stderr
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import check_line_width as audit


class WidthTests(unittest.TestCase):
    def test_display_columns_and_boundaries(self):
        for text, expected in [("a" * 200, 200), ("中" * 100, 200), ("a\t中", 6), ("e\u0301", 1), ("Ａ", 2)]:
            with self.subTest(expected=expected, length=len(text)):
                self.assertEqual(audit.display_width(text), expected)
        for source, count in [("x" * 200, 0), ("x" * 201, 1), ("中" * 101, 1), ("#" + "x" * 239, 0), ("#" + "x" * 240, 1)]:
            with self.subTest(length=len(source)):
                self.assertEqual(len(audit.check_source("sample.py", source)), count)

    def test_python_text_context_does_not_relax_unrelated_code(self):
        long_text = "x" * 210
        accepted = [f'logger.info("{long_text}")', f'"""{long_text}"""', f'options = (\n    "{long_text}",\n)', f'"""help\n{long_text}\n"""']
        rejected = [f'value = "logger.info {long_text}"', f'x = 1; logger.info("{long_text}")', f'logger.info("{long_text}"); x = 1', f'value = "{long_text}" # comment']
        for source in accepted:
            with self.subTest(category="text", source_length=len(source)):
                self.assertEqual(audit.check_source("sample.py", source), [])
        for source in rejected:
            with self.subTest(category="code", source_length=len(source)):
                self.assertEqual(len(audit.check_source("sample.py", source)), 1)
        self.assertEqual(len(audit.check_source("sample.py", '"""' + "x" * 240 + '"""')), 1)

    def test_shell_comments_and_powershell_help(self):
        for path, source in [
            ("sample.ps1", "<#\n" + "x" * 220 + "\n#>"),
            ("sample.ps1", "$help = @'\n" + "x" * 220 + "\n'@"),
            ("sample.ps1", "Write-Host '" + "x" * 210 + "'"),
            ("sample.sh", "#" + "x" * 220),
            ("sample.cmd", "REM " + "x" * 220),
            ("guide.md", "x" * 240),
        ]:
            with self.subTest(path=path):
                self.assertEqual(audit.check_source(path, source), [])
        self.assertEqual(len(audit.check_source("sample.ps1", "$value = '" + "x" * 210 + "'")), 1)
        self.assertEqual(len(audit.check_source("guide.md", "x" * 241)), 1)

    def test_invalid_python_uses_conservative_code_limit(self):
        source = "def broken(:\n    value = '" + "x" * 210 + "'"
        self.assertEqual(len(audit.check_source("sample.py", source)), 1)

    def test_block_comment_boundaries_do_not_relax_following_code(self):
        self.assertEqual(audit.check_source("sample.cpp", "/* " + "x" * 210 + " */"), [])
        for source in ["*value = " + "x" * 210, "/* note */ value = " + "x" * 210, "/* note\n*/ value = " + "x" * 210]:
            with self.subTest(length=len(source)):
                self.assertEqual(len(audit.check_source("sample.cpp", source)), 1)

    def test_incremental_selection_and_line_endings(self):
        previous = "legacy = '" + "x" * 250 + "'\r\nvalue = 1\r\n"
        current = previous.replace("value = 1", "value = 2")
        self.assertEqual(audit.added_lines(previous, current), {2})
        self.assertEqual(audit.check_source("sample.py", current, {2}), [])
        self.assertEqual(audit.added_lines(previous, previous.replace("\r\n", "\n")), set())

    def test_configuration_rejects_conflicting_limits_without_scanning_arbitrary_strings(self):
        for path, source in [
            (".editorconfig", "max_line_length = 88"),
            ("pyproject.toml", "line-length = 160"),
            (".prettierrc.json", '{"printWidth": 100}'),
            (".vscode/settings.json", '"autopep8.args": ["--max-line-length",\n"160"]'),
            ("sample.py", "# autopep8: --max-line-length=160"),
        ]:
            with self.subTest(path=path):
                violations = audit.check_source(path, source)
                self.assertEqual(len(violations), 1)
                self.assertEqual(violations[0].kind, "configuration")
                self.assertEqual(audit.check_source(path, source, set()), [])
        self.assertEqual(audit.check_source("sample.py", 'example = "--max-line-length=80"'), [])
        self.assertEqual(audit.check_source("pyproject.toml", "# line-length = 80"), [])
        self.assertEqual(audit.check_source(".editorconfig", "max_line_length = 200"), [])
        self.assertEqual(audit.check_source(".prettierrc.json", '{"example": "printWidth=80"}'), [])
        self.assertEqual(audit.check_source(".prettierrc.json", '// "printWidth": 80'), [])
        self.assertEqual(len(audit.check_source(".prettierrc.json", '{"semi": true, "printWidth": 80}')), 1)

    def test_json_comments_are_not_active_configuration(self):
        source = '/* example\n"printWidth": 80\n*/\n{"printWidth": 200, "example": "https://example.invalid/path"}'
        self.assertEqual(audit.check_source(".vscode/settings.json", source), [])
        source = '{"example": "/* text */", "printWidth": 80}'
        self.assertEqual(len(audit.check_source(".vscode/settings.json", source)), 1)
        source = '{"example": "--max-line-length=80", "autopep8.args": ["--max-line-length=200"]}'
        self.assertEqual(audit.check_source(".vscode/settings.json", source), [])

    def test_comment_and_output_syntax_are_language_specific(self):
        for path, prefix in [("sample.c", "#define VALUE "), ("sample.cpp", "echo "), ("sample.sh", "//"), ("sample.java", "REM ")]:
            with self.subTest(path=path, prefix=prefix):
                violations = audit.check_source(path, prefix + "x" * 210)
                self.assertEqual(len(violations), 1)
                self.assertEqual(violations[0].limit, audit.CODE_LIMIT)


class RepositoryFixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="line-layout-fixture-")
        self.root = Path(self.temporary.name).resolve()
        self.environment = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
        self.git("init", "-b", "layout-fixture")
        self.git("config", "user.name", "Layout Fixture")
        self.git("config", "user.email", "layout@example.invalid")
        self.git("config", "core.autocrlf", "false")

    def tearDown(self):
        if not self.root.is_relative_to(Path(tempfile.gettempdir()).resolve()):
            raise AssertionError("Unsafe synthetic fixture cleanup target")
        self.temporary.cleanup()

    def git(self, *arguments, check=True):
        result = subprocess.run(["git", "-C", str(self.root), *arguments], env=self.environment, capture_output=True, check=False)
        if check and result.returncode:
            self.fail(f"Synthetic git {arguments[0]} failed: {result.stderr.decode('utf-8', errors='replace')}")
        return result

    def write(self, name, source):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(source.encode("utf-8"))

    def baseline(self, source="value = 1\n", name="sample.py"):
        self.write(name, source)
        self.git("add", "--", name)
        self.git("commit", "-m", "Add synthetic fixture")

    def run_audit(self, *arguments):
        return subprocess.run(
            [sys.executable, "-B", str(Path(audit.__file__).resolve()), "--repo", str(self.root), *arguments],
            env=self.environment, capture_output=True, check=False,
        )


class GitIndexTests(RepositoryFixture):
    def test_unborn_index_unicode_space_paths_and_crlf(self):
        name = "nested folder/中文 sample.py"
        self.write(name, "value = '" + "x" * 201 + "'\r\n")
        self.git("add", "--", name)
        with mock.patch.dict(os.environ, self.environment):
            violations, count = audit.audit_staged(self.root)
        self.assertEqual(count, 1)
        self.assertEqual(violations[0].path, name)
        self.assertEqual(violations[0].line, 1)

    def test_worktree_is_not_substituted_for_index(self):
        self.baseline()
        self.write("sample.py", "value = '" + "x" * 210 + "'\n")
        self.git("add", "--", "sample.py")
        self.write("sample.py", "value = 2\n")
        self.assertEqual(self.run_audit("--staged").returncode, 1)
        self.git("add", "--", "sample.py")
        self.write("sample.py", "value = '" + "x" * 210 + "'\n")
        self.assertEqual(self.run_audit().returncode, 0)
        self.assertEqual(self.run_audit("sample.py").returncode, 1)

    def test_historical_lines_and_renames_do_not_block(self):
        legacy = "value = '" + "x" * 210 + "'\nnext_value = 1\n"
        self.baseline(legacy)
        self.write("sample.py", legacy.replace("next_value = 1", "next_value = 2"))
        self.git("add", "--", "sample.py")
        self.assertEqual(self.run_audit("--staged").returncode, 0)
        self.assertEqual(self.run_audit("--all").returncode, 1)
        self.git("mv", "sample.py", "renamed sample.py")
        self.assertEqual(self.run_audit("--staged").returncode, 0)

    def test_deletions_and_document_scope(self):
        self.baseline()
        self.git("rm", "sample.py")
        self.write("guide.md", "x" * 300)
        self.git("add", "--", "guide.md")
        self.assertEqual(self.run_audit("--staged").returncode, 0)
        self.assertEqual(self.run_audit("--all").returncode, 0)
        self.assertEqual(self.run_audit("guide.md").returncode, 1)

    def test_decode_errors_and_safe_diagnostics(self):
        self.write("sample.py", "value = 'synthetic-private-marker-" + "x" * 210 + "'\n")
        self.git("add", "--", "sample.py")
        result = self.run_audit()
        self.assertEqual(result.returncode, 1)
        self.assertNotIn(b"synthetic-private-marker", result.stdout + result.stderr)
        (self.root / "sample.py").write_bytes(b"\xff\xfe")
        self.git("add", "--", "sample.py")
        result = self.run_audit()
        self.assertEqual(result.returncode, 2)
        self.assertIn(b"Cannot decode", result.stderr)

    def test_invalid_modes_paths_and_git_errors(self):
        for arguments in [("--all", "sample.py"), ("--staged", "--all"), ("missing.py",), (str(self.root.parent / "outside.py"),)]:
            with self.subTest(arguments=arguments):
                self.assertEqual(self.run_audit(*arguments).returncode, 2)
        with mock.patch.object(audit, "git", side_effect=audit.AuditError("synthetic index read failure")):
            with redirect_stderr(io.StringIO()):
                self.assertEqual(audit.main(["--repo", str(self.root)]), 2)

    def test_staged_configuration_is_enforced(self):
        self.write(".editorconfig", "root = true\n[*.py]\nmax_line_length = 88\n")
        self.git("add", "--", ".editorconfig")
        self.assertEqual(self.run_audit().returncode, 1)
        self.write(".editorconfig", "root = true\n[*.py]\nmax_line_length = 200\n")
        self.git("add", "--", ".editorconfig")
        self.assertEqual(self.run_audit().returncode, 0)


class ConfigurationTests(unittest.TestCase):
    def test_configuration_and_formatter_hints_match_code_limit(self):
        root = Path(__file__).resolve().parents[2]
        editor = (root / ".editorconfig").read_text(encoding="utf-8")
        settings = (root / ".vscode" / "settings.json").read_text(encoding="utf-8")
        self.assertIn(f"max_line_length = {audit.CODE_LIMIT}", editor)
        self.assertIn(f'"--max-line-length={audit.CODE_LIMIT}"', settings)
        self.assertIn(f'"{audit.CODE_LIMIT}"', settings)
        for name in ["csv_to_excel.py", "csv_to_json.py", "excel_exporter.py", "json_to_csv.py"]:
            with self.subTest(name=name):
                self.assertIn(f"# autopep8: --max-line-length={audit.CODE_LIMIT}", (root / "office" / name).read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
