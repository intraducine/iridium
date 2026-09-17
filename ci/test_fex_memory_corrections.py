#!/usr/bin/env python3
import importlib.util
from pathlib import Path
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

    def test_build_paths_apply_corrections_and_cache_keys_track_them(self):
        action = (ROOT / "ci/prepare-runtime-inputs.sh").read_text()
        local = (ROOT / "ci/build-local-ipa.sh").read_text()
        staging = (ROOT / "ci/stage-windows-runtime.py").read_text()
        self.assertIn("apply-fex-runtime-corrections.py", action)
        self.assertLess(local.index("prepare-local-runtime-inputs.py"), local.index("apply-fex-runtime-corrections.py"))
        self.assertLess(local.index("apply-fex-runtime-corrections.py"), local.index("prepare-local-runtime.py"))
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
