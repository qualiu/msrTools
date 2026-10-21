"""Exercise ConEmu setup against synthetic XML, never installed settings."""

import os
import ctypes
from ctypes import wintypes
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import uuid
import xml.etree.ElementTree as ET
if os.name == "nt":
    import winreg


SETUP = Path(__file__).resolve().parents[1] / "Setup-ConEmu-VisualStudio.ps1"
PWSH = shutil.which("pwsh")
MSR = shutil.which("msr")


@unittest.skipUnless(os.name == "nt" and PWSH and MSR, "Requires Windows, PowerShell 7 and msr")
class ConEmuSetupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="conemu setup fixture ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.environment = os.environ.copy()
        self.environment["TMP"] = str(self.root / "temporary-configs")
        Path(self.environment["TMP"]).mkdir()

    def config(self, name, existing=False):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        values = '<value name="Unrelated" type="string" data="preserve &amp; keep"/>\n'
        if existing:
            values += '<value name="FarGotoEditorPath" type="string" data="old-editor.exe &quot;%1&quot;"/>\n'
            values += '<value name="Tabs" type="dword" data="00"/>\n'
        path.write_text('<key name="Software"><key name="ConEmu"><key name=".Vanilla">\n' + values + '</key></key></key>\n', encoding="utf-8")
        return path

    def invoke(self, paths, script=SETUP, file_extension=None, prog_id=None):
        command = [PWSH, "-NoProfile", "-File", str(script), "-ConEmuConfigPaths", ",".join(str(path) for path in paths)]
        command += ["-FileExtensions", file_extension] if file_extension else ["-SkipFileAssociations"]
        if prog_id:
            command += ["-DefaultFileProgId", prog_id]
        result = subprocess.run(command,
                                env=self.environment, capture_output=True, text=True, encoding="utf-8", timeout=30,
                                creationflags=subprocess.CREATE_NO_WINDOW)
        return result

    def assert_config(self, path, tabs):
        values = {node.attrib["name"]: node.attrib["data"] for node in ET.parse(path).iter("value")}
        self.assertEqual(values["Unrelated"], "preserve & keep")
        self.assertEqual(values["Tabs"], tabs)
        self.assertIn("Open-ClickedPathRow-in-VisualStudio.ps1", values["FarGotoEditorPath"])
        self.assertIn('"%1" "%2" "%3"', values["FarGotoEditorPath"])

    def test_add_update_and_repeat_preserve_unrelated_values(self):
        added = self.config("normal settings/ConEmu.xml")
        updated = self.config("other settings/ConEmu.xml", existing=True)
        for _ in range(2):
            result = self.invoke([added, updated])
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertNotIn("ERROR", result.stderr)
            self.assert_config(added, "01")
            self.assert_config(updated, "01")

    def test_temporary_config_auto_shows_tabs(self):
        path = self.config("temporary-configs/ConFixture.xml", existing=True)
        result = self.invoke([path])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("ERROR", result.stderr)
        self.assert_config(path, "02")

    def test_native_write_failure_is_not_reported_as_success(self):
        path = self.config("normal settings/ConEmu.xml", existing=True)
        before = path.read_bytes()
        harness = self.root / "fail-write.ps1"
        harness.write_text('''param([string] $ConEmuConfigPaths, [switch] $SkipFileAssociations)
function msr {
    if ($args -contains '-R') {
        $global:LASTEXITCODE = -1
        return
    }
    & $env:CONEMU_TEST_MSR @args
    $global:LASTEXITCODE = $LASTEXITCODE
}
& $env:CONEMU_TEST_SETUP -ConEmuConfigPaths $ConEmuConfigPaths -SkipFileAssociations:$SkipFileAssociations
exit $LASTEXITCODE
''', encoding="utf-8")
        self.environment.update(CONEMU_TEST_MSR=MSR, CONEMU_TEST_SETUP=str(SETUP))
        result = self.invoke([path], script=harness)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(path.read_bytes(), before)

    def test_setup_prepares_an_effective_edge_association(self):
        extension = ".msrtools-conemu-" + uuid.uuid4().hex
        key_path = r"Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts" + "\\" + extension
        path = self.config("normal settings/ConEmu.xml")
        try:
            result = self.invoke([path], file_extension=extension)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assert_config(path, "01")
            query = ctypes.WinDLL("shlwapi", use_last_error=True).AssocQueryStringW
            query.argtypes = [wintypes.DWORD, wintypes.DWORD, wintypes.LPCWSTR, wintypes.LPCWSTR, wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD)]
            query.restype = ctypes.c_long
            length = wintypes.DWORD(32768)
            output = ctypes.create_unicode_buffer(length.value)
            self.assertEqual(query(0, 20, extension, None, output, ctypes.byref(length)), 0)
            self.assertEqual(output.value, "MSEdgeHTM")
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Microsoft\Windows\CurrentVersion\ApplicationAssociationToasts") as key:
                self.assertEqual(winreg.QueryValueEx(key, "MSEdgeHTM_" + extension), (0, winreg.REG_DWORD))
        finally:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Microsoft\Windows\CurrentVersion\ApplicationAssociationToasts", 0, winreg.KEY_SET_VALUE) as key:
                try:
                    winreg.DeleteValue(key, "MSEdgeHTM_" + extension)
                except FileNotFoundError:
                    pass
            try:
                winreg.DeleteKey(winreg.HKEY_CURRENT_USER, key_path + r"\UserChoice")
            except FileNotFoundError:
                pass

            try:
                with winreg.OpenKey(winreg.HKEY_CURRENT_USER, key_path) as key:
                    subkeys, values, _ = winreg.QueryInfoKey(key)
                    self.assertEqual((subkeys, values), (0, 0), "Preserve unexpected data in the synthetic test key")
                winreg.DeleteKey(winreg.HKEY_CURRENT_USER, key_path)
            except FileNotFoundError:
                pass

    def test_missing_application_does_not_change_conemu_settings(self):
        path = self.config("normal settings/ConEmu.xml", existing=True)
        before = path.read_bytes()
        result = self.invoke([path], file_extension=".msrtools-conemu-" + uuid.uuid4().hex, prog_id="msrTools.Missing." + uuid.uuid4().hex)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("does not define an open command", result.stderr)
        self.assertEqual(path.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
