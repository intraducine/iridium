#!/usr/bin/env python3
"""Discard verified transfer copies after their compiler stages are retained."""
from pathlib import Path
import shutil
import os
import argparse
import hashlib
import json
import subprocess
import sys
import re

ROOT = Path(__file__).resolve().parents[1]
TRANSFERS = ('media', 'native-compiled', 'wine-compiled', 'windows-compiled',
             'graphics-compiled', 'jit-compiled')

# Compiler outputs are already retained. App linking uses the finished archives,
# frameworks and DLLs, not their loose compilation objects.
OBJECT_TREES = (
    'testrepos/Madeira/toolchains/llvm-ios-build',
    'testrepos/Madeira/wine/build-macos',
    'testrepos/Madeira/wine/build-i386',
    'testrepos/Madeira/FEX/build-ios',
    'testrepos/Madeira/FEX/build-arm64ec',
    'testrepos/Madeira/FEX/build-wow64',
    'testrepos/Madeira/research/dxmt/build-arm64ec-ci',
    'testrepos/Madeira/research/dxmt/build-aarch64-ci',
    'testrepos/Madeira/research/dxmt/build-i386-ci',
    '.build/runtime-sources/angle/out/iridium-ios',
    '.build/idevice-target', '.build/StikJIT-derived',
)


NATIVE_OBJECT_TREES = (
    'vendor/Madeira/toolchains/llvm-ios-build',
    'vendor/Madeira/toolchains/llvm-host-build',
    'vendor/Madeira/FEX/build-ios',
    'vendor/Madeira/wine/build-macos',
    'vendor/Madeira/build/ffmpeg/obj',
    'vendor/Madeira/build/gnutls-ios/obj',
    'vendor/Madeira/build/win32u-unix/obj',
    'vendor/Madeira/build/dxmt-ios/obj',
)


def checked_path(root, path):
    if not path.resolve().is_relative_to(root.resolve()):
        raise ValueError('Cleanup target escapes checkout')
    for part in (path, *path.parents):
        if part == root: break
        if part.is_symlink(): raise ValueError('Cleanup target has a symlink parent')
    return path


def cleanup_ci_runtimes(root):
    # The fresh hosted VM belongs to this device-build job; no simulator runs here.
    if (os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted'
            or Path(os.environ.get('GITHUB_WORKSPACE', '/')).resolve() != root.resolve()
            or os.environ.get('IRIDIUM_CHROME_SIMULATOR')):
        raise ValueError('Runtime image cleanup requires this hosted device-build workspace')
    before = shutil.disk_usage(root).free
    target = 110 * 1024**3  # Reserve + native/Windows peaks + pinned inputs/staging.
    if before >= target: return
    devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'booted', '--json'], text=True))
    if any(device.get('state') == 'Booted' for group in devices['devices'].values() for device in group):
        raise ValueError('A simulator is active; keep its runtime images')
    sdks = [subprocess.check_output(['xcrun', '--sdk', name, '--show-sdk-path'], text=True).strip()
            for name in ('iphoneos', 'iphonesimulator')]
    if not all(Path(sdk).is_dir() for sdk in sdks): raise ValueError('Build SDKs must exist before runtime image cleanup')
    images = json.loads(subprocess.check_output(['xcrun', 'simctl', 'runtime', 'list', '--json'], text=True))
    identifiers = []
    for image in images.values():
        identifier = image['identifier']
        if (not re.fullmatch(r'[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}', identifier)
                or not image['runtimeIdentifier'].startswith('com.apple.CoreSimulator.SimRuntime.')):
            raise ValueError('Unexpected simulator runtime identifier')
        identifiers.append(identifier)
    removed = 0
    for identifier in identifiers:
        # Recheck immediately: runtime deletion must never shut down another task.
        devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'booted', '--json'], text=True))
        if any(device.get('state') == 'Booted' for group in devices['devices'].values() for device in group):
            raise ValueError('A simulator became active; keep remaining runtime images')
        subprocess.run(['xcrun', 'simctl', 'runtime', 'delete', identifier], check=True)
        removed += 1
        if shutil.disk_usage(root).free >= target: break
    current = [subprocess.check_output(['xcrun', '--sdk', name, '--show-sdk-path'], text=True).strip()
               for name in ('iphoneos', 'iphonesimulator')]
    if current != sdks or not all(Path(sdk).is_dir() for sdk in sdks):
        raise ValueError('Build SDK paths changed during runtime image cleanup')
    after = shutil.disk_usage(root).free
    print(f'Hosted device build removed {removed} unused simulator images; '
          f'free before={before} after={after} measured_reclaimed={max(0, after - before)} bytes', flush=True)
    if after < 40 * 1024**3:
        raise ValueError(f'Hosted build needs 20 GiB reserve plus 20 GiB working space; available={after / 1024**3:.2f} GiB')


def cleanup_native(root):
    # Only this ephemeral Actions workspace may discard its retained compiler objects.
    if os.environ.get('GITHUB_ACTIONS') != 'true' or Path(os.environ.get('GITHUB_WORKSPACE', '/')).resolve() != root.resolve():
        raise ValueError('Native phase cleanup requires its GitHub Actions workspace')
    subprocess.run([sys.executable, str(root / 'ci/madeira-frontend.py'), 'native', '--reuse-only'], check=True)
    transfer = checked_path(root, root / '.build/madeira-native-compiled-transfer')
    if not transfer.is_dir(): raise ValueError('Expected retained native transfer directory')
    objects = []
    for name in NATIVE_OBJECT_TREES:
        tree = checked_path(root, root / name)
        for directory, children, files in os.walk(tree, followlinks=False):
            children[:] = [name for name in children if not (Path(directory) / name).is_symlink()]
            objects.extend(checked_path(root, Path(directory) / name) for name in files
                           if Path(name).suffix in {'.o', '.obj'} and not (Path(directory) / name).is_symlink())
    archives = []
    for item in json.loads((root / 'ci/runtime-inputs.json').read_text()):
        if item['name'] not in {'llvm', 'llvm-mingw'}: continue
        archive = checked_path(root, root / '.build/runtime-downloads' / (item['sha256'] + '.tar'))
        if not archive.exists(): continue
        destination = checked_path(root, root / item['destination'].replace('testrepos/Madeira/', 'vendor/Madeira/', 1))
        if not archive.is_file() or not destination.is_dir(): raise ValueError('Toolchain archive has no extracted input')
        with archive.open('rb') as source:
            if hashlib.file_digest(source, 'sha256').hexdigest() != item['sha256']:
                raise ValueError('Toolchain archive checksum mismatch')
        archives.append(archive)
    before = shutil.disk_usage(root).free
    shutil.rmtree(checked_path(root, transfer))
    for path in objects + archives: checked_path(root, path).unlink()
    after = shutil.disk_usage(root).free
    print(f'Native checkpoint kept; removed {len(objects)} loose objects and {len(archives)} consumed archives. '
          f'Free before={before} after={after} measured_reclaimed={max(0, after - before)} bytes', flush=True)
    if after < 40 * 1024**3:
        raise ValueError(f'Windows build needs 20 GiB reserve plus 20 GiB working space; available={after / 1024**3:.2f} GiB')


def cleanup_madeira_module(root, upstream, name, key):
    # The caller has validated the completed module before releasing its objects.
    if (os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted'
            or Path(os.environ.get('GITHUB_WORKSPACE', '/')).resolve() != root.resolve()
            or os.environ.get('IRIDIUM_CHROME_SIMULATOR')):
        raise ValueError('Module cleanup requires its hosted device-build workspace')
    if upstream != root / 'vendor/Madeira' or not re.fullmatch('[0-9a-f]{64}', key):
        raise ValueError('Invalid completed module cleanup input')
    trees = {
        'windows': ('wine/build-arm64ec', 'wine/build-macos', 'dxmt/build-arm64ec',
                    'dxmt/build-aarch64', 'FEX/build-arm64ec', 'FEX/build-wow64'),
        'moltenvk': (),
        'zink': (f'toolchains/graphics/runtime-v1-zink-{key}/obj',),
        'mesa-d3d12': ('build/mesa-d3d12/work/build',),
        'vulkan-pe': ('toolchains/dxvk-build/arm64ec', 'toolchains/vkd3d-proton-build/arm64ec'),
        'kosmickrisp': (f'toolchains/graphics/runtime-v1-kosmickrisp-{key}/build-native', f'toolchains/graphics/runtime-v1-kosmickrisp-{key}/build-ios',
                        'toolchains/graphics/translator-build'),
        'i386': ('wine/build-i386', 'dxmt/build-pe-i386'),
    }
    if name not in trees: raise ValueError('Unknown completed module: ' + name)
    objects = []
    for relative in trees[name]:
        tree = checked_path(root, upstream / relative)
        for directory, children, files in os.walk(tree, followlinks=False):
            children[:] = [child for child in children if not (Path(directory) / child).is_symlink()]
            objects.extend(checked_path(root, Path(directory) / file) for file in files
                           if Path(file).suffix in {'.o', '.obj'} and not (Path(directory) / file).is_symlink())
    before = shutil.disk_usage(root).free
    for path in objects: checked_path(root, path).unlink()
    after = shutil.disk_usage(root).free
    print(f'Checked {name} module kept; removed {len(objects)} loose objects. '
          f'Free before={before} after={after} measured_reclaimed={max(0, after - before)} bytes', flush=True)


def cleanup(root):
    build = root / '.build'
    paths = [build / (name + '-transfer') for name in TRANSFERS]
    if build.is_symlink() or any(not path.is_dir() or path.is_symlink() for path in paths):
        raise ValueError('Expected regular build transfer directories')
    objects = []
    for name in OBJECT_TREES:
        tree = root / name
        if tree.is_symlink() or not tree.resolve().is_relative_to(root.resolve()):
            raise ValueError('Compiler object directory escapes checkout')
        for directory, children, files in os.walk(tree, followlinks=False):
            children[:] = [d for d in children if not (Path(directory) / d).is_symlink()]
            objects.extend(Path(directory) / f for f in files
                           if Path(f).suffix in {'.o', '.obj'} and not (Path(directory) / f).is_symlink())
    before = shutil.disk_usage(build).free
    for path in paths:
        shutil.rmtree(path)
    for path in objects:
        path.unlink()
    after = shutil.disk_usage(build).free
    print(f'Freed {max(0, after - before) // 1048576} MiB from transfer copies and {len(objects)} compiler objects; {after // 1048576} MiB free')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--madeira-native', action='store_true')
    mode.add_argument('--hosted-device-build', action='store_true')
    args = parser.parse_args()
    if args.hosted_device_build: cleanup_ci_runtimes(ROOT)
    elif args.madeira_native: cleanup_native(ROOT)
    else: cleanup(ROOT)
