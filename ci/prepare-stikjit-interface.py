#!/usr/bin/env python3
"""Repair and import-check StikJIT's generated Swift interface, not its binary."""
from pathlib import Path
import shutil
import subprocess
import tempfile


def repair(framework):
    interfaces = list(framework.rglob('*.swiftinterface'))
    if not interfaces:
        raise ValueError('StikJIT Swift interfaces are missing')
    for path in interfaces:
        text = path.read_text()
        # The first :: selects the module; nested types require a dot.
        corrected = text.replace('StikJIT::StikJIT::', 'StikJIT::StikJIT.')
        if corrected != text:
            path.write_text(corrected)


def verify(framework):
    with tempfile.TemporaryDirectory(prefix='iridium-stik-import-') as directory:
        root = Path(directory)
        copied = root / 'StikJIT.framework'
        shutil.copytree(framework, copied)
        # Force textual import instead of accepting a cached serialized module.
        for path in (copied / 'Modules/StikJIT.swiftmodule').glob('*.swiftmodule'):
            path.unlink()
        probe = root / 'probe.swift'
        probe.write_text('import StikJIT\nlet configuration = StikJIT.Configuration.default\n'
                         'let script = StikJIT.Script.universal\n'
                         'let paths = DDIPaths(imagePath: "", trustcachePath: "", manifestPath: "")\n')
        sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
        subprocess.run(['xcrun', 'swiftc', '-typecheck', '-target', 'arm64-apple-ios27.0',
                        '-sdk', sdk, '-F', str(root), '-module-cache-path', str(root / 'cache'),
                        str(probe)], check=True)


if __name__ == '__main__':
    root = Path(__file__).resolve().parents[1]
    framework = root / 'iridium/apps/ios/BuiltinJIT/Vendor/StikJIT.xcframework/ios-arm64/StikJIT.framework'
    repair(framework)
    verify(framework)
    print('StikJIT textual interfaces import successfully; framework binary unchanged.')
