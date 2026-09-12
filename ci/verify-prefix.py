#!/usr/bin/env python3
"""Verify the prefix producer, checksums, and archive before app staging."""
import hashlib
import importlib.util
import os
from pathlib import Path
import tarfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('reuse', ROOT / 'ci/reuse-build-assets.py')
reuse = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reuse)


def check_files(folder, revision):
    if (folder / 'source-revision.txt').read_text().strip() != revision:
        raise ValueError('Prefix source revision mismatch')
    expected = {}
    for line in (folder / 'SHA256SUMS').read_text().splitlines():
        digest, name = line.split('  ', 1)
        if name in expected:
            raise ValueError('Duplicate prefix checksum')
        expected[name] = digest
    if set(expected) != {'prefix-template.tar.gz', 'source-revision.txt'}:
        raise ValueError('Unexpected prefix checksum inventory')
    for name, digest in expected.items():
        if hashlib.sha256((folder / name).read_bytes()).hexdigest() != digest:
            raise ValueError('Prefix checksum mismatch')
    with tarfile.open(folder / 'prefix-template.tar.gz') as archive:
        files = set()
        for member in archive:
            path = Path(member.name)
            if path.is_absolute() or '..' in path.parts or not path.is_relative_to('prefix'):
                raise ValueError('Unsafe prefix archive path')
            if not (member.isfile() or member.isdir()):
                raise ValueError('Unsupported prefix archive member')
            if member.isfile():
                files.add(str(path))
        if not {'prefix/system.reg', 'prefix/user.reg', 'prefix/userdef.reg'}.issubset(files):
            raise ValueError('Missing prefix registry')


if __name__ == '__main__':
    revision = reuse.verify_producer(ROOT, os.environ['PREFIX_RUN_ID'], 'prefix', os.environ['GITHUB_REF_NAME'])
    check_files(ROOT / '.build/prefix-transfer', revision)
    print('Verified prefix producer, checksums and registry archive')
