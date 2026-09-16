"""Execute bootstrap against fake host tools; never install software in tests."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("local_build_tools", ROOT / "ci/local_build_tools.py")
tools = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tools)


class LocalBuildToolsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="iridium tools ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.prefix = self.root / "brew prefix"
        self.bin = self.prefix / "bin"
        self.bin.mkdir(parents=True)
        self.calls = self.root / "calls.jsonl"
        self.env = dict(os.environ, PATH=str(self.bin), FAKE_PREFIX=str(self.prefix),
                        FAKE_CALLS=str(self.calls), DEVELOPER_DIR=str(self.root / "Xcode.app/Contents/Developer"))
        self.stub("brew", '''import json, os, pathlib, sys
prefix = pathlib.Path(os.environ["FAKE_PREFIX"])
with open(os.environ["FAKE_CALLS"], "a") as f:
    f.write(json.dumps(sys.argv[1:]) + "\\n")
if sys.argv[1:] == ["--prefix"]:
    print(prefix)
elif sys.argv[1:3] == ["install", "--formula"]:
    if os.environ.get("FAKE_INSTALL_FAILURE"): sys.exit(1)
    for name in sys.argv[3:]:
        for command in json.loads(os.environ["FAKE_FORMULAE"])[name]:
            p = prefix / "opt" / name / "bin" / command
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text("#!" + sys.executable + " -S\\nprint('test version 1')\\n")
            p.chmod(0o755)
else: sys.exit(2)
''')
        self.env["FAKE_FORMULAE"] = json.dumps(tools.FORMULAE)
        for cmd in tools.SYSTEM_TOOLS + ("xcodebuild", "xcrun"):
            self.stub(cmd, "print('test version 1')\n")
        self.addCleanup(mock.patch.stopall)
        mock.patch.object(tools, "validate_host").start()
        mock.patch.object(Path, "home", return_value=self.root / "home").start()

    def stub(self, name, source, path=None):
        path = self.bin / name if path is None else path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!" + sys.executable + " -S\n" + source)
        path.chmod(0o755)
        return path

    def install_except(self, absent=()):
        for name, cmds in tools.FORMULAE.items():
            if name not in absent:
                for cmd in cmds:
                    self.stub(cmd, "print('test version 1')\n", self.prefix / "opt" / name / "bin" / cmd)

    def commands(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()]

    def test_missing_ninja_and_mesons_are_installed_together(self):
        self.install_except({"ninja", "meson", "pkgconf"})
        env = tools.prepare_environment(self.root, environ=self.env)
        installs = [x for x in self.commands() if x[0] == "install"]
        self.assertEqual(installs, [["install", "--formula", "ninja", "pkgconf", "meson"]])
        self.assertTrue(subprocess.run(["ninja", "--version"], env=env, capture_output=True).returncode == 0)

    def test_all_missing_installed_in_one_transaction(self):
        tools.prepare_environment(self.root, environ=self.env)
        self.assertEqual([x for x in self.commands() if x[0] == "install"],
                         [["install", "--formula", *tools.FORMULAE]])

    def test_second_run_does_not_reinstall_or_upgrade(self):
        tools.prepare_environment(self.root, environ=self.env)
        before = len([x for x in self.commands() if x[0] == "install"])
        tools.prepare_environment(self.root, environ=self.env)
        after = len([x for x in self.commands() if x[0] == "install"])
        self.assertEqual((before, after), (1, 1))
        self.assertFalse(any(x[0] in ("upgrade", "reinstall", "cleanup", "update") for x in self.commands()))

    def test_check_mode_reports_every_missing_package_without_installing(self):
        with self.assertRaises(RuntimeError) as caught:
            tools.prepare_environment(self.root, install=False, environ=self.env)
        for formula in tools.FORMULAE:
            self.assertIn(formula, str(caught.exception))
        self.assertFalse(any(x[0] == "install" for x in self.commands()))

    def test_installed_keg_only_tools_are_used_without_global_linking(self):
        self.install_except()
        env = tools.prepare_environment(self.root, environ=self.env)
        self.assertEqual(tools.shutil.which("bison", path=env["PATH"]), str(self.prefix / "opt/bison/bin/bison"))
        self.assertFalse(any(x[0] == "install" for x in self.commands()))

    def test_system_bison_does_not_mask_missing_homebrew_bison(self):
        self.install_except({"bison"})
        self.stub("bison", "print('old Apple bison')\n")
        tools.prepare_environment(self.root, environ=self.env)
        self.assertIn(["install", "--formula", "bison"], self.commands())

    def test_install_failure_stops_setup(self):
        self.env["FAKE_INSTALL_FAILURE"] = "1"
        with self.assertRaisesRegex(RuntimeError, "Homebrew could not install"):
            tools.prepare_environment(self.root, environ=self.env)

    def test_all_system_missing_tools_are_reported_before_install(self):
        (self.bin / "make").unlink()
        (self.bin / "patch").unlink()
        with self.assertRaises(RuntimeError) as caught:
            tools.prepare_environment(self.root, environ=self.env)
        self.assertIn("make", str(caught.exception))
        self.assertIn("patch", str(caught.exception))
        self.assertFalse(any(x[0] == "install" for x in self.commands()))

    def test_bad_xcode_stops_before_package_install(self):
        self.stub("xcrun", "import sys\nprint('iPhoneOS SDK missing', file=sys.stderr)\nsys.exit(1)\n")
        with self.assertRaisesRegex(RuntimeError, "iPhoneOS SDK"):
            tools.prepare_environment(self.root, environ=self.env)
        self.assertFalse(any(x[0] == "install" for x in self.commands()))

    def test_broken_installed_tools_are_reported_together(self):
        self.install_except()
        for cmd in ("ninja", "meson"):
            self.stub(cmd, "import sys\nprint('broken binary', file=sys.stderr)\nsys.exit(1)\n",
                      self.prefix / "opt" / cmd / "bin" / cmd)
        with self.assertRaises(RuntimeError) as caught:
            tools.prepare_environment(self.root, environ=self.env)
        self.assertIn("ninja: broken binary", str(caught.exception))
        self.assertIn("meson: broken binary", str(caught.exception))

    def test_working_metal_does_not_download(self):
        self.install_except()
        self.stub("xcodebuild", '''import os, sys
if sys.argv[1:] != ["-version"]: raise SystemExit('unexpected download')
print('Xcode test')
''')
        tools.prepare_environment(self.root, environ=self.env)

    def test_check_mode_does_not_download_missing_metal(self):
        self.install_except()
        self.stub("xcrun", "import sys\nif 'metal' in sys.argv: sys.exit(1)\nprint('SDK path')\n")
        self.stub("xcodebuild", "import sys\nassert sys.argv[1:] == ['-version']\nprint('Xcode test')\n")
        with self.assertRaisesRegex(RuntimeError, "Metal toolchain is missing"):
            tools.prepare_environment(self.root, install=False, environ=self.env)

    def test_setup_runs_before_runtime_refresh_or_xcode(self):
        script = (ROOT / "ci/build-local-ipa.sh").read_text()
        self.assertLess(script.index("python3 ci/local_build_tools.py"), script.index("python3 ci/prepare-local-runtime.py"))
        self.assertLess(script.index("source .build/local-build-tools.env"), script.index("python3 ci/prepare-local-runtime.py"))
        subprocess.run(["bash", "-n", str(ROOT / "ci/build-local-ipa.sh")], check=True)


if __name__ == "__main__":
    unittest.main()
