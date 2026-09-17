#!/usr/bin/env python3
"""Apply Iridium's FEX memory corrections without overwriting local source edits."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
ALLOCATOR = ROOT / "testrepos/Madeira/FEX/External/rpmalloc"
HOST_PATCH = ROOT / "ci/patches/rpmalloc-host-arena.patch"
COMPACT_PATCH = ROOT / "ci/patches/rpmalloc-compact-runtime.patch"
THREAD_PATCH = ROOT / "ci/patches/fex-thread-init-failure.patch"


def check(repo: Path, *args: str) -> bool:
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    ).returncode == 0


def run(repo: Path, *args: str) -> None:
    print("+ git -C " + str(repo) + " " + " ".join(args), flush=True)
    subprocess.run(["git", "-C", str(repo), *args], check=True)


def apply_patch_idempotent(repo: Path, patch: Path, label: str) -> None:
    if check(repo, "apply", "--reverse", "--check", str(patch)):
        print(f"{label} already applied", flush=True)
        return
    if not check(repo, "apply", "--check", str(patch)):
        try:
            patch_name = patch.relative_to(ROOT)
        except ValueError:
            patch_name = patch
        raise RuntimeError(
            f"{label} conflicts with the current source tree. Preserving the checkout; "
            f"resolve {patch_name} explicitly."
        )
    run(repo, "apply", str(patch))


def main() -> None:
    if not ALLOCATOR.is_dir():
        raise RuntimeError(
            "rpmalloc source is missing. Prepare pinned runtime inputs before applying FEX corrections."
        )
    if not check(ALLOCATOR, "apply", "--reverse", "--check", str(HOST_PATCH)):
        raise RuntimeError(
            "rpmalloc-host-arena.patch must be applied before rpmalloc-compact-runtime.patch."
        )
    apply_patch_idempotent(ALLOCATOR, COMPACT_PATCH, "rpmalloc compact-runtime patch")
    apply_patch_idempotent(ROOT, THREAD_PATCH, "FEX thread-initialization patch")


if __name__ == "__main__":
    main()
