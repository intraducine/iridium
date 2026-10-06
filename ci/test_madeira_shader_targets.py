"""Run the embedded shader recipe with tool stubs; no Apple SDK is needed."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MADEIRA = ROOT / "testrepos/Madeira"


class MadeiraShaderTargetTests(unittest.TestCase):
    def test_command_library_pins_language_air_and_invalidates_old_header(self):
        source = (MADEIRA / "build/dxmt-ios/build.sh").read_text()
        start = source.index('if [ ! -f "$BUILD_DIR/shader-headers/dxmt_command.h" ]')
        end = source.index('echo "=== MADEIRA: dxmt_madeira_native -- util', start)
        recipe = source[start:end]
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            tools = folder / "tools"
            tools.mkdir()
            metal = folder / "source/dxmt/dxmt_command.metal"
            metal.parent.mkdir(parents=True)
            metal.write_text("fixture shader\n")
            build = folder / "build"
            build.mkdir()
            script = build / "build.sh"
            script.write_text("#!/bin/bash\nset -eu\n" + recipe)
            log = folder / "calls"
            (tools / "xcrun").write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ["SHADER_TEST_LOG"], "a") as output:
    output.write(json.dumps(args) + "\\n")
pathlib.Path(args[args.index("-o") + 1]).write_text("fixture\\n")
''')
            (tools / "xxd").write_text('''#!/usr/bin/env python3
import pathlib, sys
pathlib.Path(sys.argv[-1]).write_text("fixture header\\n")
''')
            for tool in tools.iterdir():
                tool.chmod(0o755)
            env = dict(os.environ)
            env["DXMT_METAL_STD"] = "metal4.1"  # native pin is fixed, not an environment override
            env.update(PATH=str(tools) + os.pathsep + env["PATH"], BUILD_DIR=str(build),
                       DXMT_SRC=str(folder / "source"), SHADER_TEST_LOG=str(log))
            def run():
                return subprocess.run(["bash", str(script)], env=env, check=True,
                                      capture_output=True, text=True, timeout=10)
            self.assertIn("OK", run().stdout)
            calls = log.read_text()
            self.assertIn('"iphoneos", "metal", "-std=metal3.1", "--target=air64-apple-ios18.0"', calls)
            self.assertIn('"iphoneos", "metallib"', calls)
            self.assertNotIn("metal4.1", calls)
            self.assertIn("CACHED", run().stdout)
            self.assertEqual(calls, log.read_text())
            header = build / "shader-headers/dxmt_command.h"
            fresh = header.stat().st_mtime_ns + 1_000_000_000
            os.utime(script, ns=(fresh, fresh))
            self.assertIn("OK", run().stdout)
            self.assertEqual(log.read_text().count('"metal"'), 2)

    def test_pe_pins_and_existing_native_ios_targets_are_preserved(self):
        meson = (MADEIRA / "research/dxmt/meson.build").read_text()
        options = (MADEIRA / "research/dxmt/meson.options").read_text()
        self.assertIn("metal_std = get_option('metal_std')", meson)
        self.assertIn("'-std=' + metal_std, '--target=air64-apple-macos14.0'", meson)
        self.assertIn("option('metal_std', type : 'string', value : 'metal3.1')", options)
        native = (ROOT / "ci/prepare-native-runtime.sh").read_text()
        self.assertIn("xcrun --sdk iphoneos metal -std=metal3.1 --target=air64-apple-ios18.0", native)


if __name__ == "__main__":
    unittest.main()
