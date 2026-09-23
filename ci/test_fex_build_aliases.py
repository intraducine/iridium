"""Filesystem and executable regression tests for local FEX alias publication."""
import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
HELPERS = ROOT / "iridium-fex-ios/iridium/ios"
SPEC = importlib.util.spec_from_file_location("fex_aliases", HELPERS / "publish_build_aliases.py")
ALIASES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ALIASES)


class FEXBuildAliasTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="iridium alias test ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.build = self.root / ALIASES.BUILD_NAME
        self.archive = self.build / ALIASES.ARCHIVE
        self.archive.parent.mkdir(parents=True)
        self.archive.write_bytes(b"!<arch>\nfixture")
        (self.build / ALIASES.MANIFEST).write_text("PLATFORM=device\n")
        self.aliases = [self.root / name for name in ALIASES.ALIAS_NAMES]

    def real_aliases(self):
        for alias in self.aliases:
            alias.mkdir()
            (alias / "keep.dat").write_bytes(b"old artifact\0local data")
            (alias / "hidden-source").mkdir()
            (alias / "hidden-source/.keep").write_text("preserve this too")

    def assert_published(self):
        for alias in self.aliases:
            self.assertTrue(alias.is_symlink())
            self.assertEqual(alias.resolve(), self.build)
            self.assertEqual((alias / ALIASES.ARCHIVE).read_bytes(), self.archive.read_bytes())

    def test_fresh_checkout_publishes_both_aliases(self):
        self.assertEqual(ALIASES.publish(self.root), [])
        self.assert_published()

    def test_existing_directories_are_moved_intact_not_deleted(self):
        self.real_aliases()
        before = self.archive.stat().st_mtime_ns
        backups = ALIASES.publish(self.root)
        self.assertEqual(len(backups), 2)
        for backup in backups:
            self.assertEqual((backup / "keep.dat").read_bytes(), b"old artifact\0local data")
            self.assertEqual((backup / "hidden-source/.keep").read_text(), "preserve this too")
        self.assert_published()
        self.assertEqual(self.archive.stat().st_mtime_ns, before)

    def test_repeat_is_noop_and_keeps_backups(self):
        self.real_aliases()
        backups = ALIASES.publish(self.root)
        stats = [p.lstat().st_ino for p in self.aliases]
        self.assertEqual(ALIASES.publish(self.root), [])
        self.assertEqual(stats, [p.lstat().st_ino for p in self.aliases])
        self.assertTrue(all(p.exists() for p in backups))

    def test_later_restored_directories_get_unique_backups(self):
        self.real_aliases()
        old = ALIASES.publish(self.root)
        for alias in self.aliases:
            alias.unlink()
        self.real_aliases()
        new = ALIASES.publish(self.root)
        self.assertTrue(set(old).isdisjoint(new))
        self.assertTrue(all(p.exists() for p in old + new))

    def test_stale_and_broken_symlinks_are_replaced_without_touching_targets(self):
        target = self.root / "other-build"
        target.mkdir()
        (target / "keep").write_text("untouched")
        self.aliases[0].symlink_to(target)
        self.aliases[1].symlink_to("does-not-exist")
        self.assertEqual(ALIASES.publish(self.root), [])
        self.assert_published()
        self.assertEqual((target / "keep").read_text(), "untouched")

    def test_correct_absolute_alias_is_not_rewritten(self):
        for alias in self.aliases:
            alias.symlink_to(self.build)
        before = [alias.lstat().st_ino for alias in self.aliases]
        self.assertEqual(ALIASES.publish(self.root), [])
        self.assertEqual(before, [alias.lstat().st_ino for alias in self.aliases])

    def test_missing_or_empty_archive_never_changes_aliases(self):
        self.real_aliases()
        for state in (b"", None):
            if state is None:
                self.archive.unlink()
            else:
                self.archive.write_bytes(state)
            with self.assertRaisesRegex(RuntimeError, "missing or empty"):
                ALIASES.publish(self.root)
            self.assertTrue(all(p.is_dir() and not p.is_symlink() for p in self.aliases))

    def test_missing_wrong_or_ambiguous_manifest_never_publishes(self):
        self.real_aliases()
        manifest = self.build / ALIASES.MANIFEST
        for content in (None, "PLATFORM=simulator\n", "PLATFORM=device\nPLATFORM=host\n"):
            if content is None:
                manifest.unlink()
            else:
                manifest.write_text(content)
            with self.assertRaises(RuntimeError):
                ALIASES.publish(self.root)
            self.assertTrue(all(not p.is_symlink() for p in self.aliases))

    def test_all_paths_validated_before_first_move(self):
        self.aliases[0].mkdir()
        (self.aliases[0] / "keep").write_text("keep")
        self.aliases[1].write_text("not a generated directory")
        with self.assertRaisesRegex(RuntimeError, "non-directory"):
            ALIASES.publish(self.root)
        self.assertEqual((self.aliases[0] / "keep").read_text(), "keep")
        self.assertFalse((self.root / ".build").exists())

    def test_backup_symlink_is_rejected(self):
        self.real_aliases()
        elsewhere = self.root / "elsewhere"
        elsewhere.mkdir()
        (self.root / ".build").symlink_to(elsewhere)
        with self.assertRaisesRegex(RuntimeError, "backup path"):
            ALIASES.publish(self.root)
        self.assertEqual(list(elsewhere.iterdir()), [])
        self.assertTrue(all(not p.is_symlink() for p in self.aliases))

    def test_canonical_build_symlink_cannot_create_alias_cycle(self):
        shutil.rmtree(self.build)
        self.aliases[0].mkdir()
        self.build.symlink_to(self.aliases[0])
        with self.assertRaisesRegex(RuntimeError, "Canonical"):
            ALIASES.publish(self.root)
        self.assertFalse(self.aliases[0].is_symlink())

    def test_preflight_needs_no_artifact_and_makes_no_changes(self):
        shutil.rmtree(self.build)
        ALIASES.check_layout(self.root)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_failed_publication_restores_both_old_directories(self):
        self.real_aliases()
        original = ALIASES.os.replace

        def fail_second(source, destination):
            if Path(destination) == self.aliases[1]:
                raise OSError("injected publication failure")
            return original(source, destination)

        with patch.object(ALIASES.os, "replace", side_effect=fail_second):
            with self.assertRaisesRegex(RuntimeError, "Previous aliases restored"):
                ALIASES.publish(self.root)
        for alias in self.aliases:
            self.assertFalse(alias.is_symlink())
            self.assertEqual((alias / "keep.dat").read_bytes(), b"old artifact\0local data")

    def test_failed_second_link_restores_previous_symlink(self):
        self.aliases[0].symlink_to("old-build")
        self.aliases[1].mkdir()
        original = ALIASES.os.replace

        def fail_second(source, destination):
            if Path(destination) == self.aliases[1]:
                raise OSError("injected publication failure")
            return original(source, destination)

        with patch.object(ALIASES.os, "replace", side_effect=fail_second):
            with self.assertRaises(RuntimeError):
                ALIASES.publish(self.root)
        self.assertEqual(ALIASES.os.readlink(self.aliases[0]), "old-build")
        self.assertTrue(self.aliases[1].is_dir())

    def test_native_recipe_validates_before_build_and_publishes_after_fex(self):
        source = (ROOT / "ci/prepare-native-runtime.sh").read_text()
        preflight = source.index('publish_build_aliases.py" --check')
        native_start = source.index('bash "$MADEIRA/build/gnutls-ios/build.sh"')
        fex_start = source.index('bash "$ROOT/iridium-fex-ios/iridium/ios/build_embedded_translator.sh"')
        publication = source.index('python3 "$ROOT/iridium-fex-ios/iridium/ios/publish_build_aliases.py"', fex_start)
        wine_start = source.index('# The iOS Wine configure step')
        self.assertLess(preflight, native_start)
        self.assertLess(fex_start, publication)
        self.assertLess(publication, wine_start)
        self.assertIn('--build-root "$ROOT/iridium-fex-ios/build-iridium-ios-device"', source[fex_start:publication])

    @unittest.skipUnless(shutil.which("cmake") and shutil.which("cc"), "requires host CMake/C compiler")
    def test_real_entrypoint_reproduces_failure_then_reuses_compiled_objects(self):
        # Compile a tiny host fixture through the actual FEX shell entrypoint.
        # This exercises alias handling, not FEX/iOS compilation.
        shutil.rmtree(self.build)
        self.real_aliases()
        scripts = self.root / "iridium/ios"
        scripts.mkdir(parents=True)
        script = scripts / "build_embedded_translator.sh"
        shutil.copy2(HELPERS / script.name, script)
        for relative in ("External/vixl", "Source/Common/cpp-optparse", "External/fmt",
                         "External/xxhash/cmake_unofficial", "External/range-v3",
                         "External/unordered_dense", "External/rpmalloc"):
            folder = self.root / relative
            folder.mkdir(parents=True)
            (folder / "CMakeLists.txt").write_text("# dependency fixture\n")
        (self.root / "fixture.c").write_text("int alias_fixture(void) { return 42; }\n")
        (self.root / "CMakeLists.txt").write_text('''cmake_minimum_required(VERSION 3.16)
project(AliasFixture C)
add_library(iridium-fex-ios-embedded STATIC fixture.c)
set_target_properties(iridium-fex-ios-embedded PROPERTIES
  ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/artifacts")
file(WRITE "${CMAKE_BINARY_DIR}/iridium-ios-embedded-artifact.txt"
  "PLATFORM=${IRIDIUM_IOS_EMBEDDED_PLATFORM}\\n")
''')
        command = ["bash", str(script), "--platform", "device", "--jobs", "2"]
        old = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(old.returncode, 73, old.stdout + old.stderr)
        self.assertIn("refusing to replace non-symlink build alias", old.stderr)
        self.assertTrue(self.archive.is_file())
        objects = list(self.build.rglob("*.o"))
        self.assertTrue(objects)
        before = {p: p.stat().st_mtime_ns for p in objects}
        fixed = subprocess.run(command + ["--build-root", str(self.build)], capture_output=True, text=True)
        self.assertEqual(fixed.returncode, 0, fixed.stdout + fixed.stderr)
        backups = ALIASES.publish(self.root)
        self.assert_published()
        self.assertEqual(len(backups), 2)
        self.assertEqual(before, {p: p.stat().st_mtime_ns for p in objects})
        self.assertEqual(ALIASES.publish(self.root), [])


if __name__ == "__main__":
    unittest.main()
