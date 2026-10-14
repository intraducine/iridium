#!/usr/bin/env python3
"""Manually build the pinned selected codecs for this Mac and run a real decode."""
import argparse
import importlib.util
from pathlib import Path
import platform
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'ci'))
spec = importlib.util.spec_from_file_location('native_codec_builder', ROOT / 'ci/build-ppsspp-native.py')
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        parser.error('Run this explicit check on an Apple Silicon Mac')
    source = ROOT / 'vendor/PPSSPP'
    native.revisions(source)
    destination = args.output.resolve()
    if source in destination.parents: parser.error('Outputs must stay outside upstream source')
    native.ffmpeg(source / 'ffmpeg', destination, 'macosx', 4)
    executable = destination / 'check-codec'
    native.run('xcrun', '--sdk', 'macosx', 'clang', '-target', 'arm64-apple-macos14.0',
        '-I' + str(destination / 'ffmpeg/include'),
        native.NATIVE / 'IRPPSSPPCodecCheck.c', ROOT / 'ci/psp/check_codec.c',
        destination / 'ffmpeg/lib/libavcodec.a', destination / 'ffmpeg/lib/libavutil.a',
        '-lm', '-lz', '-o', executable)
    native.run(executable)
