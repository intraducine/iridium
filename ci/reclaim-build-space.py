#!/usr/bin/env python3
"""Remove consumed build copies after verification and successful audit uploads."""
import argparse
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]
TRANSFERS = tuple('.build/' + name + '-compiled-transfer/compiled.tar.gz'
                  for name in ('native', 'wine', 'windows', 'graphics', 'jit')) + (
    '.build/media-transfer/media-sdk.tar.gz',
    '.build/linux-transfer/wine-userland.tar.zst',
    '.build/steam-transfer/steam-framework.tar.gz',
)
SOURCE_OUTPUT = '.build/ipa-output/Iridium-corresponding-source.tar.gz'
PACKAGE_INPUTS = (
    '.build/corresponding-source',
    '.build/linux-transfer/sources',
    '.build/unsigned-ipa/Build/Intermediates.noindex',
)
PHASES = ('prepare-source', 'source-uploaded', 'package-ready')


def reclaim(root, phase):
    if phase not in PHASES:
        raise ValueError('Unknown cleanup phase')
    root = root.resolve(strict=True)
    trees = phase == 'package-ready'
    names = PACKAGE_INPUTS if trees else TRANSFERS if phase == 'prepare-source' else (SOURCE_OUTPUT,)
    targets = []
    # Validate the entire fixed list before deleting anything. Never follow links
    # or accept caller-provided artifact paths. rmtree unlinks nested symlinks.
    for name in names:
        path = root / name
        if any(part.is_symlink() for part in (path, *path.parents) if part != root):
            raise ValueError('Build transfer path contains a link')
        if not path.resolve().is_relative_to(root):
            raise ValueError('Build transfer path escapes checkout')
        if path.exists():
            if not (path.is_dir() if trees else path.is_file()):
                raise ValueError('Unexpected build copy type')
            targets.append(path)
    before = shutil.disk_usage(root).free
    for path in targets:
        if trees:
            shutil.rmtree(path)
        else:
            path.unlink()
    freed = max(0, shutil.disk_usage(root).free - before)
    print(f'Reclaimed {freed // 1048576} MiB of consumed build copies; '
          f'{shutil.disk_usage(root).free // 1048576} MiB available.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=PHASES)
    reclaim(ROOT, parser.parse_args().phase)
