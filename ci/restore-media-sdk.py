#!/usr/bin/env python3
"""Restore the same-run media SDK and its corresponding source."""
import importlib.util
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('runtime_inputs', ROOT / 'ci/fetch-runtime-inputs.py')
inputs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inputs)


def restore(root):
    transfer = root / '.build/media-transfer'
    revision = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
    if (transfer / 'source-revision.txt').read_text().strip() != revision:
        raise ValueError('Media SDK source revision does not match this build')
    subprocess.run(['shasum', '-a', '256', '-c', 'SHA256SUMS'], cwd=transfer, check=True)
    output = root / 'iridium/apps/ios/.build/media-sdk'
    inputs.unpack(transfer / 'media-sdk.tar.gz', output, 'media-sdk')
    if not (output / 'GStreamer.xcframework/ios-arm64/libGStreamer.a').is_file():
        raise ValueError('Media SDK has an unexpected framework layout')
    source = root / '.build/corresponding-source/cerbero-1.28.6.tar.xz'
    source.parent.mkdir(parents=True, exist_ok=True)
    if source.exists():
        raise ValueError('Refusing to overwrite existing media source')
    shutil.copyfile(transfer / source.name, source)


if __name__ == '__main__':
    restore(ROOT)
