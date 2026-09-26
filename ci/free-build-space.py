#!/usr/bin/env python3
"""Discard verified transfer copies after their compiler stages are retained."""
from pathlib import Path
import shutil
import os

ROOT = Path(__file__).resolve().parents[1]
TRANSFERS = ('media', 'native-compiled', 'wine-compiled', 'windows-compiled',
             'graphics-compiled', 'jit-compiled')

# Compiler outputs are already retained. App linking uses the finished archives,
# frameworks and DLLs, not their loose compilation objects.
OBJECT_TREES = (
    'testrepos/Madeira/toolchains/llvm-ios-build',
    'testrepos/Madeira/wine/build-macos',
    'testrepos/Madeira/FEX/build-ios',
    'testrepos/Madeira/FEX/build-arm64ec',
    '.build/runtime-sources/angle/out/iridium-ios',
    '.build/idevice-target', '.build/StikJIT-derived',
)


def cleanup(root):
    build = root / '.build'
    paths = [build / (name + '-transfer') for name in TRANSFERS]
    if build.is_symlink() or any(not path.is_dir() or path.is_symlink() for path in paths):
        raise ValueError('Expected regular build transfer directories')
    objects = []
    for name in OBJECT_TREES:
        tree = root / name
        if tree.is_symlink() or not tree.resolve().is_relative_to(root.resolve()):
            raise ValueError('Compiler object directory escapes checkout')
        for directory, children, files in os.walk(tree, followlinks=False):
            children[:] = [d for d in children if not (Path(directory) / d).is_symlink()]
            objects.extend(Path(directory) / f for f in files
                           if Path(f).suffix in {'.o', '.obj'} and not (Path(directory) / f).is_symlink())
    before = shutil.disk_usage(build).free
    for path in paths:
        shutil.rmtree(path)
    for path in objects:
        path.unlink()
    after = shutil.disk_usage(build).free
    print(f'Freed {max(0, after - before) // 1048576} MiB from transfer copies and {len(objects)} compiler objects; {after // 1048576} MiB free')


if __name__ == '__main__':
    cleanup(ROOT)
