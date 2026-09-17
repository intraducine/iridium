#!/usr/bin/env python3
"""Remove consumed transfer copies after verification or successful source upload."""
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


def reclaim(root, phase):
    if phase not in ('prepare-source', 'source-uploaded'):
        raise ValueError('Unknown cleanup phase')
    root = root.resolve(strict=True)
    names = TRANSFERS if phase == 'prepare-source' else (SOURCE_OUTPUT,)
    targets = []
    # Validate the entire fixed list before deleting anything. Never follow links,
    # remove trees, or accept caller-provided artifact paths.
    for name in names:
        path = root / name
        if any(part.is_symlink() for part in (path, *path.parents) if part != root):
            raise ValueError('Build transfer path contains a link')
        if not path.resolve().is_relative_to(root):
            raise ValueError('Build transfer path escapes checkout')
        if path.exists():
            if not path.is_file():
                raise ValueError('Expected a build transfer file')
            targets.append(path)
    freed = 0
    for path in targets:
        freed += path.stat().st_size
        path.unlink()
    print(f'Reclaimed {freed // 1048576} MiB of consumed archives; '
          f'{shutil.disk_usage(root).free // 1048576} MiB available.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=('prepare-source', 'source-uploaded'))
    reclaim(ROOT, parser.parse_args().phase)
