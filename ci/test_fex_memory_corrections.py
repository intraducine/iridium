#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RPMALLOC_PATCH = ROOT / "ci/patches/rpmalloc-compact-runtime.patch"
THREAD_PATCH = ROOT / "ci/patches/fex-thread-init-failure.patch"
HELPER = ROOT / "ci/apply-fex-runtime-corrections.py"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class RuntimeCorrectionContractTests(unittest.TestCase):
    def test_patch_files_are_well_formed(self):
        for patch in (RPMALLOC_PATCH, THREAD_PATCH):
            result = subprocess.run(
                ["git", "apply", "--numstat", str(patch)],
                cwd=ROOT, capture_output=True, text=True,
            )
            self.assertEqual(
                result.returncode, 0,
                f"Malformed patch {patch.name}:\n{result.stderr}",
            )

    def test_fex_patch_matches_checkout_or_is_already_applied(self):
        forward = subprocess.run(
            ["git", "-C", str(ROOT), "apply", "--check", str(THREAD_PATCH)],
            capture_output=True, text=True,
        )
        reverse = subprocess.run(
            ["git", "-C", str(ROOT), "apply", "--reverse", "--check", str(THREAD_PATCH)],
            capture_output=True, text=True,
        )
        self.assertTrue(
            forward.returncode == 0 or reverse.returncode == 0,
            "FEX/Wine correction patch no longer matches the checked-out source\n"
            f"forward:\n{forward.stderr}\nreverse:\n{reverse.stderr}",
        )

    def test_compact_profile_and_allocator_containment_are_coupled(self):
        text = RPMALLOC_PATCH.read_text()
        for required in (
            "#define LARGE_BLOCK_SIZE_LIMIT (2 * 1024 * 1024)",
            "#define LARGE_SIZE_CLASS_COUNT 12",
            "#define LARGE_PAGE_SIZE_SHIFT 22",
            "#define SPAN_SIZE (4 * 1024 * 1024)",
            "rpmalloc-compact-spans-v1",
            "RPMALLOC_PROFILE_STR(SPAN_SIZE)",
            "RPMALLOC_PROFILE_STR(LARGE_PAGE_SIZE)",
            "RPMALLOC_PROFILE_STR(LARGE_BLOCK_SIZE_LIMIT)",
            "char buf[512]",
            "i < (int)sizeof(buf) - 1",
            "if (bad)",
            "return;",
            "page->next->prev = 0",
            "page->prev = 0",
            "page->next = 0",
            "rpm_avail_check(heap, size_class, page, /*is_head=*/1, \"consume\") != 0",
        ):
            self.assertIn(required, text)
        self.assertNotIn("CALLRET_STACK_SIZE", text)

    def test_thread_failure_is_transactional_and_stops_guest_attach(self):
        text = THREAD_PATCH.read_text()
        for required in (
            "[[nodiscard]] bool InitializeThread",
            "if (!CallRetStackAlloc)",
            "VirtualFree(const_cast<void*>(CallRetStackAlloc), 0, MEM_RELEASE)",
            "if (!FEX::Windows::CallRetStack::InitializeThread(Thread))",
            "CPUArea.ThreadState() = nullptr",
            "return STATUS_NO_MEMORY",
            "RtlExitUserThread(STATUS_NO_MEMORY)",
            "NTSTATUS arm64ec_status = arm64ec_thread_init()",
            "RtlExitUserThread( arm64ec_status )",
        ):
            self.assertIn(required, text)
        self.assertNotIn("CALLRET_STACK_SIZE =", text)

    def test_patch_application_helper_is_idempotent_and_conflict_safe(self):
        helper = load("apply_fex_runtime_corrections", HELPER)
        with tempfile.TemporaryDirectory() as name:
            repo = Path(name) / "repo"
            repo.mkdir()
            subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
            target = repo / "sample.txt"
            target.write_text("before\n")
            patch = Path(name) / "sample.patch"
            patch.write_text(
                "diff --git a/sample.txt b/sample.txt\n"
                "--- a/sample.txt\n+++ b/sample.txt\n"
                "@@ -1 +1 @@\n-before\n+after\n"
            )
            helper.apply_patch_idempotent(repo, patch, "sample")
            self.assertEqual(target.read_text(), "after\n")
            helper.apply_patch_idempotent(repo, patch, "sample")
            self.assertEqual(target.read_text(), "after\n")
            target.write_text("conflict\n")
            with self.assertRaises(RuntimeError):
                helper.apply_patch_idempotent(repo, patch, "sample")

    def test_exact_managed_patch_detection_rejects_extra_edits_and_modes(self):
        helper = load("apply_fex_runtime_corrections_exact", HELPER)
        with tempfile.TemporaryDirectory() as name:
            repo = Path(name) / "repo"
            repo.mkdir()
            subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.email", "tests@example.invalid"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.name", "Iridium Tests"], cwd=repo, check=True)
            target = repo / "sample.txt"
            target.write_text("before\n")
            subprocess.run(["git", "add", "sample.txt"], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-qm", "base"], cwd=repo, check=True)
            patch = Path(name) / "sample.patch"
            patch.write_text(
                "diff --git a/sample.txt b/sample.txt\n"
                "--- a/sample.txt\n+++ b/sample.txt\n"
                "@@ -1 +1 @@\n-before\n+after\n"
            )
            subprocess.run(["git", "apply", str(patch)], cwd=repo, check=True)
            self.assertEqual(
                helper.exact_managed_patch_changes(repo, patch, {"sample.txt"}),
                {"sample.txt"},
            )
            target.write_text("after\nextra local edit\n")
            self.assertEqual(helper.exact_managed_patch_changes(repo, patch, {"sample.txt"}), set())
            target.write_text("after\n")
            target.chmod(0o755)
            self.assertEqual(helper.exact_managed_patch_changes(repo, patch, {"sample.txt"}), set())

    def test_retained_prefix_accepts_only_exact_managed_wine_delta(self):
        helper = load("apply_fex_runtime_corrections_prefix", HELPER)
        prepare = load("prepare_local_runtime_managed_patch", ROOT / "ci/prepare-local-runtime.py")
        with tempfile.TemporaryDirectory() as name:
            repo = Path(name) / "repo"
            repo.mkdir()
            subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.email", "tests@example.invalid"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.name", "Iridium Tests"], cwd=repo, check=True)

            for relative in helper.patch_paths(THREAD_PATCH):
                source = ROOT / relative
                destination = repo / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, destination)
            metadata = repo / "testrepos/Madeira/wine/.DS_Store"
            metadata.parent.mkdir(parents=True, exist_ok=True)
            metadata.write_bytes(b"tracked macOS metadata\n")
            for relative in (
                "fixture/media.txt",
                "fixture/linux.txt",
                "fixture/graphics.txt",
                "fixture/jit.txt",
            ):
                destination = repo / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_text(relative + "\n")
            workflow = repo / prepare.WORKFLOW
            workflow.parent.mkdir(parents=True, exist_ok=True)
            workflow.write_text("name: fixture\n")
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-qm", "base"], cwd=repo, check=True)
            revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
            subprocess.run(["git", "apply", str(THREAD_PATCH)], cwd=repo, check=True)
            metadata.write_bytes(b"Finder rewrote this metadata\n")

            class FakeLinux:
                INPUTS = ("fixture/linux.txt",)

            class FakeReuse:
                MEDIA_INPUTS = ("fixture/media.txt",)
                PREFIX_INPUTS = ("testrepos/Madeira/wine",)
                linux = FakeLinux()
                COMPONENT_INPUTS = {
                    "graphics": ("fixture/graphics.txt",),
                    "jit": ("fixture/jit.txt",),
                }

                @staticmethod
                def git(root, *args):
                    return subprocess.check_output(
                        ["git", "-C", str(root), *args], text=True
                    ).strip()

                @staticmethod
                def producer_job(text, stage):
                    return text

            old_root, old_ci = prepare.ROOT, prepare.CI
            prepare.ROOT = repo
            prepare.CI = ROOT / "ci"
            try:
                prepare.verify_retained_inputs(FakeReuse, revision)

                wine_target = next(
                    relative for relative in helper.patch_paths(THREAD_PATCH)
                    if relative.startswith("testrepos/Madeira/wine/")
                )
                target = repo / wine_target
                patched = target.read_bytes()
                target.write_bytes(patched + b"\n/* unrelated local edit */\n")
                with self.assertRaisesRegex(RuntimeError, "prefix"):
                    prepare.verify_retained_inputs(FakeReuse, revision)

                target.write_bytes(patched)
                unrelated = repo / "testrepos/Madeira/wine/unrelated-local-edit.txt"
                unrelated.write_text("local\n")
                with self.assertRaisesRegex(RuntimeError, "prefix"):
                    prepare.verify_retained_inputs(FakeReuse, revision)
            finally:
                prepare.ROOT = old_root
                prepare.CI = old_ci

    def test_build_paths_apply_corrections_and_cache_keys_track_them(self):
        action = (ROOT / "ci/prepare-runtime-inputs.sh").read_text()
        local = (ROOT / "ci/build-local-ipa.sh").read_text()
        staging = (ROOT / "ci/stage-windows-runtime.py").read_text()
        prepare = (ROOT / "ci/prepare-local-runtime.py").read_text()
        self.assertIn("apply-fex-runtime-corrections.py", action)
        self.assertLess(local.index("prepare-local-runtime-inputs.py"), local.index("apply-fex-runtime-corrections.py"))
        self.assertLess(local.index("apply-fex-runtime-corrections.py"), local.index("prepare-local-runtime.py"))
        self.assertIn("worktree_changes_excluding_patch", prepare)
        self.assertIn("corrections.THREAD_PATCH", prepare)
        self.assertIn("COMPACT_PROFILE_MARKER", staging)
        self.assertIn("if COMPACT_PROFILE_MARKER not in translator_data", staging)

        reuse = load("reuse_build_assets", ROOT / "ci/reuse-build-assets.py")
        for component in ("native", "windows"):
            inputs = reuse.COMPONENT_INPUTS[component]
            self.assertIn("ci/patches/rpmalloc-compact-runtime.patch", inputs)
            self.assertIn("ci/patches/fex-thread-init-failure.patch", inputs)
            self.assertIn("ci/apply-fex-runtime-corrections.py", inputs)
        self.assertIn("ci/patches/fex-thread-init-failure.patch", reuse.COMPONENT_INPUTS["wine"])


if __name__ == "__main__":
    unittest.main()
