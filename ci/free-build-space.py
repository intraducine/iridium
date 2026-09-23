#!/usr/bin/env python3
"""Discard verified transfer copies after their compiler stages are retained."""
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]
TRANSFERS = ('media', 'native-compiled', 'wine-compiled', 'windows-compiled',
             'graphics-compiled', 'jit-compiled')


def cleanup(root):
    build = root / '.build'
    paths = [build / (name + '-transfer') for name in TRANSFERS]
    if build.is_symlink() or any(not path.is_dir() or path.is_symlink() for path in paths):
        raise ValueError('Expected regular build transfer directories')
    before = shutil.disk_usage(build).free
    for path in paths:
        shutil.rmtree(path)
    after = shutil.disk_usage(build).free
    print(f'Freed {max(0, after - before) // 1048576} MiB of uploaded transfer copies')


if __name__ == '__main__':
    cleanup(ROOT)
