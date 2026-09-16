#!/usr/bin/env python3
"""Apply the additive, reviewed allocator patches atomically on local/CI trees."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PATCHES = ('rpmalloc-host-arena.patch', 'rpmalloc-compact-spans.patch')


def apply(allocator: Path, patches: Path = ROOT / 'ci/patches') -> bool:
    source = allocator / 'rpmalloc/rpmalloc.c'
    if source.is_symlink() or not source.is_file():
        raise RuntimeError(f'Expected a regular allocator source: {source}')
    before = source.read_bytes()
    with tempfile.TemporaryDirectory(prefix='iridium-rpmalloc-') as directory:
        work = Path(directory)
        candidate = work / 'rpmalloc/rpmalloc.c'
        candidate.parent.mkdir()
        candidate.write_bytes(before)
        subprocess.run(['git', 'init', '-q', str(work)], check=True)
        for name in PATCHES:
            patch = str((patches / name).resolve())
            command = ['git', '-C', str(work), 'apply']
            already = subprocess.run(command + ['--reverse', '--check', patch], capture_output=True)
            if already.returncode == 0:
                continue
            subprocess.run(command + ['--check', patch], check=True)
            subprocess.run(command + [patch], check=True)
        after = candidate.read_bytes()
    if after == before:
        print('rpmalloc host-arena and compact-span patches already applied')
        return False
    # Do not partially patch or replace a concurrently edited source file.
    if source.read_bytes() != before:
        raise RuntimeError('Allocator source changed during patch preparation; no changes published')
    with tempfile.NamedTemporaryFile(dir=source.parent, delete=False) as stream:
        staged = Path(stream.name)
        stream.write(after)
    try:
        os.chmod(staged, source.stat().st_mode & 0o777)
        staged.replace(source)
    finally:
        staged.unlink(missing_ok=True)
    print('Applied rpmalloc host-arena and compact-span patches')
    return True


if __name__ == '__main__':
    apply(ROOT / 'testrepos/Madeira/FEX/External/rpmalloc')
