import importlib.util
from pathlib import Path
import plistlib
import re
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]

def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "ci" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

dispatch = load("dispatch_build", "dispatch-build.py")

packager = load("unsigned_packager", "package-unsigned-ipa.py")
prerequisites = load("ipa_prerequisites", "check-ipa-prerequisites.py")

class ManualBuildTests(unittest.TestCase):
    def test_manual_trigger_and_no_signing_secrets(self):
        text = (ROOT / ".github/workflows/build-unsigned-ipa.yml").read_text()
        trigger = text.split('"on":\n', 1)[1].split('permissions:', 1)[0]
        self.assertEqual(re.findall(r'^  ([a-z_]+):', trigger, re.M), ['workflow_dispatch'])
        self.assertNotIn("secrets.", text)
        self.assertNotIn("allowProvisioningUpdates", text)
        self.assertIn("CODE_SIGNING_ALLOWED=NO", text)
        self.assertLess(text.index("ci/check-ipa-prerequisites.py"), text.index("xcodebuild -project"))

    def test_dispatch_checks_and_cancels_only_its_own_run(self):
        import json
        expected = "a" * 40
        for actual in (expected, "b" * 40):
            run = {"id": 123, "display_title": "build · token", "head_sha": actual,
                   "html_url": "https://github.com/intraducine/iridium/actions/runs/123"}
            unrelated = dict(run, id=456, display_title="build · other")
            with patch.object(dispatch.uuid, "uuid4") as token, patch.object(dispatch, "gh") as gh:
                token.return_value.hex = "token"
                gh.side_effect = ["", json.dumps({"workflow_runs": [unrelated, run]}), ""]
                if actual == expected:
                    self.assertEqual(dispatch.dispatch("main", expected), run["html_url"])
                    self.assertEqual(gh.call_count, 2)
                else:
                    with self.assertRaises(ValueError):
                        dispatch.dispatch("main", expected)
                    self.assertEqual(gh.call_args.args[-1], "repos/intraducine/iridium/actions/runs/123/cancel")
        for invalid in ("", "a" * 7, "z" * 40):
            with self.assertRaises(ValueError):
                dispatch.check_commit(invalid, invalid)
        workflow = (ROOT / ".github/workflows/build-unsigned-ipa.yml").read_text()
        self.assertLess(workflow.index("ci/dispatch-build.py --check"), workflow.index("ci/reuse-build-assets.py"))

    def test_pinned_graphics_tools_bootstrap_before_sync(self):
        script = (ROOT / "ci/prepare-graphics.sh").read_text()
        self.assertLess(script.index('export DEPOT_TOOLS_UPDATE=0'), script.index('"$DEPOT/ensure_bootstrap"'))
        self.assertLess(script.index('"$DEPOT/ensure_bootstrap"'), script.index('"$DEPOT/python-bin/python3" --version'))
        self.assertLess(script.index('"$DEPOT/python-bin/python3" --version'), script.index('gclient sync'))

    def test_graphics_sdk_warning_patch_and_other_errors(self):
        import shutil
        import subprocess
        import sys
        script = (ROOT / "ci/prepare-graphics.sh").read_text()
        patch_code = script.split("python3 - <<'PATCH'\n", 1)[1].split("\nPATCH", 1)[0]
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "build/config/compiler/BUILD.gn"
            target.parent.mkdir(parents=True)
            target.write_text('config("compiler") {\n  cflags = []\n  cflags_cc = []\n}\n')
            header = Path(tmp) / "third_party/libc++/src/include/__random/clamp_to_integral.h"
            header.parent.mkdir(parents=True)
            header.write_text('::nextafter(static_cast<_RealT>(__max_val), INFINITY)')
            subprocess.run([sys.executable, "-c", patch_code], cwd=tmp, check=True)
            self.assertIn('numeric_limits<float>::infinity()', header.read_text())
            self.assertNotIn('INFINITY', header.read_text())
            self.assertIn('if (is_ios)', target.read_text())
            self.assertIn('cflags += [ "-Wno-error=unknown-attributes" ]', target.read_text())
            compiler = shutil.which("clang")
            if compiler:
                args = [compiler, "-x", "c", "-fsyntax-only", "-Wall", "-Werror", "-Wno-error=unknown-attributes", "-"]
                result = subprocess.run(args, input='__attribute__((iridium_unknown_test_attribute)) void f(void);', text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("unknown attribute", result.stderr)
                result = subprocess.run(args, input='int f(void) { int unused; return 0; }', text=True, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
        self.assertLess(script.index("\nPATCH\n"), script.index('collect-release-source.py'))

    def test_missing_runtime_and_license_records_block_build(self):
        with tempfile.TemporaryDirectory() as tmp:
            findings = prerequisites.blockers(Path(tmp))
            self.assertTrue(any("runtime" in item for item in findings))
            self.assertTrue(any("StikJIT" in item for item in findings))
            root = Path(tmp)
            for paths in prerequisites.REQUIRED.values():
                for path in paths:
                    target = root / path
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(b"fixture")
            record = root / "ci/binary-release-blockers.json"
            record.parent.mkdir(parents=True)
            record.write_text('["unresolved source"]')
            self.assertEqual(prerequisites.blockers(root), ["Source/license audit: unresolved source"])
            record.write_text('{}')
            self.assertTrue(prerequisites.blockers(root))

    def test_reject_signing_files_keys_and_external_symlinks(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "Iridium.app"
            app.mkdir()
            (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "software.iridium", "CFBundleExecutable": "Iridium"}))
            (app / "Iridium").write_bytes(bytes.fromhex("cffaedfe") + b"fixture")
            helper = app / "PlugIns/Helper.appex"
            helper.mkdir(parents=True)
            (helper / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "Helper"}))
            (helper / "Helper").write_bytes(bytes.fromhex("cffaedfe") + b"fixture")
            packager.check_payload(app)
            with self.assertRaises(ValueError):
                packager.executable_path(app, {"CFBundleExecutable": "../outside"})
            with self.assertRaises(ValueError):
                packager.package(app, app / "output")
            for filename, data in [("certificate.p12", b"fixture"), ("embedded.mobileprovision", b"fixture"), ("private.txt", b"-----BEGIN " + b"PRIVATE KEY-----")]:
                file = app / filename
                file.write_bytes(data)
                with self.assertRaises(ValueError):
                    packager.check_payload(app)
                file.unlink()
            (app / "outside").symlink_to(Path(tmp))
            with self.assertRaises(ValueError):
                packager.check_payload(app)

if __name__ == "__main__":
    unittest.main()
