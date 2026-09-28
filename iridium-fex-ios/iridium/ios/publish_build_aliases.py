#!/usr/bin/env python3
"""Publish a completed device FEX build without deleting restored build trees.

The monorepo builds at the canonical path with --build-root (which disables
implicit alias creation), then calls this helper. Real directories left at the
compatibility paths by artifact restores are moved intact to unique backups.
The canonical CMake build directory and its object cache are never moved.
"""
import argparse
import os
from pathlib import Path
import sys
import tempfile

BUILD_NAME = "build-iridium-ios-device"
ALIAS_NAMES = ("build-iridium-ios-iphoneos", "build-iridium-ios-current")
ARCHIVE = "artifacts/libiridium-fex-ios-embedded.a"
MANIFEST = "iridium-ios-embedded-artifact.txt"


def check_layout(root: Path) -> None:
    """Validate every destination before compilation or any directory move."""
    if not root.is_dir():
        raise RuntimeError(f"FEX source directory is missing: {root}")
    build = root / BUILD_NAME
    if build.is_symlink() or (build.exists() and not build.is_dir()):
        raise RuntimeError(f"Canonical FEX build path must be a real directory: {build}")
    for name in ALIAS_NAMES:
        alias = root / name
        # Replacing a symlink changes only the link, never its target.
        if not alias.is_symlink() and alias.exists() and not alias.is_dir():
            raise RuntimeError(f"Refusing to replace non-directory FEX alias: {alias}")
    for path in (root / ".build", root / ".build/build-alias-backups"):
        if path.is_symlink() or (path.exists() and not path.is_dir()):
            raise RuntimeError(f"FEX backup path must be a real directory: {path}")


def check_artifact(build: Path) -> None:
    archive = build / ARCHIVE
    manifest = build / MANIFEST
    if not archive.is_file() or archive.stat().st_size == 0:
        raise RuntimeError(f"Completed FEX archive is missing or empty: {archive}")
    if not manifest.is_file():
        raise RuntimeError(f"Completed FEX manifest is missing: {manifest}")
    platforms = [line for line in manifest.read_text().splitlines() if line.startswith("PLATFORM=")]
    if platforms != ["PLATFORM=device"]:
        raise RuntimeError(f"Refusing to publish a non-device FEX build: {manifest}")


def points_to_build(alias: Path, build: Path) -> bool:
    if not alias.is_symlink():
        return False
    target = os.path.abspath(alias.parent / os.readlink(alias))
    return target == str(build)


def publish(root: Path) -> list[Path]:
    root = root.resolve()
    check_layout(root)
    build = root / BUILD_NAME
    check_artifact(build)
    aliases = [root / name for name in ALIAS_NAMES
               if not points_to_build(root / name, build)]
    if not aliases:
        print("FEX build aliases already point to the completed device build.", flush=True)
        return []

    backups = []
    changed = []
    with tempfile.TemporaryDirectory(prefix=".iridium-alias-publish-", dir=root) as temporary:
        stage = Path(temporary)
        # Create both replacement links before moving any existing directory.
        for alias in aliases:
            (stage / alias.name).symlink_to(BUILD_NAME, target_is_directory=True)
        try:
            for alias in aliases:
                old_link = os.readlink(alias) if alias.is_symlink() else None
                backup = None
                if old_link is None and alias.exists():
                    backup_root = root / ".build/build-alias-backups"
                    backup_root.mkdir(parents=True, exist_ok=True)
                    slot = Path(tempfile.mkdtemp(prefix=alias.name + "-", dir=backup_root))
                    backup = slot / alias.name
                    alias.rename(backup)
                    backups.append(backup)
                    print(f"Preserved previous FEX build directory: {backup}", flush=True)
                # Record the directory move before publication, so even a failed
                # first replacement restores its original directory.
                changed.append((alias, backup, old_link))
                os.replace(stage / alias.name, alias)
                print(f"Published FEX build alias: {alias.name} -> {BUILD_NAME}", flush=True)
        except OSError as error:
            failures = []
            for alias, backup, old_link in reversed(changed):
                try:
                    if backup is not None:
                        if alias.is_symlink():
                            alias.unlink()
                        backup.rename(alias)
                    elif old_link is not None:
                        restore = stage / (alias.name + ".restore")
                        restore.symlink_to(old_link)
                        os.replace(restore, alias)
                    elif alias.is_symlink():
                        alias.unlink()
                except OSError as rollback_error:
                    failures.append(f"{alias}: {rollback_error}; backup: {backup}")
            detail = "\nRollback requires attention:\n" + "\n".join(failures) if failures else "\nPrevious aliases restored."
            raise RuntimeError("Could not publish FEX build aliases: " + str(error) + detail) from error
    return backups


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Validate paths without changing any files")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    if args.check:
        check_layout(root)
    else:
        publish(root)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, UnicodeError) as error:
        print("FEX build publication: " + str(error), file=sys.stderr)
        sys.exit(73)
