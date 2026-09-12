#!/usr/bin/env python3
"""Restore matching media SDK and source, rechecking cross-run provenance."""
import importlib.util
from pathlib import Path
import os
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('runtime_inputs', ROOT / 'ci/fetch-runtime-inputs.py')
inputs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inputs)


def restore(root, run_id=""):
    transfer = root / '.build/media-transfer'
    revision = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
    if run_id:
        spec = importlib.util.spec_from_file_location('asset_reuse', ROOT / 'ci/reuse-build-assets.py')
        reuse = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(reuse)
        branch = os.environ.get('GITHUB_REF_NAME') or reuse.git(root, 'branch', '--show-current')
        revision = reuse.verify_producer(root, run_id, 'media', branch)
    if (transfer / 'source-revision.txt').read_text().strip() != revision:
        raise ValueError('Media SDK source revision does not match this build')
    lines = (transfer / 'SHA256SUMS').read_text().splitlines()
    required = {'media-sdk.tar.gz', 'cerbero-1.28.6.tar.xz'}
    parsed = [re.fullmatch(r'[0-9a-f]{64}  ([a-zA-Z0-9.-]+)', line) for line in lines]
    if len(lines) != 2 or any(m is None for m in parsed) or {m[1] for m in parsed} != required:
        raise ValueError('Media checksum manifest must cover exactly SDK and source')
    if any((transfer / name).is_symlink() for name in required):
        raise ValueError('Media archives must not be symlinks')
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
    restore(ROOT, os.environ.get("MEDIA_RUN_ID", ""))
