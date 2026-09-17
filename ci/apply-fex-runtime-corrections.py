#!/usr/bin/env python3
"""Apply Iridium's FEX memory corrections without overwriting local source edits."""
from pathlib import Path
import stat
import subprocess
import tempfile

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


def patch_paths(patch: Path) -> tuple[str, ...]:
    """Return tracked destination paths touched by one of our text patches."""
    paths = []
    for line in patch.read_text().splitlines():
        if not line.startswith("+++ b/"):
            continue
        relative = line[6:].split("\t", 1)[0]
        if relative != "/dev/null" and relative not in paths:
            paths.append(relative)
    return tuple(paths)


def _head_blob(repo: Path, relative: str) -> tuple[bytes, str] | None:
    tree = subprocess.run(
        ["git", "-C", str(repo), "ls-tree", "HEAD", "--", relative],
        capture_output=True,
        text=True,
        check=False,
    )
    if tree.returncode or not tree.stdout.strip():
        return None
    fields = tree.stdout.strip().split(None, 3)
    if len(fields) < 4 or fields[1] != "blob":
        return None
    try:
        data = subprocess.check_output(
            ["git", "-C", str(repo), "show", f"HEAD:{relative}"]
        )
    except subprocess.CalledProcessError:
        return None
    return data, fields[0]


def exact_managed_patch_changes(repo: Path, patch: Path, candidates) -> set[str]:
    """Identify working files that are exactly HEAD plus the selected managed patch.

    This never edits the real checkout. Each candidate is reconstructed from HEAD in
    a temporary repository, the managed patch is applied there for that path only,
    and the result must match byte-for-byte and executable-bit-for-executable-bit.
    Any extra user edit, deletion, symlink, mode change, or unrelated dirty file is
    deliberately left unrecognized so provenance checks still reject it.
    """
    touched = set(patch_paths(patch))
    managed = set()
    for relative in sorted(set(candidates)):
        if relative not in touched:
            continue
        current = repo / relative
        if not current.is_file() or current.is_symlink():
            continue
        base = _head_blob(repo, relative)
        if base is None:
            continue
        data, mode = base
        if mode not in ("100644", "100755"):
            continue

        with tempfile.TemporaryDirectory(prefix="iridium-managed-patch-") as name:
            expected_root = Path(name)
            subprocess.run(["git", "init", "-q"], cwd=expected_root, check=True)
            expected = expected_root / relative
            expected.parent.mkdir(parents=True, exist_ok=True)
            expected.write_bytes(data)
            expected.chmod(0o755 if mode == "100755" else 0o644)
            applied = subprocess.run(
                ["git", "-C", str(expected_root), "apply", "--include", relative, str(patch)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
            if applied.returncode:
                continue
            if expected.read_bytes() != current.read_bytes():
                continue
            expected_exec = bool(expected.stat().st_mode & stat.S_IXUSR)
            current_exec = bool(current.stat().st_mode & stat.S_IXUSR)
            if expected_exec != current_exec:
                continue
        managed.add(relative)
    return managed


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
