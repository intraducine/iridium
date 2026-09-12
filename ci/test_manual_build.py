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
graphics = load("verify_graphics", "verify-graphics.py")

stik_interface = load("stik_interface", "prepare-stikjit-interface.py")
app_audit = load("app_audit", "collect-app-link-audit.py")

packager = load("unsigned_packager", "package-unsigned-ipa.py")
prerequisites = load("ipa_prerequisites", "check-ipa-prerequisites.py")

class ManualBuildTests(unittest.TestCase):
    def test_final_audit_blocks_packaging_but_not_audit_build(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'ci').mkdir()
            (root / 'ci/binary-release-blockers.json').write_text('[]')
            final = root / 'ci/binary-package-blockers.json'
            final.write_text('["Final binary review pending"]')
            with patch.object(prerequisites, 'REQUIRED', {}):
                self.assertEqual(prerequisites.blockers(root), [])
                self.assertTrue(prerequisites.blockers(root, package=True))
                final.unlink()
                self.assertTrue(prerequisites.blockers(root, package=True))
        workflow = (ROOT / '.github/workflows/build-unsigned-ipa.yml').read_text()
        self.assertLess(workflow.index('xcodebuild -project'), workflow.index('check-ipa-prerequisites.py --package'))
        self.assertLess(workflow.index('check-ipa-prerequisites.py --package'), workflow.index('ci/package-unsigned-ipa.py'))

    def test_app_inventory_hashes_native_files_and_propagates_tool_failure(self):
        import hashlib
        import subprocess
        with tempfile.TemporaryDirectory() as temp:
            app = Path(temp)
            data = bytes.fromhex('cffaedfe') + b'native fixture'
            (app / 'Iridium').write_bytes(data)
            (app / 'resource.txt').write_text('resource')
            with patch.object(app_audit.packager, 'check_payload'), patch.object(app_audit.subprocess, 'check_output') as tool:
                tool.return_value = str(app / 'Iridium') + ':\n\t/usr/lib/libSystem.B.dylib\n'
                record, = app_audit.inventory(app)
                self.assertEqual(record['sha256'], hashlib.sha256(data).hexdigest())
                self.assertEqual(record['path'], 'Iridium')
                self.assertEqual(record['linked_libraries'], ['\t/usr/lib/libSystem.B.dylib'])
                tool.side_effect = subprocess.CalledProcessError(1, 'otool')
                with self.assertRaises(subprocess.CalledProcessError):
                    app_audit.inventory(app)

    def test_lgpl_patch_rejects_unexpected_source(self):
        relink = load('lgpl_relink', 'check-lgpl-relink.py')
        with self.assertRaises(ValueError):
            relink.modify('different source')
        signature = 'mpn_add_n (mp_ptr rp, mp_srcptr up, mp_srcptr vp, mp_size_t n)\n{'
        patched = relink.modify(signature + '\n}\n' + signature + '\n}')
        self.assertEqual(patched.count(relink.MARKER), 2)
        self.assertEqual(patched.count('(void) proof[0];'), 2)

    def test_inventory_includes_windows_linux_and_dos(self):
        with tempfile.TemporaryDirectory() as temp:
            app = Path(temp)
            (app / 'linux.so').write_bytes(b'\x7fELF' + bytes(64))
            pe = b'MZ' + bytes(58) + (64).to_bytes(4, 'little') + b'PE\0\0'
            binary = app / 'windows.dll'
            binary.write_bytes(pe)
            with patch.object(app_audit.packager, 'check_payload'), patch.object(app_audit.subprocess, 'check_output') as tool:
                records = app_audit.inventory(app)
                self.assertEqual([r['format'] for r in records], ['ELF', 'PE'])
                self.assertTrue(all(r['linked_libraries'] is None for r in records))
                tool.assert_not_called()
                binary.write_bytes(pe[:-1])
                self.assertEqual(app_audit.inventory(app)[1]['format'], 'DOS')

    def test_public_fixture_exception_requires_exact_bytes(self):
        import hashlib
        import json
        data = bytes.fromhex("7f454c46") + b"-----BEGIN " + b"PRIVATE KEY-----\nfixture"
        with tempfile.TemporaryDirectory() as temp:
            app = Path(temp)
            binary = app / "library.so"
            binary.write_bytes(data)
            original = Path.read_text
            def read(path, *args, **kwargs):
                if path.name == "public-key-fixture-binaries.json":
                    return json.dumps([{"sha256": hashlib.sha256(data).hexdigest()}])
                return original(path, *args, **kwargs)
            with patch.object(Path, "read_text", read):
                # Passing the key scan reaches the required app metadata check.
                with self.assertRaises(FileNotFoundError):
                    packager.check_payload(app)
                binary.write_bytes(data + b"changed")
                with self.assertRaisesRegex(ValueError, "unreviewed private key"):
                    packager.check_payload(app)

    def test_stik_interface_repairs_nested_selector_without_changing_binary(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with self.assertRaises(ValueError):
                stik_interface.repair(root)
            binary = root / 'StikJIT'
            binary.write_bytes(b'unchanged')
            interface = root / 'arm64-apple-ios.swiftinterface'
            interface.write_text('StikJIT::StikJIT::Configuration StikJIT::DDIPaths Swift.String')
            stik_interface.repair(root)
            self.assertEqual(interface.read_text(), 'StikJIT::StikJIT.Configuration StikJIT::DDIPaths Swift.String')
            stik_interface.repair(root)
            self.assertEqual(binary.read_bytes(), b'unchanged')

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

    def test_graphics_plan_rejects_mixed_tools_backends_and_targets(self):
        root = Path("/tmp/graphics-test")
        clang = root / "xcode/bin/clang"
        command = f"{clang}++ -target arm64-apple-ios18.0 -Wall -c source.cpp -o source.o"
        graphics.check_plan(command, root, clang)
        for bad in ("", command.replace("xcode", "old-compiler"),
                    command.replace("arm64-apple-ios18.0", "arm64-apple-ios18.0-simulator"),
                    command.replace("source.cpp", "third_party/dawn/file.cpp"),
                    command.replace("-Wall", "-w"),
                    command + " -Ithird_party/libc++/src/include"):
            with self.assertRaises(ValueError):
                graphics.check_plan(bad, root, clang)

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
