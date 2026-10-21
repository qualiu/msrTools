"""Exercise ConEmu setup against synthetic XML, never installed settings."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET


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

    def invoke(self, paths, script=SETUP):
        result = subprocess.run([PWSH, "-NoProfile", "-File", str(script), "-ConEmuConfigPaths", ",".join(str(path) for path in paths)],
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
        harness.write_text('''param([string] $ConEmuConfigPaths)
function msr {
    if ($args -contains '-R') {
        $global:LASTEXITCODE = -1
        return
    }
    & $env:CONEMU_TEST_MSR @args
    $global:LASTEXITCODE = $LASTEXITCODE
}
& $env:CONEMU_TEST_SETUP -ConEmuConfigPaths $ConEmuConfigPaths
exit $LASTEXITCODE
''', encoding="utf-8")
        self.environment.update(CONEMU_TEST_MSR=MSR, CONEMU_TEST_SETUP=str(SETUP))
        result = self.invoke([path], script=harness)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(path.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
