#!/usr/bin/env python3
"""Extract the verified Linux archive for the existing iOS resource-stage script."""
from pathlib import Path
import subprocess
import tarfile
import tempfile


def extract(archive, target):
    if target.exists() or target.is_symlink():
        raise ValueError('Refusing to replace an existing userland directory')
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=target.parent) as directory:
        root = Path(directory)
        payload = root / 'payload'
        payload.mkdir()
        with tempfile.TemporaryFile() as stream:
            subprocess.run(['zstd', '-q', '-d', '-c', str(archive)], stdout=stream, check=True)
            stream.seek(0)
            with tarfile.open(fileobj=stream) as tar:
                tar.extractall(payload, filter='data')
        for name in ('bin/wineserver', 'share/wine/nls/l_intl.nls'):
            path = payload / name
            if not path.is_file() or not path.stat().st_size:
                raise ValueError('Incomplete Wine userland: ' + name)
        payload.rename(target)


if __name__ == '__main__':
    root = Path(__file__).resolve().parents[1]
    extract(root / '.build/linux-transfer/wine-userland.tar.zst',
            root / 'iridium-runtime-sdk/build/iridium-runtime-base/Userland/extracted')
    print('Extracted verified Wine userland for iOS resource staging.')
