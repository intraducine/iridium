"""Reproduce Git's interrupted --no-checkout state with real temporary repositories."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("local_submodule_recovery", ROOT / "ci/local_submodule_recovery.py")
recovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recovery)


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.source = self.base / "upstream"
        self.root = self.base / "superproject"
        self.module = "deps/fmt"
        self.path = self.root / self.module
        for p in (self.source, self.root):
            p.mkdir()
            self.git(p, "init", "-q")
            self.git(p, "config", "user.name", "Test")
            self.git(p, "config", "user.email", "test@example.invalid")
        (self.source / "CMakeLists.txt").write_text("first version\n")
        self.git(self.source, "add", ".")
        self.git(self.source, "commit", "-qm", "pinned")
        self.expected = self.git(self.source, "rev-parse", "HEAD")
        (self.root / ".gitmodules").write_text(f'[submodule "fixture"]\n\tpath = {self.module}\n\turl = {self.source}\n')
        self.git(self.root, "add", ".gitmodules")
        self.git(self.root, "update-index", "--add", "--cacheinfo", f"160000,{self.expected},{self.module}")
        self.git(self.root, "commit", "-qm", "pin dependency")

    def git(self, root, *args):
        return subprocess.check_output(["git", "-C", str(root), *args], text=True, stderr=subprocess.PIPE).strip()

    def clone_without_checkout(self, wrong=False):
        if wrong:
            (self.source / "CMakeLists.txt").write_text("later version\n")
            self.git(self.source, "commit", "-qam", "later")
        self.path.parent.mkdir(parents=True, exist_ok=True)
        metadata = self.root / ".git/modules/fixture"
        metadata.parent.mkdir(parents=True, exist_ok=True)
        self.git(self.root, "clone", "--no-checkout", "--separate-git-dir", str(metadata), str(self.source), str(self.path))
        self.git(self.path, "config", "core.worktree", str(self.path))
        self.git(self.root, "config", "submodule.fixture.url", str(self.source))
        self.assertFalse((metadata / "index").exists())
        self.assertEqual(Path(self.git(self.path, "rev-parse", "--show-superproject-working-tree")), self.root)

    def update(self):
        self.git(self.root, "-c", "protocol.file.allow=always", "submodule", "update", "--init", "--", self.module)

    def test_no_checkout_at_correct_commit_materializes_source(self):
        self.clone_without_checkout()
        recovery.recover(self.root, [self.module])
        self.assertEqual((self.path / "CMakeLists.txt").read_text(), "first version\n")
        self.assertEqual(self.git(self.path, "status", "--porcelain"), "")

    def test_no_checkout_at_wrong_commit_can_then_update_without_force(self):
        self.clone_without_checkout(wrong=True)
        recovery.recover(self.root, [self.module])
        self.update()
        self.assertEqual(self.git(self.path, "rev-parse", "HEAD"), self.expected)
        self.assertEqual((self.path / "CMakeLists.txt").read_text(), "first version\n")

    def test_header_only_tree_is_backed_up_then_full_source_can_clone(self):
        self.path.mkdir(parents=True)
        (self.path / "include").mkdir()
        (self.path / "include/fmt.h").write_text("irreplaceable local edits\n")
        recovery.recover(self.root, [self.module])
        backups = list((self.root / ".build/local-submodule-backups").glob("*/source/include/fmt.h"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), "irreplaceable local edits\n")
        self.update()
        self.assertTrue((self.path / "CMakeLists.txt").is_file())

    def test_populated_tracked_and_untracked_edits_are_untouched(self):
        self.update()
        (self.path / "CMakeLists.txt").write_text("my patch\n")
        (self.path / "notes.txt").write_text("my notes\n")
        before = self.git(self.path, "status", "--porcelain")
        recovery.recover(self.root, [self.module])
        self.assertEqual(self.git(self.path, "status", "--porcelain"), before)
        self.assertEqual((self.path / "CMakeLists.txt").read_text(), "my patch\n")

    def test_staged_delete_is_not_mistaken_for_an_interrupted_clone(self):
        self.update()
        self.git(self.path, "rm", "CMakeLists.txt")
        before = self.git(self.path, "diff", "--cached")
        recovery.recover(self.root, [self.module])
        self.assertFalse((self.path / "CMakeLists.txt").exists())
        self.assertEqual(self.git(self.path, "diff", "--cached"), before)

    def test_second_pass_is_noop(self):
        self.clone_without_checkout()
        recovery.recover(self.root, [self.module])
        timestamp = (self.path / "CMakeLists.txt").stat().st_mtime_ns
        recovery.recover(self.root, [self.module])
        self.assertEqual((self.path / "CMakeLists.txt").stat().st_mtime_ns, timestamp)

    def test_symlink_or_non_gitlink_is_rejected(self):
        self.path.parent.mkdir(parents=True)
        self.path.symlink_to(self.source, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, "Unsafe"):
            recovery.recover(self.root, [self.module])
        with self.assertRaisesRegex(RuntimeError, "Not a pinned"):
            recovery.recover(self.root, [".gitmodules"])


if __name__ == "__main__":
    unittest.main()
