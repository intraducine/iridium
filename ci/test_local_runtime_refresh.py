import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class LocalRuntimeRefreshTests(unittest.TestCase):
    def test_local_ipa_refreshes_runtime_before_packaging(self):
        build = (ROOT / "ci/build-local-ipa.sh").read_text()
        refresh = build.index("python3 ci/prepare-local-runtime.py")
        provenance = build.index("python3 ci/check-local-runtime-provenance.py")
        xcode = build.index("xcodebuild -project")
        self.assertLess(refresh, provenance)
        self.assertLess(provenance, xcode)
        self.assertIn('rm -rf "$runtime_resources/iridium-runtime-base"', build)

    def test_refresh_uses_incremental_native_build_stages(self):
        source = (ROOT / "ci/prepare-local-runtime.py").read_text()
        for command in (
            'run("bash", "ci/prepare-runtime-inputs.sh")',
            'run("bash", "ci/prepare-native-runtime.sh")',
            'run("bash", "ci/compile-wine.sh")',
            'run("bash", "ci/compile-windows-modules.sh")',
            'run("bash", "ci/prepare-windows-runtime.sh")',
        ):
            self.assertIn(command, source)
        self.assertIn("Local native runtime unchanged; reusing", source)
        self.assertIn("build_runtime_bundle.sh", source)
        self.assertIn("wine-userland.tar.zst", source)

    def test_cross_platform_inputs_never_silently_mix(self):
        source = (ROOT / "ci/prepare-local-runtime.py").read_text()
        self.assertIn("reuse.MEDIA_INPUTS", source)
        self.assertIn("reuse.PREFIX_INPUTS", source)
        self.assertIn("reuse.linux.INPUTS", source)
        self.assertIn("Run python3 ci/dispatch-build.py", source)


if __name__ == "__main__":
    unittest.main()
