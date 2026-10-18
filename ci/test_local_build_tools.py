"""Execute bootstrap against fake host tools; never install software in tests."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
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

    def test_profiles_export_cold_cross_tool_paths_and_preserve_madeira_host_compilers(self):
        self.install_except()
        targets = ("aarch64", "arm64ec", "x86_64", "i686")
        paths = {madeira: self.root / runtime / "toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin"
                 for madeira, runtime in ((False, "testrepos/Madeira"), (True, "vendor/Madeira"))}
        prepared = {}
        for madeira, directory in paths.items():
            with self.subTest(madeira=madeira):
                self.assertFalse(directory.exists())
                env = tools.prepare_environment(self.root, environ=self.env, madeira=madeira)
                prepared[madeira] = env
                self.assertIn(str(directory), env["PATH"].split(os.pathsep))
                self.assertNotIn(str(paths[not madeira]), env["PATH"].split(os.pathsep))
                self.assertIsNone(tools.shutil.which("aarch64-w64-mingw32-clang", path=env["PATH"]))

        # Downloads happen after preparation. Both trees may already exist on
        # a developer's machine, so check the selected profile wins explicitly.
        for directory in paths.values():
            for command in ("clang", "clang++", *(target + "-w64-mingw32-clang" for target in targets)):
                self.stub(command, "print('cross compiler fixture')\n", directory / command)
        for madeira, env in prepared.items():
            for target in targets:
                command = target + "-w64-mingw32-clang"
                self.assertEqual(tools.shutil.which(command, path=env["PATH"]), str(paths[madeira] / command))
        for command in ("clang", "clang++"):
            self.assertEqual(tools.shutil.which(command, path=prepared[True]["PATH"]),
                             str(self.prefix / "opt/llvm/bin" / command))
        self.assertEqual(self.env["PATH"], str(self.bin))

    def test_actions_handoff_preserves_prepared_tools_over_system_shadows(self):
        self.install_except()
        system = self.root / "system bin"
        for command, version in (("bison", "bison (GNU Bison) 2.3"), ("python3", "Python 3.9.6")):
            self.stub(command, "print(" + repr(version) + ")\n", system / command)
        self.env["PATH"] = os.pathsep.join((str(system), str(self.bin)))
        self.stub("bison", "print('bison (GNU Bison) 3.8.2')\n", self.prefix / "opt/bison/bin/bison")
        self.stub("python3", '''import os, sys
if sys.argv[1:] == ["--version"]:
    print("Python 3.11.0")
else:
    os.execv(sys.executable, [sys.executable, *sys.argv[1:]])
''')
        prepared = tools.prepare_environment(self.root, environ=self.env, madeira=True)
        output = self.root / ".build/madeira-build-tools.env"
        with mock.patch.object(sys, "argv", ["local_build_tools.py", "--madeira", "--write-env", str(output)]), \
                mock.patch.object(tools, "prepare_environment", return_value=prepared):
            tools.main()

        workflow = (ROOT / ".github/workflows/build-unsigned-ipa.yml").read_text()
        handoff = workflow.split("          source .build/madeira-build-tools.env\n", 1)[1]
        handoff = "source .build/madeira-build-tools.env\n" + textwrap.dedent(
            handoff.split("          python3 ci/madeira-frontend.py toolchains\n", 1)[0])
        verify = workflow.split("      - name: Verify inherited build tools\n        run: |\n", 1)[1]
        verify = textwrap.dedent(verify.split("      - name:", 1)[0])
        github_env = self.root / "github-env"
        github_path = self.root / "github-path"
        runner_env = dict(self.env, GITHUB_ENV=str(github_env), GITHUB_PATH=str(github_path))
        bash = tools.shutil.which("bash")
        subprocess.run([bash, "-e", "-o", "pipefail", "-c", handoff], cwd=self.root, env=runner_env, check=True)

        # The toolchain download follows the environment handoff in this step.
        cross = self.root / "vendor/Madeira/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin"
        targets = tuple(target + "-w64-mingw32-clang" for target in ("aarch64", "arm64ec", "x86_64", "i686"))
        for command in targets + ("clang", "clang++"):
            self.stub(command, "print(" + repr(command + " fixture") + ")\n", cross / command)

        # Match actions/runner's AddPathFileCommand and Handler: remove duplicate
        # entries, append each line, then reverse the list before prepending it.
        # https://github.com/actions/runner/blob/main/src/Runner.Worker/Handlers/Handler.cs
        prepend = []
        for line in github_path.read_text().splitlines():
            if line:
                prepend = [path for path in prepend if path != line] + [line]
        inherited = dict(self.env)
        inherited.update(line.split("=", 1) for line in github_env.read_text().splitlines())
        inherited["PATH"] = os.pathsep.join([*reversed(prepend), self.env["PATH"]])
        self.assertEqual(inherited["PATH"].split(os.pathsep)[:len(prepend)], prepared["PATH"].split(os.pathsep))
        self.assertEqual(inherited["DEVELOPER_DIR"], prepared["DEVELOPER_DIR"])
        result = subprocess.run([bash, "-e", "-o", "pipefail", "-c", verify], cwd=self.root,
                                env=inherited, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["bison (GNU Bison) 3.8.2", "Python 3.11.0",
                         "test version 1", "test version 1", *(command + " fixture" for command in targets)])

        # The subsequent-step check must reject shadows without silently
        # repairing the environment and allowing later compilation to fail.
        for command in ("bison", "python3", "clang", "clang++", *targets):
            shadow = self.root / (command + " shadow")
            self.stub(command, "print('old system tool')\n", shadow / command)
            bad = dict(inherited, PATH=str(shadow) + os.pathsep + inherited["PATH"])
            result = subprocess.run([bash, "-e", "-o", "pipefail", "-c", verify], cwd=self.root,
                                    env=bad, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Prepared build tool was shadowed: " + command, result.stdout)
        (cross / targets[0]).unlink()
        result = subprocess.run([bash, "-e", "-o", "pipefail", "-c", verify], cwd=self.root,
                                env=inherited, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)

    def test_pinned_steam_sdk_is_checked_before_installing_or_compiling(self):
        steam = self.root / "iridium/packages/steam"
        steam.mkdir(parents=True)
        (steam / "global.json").write_text(json.dumps({"sdk": {"version": "10.0.401"}}))
        sdk = self.root / ".build/dotnet/dotnet"
        for version in (None, "10.0.400", "10.0.401"):
            with self.subTest(version=version):
                if version is not None:
                    self.stub("dotnet", "from pathlib import Path\nassert Path.cwd().resolve() == Path(" + repr(str(steam)) + ").resolve()"
                              + "\nprint(" + repr(version) + ")\n", sdk)
                if version == "10.0.401":
                    self.install_except()
                    env = tools.prepare_environment(self.root, environ=self.env)
                    self.assertEqual(tools.shutil.which("dotnet", path=env["PATH"]), str(sdk))
                else:
                    with self.assertRaisesRegex(RuntimeError, "Steam requires .NET SDK 10.0.401"):
                        tools.prepare_environment(self.root, environ=self.env)
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

    def test_llvm_does_not_require_the_separate_lld_formula(self):
        # Homebrew LLVM no longer contains ld.lld. Cross-linkers are supplied by
        # the separately pinned LLVM-MinGW toolchain used by the native recipe.
        self.assertNotIn("ld.lld", tools.FORMULAE["llvm"])

    def test_setup_runs_before_runtime_refresh_or_xcode(self):
        script = (ROOT / "ci/build-local-ipa.sh").read_text()
        self.assertLess(script.index("python3 ci/local_build_tools.py"), script.index("python3 ci/prepare-local-runtime.py"))
        self.assertLess(script.index("source .build/local-build-tools.env"), script.index("python3 ci/prepare-local-runtime.py"))
        subprocess.run(["bash", "-n", str(ROOT / "ci/build-local-ipa.sh")], check=True)


if __name__ == "__main__":
    unittest.main()
