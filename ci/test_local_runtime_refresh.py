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
            'run("python3", "ci/prepare-local-runtime-inputs.py")',
            'run("bash", "ci/prepare-native-runtime.sh")',
            'run("bash", "ci/compile-wine.sh")',
            'run("bash", "ci/compile-windows-modules.sh")',
            'run("bash", "ci/prepare-windows-runtime.sh")',
        ):
            self.assertIn(command, source)
        self.assertIn("Local native runtime unchanged; reusing", source)
        self.assertIn("build_runtime_bundle.sh", source)
        self.assertIn('"local-" + head_short()', source)

    def test_local_input_prep_recovers_managed_submodules_without_losing_diffs(self):
        source = (ROOT / "ci/prepare-local-runtime-inputs.py").read_text()
        self.assertIn("if destination.exists()", source)
        self.assertIn("Reuse local runtime input", source)
        self.assertIn("prepare_submodules(modules)", source)
        self.assertIn("--show-superproject-working-tree", source)
        self.assertIn("checkout_has_tracked_changes(path)", source)
        self.assertIn("checkout_has_untracked_files(path)", source)
        self.assertIn("backup_tracked_changes", source)
        self.assertIn(".build/local-submodule-backups", source)
        self.assertIn("Backed up tracked changes", source)
        self.assertIn('"reset", "--hard", actual', source)
        self.assertIn("Repair managed submodule", source)
        self.assertIn("untracked files will be preserved", source)
        self.assertIn("Do not use --force", source)
        self.assertIn("Standalone checkout", source)
        self.assertIn("Refusing to overwrite local source", source)
        self.assertIn('"submodule", "update", "--init", "--depth", "1", "--", *update', source)
        self.assertIn('"apply", "--reverse", "--check"', source)
        native = (ROOT / "ci/prepare-native-runtime.sh").read_text()
        self.assertIn("LLVM iOS linker correction already applied", native)

    def test_native_preflight_exposes_pinned_toolchain_before_compiler_checks(self):
        native = (ROOT / "ci/prepare-native-runtime.sh").read_text()
        toolchain = native.index('PATH="$MADEIRA/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin:$PATH"')
        compiler_check = native.index('x86_64-w64-mingw32-gcc i686-w64-mingw32-gcc')
        self.assertLess(toolchain, compiler_check)
        self.assertIn('echo "Missing native-build tool: $tool"', native)
        self.assertIn('Missing Homebrew package: $package', native)

    def test_fingerprint_tracks_source_toolchain_and_staged_artifacts(self):
        source = (ROOT / "ci/prepare-local-runtime.py").read_text()
        self.assertIn("native_contract_inputs", source)
        self.assertIn('("xcodebuild", "-version")', source)
        self.assertIn('("xcrun", "--sdk", "iphoneos", "--show-sdk-build-version")', source)
        self.assertIn('("media", MEDIA)', source)
        self.assertIn('("prefix", PREFIX)', source)
        self.assertIn('("userland", USERLAND)', source)
        self.assertIn("IRIDIUM_FORCE_NATIVE_REBUILD", source)
        self.assertIn(".build/local-native-runtime-state.json", source)


if __name__ == "__main__":
    unittest.main()
